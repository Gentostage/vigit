local Fixture = require("tests.fixtures.git_repo")
local config = require("vigit.config")
local controller = require("vigit.ui.controller")
local layout = require("vigit.ui.layout")
local vigit = require("vigit")

local function with_repo(fn)
  local repo = Fixture.new()
  local sessions = {}
  local buffers = {}
  local ok, message = xpcall(function() fn(repo, sessions, buffers) end, debug.traceback)
  for _, session in ipairs(sessions) do
    if not session.closed then controller.dispatch(session, "abandon") end
  end
  for _, buffer in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  config.setup(nil)
  repo:cleanup()
  if not ok then error(message, 0) end
end

local function configure_handler(handler)
  assert_equal(vigit.setup({
    refresh = { poll_interval_ms = 0 },
    handlers = { open_worktrees = handler },
  }), true)
end

it("передаёт внешнему менеджеру только canonical root и code mode без создания review", function()
  with_repo(function(repo)
    vim.fn.mkdir(repo.root .. "/nested", "p")
    local received
    local token = {}
    configure_handler(function(context, ...)
      assert_equal(select("#", ...), 0)
      received = context
      return token
    end)
    local tab = vim.api.nvim_get_current_tabpage()
    local window = vim.api.nvim_get_current_win()
    local cwd = vim.fn.getcwd()
    local session = vigit.active_session()

    local returned, error = vigit.worktrees({ cwd = repo.root .. "/nested" })

    assert_equal(returned, token)
    assert_equal(error, nil)
    assert_truthy(vim.deep_equal(received, {
      root = assert(vim.uv.fs_realpath(repo.root)), mode = "code",
    }))
    assert_equal(vigit.active_session(), session)
    assert_equal(vim.api.nvim_get_current_tabpage(), tab)
    assert_equal(vim.api.nvim_get_current_win(), window)
    assert_equal(vim.fn.getcwd(), cwd)
  end)
end)

it("возвращает true для synchronous handler без возвращаемого значения", function()
  with_repo(function(repo)
    configure_handler(function() end)
    local returned, error = vigit.worktrees({ cwd = repo.root })
    assert_equal(returned, true)
    assert_equal(error, nil)
  end)
end)

it("сохраняет явный false возвращённый внешним handler", function()
  with_repo(function(repo)
    configure_handler(function() return false end)
    local returned, error = vigit.worktrees({ cwd = repo.root })
    assert_equal(returned, false)
    assert_equal(error, nil)
  end)
end)

it("передаёт typed error возвращённую внешним handler вместе с nil или false", function()
  with_repo(function(repo)
    local failure = { code = "picker_unavailable", message = "External picker unavailable" }
    for _, empty in ipairs({ "nil", "false" }) do
      configure_handler(function()
        if empty == "false" then return false, failure end
        return nil, failure
      end)
      local returned, error = vigit.worktrees({ cwd = repo.root })
      assert_equal(returned, nil)
      assert_equal(error, failure)
    end
  end)
end)

it("превращает malformed returned error в typed handler failure", function()
  with_repo(function(repo)
    configure_handler(function() return nil, "picker unavailable" end)
    local returned, error = vigit.worktrees({ cwd = repo.root })
    assert_equal(returned, nil)
    assert_equal(error.code, "handler_failed")
    assert_equal(error.details, "picker unavailable")
  end)
end)

it("не вызывает внешний handler если explicit cwd не является Git repository", function()
  local nonrepo = vim.fn.tempname()
  vim.fn.mkdir(nonrepo, "p")
  local calls = 0
  local ok, message = xpcall(function()
    configure_handler(function() calls = calls + 1 end)
    local returned, error = vigit.worktrees({ cwd = nonrepo })
    assert_equal(returned, nil)
    assert_equal(error.code, "not_repository")
    assert_equal(calls, 0)
  end, debug.traceback)
  config.setup(nil)
  vim.fn.delete(nonrepo, "rf")
  if not ok then error(message, 0) end
end)

