local Fixture = require("tests.fixtures.git_repo")
local controller = require("vigit.ui.controller")
local layout = require("vigit.ui.layout")
local log = require("vigit.ui.log")
local neovim = require("vigit.adapters.neovim")
local renderer = require("vigit.ui.renderer")
local v2 = require("vigit.v2")

local function close_session(session)
  if session and not session.closed then
    controller.dispatch(session, "abandon")
  end
end

local function prepare_changed_file(repo, path, before, after)
  repo:write(path, before)
  repo:git({ "add", "--", path })
  repo:commit("initial")
  repo:write(path, after)
end

local function focus_source_row(session, path, needle, column)
  assert_truthy(vim.wait(2000, function()
    return session.data.status ~= nil and session.busy.status == nil
  end, 10))
  local change
  for _, candidate in ipairs(session.data.status.unstaged or {}) do
    if candidate.path == path then
      change = candidate
      break
    end
  end
  assert_truthy(change)
  controller.dispatch(session, {
    name = "select_change",
    change_id = change.id,
  })
  assert_truthy(vim.wait(2000, function()
    return session.data.diffs[change.id] ~= nil
  end, 10))

  for row, line in ipairs(vim.api.nvim_buf_get_lines(
    session.owned.diff_buf,
    0,
    -1,
    false
  )) do
    local target = renderer.target_at(session.owned.diff_buf, row)
    if line:find(needle, 1, true) and target and target.source_line then
      vim.api.nvim_set_current_win(session.owned.diff_win)
      vim.api.nvim_win_set_cursor(
        session.owned.diff_win,
        { row, column or 0 }
      )
      return target
    end
  end
  error("source row not found: " .. needle)
end

local function normal_window_count(tab)
  local count = 0
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(window).relative == "" then
      count = count + 1
    end
  end
  return count
end

local function cleanup_terminals()
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer)
        and vim.bo[buffer].buftype == "terminal" then
      local job = vim.b[buffer].terminal_job_id
      if type(job) == "number" and job > 0 then
        pcall(vim.fn.jobstop, job)
      end
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
end

