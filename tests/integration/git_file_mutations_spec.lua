local git_cli = require("vigit.adapters.git_cli")
local process = require("vigit.adapters.process")
local git_repo = dofile("tests/fixtures/git_repo.lua")

local function find_change(changes, path)
  for _, change in ipairs(changes) do
    if change.path == path then
      return change
    end
  end
end

local function count(changes)
  return #(changes or {})
end

local function file_bytes(root, path)
  local handle = io.open(root .. "/" .. path, "rb")
  if not handle then
    return false
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function command_output(root, args)
  local result = vim.system(args, { cwd = root, text = false }):wait()
  assert_equal(result.code, 0)
  return result.stdout or ""
end

local function snapshot(root, path)
  return {
    bytes = file_bytes(root, path),
    status = command_output(root, {
      "git", "status", "--porcelain=v2", "-z", "--untracked-files=all",
    }),
    diff = command_output(root, { "git", "diff", "--binary" }),
    cached_diff = command_output(root, { "git", "diff", "--cached", "--binary" }),
  }
end

local function status(git, root, callback)
  git:status(root, function(result)
    assert_truthy(result.ok)
    callback(result.value)
  end)
end

local function verify_stage_then_unstage(repo, path, staged_change, done)
  local git = git_cli.new(process)
  local before = snapshot(repo.root, path)

  git:stage_file(repo.root, staged_change, function(stage_result)
    assert_truthy(stage_result.ok)
    status(git, repo.root, function(after_stage)
      assert_equal(count(after_stage.unstaged), 0)
      assert_equal(file_bytes(repo.root, path), before.bytes)

      local current = find_change(after_stage.staged, staged_change.path)
      assert_truthy(current)
      git:unstage_file(repo.root, current, function(unstage_result)
        assert_truthy(unstage_result.ok)
        status(git, repo.root, function(after_unstage)
          assert_equal(count(after_unstage.staged), 0)
          assert_equal(file_bytes(repo.root, path), before.bytes)
          repo:cleanup()
          done()
        end)
      end)
    end)
  end)
end

it("stages and unstages a tracked modification without changing bytes", function(done)
  local repo = git_repo.new()
  repo:write("tracked.txt", "base\n")
  repo:git({ "add", "--", "tracked.txt" })
  repo:commit("base")
  repo:write("tracked.txt", "worktree\n")
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    verify_stage_then_unstage(
      repo,
      "tracked.txt",
      find_change(current.unstaged, "tracked.txt"),
      done
    )
  end)
end)

it("stages and unstages a deletion without restoring the file", function(done)
  local repo = git_repo.new()
  repo:write("deleted.txt", "base\n")
  repo:git({ "add", "--", "deleted.txt" })
  repo:commit("base")
  assert_equal(vim.fn.delete(repo.root .. "/deleted.txt"), 0)
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    verify_stage_then_unstage(
      repo,
      "deleted.txt",
      find_change(current.unstaged, "deleted.txt"),
      done
    )
  end)
end)

it("stages a rename with spaces by indexing both exact paths", function(done)
  local repo = git_repo.new()
  repo:write("old name.txt", "base\n")
  repo:git({ "add", "--", "old name.txt" })
  repo:commit("base")
  assert_equal(vim.uv.fs_rename(
    repo.root .. "/old name.txt",
    repo.root .. "/new name.txt"
  ), true)
  local git = git_cli.new(process)
  local before = snapshot(repo.root, "new name.txt")
  local rename = {
    section = "unstaged",
    status = "R",
    old_path = "old name.txt",
    path = "new name.txt",
  }

  git:stage_file(repo.root, rename, function(stage_result)
    assert_truthy(stage_result.ok)
    status(git, repo.root, function(after_stage)
      assert_equal(count(after_stage.unstaged), 0)
      assert_equal(file_bytes(repo.root, "new name.txt"), before.bytes)
      local staged = find_change(after_stage.staged, "new name.txt")
      assert_truthy(staged)
      assert_equal(staged.old_path, "old name.txt")

      git:unstage_file(repo.root, staged, function(unstage_result)
        assert_truthy(unstage_result.ok)
        status(git, repo.root, function(after_unstage)
          assert_equal(count(after_unstage.staged), 0)
          assert_equal(file_bytes(repo.root, "new name.txt"), before.bytes)
          repo:cleanup()
          done()
        end)
      end)
    end)
  end)
end)

