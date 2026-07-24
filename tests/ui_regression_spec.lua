local project_root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(project_root)
package.path = project_root .. "/lua/?.lua;" .. project_root .. "/lua/?/init.lua;" .. package.path

local failures = 0

local function test(name, callback)
  local ok, err = pcall(callback)
  if ok then
    print("PASS " .. name)
    return
  end
  failures = failures + 1
  print("FAIL " .. name)
  print(err)
end

local function run(cwd, command)
  local result = vim.system(command, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, table.concat(command, " ") .. ": " .. (result.stderr or result.stdout or "failed"))
end

local function create_repo(path, python_lines)
  vim.fn.mkdir(path, "p")
  run(path, { "git", "init", "-q" })
  run(path, { "git", "config", "user.email", "vigit@example.test" })
  run(path, { "git", "config", "user.name", "Vigit Test" })
  vim.fn.writefile(python_lines, path .. "/sample.py")
  run(path, { "git", "add", "sample.py" })
  run(path, { "git", "commit", "-qm", "initial" })
end

local function find_diff_row(session, predicate)
  for row, line in ipairs(session.state.diff_lines) do
    if predicate(line, session.state.diff_map[row]) then
      return row
    end
  end
  return nil
end

local temporary = vim.fn.tempname()
local repo_a = temporary .. "/repo-a"
local repo_b = temporary .. "/repo-b"
local original = {}
for index = 1, 120 do
  original[index] = string.format("value_%03d = %d", index, index)
end
original[30] = "class PaymentService:"
original[31] = "    def execute(self, items):"
for index = 32, 110 do
  original[index] = string.format("        value_%03d = %d", index, index)
end
original[111] = "        return items"

create_repo(repo_a, original)
create_repo(repo_b, { "value = 1" })
vim.fn.writefile(original, repo_a .. "/hidden.py")
run(repo_a, { "git", "add", "hidden.py" })
run(repo_a, { "git", "commit", "-qm", "add hidden fixture" })

local changed = vim.deepcopy(original)
changed[31] = "    async def execute(self, items):"
changed[90] = "        selected_target = items[0] + 1"
vim.fn.writefile(changed, repo_a .. "/sample.py")
local hidden_changed = vim.deepcopy(original)
hidden_changed[90] = "        hidden_target = items[0] + 1"
vim.fn.writefile(hidden_changed, repo_a .. "/hidden.py")
vim.fn.writefile({ "value = 2" }, repo_b .. "/sample.py")

local treesitter_plugin = nil
local treesitter_was_loaded = false
pcall(function()
  treesitter_plugin = require("lazy.core.config").plugins["nvim-treesitter"]
  treesitter_was_loaded = treesitter_plugin and treesitter_plugin._.loaded ~= nil or false
end)

local ui = require("vigit.ui")
local actions = require("vigit.actions")
local session_a = assert(ui.open({ cwd = repo_a }))
local python_parser_loaded = pcall(function()
  assert(vim.treesitter.language.add("python"))
  assert(vim.treesitter.query.get("python", "highlights"))
end)

local function syntax_test(name, callback)
  if not python_parser_loaded then
    print("SKIP " .. name .. " (Python TreeSitter parser is not installed)")
    return
  end
  test(name, callback)
end

if treesitter_plugin and not treesitter_was_loaded then
  test("first diff render loads installed nvim-treesitter", function()
    assert(treesitter_plugin._.loaded ~= nil, "nvim-treesitter stayed lazy")
  end)
end

syntax_test("Python keywords receive TreeSitter highlights in the diff", function()
  local row = assert(find_diff_row(session_a, function(line)
    return line:match("^%s+async def execute") ~= nil
  end), "changed Python function was not rendered")
  local marks = vim.api.nvim_buf_get_extmarks(
    session_a.diff_buf,
    -1,
    { row - 1, 0 },
    { row - 1, -1 },
    { details = true }
  )
  local highlighted = false
  local syntax_mark_count = 0
  for _, mark in ipairs(marks) do
    local group = mark[4] and mark[4].hl_group or nil
    if group and group:sub(1, 1) == "@" then
      syntax_mark_count = syntax_mark_count + 1
    end
    if group == "@keyword.function.python" then
      highlighted = true
    end
  end
  assert(highlighted, "TreeSitter Python keyword highlight is missing")
  assert(syntax_mark_count < 64, "TreeSitter range metadata created excessive highlights")
end)

