local review = require("vigit.core.review")

local function assert_ok(result)
  assert_truthy(result.ok)
  return result.value
end

local markdown = table.concat({
  "# Vigit Review\n",
  "\n",
  "Преамбула, которую Vigit не интерпретирует.\n",
  "\n",
  "## [ ] VIGIT-001 · src/one.lua:4\n",
  "\n",
  "<!-- vigit-anchor\n",
  "path: src/one.lua\n",
  "line: 4\n",
  "side: new\n",
  "section: unstaged\n",
  [[context: local first = "quoted"\nsecond
]],
  "-->\n",
  "\n",
  "Первый комментарий.\n",
  "\n",
  "### Ответ агента\n",
  "\n",
  "Первый ответ.\n",
  "\n",
  "## [x] VIGIT-009 · src/two.lua:8\n",
  "\n",
  "<!-- vigit-anchor\n",
  "path: src/two.lua\n",
  "line: 8\n",
  "column: 2\n",
  "side: old\n",
  "section: staged\n",
  "context: before change\n",
  "-->\n",
  "\n",
  "Второй комментарий.\n",
  "\n",
  "### Ответ агента\n",
  "\n",
  "Второй ответ.\n",
})

it("preserves untouched blocks byte-for-byte when another comment changes", function()
  local document = assert_ok(review.parse(markdown))
  local first_raw = document.blocks[2].raw
  local updated = assert_ok(review.update(document, "VIGIT-009", {
    body = "Изменённый второй комментарий.",
  }))
  local rendered = review.serialize(updated)

  assert_truthy(rendered:find("Преамбула, которую Vigit не интерпретирует.\n", 1, true))
  assert_truthy(rendered:find(first_raw, 1, true))
  assert_truthy(rendered:find("Изменённый второй комментарий.\n", 1, true))
end)

it("canonicalizes changed fields including multiline escaped context", function()
  local document = assert_ok(review.parse(markdown))
  local updated = assert_ok(review.update(document, "VIGIT-001", {
    done = true,
    response = "Готово.",
    context = "first line\nsecond line\\tail",
  }))
  local rendered = review.serialize(updated)

  assert_truthy(rendered:find("## [x] VIGIT-001 · src/one.lua:4\n", 1, true))
  assert_truthy(rendered:find("context: first line\\nsecond line\\\\tail\n", 1, true))
  assert_truthy(rendered:find("### Ответ агента\n\nГотово.\n", 1, true))
end)

it("assigns the next ID from the greatest numeric suffix", function()
  local document = assert_ok(review.parse(markdown))
  local added = assert_ok(review.add(document, {
    path = "src/new.lua",
    line = 12,
    side = "new",
    section = "unstaged",
    context = "return value",
    body = "Новый комментарий.",
  }))

  assert_equal(added.last_added.id, "VIGIT-010")
  assert_truthy(review.serialize(added):find("## [ ] VIGIT-010 · src/new.lua:12\n", 1, true))
end)

it("deletes only the selected comment and normalizes its separator", function()
  local document = assert_ok(review.parse(markdown))
  local deleted = assert_ok(review.delete(document, "VIGIT-001"))
  local rendered = review.serialize(deleted)

  assert_equal(rendered:find("VIGIT-001", 1, true), nil)
  assert_truthy(rendered:find("VIGIT-009", 1, true))
  assert_truthy(rendered:find("Преамбула, которую Vigit не интерпретирует.\n\n## [x]", 1, true))
end)

it("renders a prompt with only open comments and no mutation instructions", function()
  local document = assert_ok(review.parse(markdown))
  local prompt = review.prompt(document, "/work/repo")

  assert_truthy(prompt:find("/work/repo", 1, true))
  assert_truthy(prompt:find("VIGIT-001", 1, true))
  assert_equal(prompt:find("VIGIT-009", 1, true), nil)
  assert_truthy(prompt:find("не stage, commit или push", 1, true))
end)

