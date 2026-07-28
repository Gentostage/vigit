local git_cli = require("vigit.adapters.git_cli")
local process = require("vigit.adapters.process")
local Result = require("vigit.core.result")
local git_repo = dofile("tests/fixtures/git_repo.lua")

local function find_change(changes, path)
  for _, change in ipairs(changes or {}) do
    if change.path == path then
      return change
    end
  end
end

local function command_output(root, args)
  local result = vim.system(args, { cwd = root, text = false }):wait()
  assert_equal(result.code, 0)
  return result.stdout or ""
end

local function file_bytes(root, path)
  local handle = io.open(root .. "/" .. path, "rb")
  if not handle then
    return false
  end
  local bytes = handle:read("*a")
  handle:close()
  return bytes
end

local function snapshot(root, path)
  return {
    bytes = file_bytes(root, path),
    index = command_output(root, { "git", "ls-files", "-s", "--", path }),
    status = command_output(root, {
      "git", "status", "--porcelain=v2", "-z", "--untracked-files=all",
    }),
  }
end

local function assert_snapshot_equal(actual, expected)
  assert_equal(actual.bytes, expected.bytes)
  assert_equal(actual.index, expected.index)
  assert_equal(actual.status, expected.status)
end

local function status(git, root, callback)
  git:status(root, function(result)
    assert_truthy(result.ok)
    callback(result.value)
  end)
end

local function diff(git, root, change, callback)
  git:diff(root, change, 1, 1024 * 1024, function(result)
    assert_truthy(result.ok)
    callback(result.value)
  end)
end

local function hunk_with(diff_model, kind, text)
  for _, hunk in ipairs(diff_model.hunks or {}) do
    for _, line in ipairs(hunk.lines or {}) do
      if line.kind == kind and line.text == text then
        return hunk
      end
    end
  end
end

local function assert_clean(git, repo, path, done)
  status(git, repo.root, function(current)
    assert_equal(find_change(current.staged, path), nil)
    assert_equal(find_change(current.unstaged, path), nil)
    repo:cleanup()
    done()
  end)
end

it("restores only the selected unstaged hunk and leaves index bytes unchanged", function(done)
  local repo = git_repo.new()
  repo:write("hunks.txt", { "one", "two", "three", "four", "five", "six", "seven", "eight" })
  repo:git({ "add", "--", "hunks.txt" })
  repo:commit("base")
  repo:write("hunks.txt", { "one", "two changed", "three", "four", "five", "six", "seven changed", "eight" })
  local git = git_cli.new(process)
  local before_index = command_output(repo.root, { "git", "ls-files", "-s", "--", "hunks.txt" })

  status(git, repo.root, function(current)
    local change = find_change(current.unstaged, "hunks.txt")
    diff(git, repo.root, change, function(file_diff)
      git:restore_hunk(repo.root, file_diff, hunk_with(file_diff, "add", "two changed"), function(result)
        assert_truthy(result.ok)
        assert_equal(command_output(repo.root, { "git", "ls-files", "-s", "--", "hunks.txt" }), before_index)
        assert_equal(file_bytes(repo.root, "hunks.txt"), "one\ntwo\nthree\nfour\nfive\nsix\nseven changed\neight\n")
        repo:cleanup()
        done()
      end)
    end)
  end)
end)

it("returns patch_conflict without changing worktree or index when an unstaged hunk is stale", function(done)
  local repo = git_repo.new()
  repo:write("stale.txt", { "one", "two", "three" })
  repo:git({ "add", "--", "stale.txt" })
  repo:commit("base")
  repo:write("stale.txt", { "one", "two changed", "three" })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    local change = find_change(current.unstaged, "stale.txt")
    diff(git, repo.root, change, function(file_diff)
      repo:write("stale.txt", { "one", "two changed again", "three" })
      local before = snapshot(repo.root, "stale.txt")
      git:restore_hunk(repo.root, file_diff, file_diff.hunks[1], function(result)
        assert_equal(result.ok, false)
        assert_equal(result.error.code, "patch_conflict")
        assert_snapshot_equal(snapshot(repo.root, "stale.txt"), before)
        repo:cleanup()
        done()
      end)
    end)
  end)