it("stages and unstages an untracked file without changing bytes", function(done)
  local repo = git_repo.new()
  repo:write("new.txt", "new bytes\n")
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    verify_stage_then_unstage(
      repo,
      "new.txt",
      find_change(current.unstaged, "new.txt"),
      done
    )
  end)
end)

it("unstages an added file with an existing HEAD without changing bytes", function(done)
  local repo = git_repo.new()
  repo:write("sentinel.txt", "base\n")
  repo:git({ "add", "--", "sentinel.txt" })
  repo:commit("base")
  repo:write("added.txt", "added bytes\n")
  repo:git({ "add", "--", "added.txt" })
  local git = git_cli.new(process)
  local before = snapshot(repo.root, "added.txt")

  status(git, repo.root, function(current)
    git:unstage_file(repo.root, find_change(current.staged, "added.txt"), function(result)
      assert_truthy(result.ok)
      status(git, repo.root, function(after_unstage)
        assert_equal(count(after_unstage.staged), 0)
        assert_equal(file_bytes(repo.root, "added.txt"), before.bytes)
        repo:cleanup()
        done()
      end)
    end)
  end)
end)

it("uses literal pathspecs and leaves wildcard matches untouched", function(done)
  local repo = git_repo.new()
  local target = ":(glob)literal*.txt"
  local unrelated = "literal-other.txt"
  repo:write(target, "base target\n")
  repo:write(unrelated, "base unrelated\n")
  repo:git({ "add", "--", target, unrelated })
  repo:commit("base")
  repo:write(target, "changed target\n")
  repo:write(unrelated, "changed unrelated\n")
  local before_target = file_bytes(repo.root, target)
  local before_unrelated = file_bytes(repo.root, unrelated)
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    git:stage_file(repo.root, find_change(current.unstaged, target), function(stage_result)
      assert_truthy(stage_result.ok)
      status(git, repo.root, function(after_stage)
        assert_truthy(find_change(after_stage.staged, target))
        assert_truthy(find_change(after_stage.unstaged, unrelated))
        assert_equal(find_change(after_stage.staged, unrelated), nil)
        assert_equal(file_bytes(repo.root, target), before_target)
        assert_equal(file_bytes(repo.root, unrelated), before_unrelated)

        git:unstage_file(repo.root, find_change(after_stage.staged, target), function(unstage_result)
          assert_truthy(unstage_result.ok)
          status(git, repo.root, function(after_unstage)
            assert_truthy(find_change(after_unstage.unstaged, target))
            assert_truthy(find_change(after_unstage.unstaged, unrelated))
            assert_equal(find_change(after_unstage.staged, unrelated), nil)
            assert_equal(file_bytes(repo.root, target), before_target)
            assert_equal(file_bytes(repo.root, unrelated), before_unrelated)
            repo:cleanup()
            done()
          end)
        end)
      end)
    end)
  end)
end)

it("does not stage a modified copy source with its target", function(done)
  local repo = git_repo.new()
  repo:write("source.txt", "base\n")
  repo:git({ "add", "--", "source.txt" })
  repo:commit("base")
  repo:write("source.txt", "modified source\n")
  repo:write("copy.txt", "copy target\n")
  local git = git_cli.new(process)
  local copy = {
    section = "unstaged",
    status = "C",
    old_path = "source.txt",
    path = "copy.txt",
  }

  git:stage_file(repo.root, copy, function(stage_result)
    assert_truthy(stage_result.ok)
    status(git, repo.root, function(after_stage)
      assert_truthy(find_change(after_stage.staged, "copy.txt"))
      assert_truthy(find_change(after_stage.unstaged, "source.txt"))
      assert_equal(find_change(after_stage.staged, "source.txt"), nil)

      git:unstage_file(repo.root, {
        section = "staged",
        status = "C",
        old_path = "source.txt",
        path = "copy.txt",
      }, function(unstage_result)
        assert_truthy(unstage_result.ok)
        status(git, repo.root, function(after_unstage)
          assert_truthy(find_change(after_unstage.unstaged, "source.txt"))
          assert_truthy(find_change(after_unstage.unstaged, "copy.txt"))
          assert_equal(find_change(after_unstage.staged, "source.txt"), nil)
          repo:cleanup()
          done()
        end)
      end)
    end)
  end)
end)

