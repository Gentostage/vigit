local status = require("vigit.core.status")

it("parses branch metadata and NUL-delimited ordinary changes", function()
  local raw = table.concat({
    "# branch.oid 0123456789abcdef",
    "# branch.head feature/read-models",
    "# branch.upstream origin/feature/read-models",
    "# branch.ab +2 -3",
    "1 .M N... 100644 100644 100644 aaaa bbbb src/a b.lua",
    "? notes/новый.md",
    "",
  }, "\0")

  local result = status.parse(raw)

  assert_truthy(result.ok)
  assert_equal(result.value.branch, {
    oid = "0123456789abcdef",
    head = "feature/read-models",
    upstream = "origin/feature/read-models",
    ahead = 2,
    behind = 3,
  })
  assert_equal(result.value.unstaged[1], {
    id = "unstaged\0src/a b.lua",
    section = "unstaged",
    status = "M",
    path = "src/a b.lua",
  })
  assert_equal(result.value.unstaged[2], {
    id = "unstaged\0notes/новый.md",
    section = "unstaged",
    status = "?",
    path = "notes/новый.md",
  })
  assert_equal(#result.value.staged, 0)
end)

it("consumes the NUL field after a rename as old_path", function()
  local raw = table.concat({
    "2 R. N... 100644 100644 100644 aaaa bbbb R100 new/name.lua",
    "old/name.lua",
    "1 M. N... 100644 100644 100644 aaaa bbbb --leading-dash.lua",
    "",
  }, "\0")

  local result = status.parse(raw)

  assert_truthy(result.ok)
  assert_equal(result.value.staged[1], {
    id = "staged\0new/name.lua",
    section = "staged",
    status = "R",
    path = "new/name.lua",
    old_path = "old/name.lua",
  })
  assert_equal(result.value.staged[2].path, "--leading-dash.lua")
end)

it("emits both entries when index and worktree states differ", function()
  local raw = "1 MM N... 100644 100644 100644 aaaa bbbb src/both.lua\0"

  local result = status.parse(raw)

  assert_truthy(result.ok)
  assert_equal(result.value.staged[1].id, "staged\0src/both.lua")
  assert_equal(result.value.staged[1].status, "M")
  assert_equal(result.value.unstaged[1].id, "unstaged\0src/both.lua")
  assert_equal(result.value.unstaged[1].status, "M")
end)

it("represents unborn and detached branch headers", function()
  local raw = table.concat({
    "# branch.oid (initial)",
    "# branch.head (detached)",
    "",
  }, "\0")

  local result = status.parse(raw)

  assert_truthy(result.ok)
  assert_equal(result.value.branch.oid, nil)
  assert_equal(result.value.branch.head, nil)
end)

it("parses unmerged records with all three stage hashes", function()
  local raw = table.concat({
    "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.lua",
    "",
  }, "\0")

  local result = status.parse(raw)

  assert_truthy(result.ok)
  assert_equal(result.value.staged[1].status, "U")
  assert_equal(result.value.unstaged[1].status, "U")
  assert_equal(result.value.unstaged[1].path, "conflict.lua")
end)

it("rejects malformed ordinary and rename records", function()
  local ordinary = status.parse("1 .M missing-fields\0")
  local rename = status.parse(
    "2 R. N... 100644 100644 100644 aaaa bbbb R100 new/name.lua\0"
  )

  assert_equal(ordinary.error.code, "malformed_status")
  assert_equal(rename.error.code, "malformed_status")
end)