syntax_test("removed Python keywords receive TreeSitter highlights", function()
  local row = assert(find_diff_row(session_a, function(line, meta)
    return line:match("^%s+def execute") ~= nil
      and meta
      and meta.change_kind == "removed"
  end), "removed Python function was not rendered")
  local marks = vim.api.nvim_buf_get_extmarks(
    session_a.diff_buf,
    -1,
    { row - 1, 0 },
    { row - 1, -1 },
    { details = true }
  )
  local highlighted = false
  for _, mark in ipairs(marks) do
    if mark[4] and mark[4].hl_group == "@keyword.function.python" then
      highlighted = true
      break
    end
  end
  assert(highlighted, "removed Python keyword highlight is missing")
end)

test("changed lines use gutter bars instead of textual diff markers", function()
  local added_row = assert(find_diff_row(session_a, function(line, meta)
    return line:match("^%s+selected_target") ~= nil
      and meta
      and meta.target_line == 90
      and meta.change_kind == "added"
  end), "added source line was not rendered without a textual marker")
  assert(session_a.state.diff_lines[added_row]:sub(1, 1) ~= "+", "added line still starts with +")

  local marks = vim.api.nvim_buf_get_extmarks(
    session_a.diff_buf,
    -1,
    { added_row - 1, 0 },
    { added_row - 1, -1 },
    { details = true }
  )
  local has_add_sign = false
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.sign_text
      and vim.trim(details.sign_text) == "▎"
      and details.sign_hl_group == "VigitDiffAddSign"
    then
      has_add_sign = true
      break
    end
  end
  assert(has_add_sign, "added line gutter marker is missing")

  local removed_row = assert(find_diff_row(session_a, function(line, meta)
    return line:match("^%s+def execute") ~= nil and meta and meta.change_kind == "removed"
  end), "removed source line was not rendered without a textual marker")
  assert(session_a.state.diff_lines[removed_row]:sub(1, 1) ~= "-", "removed line still starts with -")
  marks = vim.api.nvim_buf_get_extmarks(
    session_a.diff_buf,
    -1,
    { removed_row - 1, 0 },
    { removed_row - 1, -1 },
    { details = true }
  )
  local has_delete_sign = false
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.sign_text
      and vim.trim(details.sign_text) == "▎"
      and details.sign_hl_group == "VigitDiffDeleteSign"
    then
      has_delete_sign = true
      break
    end
  end
  assert(has_delete_sign, "removed line gutter marker is missing")
end)

local function gap_context(session, row)
  local marks = vim.api.nvim_buf_get_extmarks(
    session.diff_buf,
    -1,
    { row - 1, 0 },
    { row - 1, -1 },
    { details = true }
  )
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.virt_text and details.virt_text[1] and details.virt_text[1][2] == "VigitGapContext" then
      return details.virt_text[1][1]
    end
  end
  return nil
end

syntax_test("collapsed context omits visible class and function", function()
  local row = assert(find_diff_row(session_a, function(_, meta)
    return meta
      and meta.kind == "gap"
      and meta.file.path == "sample.py"
      and meta.target_line > 31
      and meta.target_line < 90
  end), "collapsed context between Python hunks was not rendered")
  local context = gap_context(session_a, row)
  assert(context == nil, "visible enclosing symbols were repeated in the gap")
end)

syntax_test("collapsed context shows hidden class and function", function()
  local row = assert(find_diff_row(session_a, function(_, meta)
    return meta
      and meta.kind == "gap"
      and meta.file.path == "hidden.py"
      and meta.target_line > 31
      and meta.target_line < 90
  end), "collapsed context before the Python hunk was not rendered")
  local context = gap_context(session_a, row)
  assert(context and context:match("PaymentService%.execute%("), "enclosing symbol is missing from gap")
end)

