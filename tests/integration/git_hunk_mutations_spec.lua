local git_cli = require("vigit.adapters.git_cli")
local process = require("vigit.adapters.process")
local git_repo = dofile("tests/fixtures/git_repo.lua")

local function find_change(changes, path)
  for _, change in ipairs(changes or {}) do
    if change.path == path then
      return change
    end
  end
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

local function diff_zero(git, root, change, callback)
  git:diff(root, change, 0, 1024 * 1024, function(result)
    assert_truthy(result.ok)
    callback(result.value)
  end)
end

local function hunk_with(diff_model, kind, text)
  for _, hunk in ipairs(diff_model.hunks) do
    for _, line in ipairs(hunk.lines) do
      if line.kind == kind and line.text == text then
        return hunk
      end
    end
  end
end

local function assert_hunk(diff_model, kind, text)
  assert_truthy(hunk_with(diff_model, kind, text))
end

it("moves only the selected modified hunk between worktree and index", function(done)
  local repo = git_repo.new()
  repo:write("modified.txt", {
    "one", "two", "three", "four", "five", "six", "seven", "eight",
  })
  repo:git({ "add", "--", "modified.txt" })
  repo:commit("base")
  repo:write("modified.txt", {
    "one", "two staged", "three", "four", "five", "six", "seven changed", "eight",
  })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    local change = find_change(current.unstaged, "modified.txt")
    diff(git, repo.root, change, function(worktree)
      local selected = hunk_with(worktree, "add", "two staged")
      assert_truthy(selected)
      git:stage_hunk(repo.root, worktree, selected, function(stage_result)
        assert_truthy(stage_result.ok)
        status(git, repo.root, function(after_stage)
          diff(git, repo.root, find_change(after_stage.staged, "modified.txt"), function(staged)
            diff(git, repo.root, find_change(after_stage.unstaged, "modified.txt"), function(remaining)
              assert_hunk(staged, "add", "two staged")
              assert_equal(hunk_with(staged, "add", "seven changed"), nil)
              assert_hunk(remaining, "add", "seven changed")
              assert_equal(hunk_with(remaining, "add", "two staged"), nil)
              git:unstage_hunk(repo.root, staged, hunk_with(staged, "add", "two staged"), function(unstage_result)
                assert_truthy(unstage_result.ok)
                status(git, repo.root, function(after_unstage)
                  assert_equal(find_change(after_unstage.staged, "modified.txt"), nil)
                  diff(git, repo.root, find_change(after_unstage.unstaged, "modified.txt"), function(restored)
                    assert_hunk(restored, "add", "two staged")
                    assert_hunk(restored, "add", "seven changed")
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
  end)
end)

it("moves only the selected zero-context hunk between worktree and index", function(done)
  local repo = git_repo.new()
  repo:write("zero-context.txt", {
    "one", "two", "three", "four", "five", "six", "seven", "eight",
  })
  repo:git({ "add", "--", "zero-context.txt" })
  repo:commit("base")
  repo:write("zero-context.txt", {
    "one", "two staged", "three", "four", "five", "six", "seven changed", "eight",
  })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    local change = find_change(current.unstaged, "zero-context.txt")
    diff_zero(git, repo.root, change, function(worktree)
      local selected = hunk_with(worktree, "add", "two staged")
      assert_truthy(selected)
      git:stage_hunk(repo.root, worktree, selected, function(stage_result)
        assert_truthy(stage_result.ok)
        status(git, repo.root, function(after_stage)
          diff_zero(git, repo.root, find_change(after_stage.staged, "zero-context.txt"), function(staged)
            diff_zero(git, repo.root, find_change(after_stage.unstaged, "zero-context.txt"), function(remaining)
              assert_hunk(staged, "add", "two staged")
              assert_equal(hunk_with(staged, "add", "seven changed"), nil)
              assert_hunk(remaining, "add", "seven changed")
              assert_equal(hunk_with(remaining, "add", "two staged"), nil)
              git:unstage_hunk(repo.root, staged, hunk_with(staged, "add", "two staged"), function(unstage_result)
                assert_truthy(unstage_result.ok)
                status(git, repo.root, function(after_unstage)
                  assert_equal(find_change(after_unstage.staged, "zero-context.txt"), nil)
                  diff_zero(git, repo.root, find_change(after_unstage.unstaged, "zero-context.txt"), function(restored)
                    assert_hunk(restored, "add", "two staged")
                    assert_hunk(restored, "add", "seven changed")
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
  end)
end)

it("moves only the selected deletion hunk between worktree and index", function(done)
  local repo = git_repo.new()
  repo:write("deleted.txt", {
    "one", "two", "three", "four", "five", "six", "seven", "eight",
  })
  repo:git({ "add", "--", "deleted.txt" })
  repo:commit("base")
  repo:write("deleted.txt", { "one", "three", "four", "five", "six", "eight" })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    local change = find_change(current.unstaged, "deleted.txt")
    diff(git, repo.root, change, function(worktree)
      local selected = hunk_with(worktree, "delete", "two")
      git:stage_hunk(repo.root, worktree, selected, function(stage_result)
        assert_truthy(stage_result.ok)
        status(git, repo.root, function(after_stage)
          diff(git, repo.root, find_change(after_stage.staged, "deleted.txt"), function(staged)
            diff(git, repo.root, find_change(after_stage.unstaged, "deleted.txt"), function(remaining)
              assert_hunk(staged, "delete", "two")
              assert_equal(hunk_with(staged, "delete", "seven"), nil)
              assert_hunk(remaining, "delete", "seven")
              assert_equal(hunk_with(remaining, "delete", "two"), nil)
              repo:cleanup()
              done()
            end)
          end)
        end)
      end)
    end)
  end)
end)

it("unstages exactly one changed hunk of a rename with spaces", function(done)
  local repo = git_repo.new()
  repo:write("old name.txt", {
    "one", "two", "three", "four", "five", "six", "seven", "eight",
  })
  repo:git({ "add", "--", "old name.txt" })
  repo:commit("base")
  repo:git({ "mv", "old name.txt", "new name.txt" })
  repo:write("new name.txt", {
    "one", "two renamed", "three", "four", "five", "six", "seven renamed", "eight",
  })
  repo:git({ "add", "--", "new name.txt" })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    local change = find_change(current.staged, "new name.txt")
    assert_truthy(change)
    assert_equal(change.old_path, "old name.txt")
    diff(git, repo.root, change, function(index)
      local selected = hunk_with(index, "add", "two renamed")
      assert_truthy(selected)
      git:unstage_hunk(repo.root, index, selected, function(unstage_result)
        assert_truthy(unstage_result.ok)
        status(git, repo.root, function(after_unstage)
          local staged_change = find_change(after_unstage.staged, "new name.txt")
          assert_truthy(staged_change)
          assert_equal(staged_change.old_path, "old name.txt")
          diff(git, repo.root, staged_change, function(staged)
            diff(git, repo.root, find_change(after_unstage.unstaged, "new name.txt"), function(remaining)
              assert_equal(hunk_with(staged, "add", "two renamed"), nil)
              assert_hunk(staged, "add", "seven renamed")
              assert_hunk(remaining, "add", "two renamed")
              assert_equal(hunk_with(remaining, "add", "seven renamed"), nil)
              repo:cleanup()
              done()
            end)
          end)
        end)
      end)
    end)
  end)
end)

it("stages exactly one unstaged hunk after a rename with spaces", function(done)
  local repo = git_repo.new()
  repo:write("old name.txt", {
    "one", "two", "three", "four", "five", "six", "seven", "eight",
  })
  repo:git({ "add", "--", "old name.txt" })
  repo:commit("base")
  assert_equal(vim.uv.fs_rename(repo.root .. "/old name.txt", repo.root .. "/new name.txt"), true)
  repo:write("new name.txt", {
    "one", "two staged", "three", "four", "five", "six", "seven remains", "eight",
  })
  repo:git({ "add", "-N", "--", "new name.txt" })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    local change = find_change(current.unstaged, "new name.txt")
    assert_truthy(change)
    assert_equal(change.status, "R")
    assert_equal(change.old_path, "old name.txt")
    diff(git, repo.root, change, function(worktree)
      assert_truthy((worktree.patch or ""):find("rename from old name.txt", 1, true) ~= nil)
      assert_truthy((worktree.patch or ""):find("rename to new name.txt", 1, true) ~= nil)
      local selected = hunk_with(worktree, "add", "two staged")
      assert_truthy(selected)
      git:stage_hunk(repo.root, worktree, selected, function(result)
        assert_truthy(result.ok)
        status(git, repo.root, function(after)
          local staged = find_change(after.staged, "new name.txt")
          local remaining = find_change(after.unstaged, "new name.txt")
          assert_truthy(staged)
          assert_truthy(remaining)
          diff(git, repo.root, staged, function(staged_diff)
            diff(git, repo.root, remaining, function(remaining_diff)
              assert_hunk(staged_diff, "add", "two staged")
              assert_equal(hunk_with(staged_diff, "add", "seven remains"), nil)
              assert_hunk(remaining_diff, "add", "seven remains")
              assert_equal(hunk_with(remaining_diff, "add", "two staged"), nil)
              repo:cleanup()
              done()
            end)
          end)
        end)
      end)
    end)
  end)
end)

it("keeps quoted rename index headers while reverse-applying one hunk", function(done)
  local cases = {
    { old = "old \"quote\".txt", new = "new \"quote\".txt" },
    { old = "old\\slash.txt", new = "new\\slash.txt" },
    { old = "old\tname.txt", new = "new\tname.txt" },
    { old = "старый-Ё.txt", new = "новый-Ё.txt" },
  }
  local index = 1

  local function next_case()
    local names = cases[index]
    if not names then
      done()
      return
    end
    index = index + 1
    local repo = git_repo.new()
    local ok, message = xpcall(function()
      repo:write(names.old, { "one", "two", "three", "four", "five", "six", "seven", "eight" })
      repo:git({ "add", "--", names.old })
      repo:commit("base")
      repo:git({ "mv", names.old, names.new })
      repo:write(names.new, { "one", "two reverse", "three", "four", "five", "six", "seven preserved", "eight" })
      repo:git({ "add", "--", names.new })
      local calls = {}
      local recording_process = {
        run = function(args, opts, callback)
          calls[#calls + 1] = { args = vim.deepcopy(args), stdin = opts and opts.stdin }
          return process.run(args, opts, callback)
        end,
      }
      local git = git_cli.new(recording_process)
      status(git, repo.root, function(current)
        local change = find_change(current.staged, names.new)
        assert_truthy(change)
        diff(git, repo.root, change, function(staged)
          local selected = hunk_with(staged, "add", "two reverse")
          assert_truthy(selected)
          local original = vim.system({
            "git", "--literal-pathspecs", "diff", "--cached", "--binary", "--full-index", "--", names.old, names.new,
          }, { cwd = repo.root, text = false }):wait()
          assert_equal(original.code, 0)
          local index_header = assert((original.stdout or ""):match("\n(index [^\n]+)"))
          git:unstage_hunk(repo.root, staged, selected, function(result)
            assert_truthy(result.ok)
            local reverse_calls = {}
            for _, call in ipairs(calls) do
              local reverse = false
              for _, argument in ipairs(call.args) do
                if argument == "--reverse" then reverse = true end
              end
              if call.args[1] == "git" and call.args[2] == "apply" and reverse then
                reverse_calls[#reverse_calls + 1] = call
              end
            end
            assert_equal(#reverse_calls, 2)
            assert_truthy(reverse_calls[1].stdin:find(index_header, 1, true) ~= nil)
            assert_equal(reverse_calls[1].stdin, reverse_calls[2].stdin)
            status(git, repo.root, function(after)
              local remaining = find_change(after.staged, names.new)
              assert_truthy(remaining)
              local header = vim.system({
                "git", "--literal-pathspecs", "diff", "--cached", "--binary", "--full-index", "--", names.old, names.new,
              }, { cwd = repo.root, text = false }):wait()
              assert_equal(header.code, 0)
              assert_truthy((header.stdout or ""):find("index ", 1, true) ~= nil)
              assert_truthy((header.stdout or ""):find("rename from ", 1, true) ~= nil)
              assert_truthy((header.stdout or ""):find("rename to ", 1, true) ~= nil)
              diff(git, repo.root, remaining, function(remaining_diff)
                assert_hunk(remaining_diff, "add", "seven preserved")
                assert_equal(hunk_with(remaining_diff, "add", "two reverse"), nil)
                repo:cleanup()
                next_case()
              end)
            end)
          end)
        end)
      end)
    end, debug.traceback)
    if not ok then
      repo:cleanup()
      error(message, 0)
    end
  end

  next_case()
end)

it("stages one worktree hunk of an added file already represented in the index", function(done)
  local repo = git_repo.new()
  repo:write("sentinel.txt", { "base" })
  repo:git({ "add", "--", "sentinel.txt" })
  repo:commit("base")
  repo:write("added.txt", {
    "one", "two", "three", "four", "five", "six", "seven", "eight",
  })
  repo:git({ "add", "--", "added.txt" })
  repo:write("added.txt", {
    "one", "two index", "three", "four", "five", "six", "seven worktree", "eight",
  })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    local change = find_change(current.unstaged, "added.txt")
    diff(git, repo.root, change, function(worktree)
      local selected = hunk_with(worktree, "add", "two index")
      git:stage_hunk(repo.root, worktree, selected, function(stage_result)
        assert_truthy(stage_result.ok)
        status(git, repo.root, function(after_stage)
          local staged_change = find_change(after_stage.staged, "added.txt")
          assert_truthy(staged_change)
          diff(git, repo.root, find_change(after_stage.unstaged, "added.txt"), function(remaining)
            assert_hunk(remaining, "add", "seven worktree")
            assert_equal(hunk_with(remaining, "add", "two index"), nil)
            repo:cleanup()
            done()
          end)
        end)
      end)
    end)
  end)
end)

it("rejects a completely untracked file hunk without changing the index", function(done)
  local repo = git_repo.new()
  repo:write("untracked.txt", { "one", "two" })
  local git = git_cli.new(process)

  status(git, repo.root, function(current)
    local change = find_change(current.unstaged, "untracked.txt")
    diff(git, repo.root, change, function(worktree)
      git:stage_hunk(repo.root, worktree, worktree.hunks[1], function(result)
        assert_equal(result.ok, false)
        assert_equal(result.error.code, "unsupported_hunk")
        status(git, repo.root, function(after)
          assert_equal(#after.staged, 0)
          assert_truthy(find_change(after.unstaged, "untracked.txt"))
          repo:cleanup()
          done()
        end)
      end)
    end)
  end)
end)
