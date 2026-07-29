local keymaps = require("vigit.ui.keymaps")
local help = require("vigit.ui.views.help")

local function active_entries(entries)
  local result = {}
  for _, entry in ipairs(entries) do
    result[#result + 1] = entry
  end
  return result
end

it("keeps action ids and active context mappings unique", function()
  local ids = {}
  local bindings = {}
  for _, entry in ipairs(active_entries(keymaps.entries())) do
    assert_equal(ids[entry.id], nil)
    ids[entry.id] = true
    for _, context in ipairs(entry.contexts) do
      for _, mode in ipairs(entry.modes) do
        local binding = table.concat({ context, mode, entry.lhs }, "\0")
        assert_equal(bindings[binding], nil)
        bindings[binding] = true
      end
    end
  end
end)

it("omits disabled mappings from a context", function()
  local entries = keymaps.for_context("diff", {
    keymaps = { ["change.restore"] = false },
  })

  for _, entry in ipairs(entries) do
    assert_truthy(entry.id ~= "change.restore")
  end
end)

it("omits disabled mappings from inline help", function()
  local lines = table.concat(help.lines("diff", {
    keymaps = { ["change.restore"] = false },
  }), "\n")

  assert_equal(lines:find("Restore current file to HEAD", 1, true), nil)
end)

it("renders inline help and Markdown from the active registry", function()
  local lines = table.concat(help.lines("diff"), "\n")
  local markdown = keymaps.render_markdown()

  for _, entry in ipairs(keymaps.for_context("diff")) do
    assert_truthy(lines:find(entry.description, 1, true) ~= nil)
    assert_truthy(markdown:find(entry.description, 1, true) ~= nil)
  end
  assert_equal(markdown:sub(-2), "|\n")
end)

it("builds display-width-safe auxiliary hints from active mappings", function()
  local hints = keymaps.hints("worktrees", 16, {
    keymaps = { ["worktrees.fetch"] = false },
  })

  assert_truthy(keymaps.display_width(hints) <= 16)
  assert_equal(hints:find("fetch", 1, true), nil)
  assert_equal(keymaps.display_width("界"), 2)
end)