test("f keeps the cursor on the same source line", function()
  local row = assert(find_diff_row(session_a, function(line, meta)
    return line:match("^%s+selected_target") ~= nil and meta and meta.target_line == 90
  end), "target source line was not rendered")
  vim.api.nvim_set_current_win(session_a.diff_win)
  vim.api.nvim_win_set_cursor(session_a.diff_win, { row, 0 })

  actions.toggle_full_context(session_a)

  local current_row = vim.api.nvim_win_get_cursor(session_a.diff_win)[1]
  local current_meta = session_a.state.diff_map[current_row]
  assert(current_meta and current_meta.target_line == 90, "cursor moved away from source line 90")
end)

test("gd opens the source position and requests an LSP definition", function()
  local row = assert(find_diff_row(session_a, function(line, meta)
    return line:match("^%s+selected_target") ~= nil and meta and meta.target_line == 90
  end), "definition source line was not rendered")
  local diff_line = session_a.state.diff_lines[row]
  local symbol_column = assert(diff_line:find("selected_target", 1, true)) - 1
  vim.api.nvim_set_current_win(session_a.diff_win)
  vim.api.nvim_win_set_cursor(session_a.diff_win, { row, symbol_column })

  local mapping
  vim.api.nvim_buf_call(session_a.diff_buf, function()
    mapping = vim.fn.maparg("gd", "n", false, true)
  end)
  assert(mapping and type(mapping.callback) == "function", "gd buffer mapping is missing")

  local old_get_clients = vim.lsp.get_clients
  local old_definition = vim.lsp.buf.definition
  local definition_called = false
  vim.lsp.get_clients = function(opts)
    assert(opts.bufnr == vim.api.nvim_get_current_buf(), "LSP lookup used a different buffer")
    return {
      {
        supports_method = function(_, method)
          return method == "textDocument/definition"
        end,
      },
    }
  end
  vim.lsp.buf.definition = function()
    definition_called = true
  end

  local ok, err = pcall(mapping.callback)
  if ok then
    vim.wait(1000, function()
      return definition_called
    end, 20)
  end
  vim.lsp.get_clients = old_get_clients
  vim.lsp.buf.definition = old_definition
  assert(ok, err)
  assert(definition_called, "LSP definition was not requested")
  assert(vim.api.nvim_get_current_tabpage() == session_a.editor.tab, "definition did not use the edit tab")
  local cursor = vim.api.nvim_win_get_cursor(0)
  assert(cursor[1] == 90, "definition opened a different source line")
  assert(cursor[2] == symbol_column, "definition opened a different source column")
  assert(ui.return_from_editor(session_a))
end)

test("Q returns to the Vigit tab that opened the editor", function()
  local session_b = assert(ui.open({ cwd = repo_b }))
  assert(vim.api.nvim_get_current_tabpage() == session_b.vigit_tab, "second worktree tab is not active")
  local file = assert(session_a.state.diffs.unstaged[1], "edited file is missing")
  assert(ui.open_editor(session_a, file, 90))

  assert(ui.return_from_editor(session_a))

  assert(
    vim.api.nvim_get_current_tabpage() == session_a.vigit_tab,
    "Q returned to a different worktree tab"
  )
end)

test("? opens context-aware keymap help", function()
  vim.api.nvim_set_current_tabpage(session_a.vigit_tab)
  vim.api.nvim_set_current_win(session_a.diff_win)
  local mapping = vim.fn.maparg("?", "n", false, true)
  assert(mapping and type(mapping.callback) == "function", "diff help mapping is missing")
  assert(tostring(mapping.desc):match("Show Vigit help"), "diff help mapping has no description")

  mapping.callback()
  local help_buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[help_buf].filetype == "vigit-help", "help popup did not open")
  local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
  assert(
    vim.iter(lines):any(function(line)
      return line:match("CURRENT.*DIFF") ~= nil
    end),
    "help did not put the current diff context first"
  )
  local close_mapping = vim.fn.maparg("q", "n", false, true)
  assert(close_mapping and type(close_mapping.callback) == "function", "help close mapping is missing")
  close_mapping.callback()
