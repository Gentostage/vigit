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

it("reads staged and unstaged states of the same file", function(done)
  local repo = git_repo.new()
  repo:write("both.txt", { "base" })
  repo:git({ "add", "--", "both.txt" })
  repo:commit("base")
  repo:write("both.txt", { "staged" })
  repo:git({ "add", "--", "both.txt" })
  repo:write("both.txt", { "worktree" })

  git_cli.new(process):status(repo.root, function(result)
    assert_truthy(result.ok)
    assert_equal(find_change(result.value.staged, "both.txt").status, "M")
    assert_equal(find_change(result.value.unstaged, "both.txt").status, "M")
    repo:cleanup()
    done()
  end)
end)

it("reads rename, delete and Unicode untracked paths", function(done)
  local repo = git_repo.new()
  repo:write("old name.txt", { "rename me" })
  repo:write("delete.txt", { "delete me" })
  repo:git({ "add", "--", "old name.txt", "delete.txt" })
  repo:commit("base")
  repo:git({ "mv", "old name.txt", "new name.txt" })
  repo:git({ "rm", "--", "delete.txt" })
  repo:write("каталог/new file.txt", { "unicode" })

  git_cli.new(process):status(repo.root, function(result)
    assert_truthy(result.ok)
    local rename = find_change(result.value.staged, "new name.txt")
    local deleted = find_change(result.value.staged, "delete.txt")
    local untracked = find_change(result.value.unstaged, "каталог/new file.txt")
    assert_equal(rename.status, "R")
    assert_equal(rename.old_path, "old name.txt")
    assert_equal(deleted.status, "D")
    assert_equal(untracked.status, "?")
    repo:cleanup()
    done()
  end)
end)

it("omits ignored files from status results", function(done)
  local repo = git_repo.new()
  repo:write(".gitignore", { "ignored.log" })
  repo:git({ "add", "--", ".gitignore" })
  repo:commit("ignore fixture")
  repo:write("ignored.log", { "ignored" })
  repo:write("visible.log", { "visible" })

  git_cli.new(process):status(repo.root, function(result)
    assert_truthy(result.ok)
    assert_truthy(find_change(result.value.unstaged, "visible.log"))
    assert_equal(find_change(result.value.unstaged, "ignored.log"), nil)
    repo:cleanup()
    done()
  end)
end)

it("reads the new index path for an unstaged edit after a staged rename", function(done)
  local repo = git_repo.new()
  repo:write("old name.txt", { "base" })
  repo:git({ "add", "--", "old name.txt" })
  repo:commit("base")
  repo:git({ "mv", "old name.txt", "new name.txt" })
  repo:write("new name.txt", { "modified" })
  local git = git_cli.new(process)

  git:status(repo.root, function(status_result)
    local staged = find_change(status_result.value.staged, "new name.txt")
    local unstaged = find_change(status_result.value.unstaged, "new name.txt")
    assert_equal(staged.old_path, "old name.txt")
    assert_equal(unstaged.old_path, nil)

    git:snapshot(repo.root, unstaged, "old", function(old_result)
      git:snapshot(repo.root, unstaged, "new", function(new_result)
        assert_truthy(old_result.ok)
        assert_equal(old_result.value, "base\n")
        assert_equal(new_result.value, "modified\n")
        repo:cleanup()
        done()
      end)
    end)
  end)
end)

