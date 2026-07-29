local function read(path)
  local handle = assert(io.open(path, "rb"))
  local content = handle:read("*a")
  handle:close()
  return content
end

it("bundled skill resolves only open comments and records the agent result", function()
  local content = read("skills/vigit-review/SKILL.md")

  assert_truthy(content:find("только открытые", 1, true))
  assert_truthy(content:find("### Ответ агента", 1, true))
  assert_truthy(content:find("[x]", 1, true))
  assert_truthy(content:find("неизвестный Markdown", 1, true))
  assert_truthy(content:find("не stage, commit или push", 1, true))
  assert_equal(content:find("Do not edit `comments.md`", 1, true), nil)
end)

it("bundled skill metadata invokes the exact installed skill", function()
  local content = read("skills/vigit-review/agents/openai.yaml")

  assert_truthy(content:find("$vigit-review", 1, true))
  assert_truthy(content:find(".vigit/comments.md", 1, true))
end)
