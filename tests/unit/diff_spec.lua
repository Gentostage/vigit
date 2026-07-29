local diff = require("vigit.core.diff")

local change = {
  id = "unstaged\0src/a.lua",
  section = "unstaged",
  status = "M",
  path = "src/a.lua",
}

it("parses unified hunks into marker-free line models", function()
  local fixture_patch = table.concat({
    "diff --git a/src/a.lua b/src/a.lua",
    "index 1111111..2222222 100644",
    "--- a/src/a.lua",
    "+++ b/src/a.lua",
    "@@ -10,2 +10,2 @@ local scope",
    "-local old = true",
    "+local new = true",
    "",
  }, "\n")

  local parsed = diff.parse(fixture_patch, change)

  assert_truthy(parsed.ok)
  assert_equal(parsed.value.headers, {
    "diff --git a/src/a.lua b/src/a.lua",
    "index 1111111..2222222 100644",
    "--- a/src/a.lua",
    "+++ b/src/a.lua",
  })
  assert_equal(parsed.value.hunks[1].id, change.id .. "\0" .. "10:10")
  assert_equal(parsed.value.hunks[1].header, "@@ -10,2 +10,2 @@ local scope")
  assert_equal(parsed.value.hunks[1].patch, table.concat({
    "@@ -10,2 +10,2 @@ local scope",
    "-local old = true",
    "+local new = true",
  }, "\n"))
  assert_equal(parsed.value.hunks[1].lines[1], {
    kind = "delete",
    text = "local old = true",
    old_line = 10,
    new_line = nil,
  })
  assert_equal(parsed.value.hunks[1].lines[2], {
    kind = "add",
    text = "local new = true",
    old_line = nil,
    new_line = 10,
  })
end)

it("strips exactly one diff marker from code text", function()
  local parsed = diff.parse(table.concat({
    "diff --git a/src/a.lua b/src/a.lua",
    "--- a/src/a.lua",
    "+++ b/src/a.lua",
    "@@ -1 +1 @@",
    "--old",
    "++new",
    "",
  }, "\n"), change)

  assert_truthy(parsed.ok)
  assert_equal(parsed.value.hunks[1].lines[1].text, "-old")
  assert_equal(parsed.value.hunks[1].lines[2].text, "+new")
end)

it("tracks context line numbers and preserves no-newline metadata", function()
  local parsed = diff.parse(table.concat({
    "diff --git a/src/a.lua b/src/a.lua",
    "--- a/src/a.lua",
    "+++ b/src/a.lua",
    "@@ -4,2 +4,2 @@",
    " same",
    "-old",
    "\\ No newline at end of file",
    "+new",
    "",
  }, "\n"), change)

  assert_truthy(parsed.ok)
  assert_equal(parsed.value.hunks[1].lines[1], {
    kind = "context",
    text = "same",
    old_line = 4,
    new_line = 4,
  })
  assert_equal(parsed.value.hunks[1].lines[3], {
    kind = "meta",
    text = "\\ No newline at end of file",
    old_line = nil,
    new_line = nil,
  })
end)

it("removes CR from display text while preserving exact hunk patch bytes", function()
  local raw = table.concat({
    "diff --git a/src/a.lua b/src/a.lua",
    "--- a/src/a.lua",
    "+++ b/src/a.lua",
    "@@ -1 +1 @@",
    "-local old = true\r",
    "+local new = true\r",
    "",
  }, "\n")

  local parsed = diff.parse(raw, change)

  assert_truthy(parsed.ok)
  assert_equal(parsed.value.hunks[1].lines[1].text, "local old = true")
  assert_equal(parsed.value.hunks[1].lines[2].text, "local new = true")
  assert_equal(parsed.value.hunks[1].patch, table.concat({
    "@@ -1 +1 @@",
    "-local old = true\r",
    "+local new = true\r",
  }, "\n"))
  assert_equal(parsed.value.patch, raw)
end)

it("detects binary patches without fabricating hunks", function()
  local parsed = diff.parse(table.concat({
    "diff --git a/image.png b/image.png",
    "index 1111111..2222222 100644",
    "Binary files a/image.png and b/image.png differ",
    "",
  }, "\n"), {
    id = "unstaged\0image.png",
    section = "unstaged",
    status = "M",
    path = "image.png",
  })

  assert_truthy(parsed.ok)
  assert_equal(parsed.value.binary, true)
  assert_equal(#parsed.value.hunks, 0)
end)

it("rejects combined conflict hunks instead of returning an empty diff", function()
  local parsed = diff.parse(table.concat({
    "diff --cc conflict.lua",
    "index 1111111,2222222..3333333",
    "--- a/conflict.lua",
    "+++ b/conflict.lua",
    "@@@ -1,1 -1,1 +1,1 @@@",
    "- -ours",
    " +theirs",
    "",
  }, "\n"), {
    id = "unstaged\0conflict.lua",
    section = "unstaged",
    status = "U",
    path = "conflict.lua",
    unmerged = true,
  })

  assert_equal(parsed.error.code, "unsupported_combined_diff")
end)

it("rejects malformed hunk headers", function()
  local parsed = diff.parse(table.concat({
    "diff --git a/src/a.lua b/src/a.lua",
    "@@ broken @@",
    "-old",
    "",
  }, "\n"), change)

  assert_equal(parsed.error.code, "malformed_diff")
end)