it("reads diffs and snapshots for staged and unstaged changes", function(done)
  local repo = git_repo.new()
  repo:write("both.txt", { "base" })
  repo:git({ "add", "--", "both.txt" })
  repo:commit("base")
  repo:write("both.txt", { "staged" })
  repo:git({ "add", "--", "both.txt" })
  repo:write("both.txt", { "worktree" })
  local git = git_cli.new(process)

  git:status(repo.root, function(status_result)
    local staged = find_change(status_result.value.staged, "both.txt")
    local unstaged = find_change(status_result.value.unstaged, "both.txt")

    git:diff(repo.root, staged, 0, 1024 * 1024, function(staged_diff)
      assert_truthy(staged_diff.ok)
      assert_equal(staged_diff.value.hunks[1].lines[1].text, "base")
      assert_equal(staged_diff.value.hunks[1].lines[2].text, "staged")

      git:diff(repo.root, unstaged, 0, 1024 * 1024, function(unstaged_diff)
        assert_truthy(unstaged_diff.ok)
        assert_equal(unstaged_diff.value.hunks[1].lines[1].text, "staged")
        assert_equal(unstaged_diff.value.hunks[1].lines[2].text, "worktree")

        git:snapshot(repo.root, staged, "old", function(staged_old)
          git:snapshot(repo.root, staged, "new", function(staged_new)
            git:snapshot(repo.root, unstaged, "old", function(unstaged_old)
              git:snapshot(repo.root, unstaged, "new", function(unstaged_new)
                assert_equal(staged_old.value, "base\n")
                assert_equal(staged_new.value, "staged\n")
                assert_equal(unstaged_old.value, "staged\n")
                assert_equal(unstaged_new.value, "worktree\n")
                repo:cleanup()
                done()
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end)

it("supports an unborn HEAD and staged snapshots", function(done)
  local repo = git_repo.new()
  repo:write("first.txt", { "first" })
  repo:git({ "add", "--", "first.txt" })
  local git = git_cli.new(process)

  git:status(repo.root, function(status_result)
    assert_truthy(status_result.ok)
    assert_equal(status_result.value.branch.oid, nil)
    local staged = find_change(status_result.value.staged, "first.txt")
    assert_equal(staged.status, "A")

    git:snapshot(repo.root, staged, "old", function(old_result)
      git:snapshot(repo.root, staged, "new", function(new_result)
        assert_equal(old_result.value, "")
        assert_equal(new_result.value, "first\n")
        repo:cleanup()
        done()
      end)
    end)
  end)
end)

it("rejects conflict snapshots before ordinary add/delete fast paths", function(done)
  local fake_process = {
    run = function()
      error("conflict snapshot must not invoke an ordinary Git read")
    end,
  }
  local change = {
    id = "staged\0conflict.lua",
    section = "staged",
    status = "A",
    path = "conflict.lua",
    unmerged = true,
  }

  git_cli.new(fake_process):snapshot(fixture.root, change, "old", function(result)
    assert_equal(result.error.code, "unsupported_conflict_snapshot")
    done()
  end)
end)

it("creates a synthetic diff and snapshots for an untracked file", function(done)
  local repo = git_repo.new()
  repo:write("notes/новый file.md", { "one", "+two" })
  local git = git_cli.new(process)

  git:status(repo.root, function(status_result)
    local change = find_change(status_result.value.unstaged, "notes/новый file.md")
    git:diff(repo.root, change, 3, 1024 * 1024, function(diff_result)
      assert_truthy(diff_result.ok)
      assert_equal(diff_result.value.hunks[1].lines[1].text, "one")
      assert_equal(diff_result.value.hunks[1].lines[2].text, "+two")

      git:snapshot(repo.root, change, "old", function(old_result)
        git:snapshot(repo.root, change, "new", function(new_result)
          assert_equal(old_result.value, "")
          assert_equal(new_result.value, "one\n+two\n")
          repo:cleanup()
          done()
        end)
      end)
    end)
  end)
end)

it("reads a symlink target without following it outside the root", function(done)
  local repo = git_repo.new()
  local target = "../../definitely-outside-vigit-root"
  repo:symlink(target, "escape link")
  local git = git_cli.new(process)

  git:status(repo.root, function(status_result)
    local change = find_change(status_result.value.unstaged, "escape link")
    git:diff(repo.root, change, 3, 1024 * 1024, function(diff_result)
      assert_truthy(diff_result.ok)
      assert_equal(diff_result.value.hunks[1].lines[1].text, target)

      git:snapshot(repo.root, change, "new", function(snapshot_result)
        assert_truthy(snapshot_result.ok)
        assert_equal(snapshot_result.value, target)
        repo:cleanup()
        done()
      end)
    end)
  end)
end)

it("rejects absolute, empty and traversal untracked paths before reading", function(done)
  local reads = 0
  local filesystem = {
    read_file = function(_, _, callback)
      reads = reads + 1
      callback({ ok = true, value = "must not be read" })
      return { cancel = function() end }
    end,
  }
  local git = git_cli.new(process, filesystem)
  local paths = {
    "",
    ".",
    "/tmp/outside",
    "../outside",
    "dir/../outside",
    "dir/./file",
    "dir//file",
  }
  local index = 0

  local function check_next()
    index = index + 1
    local path = paths[index]
    if not path then
      assert_equal(reads, 0)
      done()
      return
    end
    git:diff(fixture.root, {
      id = "unstaged\0" .. path,
      section = "unstaged",
      status = "?",
      path = path,
    }, 3, 1024, function(result)
      assert_equal(result.ok, false)
      assert_equal(result.error.code, "git_diff_failed")
      check_next()
    end)
  end

  check_next()
end)

it("rejects a canonical parent that escapes through a symlink", function(done)
  local repo = git_repo.new()
  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "outside secret" }, outside .. "/secret.txt")
  repo:symlink(outside, "escape")
  local change = {
    id = "unstaged\0escape/secret.txt",
    section = "unstaged",
    status = "?",
    path = "escape/secret.txt",
  }

  git_cli.new(process):diff(repo.root, change, 3, 1024, function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "git_diff_failed")
    repo:cleanup()
    vim.fn.delete(outside, "rf")
    done()
  end)
end)

it("reads POSIX untracked names containing backslash and colon", function(done)
  if package.config:sub(1, 1) ~= "/" then
    done()
    return
  end

  local repo = git_repo.new()
  local names = {
    { path = "dir\\name.txt", content = "backslash" },
    { path = "C:notes.txt", content = "colon" },
  }
  repo:write(names[1].path, { names[1].content })
  repo:write(names[2].path, { names[2].content })
  local git = git_cli.new(process)

  git:status(repo.root, function(status_result)
    assert_truthy(status_result.ok)
    local index = 0
    local function read_next()
      index = index + 1
      local expected = names[index]
      if not expected then
        repo:cleanup()
        done()
        return
      end

      local change = find_change(status_result.value.unstaged, expected.path)
      assert_truthy(change)
      git:diff(repo.root, change, 3, 1024, function(diff_result)
        assert_truthy(diff_result.ok)
        assert_equal(diff_result.value.hunks[1].lines[1].text, expected.content)
        read_next()
      end)
    end
    read_next()
  end)
end)

it("rejects a POSIX backslash sibling outside the repository", function(done)
  if package.config:sub(1, 1) ~= "/" then
    done()
    return
  end

  local repo = git_repo.new()
  local outside = repo.root .. "\\outside"
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "outside secret" }, outside .. "/secret.txt")
  repo:symlink(outside, "escape-backslash")
  local change = {
    id = "unstaged\0escape-backslash/secret.txt",
    section = "unstaged",
    status = "?",
    path = "escape-backslash/secret.txt",
  }

  git_cli.new(process):diff(repo.root, change, 3, 1024, function(result)
    local ok, message = xpcall(function()
      assert_equal(result.ok, false)
      assert_equal(result.error.code, "git_diff_failed")
    end, debug.traceback)
    repo:cleanup()
    vim.fn.delete(outside, "rf")
    if not ok then
      error(message, 0)
    end
    done()
  end)
end)

it("rejects a parent swapped after canonicalization but before lstat", function(done)
  local repo = git_repo.new()
  local outside = vim.fn.tempname()
  local parent = repo.root .. "/parent"
  local original_parent = repo.root .. "/parent-original"
  local victim = parent .. "/victim.txt"
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "outside secret" }, outside .. "/victim.txt")
  repo:write("parent/victim.txt", { "inside" })
  local original_lstat = vim.uv.fs_lstat
  local original_read = vim.uv.fs_read
  local swapped = false
  local swap_error
  local reads = 0

  vim.uv.fs_lstat = function(path, callback)
    if path == victim and not swapped then
      swapped = true
      local renamed, rename_error = vim.uv.fs_rename(parent, original_parent)
      if not renamed then
        swap_error = rename_error
      else
        local linked, link_error = vim.uv.fs_symlink(outside, parent)
        if not linked then
          swap_error = link_error
        end
      end
    end
    return original_lstat(path, callback)
  end
  vim.uv.fs_read = function(...)
    reads = reads + 1
    return original_read(...)
  end

  git_cli.new(process):diff(repo.root, {
    id = "unstaged\0parent/victim.txt",
    section = "unstaged",
    status = "?",
    path = "parent/victim.txt",
  }, 3, 1024, function(result)
    vim.uv.fs_lstat = original_lstat
    vim.uv.fs_read = original_read
    local ok, message = xpcall(function()
      assert_equal(swapped, true)
      assert_equal(swap_error, nil)
      assert_equal(reads, 0)
      assert_equal(result.ok, false)
      assert_equal(result.error.code, "git_diff_failed")
    end, debug.traceback)
    repo:cleanup()
    vim.fn.delete(outside, "rf")
    if not ok then
      error(message, 0)
    end
    done()
  end)
end)

