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
      assert_equal(calls[1].args, {
        "git", "diff", "--cached", "--no-ext-diff", "--unified=5", "--", "name.txt",
      })
      assert_equal(calls[2].args, {
        "git", "diff", "--no-ext-diff", "--unified=5", "--", "name.txt",
      })
      assert_equal(calls[1].opts.cwd, "/repo")
      done()
    end)
  end)
end)