it("rejects duplicate IDs, malformed metadata and unsafe paths", function()
  local duplicate = markdown:gsub("VIGIT%-009", "VIGIT-001")
  assert_equal(review.parse(duplicate).error.code, "duplicate_id")

  local malformed = markdown:gsub("side: old\n", "side: old\nside: new\n")
  assert_equal(review.parse(malformed).error.code, "malformed_metadata")

  local unsafe = assert_ok(review.parse(markdown))
  assert_equal(review.add(unsafe, {
    path = "../outside.lua",
    line = 1,
    side = "new",
    section = "unstaged",
    context = "x",
    body = "x",
  }).error.code, "invalid_path")
end)

it("rejects a comment without the required agent response delimiter", function()
  local missing_response = markdown:gsub("\n### Ответ агента\n\nПервый ответ.\n", "\n", 1)
  assert_equal(review.parse(missing_response).error.code, "malformed_comment")
end)

it("rejects reserved delimiters in added or updated user text", function()
  local document = assert_ok(review.parse(markdown))
  local input = {
    path = "src/new.lua", line = 1, side = "new", section = "unstaged",
    context = "return value", body = "## [ ] VIGIT-111 · src/escape.lua:1",
  }
  local added = review.add(document, input)
  assert_equal(added.error.code, "invalid_comment")
  assert_equal(added.error.message, "Comment text contains a reserved delimiter")
  assert_equal(review.update(document, "VIGIT-001", {
    response = "### Ответ агента",
  }).error.code, "invalid_comment")
end)

it("rejects invalid context escapes and a metadata close with trailing bytes", function()
  assert_equal(review.parse(markdown:gsub([[context: local first = "quoted"\nsecond]], "context: bad\\q")).error.code, "malformed_metadata")
  assert_equal(review.parse(markdown:gsub("-->\n", "-->TRAILING\n", 1)).error.code, "malformed_metadata")
end)

it("preserves terminal unknown prose bytes when adding a comment", function()
  local source = "Unknown terminal prose.\n\n\n"
  local document = assert_ok(review.parse(source))
  local added = assert_ok(review.add(document, {
    path = "src/new.lua", line = 1, side = "new", section = "unstaged",
    context = "return value", body = "New comment.",
  }))
  local rendered = review.serialize(added)
  assert_truthy(rendered:find("Unknown terminal prose.\n\n\n", 1, true))
end)

it("increments numeric suffixes beyond Lua number precision", function()
  local huge = markdown:gsub("VIGIT%-009", "VIGIT-999999999999999999999999999999999999999999")
  local document = assert_ok(review.parse(huge))
  local added = assert_ok(review.add(document, {
    path = "src/new.lua", line = 1, side = "new", section = "unstaged",
    context = "return value", body = "New comment.",
  }))
  assert_equal(added.last_added.id, "VIGIT-1000000000000000000000000000000000000000000")
end)

it("includes the canonical comment file and blocked-comment rule in the prompt", function()
  local document = assert_ok(review.parse(markdown))
  local prompt = review.prompt(document, "/work/repo")
  assert_truthy(prompt:find("/work/repo/.vigit/comments.md", 1, true))
  assert_truthy(prompt:find("остаётся `[ ]`", 1, true))
end)

it("round-trips a canonical context ending in one literal backslash", function()
  local document = assert_ok(review.parse(""))
  local added = assert_ok(review.add(document, {
    path = "src/new.lua", line = 1, side = "new", section = "unstaged",
    context = [=[ends with \]=], body = "New comment.",
  }))
  local reparsed = assert_ok(review.parse(review.serialize(added)))
  assert_equal(reparsed.comments[1].context, [=[ends with \]=])
end)

it("accepts exact CRLF lines but rejects doubled carriage returns", function()
  assert_truthy(review.parse(markdown:gsub("\n", "\r\n")).ok)
  assert_equal(review.parse(markdown:gsub("\n", "\r\r\n")).ok, false)
end)

it("accepts an empty context metadata value for a blank changed source line", function()
  local document = assert_ok(review.parse(""))
  local added = assert_ok(review.add(document, {
    path = "src/blank.lua", line = 2, side = "new", section = "unstaged", context = "", body = "Explain blank line.",
  }))
  local reparsed = assert_ok(review.parse(review.serialize(added)))
  assert_equal(reparsed.comments[1].context, "")
end)