it("fails closed and closes fd when descriptor path is unavailable", function(done)
  local repo = git_repo.new()
  repo:write("victim.txt", { "inside" })
  local original_open = vim.uv.fs_open
  local original_realpath = vim.uv.fs_realpath
  local original_close = vim.uv.fs_close
  local original_fstat = vim.uv.fs_fstat
  local descriptor
  local closes = 0
  local fstats = 0

  vim.uv.fs_open = function(path, flags, mode, callback)
    return original_open(path, flags, mode, function(open_error, opened_descriptor)
      descriptor = opened_descriptor
      callback(open_error, opened_descriptor)
    end)
  end
  vim.uv.fs_realpath = function(path, callback)
    if path:match("^/proc/self/fd/") then
      callback("injected descriptor path failure")
      return
    end
    return original_realpath(path, callback)
  end
  vim.uv.fs_close = function(opened_descriptor, ...)
    if opened_descriptor == descriptor then
      closes = closes + 1
    end
    return original_close(opened_descriptor, ...)
  end
  vim.uv.fs_fstat = function(...)
    fstats = fstats + 1
    return original_fstat(...)
  end

  git_cli.new(process):diff(repo.root, {
    id = "unstaged\0victim.txt",
    section = "unstaged",
    status = "?",
    path = "victim.txt",
  }, 3, 1024, function(result)
    vim.uv.fs_open = original_open
    vim.uv.fs_realpath = original_realpath
    vim.uv.fs_close = original_close
    vim.uv.fs_fstat = original_fstat
    local ok, message = xpcall(function()
      assert_truthy(descriptor)
      assert_equal(closes, 1)
      assert_equal(fstats, 0)
      assert_equal(result.ok, false)
      assert_equal(result.error.code, "git_diff_failed")
      assert_truthy(result.error.details:match("descriptor path failure"))
    end, debug.traceback)
    repo:cleanup()
    if not ok then
      error(message, 0)
    end
    done()
  end)
end)