end)

it("rejects a staged hunk before spawning a process", function(done)
  local calls = 0
  local git = git_cli.new({
    run = function()
      calls = calls + 1
    end,
  })
  git:restore_hunk("/repo", {
    section = "staged",
    path = "file.txt",
    hunks = { { id = "hunk", patch = "@@ -1 +1 @@\n-old\n+new" } },
  }, { id = "hunk", patch = "@@ -1 +1 @@\n-old\n+new" }, function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "unstage_first")
    assert_equal(calls, 0)
    done()
  end)
end)

it("restores an unstaged tracked file from the index", function(done)
  local repo = git_repo.new()
  repo:write("tracked.txt", "base\n")
  local base_bytes = file_bytes(repo.root, "tracked.txt")
  repo:git({ "add", "--", "tracked.txt" })
  repo:commit("base")
  repo:write("tracked.txt", "worktree\n")
  local git = git_cli.new(process)
  status(git, repo.root, function(current)
    git:restore_file(repo.root, find_change(current.unstaged, "tracked.txt"), function(result)
      assert_truthy(result.ok)
      assert_equal(file_bytes(repo.root, "tracked.txt"), base_bytes)
      assert_clean(git, repo, "tracked.txt", done)
    end)
  end)
end)

it("restores mixed tracked index and worktree state from HEAD", function(done)
  local repo = git_repo.new()
  repo:write("mixed.txt", "base\n")
  local base_bytes = file_bytes(repo.root, "mixed.txt")
  repo:git({ "add", "--", "mixed.txt" })
  repo:commit("base")
  repo:write("mixed.txt", "index\n")
  repo:git({ "add", "--", "mixed.txt" })
  repo:write("mixed.txt", "worktree\n")
  local git = git_cli.new(process)
  status(git, repo.root, function(current)
    git:restore_file(repo.root, find_change(current.unstaged, "mixed.txt"), function(result)
      assert_truthy(result.ok)
      assert_equal(file_bytes(repo.root, "mixed.txt"), base_bytes)
      assert_clean(git, repo, "mixed.txt", done)
    end)
  end)
end)

it("removes a staged added file from index and worktree", function(done)
  local repo = git_repo.new()
  repo:write("base.txt", "base\n")
  repo:git({ "add", "--", "base.txt" })
  repo:commit("base")
  repo:write("added.txt", "added\n")
  repo:git({ "add", "--", "added.txt" })
  local git = git_cli.new(process)
  status(git, repo.root, function(current)
    git:restore_file(repo.root, find_change(current.staged, "added.txt"), function(result)
      assert_truthy(result.ok)
      assert_equal(file_bytes(repo.root, "added.txt"), false)
      assert_clean(git, repo, "added.txt", done)
    end)
  end)
end)

it("removes an unborn staged magic-path addition atomically from index and worktree", function(done)
  local repo = git_repo.new()
  local target = ":(glob)unborn*.txt"
  repo:write(target, "added before the first commit\n")
  repo:git({ "--literal-pathspecs", "add", "--", target })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    assert_equal(current.branch.oid, nil)
    local change = find_change(current.staged, target)
    assert_truthy(change)
    git:restore_file(repo.root, change, function(result)
      assert_truthy(result.ok)
      status(git, repo.root, function(after)
        assert_equal(file_bytes(repo.root, target), false)
        assert_equal(command_output(repo.root, { "git", "ls-files", "-s", "--", target }), "")
        assert_equal(find_change(after.staged, target), nil)
        assert_equal(find_change(after.unstaged, target), nil)
        repo:cleanup()
        done()
      end)
    end)
  end)
end)

it("removes an unborn staged addition with later worktree edits", function(done)
  local repo = git_repo.new()
  local target = "mixed addition.txt"
  repo:write(target, "indexed bytes\n")
  repo:git({ "add", "--", target })
  repo:write(target, "worktree bytes after staging\n")
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    assert_equal(current.branch.oid, nil)
    assert_truthy(find_change(current.staged, target))
    local change = find_change(current.unstaged, target)
    assert_truthy(change)
    git:restore_file(repo.root, change, function(result)
      assert_truthy(result.ok)
      assert_clean(git, repo, target, done)
    end)
  end)
