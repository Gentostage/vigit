local Fixture = require("tests.fixtures.git_repo")
local EmbeddedUI = require("tests.fixtures.embedded_ui")
local plugin = require("vigit")
local controller = require("vigit.ui.controller")
local config = require("vigit.config")

local function keys(lhs)
  vim.api.nvim_feedkeys(vim.keycode(lhs), "x", false)
end

local function with_review(run)
  local repo = Fixture.new()
  local original_config = vim.deepcopy(config.get())
  local original_langmap = vim.o.langmap
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_get_current_buf()
  local source_maps = vim.api.nvim_buf_get_keymap(source_buf, "n")
  local session, second_win
  local ok, message = xpcall(function()
    vim.cmd("vsplit")
    second_win = vim.api.nvim_get_current_win()
    session = assert(plugin.open({ cwd = repo.root }))
    run(session, source_win, second_win)
    assert_equal(vim.inspect(vim.api.nvim_buf_get_keymap(source_buf, "n")), vim.inspect(source_maps))
  end, debug.traceback)
  keys("<Esc>")
  if session then controller.dispatch(session, "abandon") end
  if second_win and vim.api.nvim_win_is_valid(second_win) then
    vim.api.nvim_win_close(second_win, true)
  end
  vim.api.nvim_set_current_win(source_win)
  config.setup(original_config)
  vim.o.langmap = original_langmap
  repo:cleanup()
  if not ok then error(message, 0) end
end

it("Ctrl-W h/l переключают только панели Vigit с обеих сторон", function()
  with_review(function(session)
    for _, side in ipairs({ "right", "left" }) do
      config.setup({ ui = { changes_side = side } })
      require("vigit.ui.layout").resize(session)
      local left = side == "left" and session.owned.changes_win or session.owned.diff_win
      local right = side == "right" and session.owned.changes_win or session.owned.diff_win
      for _, visual in ipairs({ false, true }) do
        for _, lhs in ipairs({ "<C-w>h", "<C-w><C-h>", "<C-w><Left>", "<C-ц>р" }) do
          vim.api.nvim_set_current_win(right)
          if visual then keys("v") end
          keys(lhs)
          assert_equal(vim.api.nvim_get_current_win(), left)
          assert_equal(vim.fn.mode(), "n")
        end
        for _, lhs in ipairs({ "<C-w>l", "<C-w><C-l>", "<C-w><Right>", "<C-ц>д" }) do
          vim.api.nvim_set_current_win(left)
          if visual then keys("v") end
          keys(lhs)
          assert_equal(vim.api.nvim_get_current_win(), right)
          assert_equal(vim.fn.mode(), "n")
        end
      end
    end
  end)
end)

it("Ctrl-W j/k и стрелки не уводят курсор за Vigit", function()
  with_review(function(session)
    for _, window in ipairs({ session.owned.diff_win, session.owned.changes_win }) do
      for _, lhs in ipairs({
        "<C-w>j", "<C-w>k", "<C-w><C-j>", "<C-w><C-k>",
        "<C-w><Up>", "<C-w><Down>", "<C-ц>о", "<C-ц>л",
      }) do
        vim.api.nvim_set_current_win(window)
        keys(lhs)
        assert_equal(vim.api.nvim_get_current_win(), window)
        keys("v")
        keys(lhs)
        assert_equal(vim.api.nvim_get_current_win(), window)
        assert_equal(vim.fn.mode(), "v")
        keys("<Esc>")
      end
    end
  end)
end)

it("русский langmap не выводит оконную навигацию за overlay", function()
  with_review(function(session)
    vim.o.langmap = "рh,оj,лk,дl"
    vim.api.nvim_set_current_win(session.owned.changes_win)
    keys("<C-w>р")
    assert_equal(vim.api.nvim_get_current_win(), session.owned.diff_win)
    keys("<C-w>д")
    assert_equal(vim.api.nvim_get_current_win(), session.owned.changes_win)
    keys("<C-w>о")
    assert_equal(vim.api.nvim_get_current_win(), session.owned.changes_win)
    keys("<C-w>л")
    assert_equal(vim.api.nvim_get_current_win(), session.owned.changes_win)
  end)
end)

it("обычная Ctrl-W навигация сохраняется после выхода в редактор", function()
  with_review(function(session, source_win, second_win)
    controller.dispatch(session, "close")
    vim.api.nvim_set_current_win(source_win)
    keys("<C-w>h")
    assert_equal(vim.api.nvim_get_current_win(), second_win)
    keys("<C-w>l")
    assert_equal(vim.api.nvim_get_current_win(), source_win)
  end)
end)

local function with_mouse_ui(run)
  local root = vim.fn.getcwd()
  local ui = EmbeddedUI.new(root)
  local ok, message = xpcall(function()
    ui:lua([[
      local root = ...
      package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. root .. '/?.lua;' .. package.path
      repo = require('tests.fixtures.git_repo').new()
      repo:write('sample.txt', {'alpha beta gamma', 'delta epsilon zeta', 'third fourth fifth'})
      session = assert(require('vigit').open({cwd = repo.root}))
      vim.o.mouse = 'a'
    ]], { root })
    assert_truthy(ui:wait(2000, function()
      return ui:lua("return #require('vigit.ui.renderer').file_targets(session) == 1")
    end))
    ui:lua([[
      local item = require('vigit.ui.renderer').file_targets(session)[1]
      require('vigit.ui.controller').dispatch(session, {name='select_change', change_id=item.change_id})
    ]])
    assert_truthy(ui:wait(2000, function()
      return ui:lua("return vim.api.nvim_buf_line_count(session.owned.diff_buf) == 4")
    end))
    run(ui)
  end, debug.traceback)
  pcall(function()
    ui:lua("require('vigit.ui.controller').dispatch(session, 'abandon'); repo:cleanup()")
  end)
  ui:close()
  if not ok then error(message, 0) end
