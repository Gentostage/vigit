local git_cli = require("vigit.adapters.git_cli")
local process = require("vigit.adapters.process")

local function run(args, opts)
  local result = vim.system(args, opts or { text = false }):wait()
  if result.code ~= 0 then
    error(string.format("command failed (%s): %s", table.concat(args, " "), result.stderr or ""))
  end
  return result
end

local function git(root, args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  return run(command, { text = false })
end

local function write(root, path, lines)
  assert_equal(vim.fn.mkdir(vim.fs.dirname(root .. "/" .. path), "p"), 1)
  assert_equal(vim.fn.writefile(lines, root .. "/" .. path), 0)
end

local function remove(path)
  return vim.fn.delete(path, "rf") == 0
end

local function workspace()
  local root = vim.fn.tempname()
  assert_equal(vim.fn.mkdir(root, "p"), 1)
  register_cleanup(function() return remove(root) end)
  local primary = root .. "/primary"
  local remote = root .. "/origin.git"
  run({ "git", "init", "-q", primary }, { text = false })
  git(primary, { "config", "user.name", "Vigit Tests" })
  git(primary, { "config", "user.email", "vigit@example.invalid" })
  write(primary, "base.txt", { "base" })
  git(primary, { "add", "--", "base.txt" })
  git(primary, { "commit", "-q", "-m", "base" })
  git(primary, { "branch", "-M", "main" })
  run({ "git", "init", "-q", "--bare", remote }, { text = false })
  git(primary, { "remote", "add", "origin", remote })
  git(primary, { "push", "-q", "-u", "origin", "main" })
  return { root = root, primary = primary, remote = remote }
end

local function add_worktree(state, name)
  local path = state.root .. "/" .. name
  git(state.primary, { "worktree", "add", "-q", "-b", name, path, "main" })
  return path
end

local function push_upstream(path, name)
  git(path, { "push", "-q", "-u", "origin", name })
end

local function remote_commit(state, branch, file)
  local writer = state.root .. "/writer-" .. branch:gsub("/", "-")
  run({ "git", "clone", "-q", "--branch", branch, state.remote, writer }, { text = false })
  git(writer, { "config", "user.name", "Vigit Tests" })
  git(writer, { "config", "user.email", "vigit@example.invalid" })
  write(writer, file, { "remote" })
  git(writer, { "add", "--", file })
  git(writer, { "commit", "-q", "-m", "remote" })
  git(writer, { "push", "-q", "origin", branch })
  remove(writer)
end

local function recording_process(commands)
  return {
    run = function(args, opts, callback)
      commands[#commands + 1] = vim.deepcopy(args)
      return process.run(args, opts, callback)
    end,
  }
end

local function contains_fetch(commands)
  for _, args in ipairs(commands) do
    for _, arg in ipairs(args) do
      if arg == "fetch" then
        return true
      end
    end
  end
  return false
end

it("lists root linked detached and locked worktrees without fetching", function(done)
  local state = workspace()
  local clean = add_worktree(state, "clean")
  local detached = state.root .. "/detached"
  local locked = add_worktree(state, "locked")
  git(state.primary, { "worktree", "add", "-q", "--detach", detached, "main" })
  git(state.primary, { "worktree", "lock", "--reason", "maintenance", locked })
  local commands = {}

  git_cli.new(recording_process(commands)):worktrees(state.primary, function(result)
    assert_truthy(result.ok)
    assert_equal(result.value[1].path, state.primary)
    assert_equal(result.value[1].kind, "root")
    local entries = {}
    for _, entry in ipairs(result.value) do entries[entry.path] = entry end
    assert_equal(entries[clean].kind, "linked")
    assert_equal(entries[detached].detached, true)
    assert_equal(entries[locked].locked, "maintenance")
    assert_equal(contains_fetch(commands), false)
    done()
  end)
end)

it("counts staged unstaged and untracked worktree changes without fetching", function(done)
  local state = workspace()
  local dirty = add_worktree(state, "dirty")
  write(dirty, "base.txt", { "staged" })
  git(dirty, { "add", "--", "base.txt" })
  write(dirty, "base.txt", { "unstaged" })
  write(dirty, "untracked.txt", { "untracked" })
  local commands = {}

  git_cli.new(recording_process(commands)):worktree_status(dirty, function(result)
    assert_equal(result.value.staged, 1)
    assert_equal(result.value.unstaged, 1)
    assert_equal(result.value.untracked, 1)
    assert_equal(result.value.dirty, true)
    assert_equal(contains_fetch(commands), false)
    done()
  end)
end)

it("returns typed tracking detached and no-upstream states with divergence counts", function(done)
  local state = workspace()
  local equal = add_worktree(state, "equal")
  local ahead = add_worktree(state, "ahead")
  local behind = add_worktree(state, "behind")
  local diverged = add_worktree(state, "diverged")
  local no_upstream = add_worktree(state, "no-upstream")
  local detached = state.root .. "/detached"
  for name, path in pairs({ equal = equal, ahead = ahead, behind = behind, diverged = diverged }) do
    push_upstream(path, name)
  end
  write(ahead, "ahead.txt", { "ahead" })
  git(ahead, { "add", "--", "ahead.txt" })
  git(ahead, { "commit", "-q", "-m", "ahead" })
  remote_commit(state, "behind", "behind.txt")
  write(diverged, "local.txt", { "local" })
  git(diverged, { "add", "--", "local.txt" })
  git(diverged, { "commit", "-q", "-m", "local" })
  remote_commit(state, "diverged", "remote.txt")
  git(state.primary, { "fetch", "-q", "origin" })
  git(state.primary, { "worktree", "add", "-q", "--detach", detached, "main" })
  local commands = {}
  local adapter = git_cli.new(recording_process(commands))

  adapter:upstream(equal, function(equal_result)
    adapter:upstream(ahead, function(ahead_result)
      adapter:upstream(behind, function(behind_result)
        adapter:upstream(diverged, function(diverged_result)
          adapter:upstream(detached, function(detached_result)
            adapter:upstream(no_upstream, function(no_upstream_result)
              assert_equal(equal_result.value.state, "tracking")
              assert_equal(equal_result.value.name, "origin/equal")
              assert_equal(equal_result.value.remote, "origin")
              assert_equal(equal_result.value.source, "local_refs")
              assert_equal(equal_result.value.ahead, 0)
              assert_equal(equal_result.value.behind, 0)
              assert_equal(ahead_result.value.ahead, 1)
              assert_equal(ahead_result.value.behind, 0)
              assert_equal(behind_result.value.ahead, 0)
              assert_equal(behind_result.value.behind, 1)
              assert_equal(diverged_result.value.ahead, 1)
              assert_equal(diverged_result.value.behind, 1)
              assert_equal(detached_result.value.state, "detached")
              assert_equal(no_upstream_result.value.state, "no_upstream")
              assert_equal(contains_fetch(commands), false)
              done()
            end)
          end)
        end)
      end)
    end)
  end)
end)

it("fetches only when explicitly requested and uses the upstream remote", function(done)
  local state = workspace()
  local linked = add_worktree(state, "tracked")
  push_upstream(linked, "tracked")
  local commands = {}
  local callbacks = 0

  git_cli.new(recording_process(commands)):fetch(linked, function(result)
    callbacks = callbacks + 1
    assert_truthy(result.ok)
    local fetches = {}
    for _, command in ipairs(commands) do
      if command[4] == "fetch" then fetches[#fetches + 1] = command end
    end
    assert_equal(#fetches, 1)
    local fetch = fetches[1]
    assert_equal(fetch[1], "git")
    assert_equal(fetch[2], "-C")
    assert_equal(fetch[3], linked)
    assert_equal(fetch[4], "fetch")
    assert_equal(fetch[5], "--prune")
    assert_equal(fetch[6], "origin")
    vim.defer_fn(function()
      assert_equal(callbacks, 1)
      done()
    end, 20)
  end)
end)

it("rejects truncated NUL status output before returning counts", function(done)
  local fake_process = {
    run = function(_, _, callback)
      callback({ ok = true, value = { stdout = "# branch.oid abc" } })
      return { cancel = function() end }
    end,
  }

  git_cli.new(fake_process):worktree_status("/repo", function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "malformed_status")
    done()
  end)
end)

it("resolves a slash-containing configured remote instead of an ambiguous ref prefix", function(done)
  local state = workspace()
  local linked = add_worktree(state, "slash")
  git(linked, { "remote", "add", "team", state.remote })
  git(linked, { "remote", "add", "team/origin", state.remote })
  git(linked, { "config", "remote.team.fetch", "+refs/heads/*:refs/remotes/team-prefix/*" })
  git(linked, { "fetch", "-q", "team/origin" })
  git(linked, { "branch", "--set-upstream-to=team/origin/main", "slash" })

  git_cli.new(process):upstream(linked, function(result)
    assert_truthy(result.ok)
    assert_equal(result.value.state, "tracking")
    assert_equal(result.value.name, "team/origin/main")
    assert_equal(result.value.remote, "team/origin")
    assert_equal(result.value.source, "local_refs")
    done()
  end)
end)

it("accepts Git's ambiguous upstream confirmation spelling", function(done)
  local state = workspace()
  local linked = add_worktree(state, "ambiguous")
  git(linked, { "branch", "origin/main", "main" })
  git(linked, { "config", "branch.ambiguous.remote", "origin" })
  git(linked, { "config", "branch.ambiguous.merge", "refs/heads/main" })

  local raw = git(linked, {
    "rev-parse",
    "--abbrev-ref",
    "--symbolic-full-name",
    "@{upstream}",
  })
  local raw_value = (raw.stdout or ""):gsub("[\r\n]+$", "")
  assert_equal(raw_value, "remotes/origin/main")

  git_cli.new(process):upstream(linked, function(result)
    assert_truthy(result.ok)
    assert_equal(result.value.state, "tracking")
    assert_equal(result.value.name, "origin/main")
    assert_equal(result.value.remote, "origin")
    done()
  end)
end)

it("maps local-dot and unborn attached branches to successful no-upstream", function(done)
  local state = workspace()
  local linked = add_worktree(state, "dot")
  git(linked, { "config", "branch.dot.remote", "." })
  git(linked, { "config", "branch.dot.merge", "refs/heads/main" })
  local unborn = vim.fn.tempname()
  assert_equal(vim.fn.mkdir(unborn, "p"), 1)
  register_cleanup(function() return remove(unborn) end)
  run({ "git", "init", "-q", unborn }, { text = false })
  local adapter = git_cli.new(process)

  adapter:upstream(linked, function(dot_result)
    adapter:upstream(unborn, function(unborn_result)
      assert_equal(dot_result.value.state, "no_upstream")
      assert_equal(unborn_result.value.state, "no_upstream")
      done()
    end)
  end)
end)

local function includes(args, value)
  for _, arg in ipairs(args) do
    if arg == value then return true end
  end
  return false
end

it("returns a typed Git error for nonsemantic symbolic-ref failure", function(done)
  local fake_process = {
    run = function(_, _, callback)
      callback({
        ok = false,
        error = {
          code = "process_failed",
          message = "Process exited with code 128",
          details = "fatal: not a git repository",
        },
      })
      return { cancel = function() end }
    end,
  }

  git_cli.new(fake_process):upstream("/missing", function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "git_upstream_failed")
    done()
  end)
end)

it("returns a typed Git error when upstream metadata query fails", function(done)
  local fake_process = {
    run = function(args, _, callback)
      if includes(args, "symbolic-ref") then
        callback({ ok = true, value = { stdout = "feature\n" } })
      else
        callback({
          ok = false,
          error = {
            code = "process_failed",
            message = "Process exited with code 128",
            details = "fatal: cannot read git metadata",
          },
        })
      end
      return { cancel = function() end }
    end,
  }

  git_cli.new(fake_process):upstream("/repo", function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "git_upstream_failed")
    done()
  end)
end)

it("returns a typed Git error for a real missing repository root", function(done)
  git_cli.new(process):upstream(vim.fn.tempname(), function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "git_upstream_failed")
    done()
  end)
end)