end)

it("refuses an unborn staged gitlink without touching nested data or git metadata", function(done)
  local repo, source = git_repo.new(), git_repo.new()
  local ok, message = xpcall(function()
    source:write("tracked.txt", "submodule base\n")
    source:git({ "add", "--", "tracked.txt" })
    source:commit("base")
    repo:git({ "-c", "protocol.file.allow=always", "submodule", "add", "--", source.root, "nested/module" })
    repo:write("nested/module/keep-untracked.txt", "must survive\n")
    local before = {
      gitmodules = file_bytes(repo.root, ".gitmodules"),
      nested = file_bytes(repo.root, "nested/module/keep-untracked.txt"),
      index = command_output(repo.root, { "git", "ls-files", "--stage", "-z", "--" }),
      status = command_output(repo.root, { "git", "status", "--porcelain=v2", "-z", "--untracked-files=all" }),
    }
    local git = git_cli.new(process)
    status(git, repo.root, function(current)
      assert_equal(current.branch.oid, nil)
      local change = find_change(current.staged, "nested/module")
      assert_truthy(change)
      git:restore_file(repo.root, change, function(result)
        assert_equal(result.ok, false)
        assert_equal(result.error.code, "unsupported_unborn_gitlink")
        status(git, repo.root, function()
          assert_equal(file_bytes(repo.root, ".gitmodules"), before.gitmodules)
          assert_equal(file_bytes(repo.root, "nested/module/keep-untracked.txt"), before.nested)
          assert_equal(command_output(repo.root, { "git", "ls-files", "--stage", "-z", "--" }), before.index)
          assert_equal(command_output(repo.root, { "git", "status", "--porcelain=v2", "-z", "--untracked-files=all" }), before.status)
          assert_truthy(vim.uv.fs_stat(repo.root .. "/nested/module"))
          repo:cleanup()
          source:cleanup()
          done()
        end)
      end)
    end)
  end, debug.traceback)
  if not ok then
    repo:cleanup()
    source:cleanup()
    error(message, 0)
  end
end)

it("removes an unborn staged symbolic link without following its untracked target", function(done)
  local repo = git_repo.new()
  repo:write("target.txt", "keep target bytes\n")
  repo:symlink("target.txt", "added-link")
  repo:git({ "add", "--", "added-link" })
  local git = git_cli.new(process)
  local target_before = file_bytes(repo.root, "target.txt")

  status(git, repo.root, function(current)
    assert_equal(current.branch.oid, nil)
    local change = find_change(current.staged, "added-link")
    assert_truthy(change)
    git:restore_file(repo.root, change, function(result)
      assert_truthy(result.ok)
      status(git, repo.root, function(after)
        assert_equal(vim.uv.fs_lstat(repo.root .. "/added-link"), nil)
        assert_equal(file_bytes(repo.root, "target.txt"), target_before)
        assert_equal(find_change(after.staged, "added-link"), nil)
        assert_truthy(find_change(after.unstaged, "target.txt"))
        repo:cleanup()
        done()
      end)
    end)
  end)
end)

