local State = require("vigit.state")

local fake_git = {
  status = function()
    return {
      unstaged = { { path = "lua/a.lua", status = "M", section = "unstaged" } },
      staged = { { path = "README.md", status = "M", section = "staged" } },
    }
  end,
  diff = function(section)
    local hunk = {
      header = "@@ -1 +1 @@",
      old_start = 1,
      old_count = 1,
      new_start = 1,
      new_count = 1,
      patch_lines = { "@@ -1 +1 @@", "-old", "+new" },
    }
    return {
      {
        path = section == "unstaged" and "lua/a.lua" or "README.md",
        section = section,
        target_line = 1,
        hunks = { hunk },
        lines = {
          { kind = "hunk", text = "@@ -1 +1 @@", hunk = hunk, target_line = 1 },
          { kind = "removed", text = "-old", hunk = hunk, old_line = 1, target_line = 1 },
          { kind = "added", text = "+new", hunk = hunk, new_line = 1, target_line = 1 },
        },
      },
    }
  end,
}

it("refresh builds changes and diff render lines", function()
  local state = State.new({ git = fake_git })
  local ok, err = state:refresh()

  assert_equal(ok, true)
  assert_equal(err, nil)
  assert_equal(state.changes_lines[1], "Staged")
  assert_equal(state.changes_lines[2], " M README.md")
  assert_equal(state.diff_lines[1], "Unstaged")
  assert_truthy(state.diff_lines[2]:match("lua/a.lua"))
end)

it("looks up files and hunks from rendered cursor lines", function()
  local state = State.new({ git = fake_git })
  state:refresh()

  local file = state:file_at_line("changes", 2)
  assert_equal(file.path, "README.md")

  local hunk = state:hunk_at_line(3)
  assert_truthy(hunk)
  assert_equal(hunk.file.path, "lua/a.lua")
end)