it("W и VigitWorktrees передают review root без изменения session и layout", function()
  with_repo(function(repo, sessions)
    local received = {}
    configure_handler(function(context) received[#received + 1] = context end)
    local session = assert(vigit.open({ cwd = repo.root }))
    sessions[1] = session
    local window = vim.api.nvim_get_current_win()
    local buffer = vim.api.nvim_get_current_buf()
    local mapping = vim.fn.maparg("W", "n", false, true)
    assert_equal(type(mapping.callback), "function")

    mapping.callback()
    vim.cmd("VigitWorktrees")

    assert_equal(#received, 2)
    for _, context in ipairs(received) do
      assert_truthy(vim.deep_equal(context, { root = session.root, mode = "review" }))
    end
    assert_equal(vigit.active_session(), session)
    assert_equal(vim.api.nvim_get_current_win(), window)
    assert_equal(vim.api.nvim_get_current_buf(), buffer)
    assert_truthy(layout.is_visible(session))
    assert_equal(session.workspace:mode_name(), "review")
  end)
end)

it("в code mode разрешает root текущего source buffer и не восстанавливает review", function()
  with_repo(function(repo, sessions, buffers)
    local other = Fixture.new()
    local ok, message = xpcall(function()
      other:write("source.lua", { "return true" })
      local received
      configure_handler(function(context) received = context end)
      sessions[1] = assert(vigit.open({ cwd = repo.root }))
      controller.dispatch(sessions[1], "close")
      local buffer = vim.fn.bufadd(other.root .. "/source.lua")
      buffers[1] = buffer
      vim.fn.bufload(buffer)
      vim.api.nvim_set_current_buf(buffer)

      assert_equal(vigit.worktrees(), true)

      assert_truthy(vim.deep_equal(received, {
        root = assert(vim.uv.fs_realpath(other.root)), mode = "code",
      }))
      assert_equal(vim.api.nvim_get_current_buf(), buffer)
      assert_equal(sessions[1].workspace:mode_name(), "code")
      assert_equal(layout.is_visible(sessions[1]), false)
    end, debug.traceback)
    other:cleanup()
    if not ok then error(message, 0) end
  end)
end)

it("возвращает понятную unavailable error без встроенного fallback", function()
  with_repo(function(repo)
    for _, handlers in ipairs({ {}, { open_worktrees = false } }) do
      assert_equal(vigit.setup({ handlers = handlers }), true)
      local window = vim.api.nvim_get_current_win()
      local returned, error = vigit.worktrees({ cwd = repo.root })
      assert_equal(returned, nil)
      assert_equal(error.code, "handler_unavailable")
      assert_truthy(error.message:find("handlers.open_worktrees", 1, true))
      assert_equal(vim.api.nvim_get_current_win(), window)
    end
  end)
end)

it("nofile tree buffer в code mode использует editor cwd вместо cached review root", function()
  with_repo(function(repo, sessions, buffers)
    local other = Fixture.new()
    local ok, message = xpcall(function()
      local received
      configure_handler(function(context) received = context end)
      sessions[1] = assert(vigit.open({ cwd = repo.root }))
      controller.dispatch(sessions[1], "close")
      local tree = vim.api.nvim_create_buf(false, true)
      buffers[1] = tree
      vim.api.nvim_buf_set_name(tree, "NvimTree_" .. vim.api.nvim_get_current_tabpage())
      vim.bo[tree].buftype = "nofile"
      vim.api.nvim_set_current_buf(tree)
      vim.cmd("tcd " .. vim.fn.fnameescape(other.root))

      assert_equal(vigit.worktrees(), true)

      local root = assert(vim.uv.fs_realpath(other.root))
      assert_truthy(vim.deep_equal(received, { root = root, mode = "code" }))
      sessions[2] = assert(vigit.open())
      assert_equal(sessions[2].root, root)
      assert_truthy(sessions[2] ~= sessions[1])
    end, debug.traceback)
    other:cleanup()
    if not ok then error(message, 0) end
  end)
end)

it("code mode возвращает not_repository если editor path и cwd вне Git вместо cached root", function()
  with_repo(function(repo, sessions, buffers)
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    local calls = 0
    local ok, message = xpcall(function()
      configure_handler(function() calls = calls + 1 end)
      sessions[1] = assert(vigit.open({ cwd = repo.root }))
      controller.dispatch(sessions[1], "close")
      buffers[1] = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buffers[1])
      vim.cmd("tcd " .. vim.fn.fnameescape(outside))

      local returned, error = vigit.worktrees()
      assert_equal(returned, nil)
      assert_equal(error.code, "not_repository")
      assert_equal(calls, 0)
      local opened, open_error = vigit.open()
      assert_equal(opened, nil)
      assert_equal(open_error.code, "not_repository")
      assert_equal(sessions[1].workspace:mode_name(), "code")
    end, debug.traceback)
    vim.fn.delete(outside, "rf")
    if not ok then error(message, 0) end
  end)
end)

it("source вне Git в code mode разрешает effective editor cwd", function()
  with_repo(function(repo, _, buffers)
    local outside = vim.fn.tempname()
    vim.fn.writefile({ "return true" }, outside)
    local ok, message = xpcall(function()
      local received
      configure_handler(function(context) received = context end)
      buffers[1] = vim.fn.bufadd(outside)
      vim.fn.bufload(buffers[1])
      vim.api.nvim_set_current_buf(buffers[1])
      vim.cmd("tcd " .. vim.fn.fnameescape(repo.root))
      assert_equal(vigit.worktrees(), true)
      assert_truthy(vim.deep_equal(received, {
        root = assert(vim.uv.fs_realpath(repo.root)), mode = "code",
      }))
    end, debug.traceback)
    vim.fn.delete(outside)
    if not ok then error(message, 0) end
  end)
end)

it("перехватывает исключение внешнего handler и сохраняет review", function()
  with_repo(function(repo, sessions)
    configure_handler(function() error("external picker failed") end)
    sessions[1] = assert(vigit.open({ cwd = repo.root }))
    local returned, error = vigit.worktrees()
    assert_equal(returned, nil)
    assert_equal(error.code, "handler_failed")
    assert_truthy(error.details:find("external picker failed", 1, true))
    assert_equal(vigit.active_session(), sessions[1])
    assert_truthy(layout.is_visible(sessions[1]))
  end)
end)

it("command и W сообщают unavailable error пользователю", function()
  with_repo(function(repo, sessions)
    assert_equal(vigit.setup({ handlers = { open_worktrees = false } }), true)
    sessions[1] = assert(vigit.open({ cwd = repo.root }))
    local original_notify = vim.notify
    local notifications = {}
    local ok, message = xpcall(function()
      vim.notify = function(text, level) notifications[#notifications + 1] = { text, level } end
      vim.cmd("VigitWorktrees")
      vim.fn.maparg("W", "n", false, true).callback()
      assert_equal(#notifications, 2)
      for _, notification in ipairs(notifications) do
        assert_truthy(notification[1]:find("handler_unavailable", 1, true))
        assert_equal(notification[2], vim.log.levels.ERROR)
      end
    end, debug.traceback)
    vim.notify = original_notify
    if not ok then error(message, 0) end
  end)
end)

it("обычный open сохраняет отдельные review sessions для linked worktree без manager handler", function()
  with_repo(function(repo, sessions)
    repo:write("shared.lua", { "return true" })
    repo:git({ "add", "--", "shared.lua" })
    repo:commit("initial")
    local linked = repo.root .. "/linked"
    repo:git({ "worktree", "add", "-q", "-b", "linked", linked })
    vim.fn.mkdir(linked .. "/nested", "p")
    assert_equal(vigit.setup({ handlers = { open_worktrees = false } }), true)
    sessions[1] = assert(vigit.open({ cwd = repo.root }))
    sessions[1].view.changes_mode = "list"
    sessions[2] = assert(vigit.open({ cwd = linked }))
    sessions[2].view.changes_mode = "tree"

    assert_truthy(sessions[1] ~= sessions[2])
    assert_equal(vigit.open({ cwd = repo.root }), sessions[1])
    assert_equal(sessions[1].view.changes_mode, "list")
    assert_equal(vigit.open({ cwd = linked .. "/nested" }), sessions[2])
    assert_equal(sessions[2].view.changes_mode, "tree")
    assert_equal(sessions[1].closed, false)
  end)
end)

it("оставляет W и native Tab semantics в owned auxiliary review contexts", function()
  local keymaps = require("vigit.ui.keymaps")
  for _, context in ipairs({ "comments", "prompt", "comment_editor" }) do
    local buffer = vim.api.nvim_create_buf(false, true)
    local calls = 0
    local ok, message = xpcall(function()
      keymaps.apply_aux(nil, buffer, context, {
        open_worktrees = function() calls = calls + 1 end,
      })
      vim.api.nvim_set_current_buf(buffer)
      local mapping = vim.fn.maparg("W", "n", false, true)
      assert_equal(mapping.buffer, 1)
      mapping.callback()
      assert_equal(calls, 1)
      assert_equal(next(vim.fn.maparg("<Tab>", "n", false, true)), nil)
    end, debug.traceback)
    vim.api.nvim_buf_delete(buffer, { force = true })
    if not ok then error(message, 0) end
  end
end)
