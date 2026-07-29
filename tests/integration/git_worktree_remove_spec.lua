local git_cli = require("vigit.adapters.git_cli")
local process = require("vigit.adapters.process")
local Worktrees = require("vigit.application.worktrees")
local Result = require("vigit.core.result")

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

local function remove(path)
  return vim.fn.delete(path, "rf") == 0
end

local function workspace()
  local root = vim.fn.tempname()
  assert_equal(vim.fn.mkdir(root, "p"), 1)
  register_cleanup(function() return remove(root) end)
  local primary = root .. "/primary"
  local linked = root .. "/linked"
  local unrelated = root .. "/unrelated"
  local remote = root .. "/origin.git"
  run({ "git", "init", "-q", primary }, { text = false })
  git(primary, { "config", "user.name", "Vigit Tests" })
  git(primary, { "config", "user.email", "vigit@example.invalid" })
  assert_equal(vim.fn.writefile({ "base" }, primary .. "/base.txt"), 0)
  git(primary, { "add", "--", "base.txt" })
  git(primary, { "commit", "-q", "-m", "base" })
  git(primary, { "branch", "-M", "main" })
  run({ "git", "init", "-q", "--bare", remote }, { text = false })
  git(primary, { "remote", "add", "origin", remote })
  git(primary, { "push", "-q", "-u", "origin", "main" })
  git(primary, { "worktree", "add", "-q", "-b", "linked", linked, "main" })
  git(linked, { "push", "-q", "-u", "origin", "linked" })
  git(primary, { "worktree", "add", "-q", "-b", "unrelated", unrelated, "main" })
  return { primary = primary, linked = linked, unrelated = unrelated }
end

it("удаляет linked worktree из primary root и сохраняет branch ref", function(done)
  local state = workspace()
  local commands = {}
  local adapter = git_cli.new({
    run = function(args, opts, callback)
      commands[#commands + 1] = { args = vim.deepcopy(args), cwd = opts.cwd }
      return process.run(args, opts, callback)
    end,
  })

  adapter:remove_worktree(state.primary, state.linked, function(result)
    assert_truthy(result.ok)
    assert_equal(vim.fn.isdirectory(state.linked), 0)
    local listed = git(state.primary, { "worktree", "list", "--porcelain" })
    assert_truthy((listed.stdout or ""):find(state.linked, 1, true) == nil)
    git(state.primary, { "show-ref", "--verify", "--quiet", "refs/heads/linked" })
    local remove_command
    for _, command in ipairs(commands) do
      if command.args[4] == "worktree" and command.args[5] == "remove" then
        remove_command = command
        break
      end
    end
    assert_truthy(remove_command ~= nil)
    assert_equal(#remove_command.args, 7)
    assert_equal(remove_command.args[1], "git")
    assert_equal(remove_command.args[2], "-C")
    assert_equal(remove_command.args[3], state.primary)
    assert_equal(remove_command.args[4], "worktree")
    assert_equal(remove_command.args[5], "remove")
    assert_equal(remove_command.args[6], "--")
    assert_equal(remove_command.args[7], state.linked)
    assert_equal(remove_command.cwd, nil)
    done()
  end)
end)

it("возвращает git_failed при неуспешном процессе удаления", function(done)
  local adapter = git_cli.new({
    run = function(_, _, callback)
      callback({
        ok = false,
        error = { code = "process_failed", message = "Process exited with code 128", details = "denied" },
      })
      return { cancel = function() end }
    end,
  })
  adapter:remove_worktree("/repo", "/repo/linked", function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "git_failed")
    done()
  end)
end)

it("принимает remove completion только один раз и подавляет callback после cancel", function(done)
  local active
  local adapter = git_cli.new({
    run = function(_, _, callback)
      active = callback
      return { cancel = function() end }
    end,
  })
  local callbacks = 0
  adapter:remove_worktree("/repo", "/repo/linked", function()
    callbacks = callbacks + 1
  end)
  active({ ok = true, value = {} })
  active({ ok = true, value = {} })
  assert_equal(callbacks, 1)

  local cancelled_callbacks = 0
  local request = adapter:remove_worktree("/repo", "/repo/linked", function()
    cancelled_callbacks = cancelled_callbacks + 1
  end)
  request.cancel()
  active({ ok = true, value = {} })
  assert_equal(cancelled_callbacks, 0)
  done()
end)

it("повторный preflight отменяет remove при dirty race и сохраняет primary, unrelated и branch", function(done)
  local state = workspace()
  local confirmations = {}
  local remove_calls = 0
  local adapter = git_cli.new({
    run = function(args, opts, callback)
      if args[4] == "worktree" and args[5] == "remove" then
        remove_calls = remove_calls + 1
      end
      return process.run(args, opts, callback)
    end,
  })
  local app = Worktrees.new({
    git = adapter,
    neovim = { loaded_source_buffers = function() return Result.ok({}) end },
    confirm = function(_, callback)
      confirmations[#confirmations + 1] = callback
      return { cancel = function() end }
    end,
  })
  local entry = {
    kind = "linked",
    path = state.linked,
    head = vim.trim(git(state.linked, { "rev-parse", "HEAD" }).stdout),
    branch_ref = "refs/heads/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local first

  app:remove(entry, function(result) first = result end)
  assert_equal(#confirmations, 1)
  assert_equal(vim.fn.writefile({ "dirty" }, state.linked .. "/race.txt"), 0)
  confirmations[1](true)
  assert_truthy(vim.wait(2000, function() return first ~= nil end, 10))
  assert_equal(first.ok, false)
  assert_equal(first.error.code, "dirty")
  assert_equal(remove_calls, 0)

  git(state.linked, { "clean", "-fd" })
  local second
  app:remove(entry, function(result) second = result end)
  assert_equal(#confirmations, 2)
  confirmations[2](true)
  assert_truthy(vim.wait(2000, function() return second ~= nil end, 10))
  assert_truthy(second.ok)
  assert_equal(remove_calls, 1)
  assert_equal(vim.fn.isdirectory(state.linked), 0)
  assert_equal(vim.fn.isdirectory(state.primary), 1)
  assert_equal(vim.fn.isdirectory(state.unrelated), 1)
  git(state.primary, { "show-ref", "--verify", "--quiet", "refs/heads/linked" })
  local listed = git(state.primary, { "worktree", "list", "--porcelain" })
  assert_truthy((listed.stdout or ""):find(state.linked, 1, true) == nil)
  assert_truthy((listed.stdout or ""):find(state.unrelated, 1, true) ~= nil)
  done()
end)