end

local function mouse_at(ui, action, line, column, modifiers, pane)
  local position = ui:lua([[
    local line, column, pane = ...
    vim.cmd('redraw!')
    return vim.fn.screenpos(session.owned[pane .. '_win'], line, column)
  ]], { line, column, pane or "diff" })
  ui:call("nvim_input_mouse", "left", action, modifiers or "", 0, position.row - 1, position.col - 1)
end

it("перетаскивание мышью в diff выделяет и копирует точный текст", function()
  with_mouse_ui(function(ui)
    ui:lua("vim.api.nvim_set_current_win(session.owned.changes_win)")
    mouse_at(ui, "press", 2, 3)
    assert_truthy(ui:wait(1000, function()
      local cursor = ui:lua("return vim.api.nvim_win_get_cursor(0)")
      return cursor[1] == 2 and cursor[2] == 2
    end))
    mouse_at(ui, "drag", 3, 9)
    assert_truthy(ui:wait(1000, function() return ui:lua("return vim.fn.mode()") == "v" end))
    mouse_at(ui, "release", 3, 9)
    ui:call("nvim_input", "y")
    assert_truthy(ui:wait(1000, function()
      return ui:lua([[return vim.fn.getreg('"')]]) == "pha beta gamma\ndelta eps"
    end))
  end)
end)

it("клик из diff в дерево раскрывает каталог с первого нажатия", function()
  with_mouse_ui(function(ui)
    ui:lua([[
      repo:write('src/extra.txt', {'extra'})
      require('vigit.ui.controller').dispatch(session, 'refresh')
    ]])
    assert_truthy(ui:wait(2000, function()
      return ui:lua("return #require('vigit.ui.renderer').file_targets(session) == 2")
    end))
    local row = ui:lua([[
      local renderer = require('vigit.ui.renderer')
      for row = 1, vim.api.nvim_buf_line_count(session.owned.changes_buf) do
        local target = renderer.target_at(session.owned.changes_buf, row)
        if target and target.kind == 'directory' and target.path == 'src' then
          return row
        end
      end
    ]])
    assert_truthy(type(row) == "number")
    ui:lua("vim.api.nvim_set_current_win(session.owned.diff_win)")
    mouse_at(ui, "press", row, 3, "", "changes")
    mouse_at(ui, "release", row, 3, "", "changes")
    assert_truthy(ui:wait(1000, function()
      return ui:lua([[return session.view.expanded_dirs['unstaged\0src'] == false
        and vim.api.nvim_get_current_win() == session.owned.changes_win]])
    end))
  end)
end)

it("двойной клик в diff выделяет слово вместо действия дерева", function()
  with_mouse_ui(function(ui)
    mouse_at(ui, "press", 2, 8, "2")
    mouse_at(ui, "release", 2, 8, "2")
    assert_truthy(ui:wait(1000, function() return ui:lua("return vim.fn.mode()") == "v" end))
    ui:call("nvim_input", "y")
    assert_truthy(ui:wait(1000, function()
      return ui:lua([[return vim.fn.getreg('"')]]) == "beta"
    end))
  end)
end)

it("клик и сразу s стейджит выбранный мышью файл, а не предыдущий", function()
  with_mouse_ui(function(ui)
    ui:lua([[
      repo:write('other.txt', {'other content'})
      require('vigit.ui.controller').dispatch(session, 'refresh')
    ]])
    assert_truthy(ui:wait(2000, function()
      return ui:lua("return #require('vigit.ui.renderer').file_targets(session) == 2")
    end))
    local row = ui:lua([[
      for _, target in ipairs(require('vigit.ui.renderer').file_targets(session)) do
        if target.change_id == 'unstaged\0other.txt' then return target.row end
      end
    ]])
    assert_truthy(type(row) == "number")
    ui:lua([[
      local row = ...
      vim.api.nvim_set_current_win(session.owned.diff_win)
      vim.cmd('redraw!')
      local position = vim.fn.screenpos(session.owned.changes_win, row, 3)
      vim.api.nvim_input_mouse('left', 'press', '', 0, position.row - 1, position.col - 1)
      vim.api.nvim_input('s')
    ]], { row })
    assert_truthy(ui:wait(2000, function()
      return ui:lua("return #session.data.status.staged == 1 and session.busy.status == nil")
    end))
    assert_equal(ui:lua("return session.data.status.staged[1].path"), "other.txt")
    assert_equal(ui:lua("return session.data.status.unstaged[1].path"), "sample.txt")
    assert_equal(ui:lua([[return repo:git({'diff', '--cached', '--name-only'}).stdout]]), "other.txt\n")
    assert_equal(ui:lua([[return repo:git({'show', ':other.txt'}).stdout]]), "other content\n")
  end)
end)