local function exact_command(args, expected)
  if #args ~= #expected then return false end
  for index, value in ipairs(expected) do
    if args[index] ~= value then return false end
  end
  return true
end

local function confirmation_process()
  local calls = {}
  local active = {}
  local cancels = {}
  return {
    run = function(args, _, callback)
      calls[#calls + 1] = vim.deepcopy(args)
      if includes(args, "symbolic-ref") then
        callback({ ok = true, value = { stdout = "feature\n" } })
      elseif includes(args, "for-each-ref") then
        callback({ ok = true, value = { stdout = "refs/remotes/team/origin/feature\tteam/origin/feature\tteam/origin\n" } })
      elseif includes(args, "@{upstream}") then
        active.confirmation = callback
        return {
          cancel = function() cancels.confirmation = (cancels.confirmation or 0) + 1 end,
        }
      elseif includes(args, "rev-list") then
        callback({ ok = true, value = { stdout = "0\t0\n" } })
      else
        error("unexpected command")
      end
      return { cancel = function() end }
    end,
    active = active,
    calls = calls,
    cancels = cancels,
  }
end

it("confirms a real remote-tracking upstream with the literal rev-parse before rev-list", function(done)
  local fake = confirmation_process()
  git_cli.new(fake):upstream("/repo", function(result)
    assert_truthy(result.ok)
    local confirmation_index
    local rev_list_index
    for index, args in ipairs(fake.calls) do
      if exact_command(args, {
        "git", "-C", "/repo", "rev-parse", "--abbrev-ref",
        "--symbolic-full-name", "@{upstream}",
      }) then
        confirmation_index = index
      elseif includes(args, "rev-list") then
        rev_list_index = index
      end
    end
    assert_truthy(confirmation_index)
    assert_truthy(rev_list_index)
    assert_truthy(confirmation_index < rev_list_index)
    done()
  end)
  assert_truthy(fake.active.confirmation)
  fake.active.confirmation({ ok = true, value = { stdout = "team/origin/feature\n" } })
end)

it("propagates a literal upstream confirmation process failure", function(done)
  local fake = confirmation_process()
  git_cli.new(fake):upstream("/repo", function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "git_upstream_failed")
    done()
  end)
  assert_truthy(fake.active.confirmation)
  fake.active.confirmation({
    ok = false,
    error = {
      code = "process_failed",
      message = "Process exited with code 128",
      details = "fatal: confirmation failed",
    },
  })
end)