it("публикует workspace root для global, tab и process consumers", function()
  local repo = Fixture.new()
  local original_global = vim.fn.getcwd(-1, -1)
  local original_tab = vim.fn.getcwd(0, 0)
  local group = vim.api.nvim_create_augroup("VigitRootInvariantSpec", {
    clear = true,
  })
  local observed = {}
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      observed[#observed + 1] = {
        global = vim.fn.getcwd(-1, -1),
        tab = vim.fn.getcwd(0, 0),
        process = vim.uv.cwd(),
      }
    end,
  })

  local ok, message = xpcall(function()
    local rooted = neovim.bind_workspace_root(
      vim.api.nvim_get_current_tabpage(),
      repo.root
    )
    assert_truthy(rooted.ok)
    local expected = assert(vim.uv.fs_realpath(repo.root))
    assert_equal(vim.fn.getcwd(-1, -1), expected)
    assert_equal(vim.fn.getcwd(0, 0), expected)
    assert_equal(vim.uv.cwd(), expected)
    assert_truthy(#observed >= 1)
    assert_equal(observed[1].global, expected)
    assert_equal(observed[1].process, expected)
  end, debug.traceback)

  vim.api.nvim_del_augroup_by_id(group)
  vim.cmd("cd " .. vim.fn.fnameescape(original_global))
  vim.cmd("tcd " .. vim.fn.fnameescape(original_tab))
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("показывает review overlay в текущем tab и скрывает его без закрытия session", function()
  local repo = Fixture.new()
  local session
  local initial_tab = vim.api.nvim_get_current_tabpage()
  local initial_win = vim.api.nvim_get_current_win()
  local initial_tabs = #vim.api.nvim_list_tabpages()

  local ok, message = xpcall(function()
    session = assert(v2.open({ cwd = repo.root }))

    assert_equal(#vim.api.nvim_list_tabpages(), initial_tabs)
    assert_equal(session.owned.tab, initial_tab)
    assert_truthy(layout.is_visible(session))
    assert_truthy(vim.api.nvim_win_is_valid(session.owned.diff_win))
    assert_truthy(vim.api.nvim_win_is_valid(session.owned.changes_win))
    assert_truthy(vim.wait(2000, function()
      return session.busy.status == nil
    end, 10))

    controller.dispatch(session, "close")

    assert_equal(session.closed, false)
    assert_equal(layout.is_visible(session), false)
    assert_equal(#vim.api.nvim_list_tabpages(), initial_tabs)
    assert_equal(vim.api.nvim_get_current_tabpage(), initial_tab)
    assert_equal(vim.api.nvim_get_current_win(), initial_win)

    local before = session.reads.generation
    assert_equal(assert(v2.open()), session)
    assert_truthy(vim.wait(1000, function()
      return session.reads.generation == before + 1
    end, 10))
    assert_truthy(layout.is_visible(session))
  end, debug.traceback)

  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("переключает два worktree через одну live session в том же tab", function()
  local repo_a = Fixture.new()
  local repo_b = Fixture.new()
  local first
  local second
  local initial_tab = vim.api.nvim_get_current_tabpage()
  local initial_tabs = #vim.api.nvim_list_tabpages()

  local ok, message = xpcall(function()
    first = assert(v2.open({ cwd = repo_a.root }))
    local first_diff_buf = first.owned.diff_buf
    local first_changes_buf = first.owned.changes_buf
    second = assert(v2.open({ cwd = repo_b.root }))

    assert_equal(#vim.api.nvim_list_tabpages(), initial_tabs)
    assert_equal(second.owned.tab, initial_tab)
    assert_equal(v2.active_session(), second)
    assert_equal(second.root, assert(vim.uv.fs_realpath(repo_b.root)))
    assert_equal(first.closed, false)
    assert_equal(vim.api.nvim_buf_is_valid(first_diff_buf), true)
    assert_equal(vim.api.nvim_buf_is_valid(first_changes_buf), true)
  end, debug.traceback)

  close_session(second)
  close_session(first)
  repo_a:cleanup()
  repo_b:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("в code mode открывает Vigit для worktree текущего source buffer", function()
  local root_repo = Fixture.new()
  local linked_repo = Fixture.new()
  local root_session
  local linked_session
  local source_buffer

  local ok, message = xpcall(function()
    for _, repo in ipairs({ root_repo, linked_repo }) do
      repo:write("src/service.py", { "value = 1" })
      repo:git({ "add", "--", "src/service.py" })
      repo:commit("initial")
    end

    linked_session = assert(v2.open({ cwd = linked_repo.root }))
    controller.dispatch(linked_session, "close")
    vim.cmd("edit " .. vim.fn.fnameescape(linked_repo.root .. "/src/service.py"))
    source_buffer = vim.api.nvim_get_current_buf()

    root_session = assert(v2.open({ cwd = root_repo.root }))
    controller.dispatch(root_session, "close")
    assert_equal(vim.api.nvim_get_current_buf(), source_buffer)

    local reopened = assert(v2.open())

    assert_equal(reopened, linked_session)
    assert_equal(v2.active_session(), linked_session)
    assert_equal(vim.fn.getcwd(0, 0), assert(vim.uv.fs_realpath(linked_repo.root)))
    assert_truthy(layout.is_visible(linked_session))
    local saw_mismatch = false
    local saw_switch = false
    for _, entry in ipairs(log.entries()) do
      if entry.code == "root_mismatch"
          and entry.details.root == linked_session.root
          and entry.details.active_root == root_session.root then
        saw_mismatch = true
      elseif entry.code == "session_switch"
          and entry.details.from_root == root_session.root
          and entry.details.to_root == linked_session.root then
        saw_switch = true
      end
    end
    assert_truthy(saw_mismatch)
    assert_truthy(saw_switch)
  end, debug.traceback)

  close_session(root_session)
  close_session(linked_session)
  if source_buffer and vim.api.nvim_buf_is_valid(source_buffer) then
    pcall(vim.api.nvim_buf_delete, source_buffer, { force = true })
  end
  root_repo:cleanup()
  linked_repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("выбирает worktree текущего файла при вызове Vigit из внешнего tab", function()
  local repo = Fixture.new()
  local linked = vim.fn.tempname()
  local root_session
  local linked_session
  local external_tab
  local source_buffer

  local ok, message = xpcall(function()
    repo:write("src/service.py", { "value = 1" })
    repo:git({ "add", "--", "src/service.py" })
    repo:commit("initial")
    repo:git({ "worktree", "add", "-q", "-b", "linked", linked })

    root_session = assert(v2.open({ cwd = repo.root }))
    controller.dispatch(root_session, "close")

    vim.cmd("tabnew")
    external_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("edit " .. vim.fn.fnameescape(linked .. "/src/service.py"))
    source_buffer = vim.api.nvim_get_current_buf()

    linked_session = assert(v2.open())

    assert_equal(linked_session.root, assert(vim.uv.fs_realpath(linked)))
    assert_equal(v2.active_session(), linked_session)
    assert_truthy(layout.is_visible(linked_session))
  end, debug.traceback)

  close_session(linked_session)
  close_session(root_session)
  if external_tab and vim.api.nvim_tabpage_is_valid(external_tab) then
    vim.api.nvim_set_current_tabpage(external_tab)
    pcall(vim.cmd, "tabclose")
  end
  if source_buffer and vim.api.nvim_buf_is_valid(source_buffer) then
    pcall(vim.api.nvim_buf_delete, source_buffer, { force = true })
  end
  vim.fn.delete(linked, "rf")
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("открывает source buffer в editor window того же workspace tab", function()
  local repo = Fixture.new()
  local session
  local source_buffer
  local initial_tab = vim.api.nvim_get_current_tabpage()
  local initial_tabs = #vim.api.nvim_list_tabpages()
  local initial_win = vim.api.nvim_get_current_win()

  local ok, message = xpcall(function()
    prepare_changed_file(
      repo,
      "src/service.py",
      { "def service():", "    return \"old\"" },
      { "def service():", "    return \"new\"" }
    )
    session = assert(v2.open({ cwd = repo.root }))
    local target = focus_source_row(
      session,
      "src/service.py",
      "return \"new\"",
      4
    )

    controller.dispatch(session, "open_file")
    source_buffer = vim.api.nvim_get_current_buf()

    assert_equal(#vim.api.nvim_list_tabpages(), initial_tabs)
    assert_equal(vim.api.nvim_get_current_tabpage(), initial_tab)
    assert_equal(vim.api.nvim_get_current_win(), initial_win)
    assert_equal(
      vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()),
      assert(vim.uv.fs_realpath(repo.root .. "/src/service.py"))
    )
    assert_equal(vim.bo[vim.api.nvim_get_current_buf()].buflisted, true)
    assert_equal(
      session.resources.source_buffers[source_buffer],
      assert(vim.uv.fs_realpath(repo.root .. "/src/service.py"))
    )
    local cursor = vim.api.nvim_win_get_cursor(initial_win)
    assert_equal(cursor[1], target.source_line)
    assert_equal(cursor[2], 4)
    assert_equal(layout.is_visible(session), false)
    assert_equal(session.workspace:mode_name(), "code")
  end, debug.traceback)

  close_session(session)
  if source_buffer and vim.api.nvim_buf_is_valid(source_buffer) then
    pcall(vim.api.nvim_buf_delete, source_buffer, { force = true })
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= initial_tab and vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      pcall(vim.cmd, "tabclose")
    end
  end
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("открывает terminal split внутри workspace tab", function()
  local repo = Fixture.new()
  local session
  local initial_tab = vim.api.nvim_get_current_tabpage()
  local initial_tabs = #vim.api.nvim_list_tabpages()

  local ok, message = xpcall(function()
    prepare_changed_file(
      repo,
      "src/service.py",
      { "value = \"old\"" },
      { "value = \"new\"" }
    )
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "value = \"new\"", 0)

    local terminal_mapping = vim.fn.maparg(
      "<leader>h",
      "n",
      false,
      true
    )
    assert_equal(terminal_mapping.buffer, 1)
    assert_equal(type(terminal_mapping.callback), "function")
    terminal_mapping.callback()

    assert_equal(#vim.api.nvim_list_tabpages(), initial_tabs)
    assert_equal(vim.api.nvim_get_current_tabpage(), initial_tab)
    assert_equal(normal_window_count(initial_tab), 2)
    assert_truthy(session.resources.terminal)
    assert_truthy(session.resources.terminal.job > 0)
    assert_equal(
      vim.bo[session.resources.terminal.buf].buftype,
      "terminal"
    )
    local vigit_autocmds = 0
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({
      event = "TermClose",
      buffer = session.resources.terminal.buf,
    })) do
      if (autocmd.desc or ""):find("Vigit", 1, true) then
        vigit_autocmds = vigit_autocmds + 1
      end
    end
    assert_equal(vigit_autocmds, 0)
    assert_equal(session.workspace:mode_name(), "code")
  end, debug.traceback)

  cleanup_terminals()
  close_session(session)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= initial_tab and vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      pcall(vim.cmd, "tabclose")
    end
  end
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("блокирует switch, пока workspace terminal process работает", function()
  local repo_a = Fixture.new()
  local repo_b = Fixture.new()
  local session
  local switched
  local terminal_job

  local ok, message = xpcall(function()
    prepare_changed_file(
      repo_a,
      "src/service.py",
      { "value = \"old\"" },
      { "value = \"new\"" }
    )
    session = assert(v2.open({ cwd = repo_a.root }))
    focus_source_row(session, "src/service.py", "value = \"new\"", 0)
    controller.dispatch(session, "open_terminal")
    terminal_job = session.resources.terminal.job

    local switch_error
    switched, switch_error = v2.open({ cwd = repo_b.root })

    assert_equal(switched, nil)
    assert_equal(switch_error.code, "running_terminal")
    assert_equal(v2.active_session(), session)
    assert_equal(vim.fn.jobwait({ terminal_job }, 0)[1], -1)
  end, debug.traceback)

  cleanup_terminals()
  close_session(switched)
  close_session(session)
  repo_a:cleanup()
  repo_b:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("блокирует switch при modified source buffer без потери текста", function()
  local repo_a = Fixture.new()
  local repo_b = Fixture.new()
  local session
  local source_buffer

  local ok, message = xpcall(function()
    prepare_changed_file(
      repo_a,
      "src/service.py",
      { "value = \"old\"" },
      { "value = \"new\"" }
    )
    session = assert(v2.open({ cwd = repo_a.root }))
    focus_source_row(session, "src/service.py", "value = \"new\"", 0)
    controller.dispatch(session, "open_file")
    source_buffer = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(
      source_buffer,
      0,
      -1,
      false,
      { "unsaved = true" }
    )

    local switched, switch_error = v2.open({ cwd = repo_b.root })

    assert_equal(switched, nil)
    assert_equal(switch_error.code, "modified_source_buffers")
    assert_equal(v2.active_session(), session)
    assert_equal(session.root, assert(vim.uv.fs_realpath(repo_a.root)))
    assert_equal(session.closed, false)
    assert_equal(
      vim.api.nvim_buf_get_lines(source_buffer, 0, -1, false)[1],
      "unsaved = true"
    )
  end, debug.traceback)

  if source_buffer and vim.api.nvim_buf_is_valid(source_buffer) then
    vim.bo[source_buffer].modified = false
  end
  close_session(session)
  if source_buffer and vim.api.nvim_buf_is_valid(source_buffer) then
    pcall(vim.api.nvim_buf_delete, source_buffer, { force = true })
  end
  repo_a:cleanup()
  repo_b:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("сохраняет unmodified user source buffer после успешного switch", function()
  local repo_a = Fixture.new()
  local repo_b = Fixture.new()
  local session
  local switched
  local source_buffer

  local ok, message = xpcall(function()
    prepare_changed_file(
      repo_a,
      "src/service.py",
      { "value = \"old\"" },
      { "value = \"new\"" }
    )
    session = assert(v2.open({ cwd = repo_a.root }))
    focus_source_row(session, "src/service.py", "value = \"new\"", 0)
    controller.dispatch(session, "open_file")
    source_buffer = vim.api.nvim_get_current_buf()
    assert_equal(vim.bo[source_buffer].modified, false)

    switched = assert(v2.open({ cwd = repo_b.root }))

    assert_equal(switched.root, assert(vim.uv.fs_realpath(repo_b.root)))
    assert_equal(vim.api.nvim_buf_is_valid(source_buffer), true)
    assert_equal(v2.active_session(), switched)
  end, debug.traceback)

  close_session(switched)
  close_session(session)
  if source_buffer and vim.api.nvim_buf_is_valid(source_buffer) then
    pcall(vim.api.nvim_buf_delete, source_buffer, { force = true })
  end
  repo_a:cleanup()
  repo_b:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("блокирует switch, если source buffer показан во внешнем tab", function()
  local repo_a = Fixture.new()
  local repo_b = Fixture.new()
  local session
  local source_buffer
  local workspace_tab
  local external_tab

  local ok, message = xpcall(function()
    prepare_changed_file(
      repo_a,
      "src/service.py",
      { "value = \"old\"" },
      { "value = \"new\"" }
    )
    session = assert(v2.open({ cwd = repo_a.root }))
    workspace_tab = session.workspace.tab
    focus_source_row(session, "src/service.py", "value = \"new\"", 0)
    controller.dispatch(session, "open_file")
    source_buffer = vim.api.nvim_get_current_buf()

    vim.cmd("tabnew")
    external_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), source_buffer)

    local switched, switch_error = v2.open({ cwd = repo_b.root })

    assert_equal(switched, nil)
    assert_equal(switch_error.code, "source_buffer_in_external_tab")
    assert_equal(session.workspace:active_session(), session)
    assert_equal(vim.api.nvim_buf_is_valid(source_buffer), true)
    assert_equal(vim.api.nvim_get_current_tabpage(), external_tab)
  end, debug.traceback)

  if external_tab and vim.api.nvim_tabpage_is_valid(external_tab) then
    vim.api.nvim_set_current_tabpage(external_tab)
    pcall(vim.cmd, "tabclose")
  end
  if workspace_tab and vim.api.nvim_tabpage_is_valid(workspace_tab) then
    vim.api.nvim_set_current_tabpage(workspace_tab)
  end
  close_session(session)
  if source_buffer and vim.api.nvim_buf_is_valid(source_buffer) then
    pcall(vim.api.nvim_buf_delete, source_buffer, { force = true })
  end
  repo_a:cleanup()
  repo_b:cleanup()
  if not ok then
    error(message, 0)
  end
end)
