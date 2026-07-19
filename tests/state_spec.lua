local State = require("vigit.state")

local fake_git = {
  status = function()
    return {
      unstaged = { { path = "lua/a.lua", status = "M", section = "unstaged" } },
      staged = { { path = "README.md", status = "M", section = "staged" } },
    }
  end,
  diff = function(section)
    return {
      {
        path = section == "unstaged" and "lua/a.lua" or "README.md",
        section = section,
        hunks = {
          { header = "@@ -1 +1 @@", patch_lines = { "@@ -1 +1 @@", "-old", "+new" } },
        },
        lines = {
          { kind = "hunk", text = "@@ -1 +1 @@" },
          { kind = "removed", text = "-old" },
          { kind = "added", text = "+new" },
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
  assert_equal(state.changes_lines[1], "Unstaged")
  assert_equal(state.changes_lines[2], " M lua/a.lua")
  assert_equal(state.diff_lines[1], "Unstaged")
  assert_equal(state.diff_lines[2], "@@ lua/a.lua")
end)

it("looks up files and hunks from rendered cursor lines", function()
  local state = State.new({ git = fake_git })
  state:refresh()

  local file = state:file_at_line("changes", 2)
  assert_equal(file.path, "lua/a.lua")

  local hunk = state:hunk_at_line(3)
  assert_truthy(hunk)
  assert_equal(hunk.file.path, "lua/a.lua")
end)