end)

test("X removes an untracked file selected from one-file diff", function()
  local path = repo_a .. "/scratch.md"
  vim.fn.writefile({ "# scratch" }, path)
  actions.refresh(session_a)
  local file = nil
  for _, candidate in ipairs(session_a.state.diffs.unstaged) do
    if candidate.path == "scratch.md" then
      file = candidate
      break
    end
  end
  assert(file and file.status == "?", "untracked diff lost its status")
  assert(session_a.state:select_file(file))
  ui.render(session_a)
  local row = assert(session_a.state:diff_line_for_file(file), "untracked file header is missing")
  vim.api.nvim_set_current_win(session_a.diff_win)
  vim.api.nvim_win_set_cursor(session_a.diff_win, { row, 0 })

  local old_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 1
  end
  local ok, err = pcall(actions.restore_file, session_a)
  vim.fn.confirm = old_confirm
  assert(ok, err)
  assert(vim.fn.filereadable(path) == 0, "X did not remove the untracked file")
end)

test("T opens a terminal in the active worktree and Q returns to Vigit", function()
  vim.api.nvim_set_current_tabpage(session_a.vigit_tab)
  assert(actions.open_terminal(session_a))
  local terminal_buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[terminal_buf].buftype == "terminal", "T did not open a terminal buffer")
  assert(vim.fn.getcwd() == repo_a, "terminal opened outside the active worktree")

  local mapping
  vim.api.nvim_buf_call(terminal_buf, function()
    mapping = vim.fn.maparg("Q", "n", false, true)
  end)
  assert(mapping and type(mapping.callback) == "function", "terminal Q mapping is missing")
  mapping.callback()
  assert(vim.api.nvim_get_current_tabpage() == session_a.vigit_tab, "terminal Q returned to another tab")
end)

test("d closes and removes an open clean pushed worktree", function()
  local remote = temporary .. "/worktree-origin.git"
  local primary = temporary .. "/worktree-primary"
  local linked = temporary .. "/worktree-linked"
  vim.fn.mkdir(remote, "p")
  run(remote, { "git", "init", "--bare", "-q" })
  create_repo(primary, { "value = 1" })
  run(primary, { "git", "branch", "-M", "main" })
  run(primary, { "git", "remote", "add", "origin", remote })
  run(primary, { "git", "push", "-q", "-u", "origin", "main" })
  run(remote, { "git", "symbolic-ref", "HEAD", "refs/heads/main" })
  run(primary, { "git", "branch", "feature" })
  run(primary, { "git", "worktree", "add", "-q", linked, "feature" })
  run(linked, { "git", "push", "-q", "-u", "origin", "feature" })

  local linked_session = assert(ui.open({ cwd = linked }))
  assert(ui.open_editor(linked_session, { path = "sample.py" }, 1))
  local linked_editor_tab = linked_session.editor.tab
  vim.api.nvim_set_current_tabpage(linked_session.vigit_tab)
  local picker = require("vigit.worktree_picker").open(linked_session)
  local old_input = vim.ui.input
  vim.ui.input = function(_, callback)
    callback("DELETE")
  end
  local ok, err = pcall(require("vigit.worktree_picker").remove_selected, picker)
  vim.ui.input = old_input
  assert(ok, err)
  assert(
    not vim.api.nvim_tabpage_is_valid(linked_editor_tab),
    "worktree editor tab remained open after removal"
  )
  assert(vim.fn.isdirectory(linked) == 0, "linked worktree directory still exists")
  local list = vim.system({ "git", "-C", primary, "worktree", "list", "--porcelain" }, { text = true }):wait()
  assert(list.code == 0 and not list.stdout:find(linked, 1, true), "worktree is still registered")
  local branches = vim.system({ "git", "-C", primary, "branch", "--list", "feature" }, { text = true }):wait()
  assert(branches.code == 0 and branches.stdout:match("feature"), "feature branch was deleted")
end)

vim.fn.delete(temporary, "rf")

if failures > 0 then
  vim.cmd("cquit " .. failures)
else
  vim.cmd("qa!")
end