it("rejects empty successful literal upstream confirmation", function(done)
  local fake = confirmation_process()
  git_cli.new(fake):upstream("/repo", function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "malformed_upstream")
    done()
  end)
  assert_truthy(fake.active.confirmation)
  fake.active.confirmation({ ok = true, value = { stdout = "" } })
end)

it("cancels the active literal upstream confirmation phase", function(done)
  local fake = confirmation_process()
  local callbacks = 0
  local operation = git_cli.new(fake):upstream("/repo", function()
    callbacks = callbacks + 1
  end)
  assert_truthy(fake.active.confirmation)
  operation.cancel()
  assert_equal(fake.cancels.confirmation, 1)
  fake.active.confirmation({ ok = true, value = { stdout = "team/origin/feature\n" } })
  assert_equal(callbacks, 0)
  done()
end)

local function fake_upstream_process()
  local active = {}
  local cancels = {}
  local function starts(args, value)
    for _, arg in ipairs(args) do
      if arg == value then return true end
    end
    return false
  end
  return {
    run = function(args, _, callback)
      local phase
      if starts(args, "symbolic-ref") then
        phase = "symbolic_ref"
      elseif starts(args, "for-each-ref") then
        phase = "upstream_metadata"
      elseif starts(args, "@{upstream}") then
        phase = "upstream_confirmation"
      elseif starts(args, "rev-list") then
        phase = "rev_list"
      else
        error("unexpected command")
      end
      active[phase] = callback
      return {
        cancel = function() cancels[phase] = (cancels[phase] or 0) + 1 end,
      }
    end,
    active = active,
    cancels = cancels,
  }