it("rejects a rename without a distinct old path before spawning", function(done)
  local calls = 0
  local fake_process = {
    run = function()
      calls = calls + 1
      error("rename validation must run before process invocation")
    end,
  }
  local git = git_cli.new(fake_process)

  local old_paths = { false, "rename.txt" }
  local index = 0
  local function check_next()
    index = index + 1
    local old_path = old_paths[index] or nil
    if index > #old_paths then
      assert_equal(calls, 0)
      done()
      return
    end
    git:stage_file("/repo", {
      section = "unstaged",
      status = "R",
      old_path = old_path,
      path = "rename.txt",
    }, function(result)
      assert_equal(result.ok, false)
      assert_equal(result.error.code, "stale_change")
      check_next()
    end)
  end

  check_next()
end)

it("rejects stage and unstage when their post-status still has the target layer", function(done)
  local process_calls = 0
  local fake_process = {
    run = function(_, _, callback)
      process_calls = process_calls + 1
      if process_calls == 2 then
        callback({ ok = true, value = { stdout = "patch" } })
      else
        callback({ ok = true, value = { stdout = "" } })
      end
      return { cancel = function() end }
    end,
  }
  local git = git_cli.new(fake_process)
  local stage_change = {
    section = "unstaged",
    status = "M",
    path = "same.txt",
  }
  local unstage_change = {
    section = "staged",
    status = "M",
    path = "same.txt",
  }
  local status_results = {
    { staged = {}, unstaged = { stage_change } },
    { staged = { unstage_change }, unstaged = {} },
  }
  function git:status(_, callback)
    callback({ ok = true, value = table.remove(status_results, 1) })
    return { cancel = function() end }
  end

  git:stage_file("/repo", stage_change, function(stage_result)
    assert_equal(stage_result.ok, false)
    assert_equal(stage_result.error.code, "stale_change")
    git:unstage_file("/repo", unstage_change, function(unstage_result)
      assert_equal(unstage_result.ok, false)
      assert_equal(unstage_result.error.code, "stale_change")
      done()
    end)
  end)
end)

it("stages then unstages a mixed staged and worktree modification", function(done)
  local repo = git_repo.new()
  repo:write("mixed.txt", "base\n")
  repo:git({ "add", "--", "mixed.txt" })
  repo:commit("base")
  repo:write("mixed.txt", "index\n")
  repo:git({ "add", "--", "mixed.txt" })
  repo:write("mixed.txt", "worktree\n")
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    verify_stage_then_unstage(
      repo,
      "mixed.txt",
      find_change(current.unstaged, "mixed.txt"),
      done
    )
  end)
end)

it("unstages an added file in an unborn repository without changing bytes", function(done)
  local repo = git_repo.new()
  repo:write("first.txt", "first bytes\n")
  repo:git({ "add", "--", "first.txt" })
  local git = git_cli.new(process)
  local before = snapshot(repo.root, "first.txt")

  status(git, repo.root, function(current)
    git:unstage_file(repo.root, find_change(current.staged, "first.txt"), function(result)
      assert_truthy(result.ok)
      status(git, repo.root, function(after_unstage)
        assert_equal(count(after_unstage.staged), 0)
        assert_equal(file_bytes(repo.root, "first.txt"), before.bytes)
        repo:cleanup()
        done()
      end)
    end)
  end)
end)

it("returns stale_change for empty or stale file mutation input", function(done)
  local repo = git_repo.new()
  local git = git_cli.new(process)

  git:stage_file(repo.root, { path = "" }, function(empty_result)
    assert_equal(empty_result.ok, false)
    assert_equal(empty_result.error.code, "stale_change")
    git:unstage_file(repo.root, { path = "missing.txt" }, function(stale_result)
      assert_equal(stale_result.ok, false)
      assert_equal(stale_result.error.code, "stale_change")
      repo:cleanup()
      done()
    end)
  end)
end)
