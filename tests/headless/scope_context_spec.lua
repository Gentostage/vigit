local Diff = require("vigit.core.diff")
local diff_view = require("vigit.ui.views.diff")
local highlights = require("vigit.ui.highlights")

local change = {
  id = "unstaged\0scope.py",
  section = "unstaged",
  status = "M",
  path = "scope.py",
}

local function review(lines, symbols)
  local raw = table.concat(lines, "\n")
  local parsed = Diff.parse(raw, change)
  assert_truthy(parsed.ok)
  local rendered = diff_view.render({
    data = {
      status = { staged = {}, unstaged = { change } },
      diffs = { [change.id] = parsed.value },
    },
    view = { diff_mode = "one_file", selected_change_id = change.id },
  }, 100)
  local buffer = vim.api.nvim_create_buf(false, true)
  local namespace = vim.api.nvim_create_namespace("vigit-test-scope-context")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, rendered.lines)
  local inspections = {}
  for side, side_symbols in pairs(symbols or {}) do
    inspections[side] = { language = "python", captures = {}, symbols = side_symbols }
  end
  highlights.apply_diff(buffer, rendered, { [change.id] = inspections }, namespace)
  local contexts = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })) do
    if mark[4].virt_text then
      contexts[#contexts + 1] = { row = mark[2] + 1, text = mark[4].virt_text[1][1] }
    end
  end
  vim.api.nvim_buf_delete(buffer, { force = true })
  assert_equal(parsed.value.patch, raw)
  return contexts, rendered
end

local function symbol(kind, name, label, start_row, end_row)
  return {
    kind = kind,
    name = name,
    label = label,
    start_row = start_row,
    end_row = end_row,
    declaration_row = start_row,
  }
end

it("не подписывает удалённые chunks, если объявление уже есть в diff", function()
  local contexts, rendered = review({
    "@@ -1,2 +1,1 @@ def run():",
    " def run():",
    "-    removed",
    "@@ -10 +9,0 @@ def run():",
    "-    removed later",
    "",
  }, {
    old = { symbol("function", "run", "run()", 0, 11) },
    new = { symbol("function", "run", "run()", 0, 9) },
  })
  assert_equal(#contexts, 0)
  local declarations = 0
  for _, row in ipairs(rendered.rows) do
    if row.text == "def run():" then declarations = declarations + 1 end
  end
  assert_equal(declarations, 1)
end)

it("не повторяет hidden scope между hunks, но различает одноимённые функции", function()
  local contexts, rendered = review({
    "@@ -5 +5 @@ def run():",
    "-    before",
    "+    after",
    "@@ -10 +10,0 @@ def run():",
    "-    removed",
    "@@ -20 +19 @@ def run():",
    "-    other before",
    "+    other after",
    "",
  }, {
    old = {
      symbol("function", "run", "run()", 0, 12),
      symbol("function", "run", "run()", 18, 24),
    },
    new = {
      symbol("function", "run", "run()", 0, 11),
      symbol("function", "run", "run()", 17, 23),
    },
  })
  assert_equal(#contexts, 2)
  assert_equal(contexts[1].text, " · run()")
  assert_equal(contexts[2].text, " · run()")
  assert_equal(rendered.rows[contexts[1].row].source_anchor.source_line, 5)
  assert_equal(rendered.rows[contexts[2].row].source_anchor.source_line, 19)
end)

it("показывает только скрытый class, когда объявление метода видно", function()
  local symbols = {
    symbol("class", "Service", "Service", 0, 10),
    symbol("method", "run", "Service.run()", 4, 9),
  }
  local contexts = review({
    "@@ -5,2 +5,2 @@ class Service:",
    "     def run(self):",
    "-        before",
    "+        after",
    "",
  }, { old = symbols, new = symbols })
  assert_equal(#contexts, 1)
  assert_equal(contexts[1].text, " · Service")
end)

it("показывает old scope, когда новый код находится вне функции", function()
  local contexts = review({
    "@@ -5 +5 @@ def run():",
    "-    old body",
    "+new_global = 1",
    "",
  }, {
    old = { symbol("function", "run", "run()", 0, 9) },
    new = {},
  })
  assert_equal(#contexts, 1)
  assert_equal(contexts[1].text, " · run()")
end)

it("без parser показывает только скрытый Git context и не повторяет его", function()
  local visible = review({
    "@@ -1,2 +1,2 @@ def run():",
    " def run():",
    "-    before",
    "+    after",
    "@@ -10 +10 @@ def run():",
    "-    before tail",
    "+    after tail",
    "",
  })
  assert_equal(#visible, 0)

  local hidden = review({
    "@@ -5 +5 @@ def run():",
    "-    before",
    "+    after",
    "@@ -10 +10 @@ def run():",
    "-    before tail",
    "+    after tail",
    "",
  })
  assert_equal(#hidden, 1)
  assert_equal(hidden[1].text, " · def run():")
end)

it("сохраняет fallback для пустых symbols, но не возвращает старый известный scope", function()
  local hidden = review({
    "@@ -6,3 +6,3 @@ local run = function()",
    "     4,",
    "-    5,",
    "+    6,",
    "   }",
    "",
  }, { old = {}, new = {} })
  assert_equal(#hidden, 1)
  assert_equal(hidden[1].text, " · local run = function()")

  local outside = review({
    "@@ -6 +6 @@ def run():",
    "-before_global = 1",
    "+after_global = 2",
    "",
  }, {
    old = { symbol("function", "run", "run()", 0, 2) },
    new = { symbol("function", "run", "run()", 0, 2) },
  })
  assert_equal(#outside, 0)
end)
