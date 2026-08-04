local Fixture = require("tests.fixtures.git_repo")
local controller = require("vigit.ui.controller")

local function close_session(session)
  if session and not session.closed then controller.dispatch(session, "abandon") end
end

local function wait_idle(session)
  assert_truthy(vim.wait(2000, function()
    return session.closed or session.busy.status == nil
  end, 10))
end

it("installs one observer group without touching source state and refreshes only the active match", function()
  local repo = Fixture.new()
  local other_repo = Fixture.new()
  local session, other_session
  local source = vim.api.nvim_create_buf(false, true)
  local unrelated = vim.api.nvim_create_buf(false, true)
  local ok, message = xpcall(function()
    local plugin = require("vigit")
    assert_equal(plugin.setup({ refresh = {
      debounce_ms = 25,
      poll_interval_ms = 0,
    } }), true)
    assert_equal(plugin.setup({ refresh = {
      debounce_ms = 25,
      poll_interval_ms = 0,
    } }), true)
    assert_equal(#vim.api.nvim_get_autocmds({ group = "VigitRefreshObservers" }), 4)

    session = assert(require("vigit.v2").open({ cwd = repo.root }))
    other_session = assert(require("vigit.v2").open({ cwd = other_repo.root }))
    assert_equal(assert(require("vigit.v2").open({ cwd = repo.root })), session)
    wait_idle(session)
    wait_idle(other_session)
    vim.api.nvim_buf_set_name(source, repo.root .. "/changed.lua")
    vim.api.nvim_buf_set_name(unrelated, vim.fn.tempname() .. "/outside.lua")
    vim.cmd("tabnew")
    local source_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(source_window, source)
    vim.wo[source_window].winbar = "source winbar"
    vim.bo[source].modifiable = true
    vim.bo[source].bufhidden = "hide"
    vim.keymap.set("n", "gZ", function() end, { buffer = source })
    local source_options = {
      modifiable = vim.bo[source].modifiable,
      bufhidden = vim.bo[source].bufhidden,
      mapping = vim.fn.maparg("gZ", "n", false, true).buffer,
      autocmds = #vim.api.nvim_get_autocmds({ event = "BufWritePost", buffer = source }),
      winbar = vim.wo[source_window].winbar,
    }

    local before = session.reads.generation
    local other_before = other_session.reads.generation
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = source })
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = source })
    assert_truthy(vim.wait(1000, function()
      return session.reads.generation == before + 1
    end, 10))
    wait_idle(session)
    assert_equal(other_session.reads.generation, other_before)
    assert_equal(vim.bo[source].modifiable, source_options.modifiable)
    assert_equal(vim.bo[source].bufhidden, source_options.bufhidden)
    assert_equal(vim.fn.maparg("gZ", "n", false, true).buffer, source_options.mapping)
    assert_equal(#vim.api.nvim_get_autocmds({ event = "BufWritePost", buffer = source }), source_options.autocmds)
    assert_equal(vim.wo[source_window].winbar, source_options.winbar)

    before = session.reads.generation
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = unrelated })
    vim.wait(80)
    assert_equal(session.reads.generation, before)

    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.api.nvim_exec_autocmds("TabEnter", {})
    assert_truthy(vim.wait(1000, function()
      return session.reads.generation == before + 1
    end, 10))
    wait_idle(session)

    before = session.reads.generation
    vim.api.nvim_exec_autocmds("FocusGained", {})
    assert_truthy(vim.wait(1000, function()
      return session.reads.generation == before + 1
    end, 10))
    wait_idle(session)

    vim.cmd("tabnew")
    before = session.reads.generation
    local other_before = other_session.reads.generation
    vim.api.nvim_exec_autocmds("TabEnter", {})
    vim.wait(80)
    assert_equal(session.reads.generation, before)
    assert_equal(other_session.reads.generation, other_before)

    vim.api.nvim_set_current_tabpage(session.owned.tab)
    before = session.reads.generation
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = source })
    session.reads.generation = session.reads.generation + 1
    vim.wait(100)
    assert_equal(session.reads.generation, before + 1)

    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = source })
    controller.dispatch(session, "abandon")
    local after_close = session.reads.generation
    vim.wait(100)
    assert_equal(session.reads.generation, after_close)
  end, debug.traceback)

  close_session(session)
  close_session(other_session)
  for _, buffer in ipairs({ source, unrelated }) do
    if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
  end
  repo:cleanup()
  other_repo:cleanup()
  if not ok then error(message, 0) end
end)

it("polls a visible review silently and refreshes only after Git changes", function()
  local repo = Fixture.new()
  local session
  local external_tab
  local plugin = require("vigit")
  local ok, message = xpcall(function()
    repo:write("tracked.lua", { "return 'old'" })
    repo:git({ "add", "--", "tracked.lua" })
    repo:commit("initial")
    assert_equal(plugin.setup({ refresh = {
      debounce_ms = 5,
      on_write = false,
      on_tab_enter = false,
      on_focus = false,
      poll_interval_ms = 25,
    } }), true)
    session = assert(require("vigit.v2").open({ cwd = repo.root }))
    wait_idle(session)

    local before = session.reads.generation
    vim.wait(100)
    assert_equal(session.reads.generation, before)
    assert_equal(session.busy.status, nil)

    repo:write("tracked.lua", { "return 'changed'" })
    assert_truthy(vim.wait(1000, function()
      local unstaged = session.data.status
        and session.data.status.unstaged or {}
      return session.reads.generation == before + 1
        and unstaged[1]
        and unstaged[1].path == "tracked.lua"
        and session.busy.status == nil
    end, 10))
    local changed_generation = session.reads.generation
    vim.wait(100)
    assert_equal(session.reads.generation, changed_generation)

    session.busy.status = { cancel = function() end }
    before = session.reads.generation
    vim.wait(100)
    assert_equal(session.reads.generation, before)
    session.busy.status = nil

    vim.cmd("tabnew")
    external_tab = vim.api.nvim_get_current_tabpage()
    before = session.reads.generation
    vim.wait(100)
    assert_equal(session.reads.generation, before)
    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(external_tab))
    external_tab = nil

    controller.dispatch(session, "close")
    vim.wait(30)
    wait_idle(session)
    before = session.reads.generation
    vim.wait(100)
    assert_equal(session.reads.generation, before)
  end, debug.traceback)

  assert_equal(plugin.setup({ refresh = { poll_interval_ms = 0 } }), true)
  if external_tab and vim.api.nvim_tabpage_is_valid(external_tab) then
    vim.api.nvim_set_current_tabpage(external_tab)
    pcall(vim.cmd, "tabclose")
  end
  close_session(session)
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("routes public registry intents through the real controller", function()
  local keymaps = require("vigit.ui.keymaps")
  for _, context in ipairs({ "diff", "changes" }) do
    for _, entry in ipairs(keymaps.for_context(context)) do
      assert_truthy(controller.supports_intent(entry.intent))
    end
  end
end)

it("opens diagnostics in a read-only scratch buffer", function()
  package.loaded["vigit.ui.log"] = nil
  local log = require("vigit.ui.log")
  log.push({ code = "process_failed", message = "Process failed", details = {
    args = { "git", "status" }, cwd = "/repo", exit_code = 17,
  } })

  local buffer = log.open()
  assert_equal(vim.bo[buffer].buftype, "nofile")
  assert_equal(vim.bo[buffer].modifiable, false)
  assert_equal(vim.bo[buffer].readonly, true)
  assert_truthy(table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"):find("exit_code=17", 1, true) ~= nil)
  vim.api.nvim_buf_delete(buffer, { force = true })
end)