it("rejects a file swapped to an outside symlink between lstat and open", function(done)
  local repo = git_repo.new()
  local outside = vim.fn.tempname()
  local victim = repo.root .. "/victim.txt"
  vim.fn.writefile({ "outside secret" }, outside)
  repo:write("victim.txt", { "inside" })
  local original_open = vim.uv.fs_open
  local swapped = false

  vim.uv.fs_open = function(path, flags, mode, callback)
    if path == victim and not swapped then
      swapped = true
      assert_equal(vim.uv.fs_unlink(victim), true)
      assert_equal(vim.uv.fs_symlink(outside, victim), true)
    end
    return original_open(path, flags, mode, callback)
  end

  git_cli.new(process):diff(repo.root, {
    id = "unstaged\0victim.txt",
    section = "unstaged",
    status = "?",
    path = "victim.txt",
  }, 3, 1024, function(result)
    vim.uv.fs_open = original_open
    local ok, message = xpcall(function()
      assert_equal(swapped, true)
      assert_equal(result.ok, false)
      assert_equal(result.error.code, "git_diff_failed")
    end, debug.traceback)
    repo:cleanup()
    vim.fn.delete(outside)
    if not ok then
      error(message, 0)
    end
    done()
  end)
end)

it("rejects unsupported worktree file types without opening them", function(done)
  local repo = git_repo.new()
  repo:mkfifo("named-pipe")
  local change = {
    id = "unstaged\0named-pipe",
    section = "unstaged",
    status = "?",
    path = "named-pipe",
  }

  git_cli.new(process):diff(repo.root, change, 3, 1024, function(result)
    assert_equal(result.error.code, "git_diff_failed")
    assert_truthy(result.error.details:match("Unsupported file type"))
    repo:cleanup()
    done()
  end)
end)

it("rejects oversized stdout before parsing", function(done)
  local fake_process = {
    run = function(_, _, callback)
      vim.schedule(function()
        callback({
          ok = true,
          value = { stdout = string.rep("x", 9), stderr = "", code = 0 },
        })
      end)
      return { cancel = function() end }
    end,
  }
  local change = {
    id = "unstaged\0big.txt",
    section = "unstaged",
    status = "M",
    path = "big.txt",
  }

  git_cli.new(fake_process):diff(fixture.root, change, 3, 8, function(result)
    assert_equal(result.error.code, "diff_too_large")
    done()
  end)
end)

it("uses argument arrays for staged and unstaged diff reads", function(done)
  local calls = {}
  local fake_process = {
    run = function(args, opts, callback)
      calls[#calls + 1] = { args = args, opts = opts }
      vim.schedule(function()
        callback({
          ok = true,
          value = { stdout = "", stderr = "", code = 0 },
        })
      end)
      return { cancel = function() end }
    end,
  }
  local git = git_cli.new(fake_process)
  local staged = {
    id = "staged\0name.txt",
    section = "staged",
    status = "M",
    path = "name.txt",
  }
  local unstaged = {
    id = "unstaged\0name.txt",
    section = "unstaged",
    status = "M",
    path = "name.txt",
  }

  git:diff("/repo", staged, 5, 1024, function()
    git:diff("/repo", unstaged, 5, 1024, function()
      assert_equal(
        table.concat(calls[1].args, "\0"),
        table.concat({
          "git", "--literal-pathspecs", "diff", "--cached", "--no-ext-diff", "--full-index", "--unified=5", "--", "name.txt",
        }, "\0")
      )
      assert_equal(
        table.concat(calls[2].args, "\0"),
        table.concat({
          "git", "--literal-pathspecs", "diff", "--no-ext-diff", "--full-index", "--unified=5", "--", "name.txt",
        }, "\0")
      )
      assert_equal(calls[1].opts.cwd, "/repo")
      done()
    end)
  end)
end)