end

local function drive_tracking(fake)
  if fake.active.symbolic_ref then
    fake.active.symbolic_ref({ ok = true, value = { stdout = "feature\n" } })
  end
  fake.active.upstream_metadata({ ok = true, value = { stdout = "refs/remotes/team/origin/feature\tteam/origin/feature\tteam/origin\n" } })
  fake.active.upstream_confirmation({ ok = true, value = { stdout = "team/origin/feature\n" } })
end

it("cancels an active upstream rev-list phase and suppresses its callback", function(done)
  local fake = fake_upstream_process()
  local callbacks = 0
  local operation = git_cli.new(fake):upstream("/repo", function()
    callbacks = callbacks + 1
  end)
  drive_tracking(fake)

  operation.cancel()
  assert_equal(fake.cancels.rev_list, 1)
  fake.active.rev_list({ ok = true, value = { stdout = "0\t0\n" } })
  assert_equal(callbacks, 0)
  done()
end)

it("cancels every active upstream process phase", function(done)
  local phases = {
    "symbolic_ref",
    "upstream_metadata",
    "upstream_confirmation",
    "rev_list",
  }
  for _, phase in ipairs(phases) do
    local fake = fake_upstream_process()
    local operation = git_cli.new(fake):upstream("/repo", function() end)
    if phase == "upstream_metadata" or phase == "upstream_confirmation" or phase == "rev_list" then
      fake.active.symbolic_ref({ ok = true, value = { stdout = "feature\n" } })
    end
    if phase == "upstream_confirmation" or phase == "rev_list" then
      fake.active.upstream_metadata({ ok = true, value = { stdout = "refs/remotes/team/origin/feature\tteam/origin/feature\tteam/origin\n" } })
    end
    if phase == "rev_list" then
      fake.active.upstream_confirmation({ ok = true, value = { stdout = "team/origin/feature\n" } })
    end
    operation.cancel()
    assert_equal(fake.cancels[phase], 1)
  end
  done()
end)

it("delivers an upstream completion at most once when a process callback repeats", function(done)
  local fake = fake_upstream_process()
  local callbacks = 0
  git_cli.new(fake):upstream("/repo", function(result)
    assert_truthy(result.ok)
    callbacks = callbacks + 1
  end)
  drive_tracking(fake)
  local result = { ok = true, value = { stdout = "0\t0\n" } }
  fake.active.rev_list(result)
  fake.active.rev_list(result)
  assert_equal(callbacks, 1)
  done()
end)
