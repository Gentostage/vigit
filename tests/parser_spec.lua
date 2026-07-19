local parser = require("vigit.parser")

describe("parser", function() end)

it("splits porcelain status into staged and unstaged files", function()
  local result = parser.parse_status(table.concat({
    " M lua/a.lua",
    "M  lua/b.lua",
    "MM lua/c.lua",
    "A  lua/new.lua",
    "R  old.lua -> lua/renamed.lua",
  }, "\n"))

  assert_equal(#result.unstaged, 2)
  assert_equal(result.unstaged[1].path, "lua/a.lua")
  assert_equal(result.unstaged[1].status, "M")
  assert_equal(result.unstaged[2].path, "lua/c.lua")

  assert_equal(#result.staged, 4)
  assert_equal(result.staged[1].path, "lua/b.lua")
  assert_equal(result.staged[3].status, "A")
  assert_equal(result.staged[4].old_path, "old.lua")
  assert_equal(result.staged[4].path, "lua/renamed.lua")
end)

it("omits ignored porcelain status entries", function()
  local result = parser.parse_status("!! ignored.log")

  assert_equal(#result.staged, 0)
  assert_equal(#result.unstaged, 0)
end)

it("parses unified diff into files and hunks", function()
  local diff = table.concat({
    "diff --git a/lua/a.lua b/lua/a.lua",
    "index 1111111..2222222 100644",
    "--- a/lua/a.lua",
    "+++ b/lua/a.lua",
    "@@ -1,2 +1,2 @@",
    " local x = 1",
    "-local y = 2",
    "+local y = 3",
  }, "\n")

  local files = parser.parse_diff(diff, "unstaged")

  assert_equal(#files, 1)
  assert_equal(files[1].path, "lua/a.lua")
  assert_equal(files[1].section, "unstaged")
  assert_equal(#files[1].hunks, 1)
  assert_equal(files[1].hunks[1].old_start, 1)
  assert_equal(files[1].hunks[1].old_count, 2)
  assert_equal(files[1].hunks[1].new_start, 1)
  assert_equal(files[1].hunks[1].new_count, 2)
  assert_equal(files[1].hunks[1].lines[2].kind, "removed")
  assert_equal(files[1].hunks[1].lines[3].kind, "added")
end)