it("fails closed on malformed, truncated, and empty unborn index preflight output", function(done)
  local cases = {
    { name = "arbitrary object id", raw = "100644 NOT_A_HASH 0\tfile.txt\0" },
    { name = "uppercase object id", raw = "100644 " .. string.rep("A", 40) .. " 0\tfile.txt\0" },
    { name = "nonzero stage", raw = "100644 " .. string.rep("a", 40) .. " 1\tfile.txt\0" },
    { name = "unsupported mode", raw = "040000 " .. string.rep("a", 40) .. " 0\tfile.txt\0" },
    { name = "duplicate path", raw = "100644 " .. string.rep("a", 40) .. " 0\tfile.txt\0"
      .. "100644 " .. string.rep("b", 40) .. " 0\tfile.txt\0" },
    { name = "unexpected extra path", raw = "100644 " .. string.rep("a", 40) .. " 0\tfile.txt\0"
      .. "100644 " .. string.rep("b", 40) .. " 0\textra.txt\0" },
    { name = "truncated record", raw = "100644 " .. string.rep("a", 40) .. " 0\tfile.txt" },
    { name = "empty output", raw = "" },
  }
  local index = 1

  local function next_case()
    local current = cases[index]
    if not current then
      done()
      return
    end
    index = index + 1
    local calls = {}
    local git = git_cli.new({
      run = function(args, _, callback)
        calls[#calls + 1] = args
        vim.schedule(function()
          callback(Result.ok({ stdout = current.raw, stderr = "", code = 0 }))
        end)
        return { cancel = function() end }
      end,
    })
    git.status = function(_, _, callback)
      vim.schedule(function()
        callback(Result.ok({
          branch = { oid = nil },
          staged = { { section = "staged", status = "A", path = "file.txt" } },
          unstaged = {},
        }))
      end)
      return { cancel = function() end }
    end

    git:restore_file("/repo", {
      section = "staged", status = "A", path = "file.txt",
    }, function(result)
      assert_equal(result.ok, false)
      assert_equal(result.error.code, "unsupported_unborn_restore")
      assert_equal(#calls, 1)
      assert_equal(calls[1][3], "ls-files")
      next_case()
    end)
  end

  next_case()
end)

it("accepts a NUL-framed SHA-256 entry while preserving tab newline and Unicode path bytes", function(done)
  local path = "tab\tline\nЮ.txt"
  local calls, status_calls = {}, 0
  local git = git_cli.new({
    run = function(args, _, callback)
      calls[#calls + 1] = args
      vim.schedule(function()
        if args[3] == "ls-files" then
          callback(Result.ok({ stdout = "100644 " .. string.rep("a", 64) .. " 0\t" .. path .. "\0" }))
        else
          callback(Result.ok({ stdout = "", stderr = "", code = 0 }))
        end
      end)
      return { cancel = function() end }
    end,
  })
  git.status = function(_, _, callback)
    status_calls = status_calls + 1
    vim.schedule(function()
      callback(Result.ok({
        branch = { oid = nil },
        staged = status_calls == 1 and { { section = "staged", status = "A", path = path } } or {},
        unstaged = {},
      }))
    end)
    return { cancel = function() end }
  end

  git:restore_file("/repo", {
    section = "staged", status = "A", path = path,
  }, function(result)
    assert_truthy(result.ok)
    assert_equal(#calls, 2)
    assert_equal(calls[2][3], "rm")
    assert_equal(calls[2][#calls[2]], path)
    done()
  end)
end)

it("deletes an untracked regular file through the rollback adapter", function(done)
  local repo = git_repo.new()
  repo:write("untracked.txt", "temporary\n")
  local git = git_cli.new(process)
  status(git, repo.root, function(current)
    git:restore_file(repo.root, find_change(current.unstaged, "untracked.txt"), function(result)
      assert_truthy(result.ok)
      assert_equal(file_bytes(repo.root, "untracked.txt"), false)
      assert_clean(git, repo, "untracked.txt", done)
    end)
  end)
end)

it("deletes an untracked symbolic link without following it", function(done)
  local repo = git_repo.new()
  repo:write("target.txt", "outside link payload\n")
  repo:symlink("target.txt", "untracked-link")
  local git = git_cli.new(process)
  status(git, repo.root, function(current)
    git:restore_file(repo.root, find_change(current.unstaged, "untracked-link"), function(result)
      assert_truthy(result.ok)
      assert_equal(vim.uv.fs_lstat(repo.root .. "/untracked-link"), nil)
      assert_truthy(vim.uv.fs_lstat(repo.root .. "/target.txt"))
      assert_clean(git, repo, "untracked-link", done)
    end)
  end)
end)

it("restores a deleted tracked path and a renamed tracked identity from HEAD", function(done)
  local repo = git_repo.new()
  repo:write("deleted.txt", "deleted base\n")
  repo:write("old name.txt", "rename base\n")
  local deleted_bytes = file_bytes(repo.root, "deleted.txt")
  local renamed_bytes = file_bytes(repo.root, "old name.txt")
  repo:git({ "add", "--", "deleted.txt", "old name.txt" })
  repo:commit("base")
  assert_equal(vim.fn.delete(repo.root .. "/deleted.txt"), 0)
  assert_equal(vim.uv.fs_rename(repo.root .. "/old name.txt", repo.root .. "/new name.txt"), true)
  repo:git({ "add", "-A", "--" })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    git:restore_file(repo.root, find_change(current.staged, "deleted.txt"), function(deleted_result)
      assert_truthy(deleted_result.ok)
      assert_equal(file_bytes(repo.root, "deleted.txt"), deleted_bytes)
      status(git, repo.root, function(after_deleted)
        git:restore_file(repo.root, find_change(after_deleted.staged, "new name.txt"), function(rename_result)
          assert_truthy(rename_result.ok)
          assert_equal(file_bytes(repo.root, "old name.txt"), renamed_bytes)
          assert_equal(file_bytes(repo.root, "new name.txt"), false)
          assert_clean(git, repo, "old name.txt", function()
            repo:cleanup()
            done()
          end)
        end)
      end)
    end)
  end)
end)

it("diffs and restores only an exact magic pathspec filename", function(done)
  local repo = git_repo.new()
  local target = ":(glob)magic*.txt"
  local unrelated = "magic-other.txt"
  repo:write(target, { "target base" })
  repo:write(unrelated, { "unrelated base" })
  repo:git({ "--literal-pathspecs", "add", "--", target, unrelated })
  repo:commit("base")
  repo:write(target, { "target changed" })
  repo:write(unrelated, { "unrelated changed" })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    local change = find_change(current.unstaged, target)
    diff(git, repo.root, change, function(file_diff)
      assert_equal(file_diff.path, target)
      local selected = hunk_with(file_diff, "add", "target changed")
      assert_truthy(selected)
      assert_equal(hunk_with(file_diff, "add", "unrelated changed"), nil)
      git:restore_hunk(repo.root, file_diff, selected, function(result)
        assert_truthy(result.ok)
        assert_equal(file_bytes(repo.root, target), "target base\n")
        assert_equal(file_bytes(repo.root, unrelated), "unrelated changed\n")
        repo:cleanup()
        done()
      end)
    end)
  end)
end)

it("coalesces staged deletion and recreated untracked path into one HEAD restore", function(done)
  local repo = git_repo.new()
  repo:write("recreated.txt", "base\n")
  local base_bytes = file_bytes(repo.root, "recreated.txt")
  repo:git({ "add", "--", "recreated.txt" })
  repo:commit("base")
  assert_equal(vim.fn.delete(repo.root .. "/recreated.txt"), 0)
  repo:git({ "add", "--", "recreated.txt" })
  repo:write("recreated.txt", "recreated\n")
  local git = git_cli.new(process)
  status(git, repo.root, function(current)
    git:restore_file(repo.root, find_change(current.unstaged, "recreated.txt"), function(result)
      assert_truthy(result.ok)
      assert_equal(file_bytes(repo.root, "recreated.txt"), base_bytes)
      assert_clean(git, repo, "recreated.txt", done)
    end)
  end)
end)

it("coalesces staged rename and unstaged edit into one HEAD identity restore", function(done)
  local repo = git_repo.new()
  repo:write("old.txt", "base\n")
  local base_bytes = file_bytes(repo.root, "old.txt")
  repo:git({ "add", "--", "old.txt" })
  repo:commit("base")
  repo:git({ "mv", "old.txt", "new.txt" })
  repo:git({ "add", "--", "new.txt" })
  repo:write("new.txt", "changed\n")
  local git = git_cli.new(process)
  status(git, repo.root, function(current)
    git:restore_file(repo.root, find_change(current.unstaged, "new.txt"), function(result)
      assert_truthy(result.ok)
      assert_equal(file_bytes(repo.root, "old.txt"), base_bytes)
      assert_equal(file_bytes(repo.root, "new.txt"), false)
      assert_clean(git, repo, "old.txt", done)
    end)
  end)
end)
