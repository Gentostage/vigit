local config = require("vigit.config")

local M = {}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function changes_width()
  return clamp(config.get().ui.changes_width, 24, 30)
end

local function editor_height()
  return math.max(1, vim.o.lines - vim.o.cmdheight - 1)
end

local function configure_buffer(buffer, name, filetype)
  if vim.api.nvim_buf_get_name(buffer) == "" then
    vim.api.nvim_buf_set_name(buffer, name)
  end
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = filetype
end

local function diff_float_config(session)
  local sidebar_visible = session.view.changes_overlay_visible ~= false
  local sidebar_width = sidebar_visible and changes_width() or 0
  return {
    relative = "editor",
    row = 0,
    col = config.get().ui.changes_side == "left" and sidebar_width or 0,
    width = math.max(1, vim.o.columns - sidebar_width),
    height = editor_height(),
    style = "minimal",
    border = "none",
    zindex = 50,
  }
end

local function changes_float_config()
  local width = math.min(changes_width(), math.max(1, vim.o.columns - 1))
  return {
    relative = "editor",
    row = 0,
    col = config.get().ui.changes_side == "left"
        and 0
      or math.max(0, vim.o.columns - width),
    width = width,
    height = editor_height(),
    style = "minimal",
    border = "none",
    zindex = 51,
  }
end

local function close_window(window)
  if valid_window(window) then
    pcall(vim.api.nvim_win_close, window, true)
  end
end

local function save_cursor(session, kind, window)
  if not valid_window(window) then
    return
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, window)
  if not ok then
    return
  end
  session.view.review_cursors = session.view.review_cursors or {}
  session.view.review_cursors[kind] = cursor
end

local function restore_cursor(session, kind, window, buffer)
  local cursor = session.view.review_cursors
    and session.view.review_cursors[kind]
  if not cursor or not valid_window(window) or not valid_buffer(buffer) then
    return
  end
  local line_count = math.max(1, vim.api.nvim_buf_line_count(buffer))
  local line = clamp(cursor[1], 1, line_count)
  local text = vim.api.nvim_buf_get_lines(buffer, line - 1, line, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, window, {
    line,
    clamp(cursor[2], 0, #text),
  })
end

local function create_buffer(session, kind)
  local buffer = vim.api.nvim_create_buf(false, true)
  configure_buffer(
    buffer,
    string.format("vigit://%s/%s", session.id, kind),
    "vigit-" .. kind
  )
  return buffer
end

local function ensure_buffers(session)
  if not valid_buffer(session.owned.diff_buf) then
    session.owned.diff_buf = create_buffer(session, "diff")
  end
  if not valid_buffer(session.owned.changes_buf) then
    session.owned.changes_buf = create_buffer(session, "changes")
  end
end

local function adopt_workspace(session, workspace)
  workspace = workspace or session.workspace
  if workspace then
    session.workspace = workspace
    workspace.tab = workspace.tab or vim.api.nvim_get_current_tabpage()
    workspace.code_win = valid_window(workspace.code_win)
        and workspace.code_win
      or vim.api.nvim_get_current_win()
    workspace.mode = workspace.mode or "review"
  else
    workspace = {
      tab = vim.api.nvim_get_current_tabpage(),
      code_win = vim.api.nvim_get_current_win(),
      root = session.root,
      mode = "review",
      source_buffers = {},
      terminal = nil,
    }
    session.workspace = workspace
  end
  session.owned.tab = workspace.tab
  return workspace
end

function M.configure_changes_window(window)
  if not valid_window(window) then
    return
  end
  vim.wo[window].number = false
  vim.wo[window].relativenumber = false
  vim.wo[window].signcolumn = "no"
  vim.wo[window].foldcolumn = "0"
  vim.wo[window].statuscolumn = ""
  vim.wo[window].wrap = false
  vim.wo[window].cursorline = true
  vim.wo[window].winfixwidth = true
end

function M.is_visible(session)
  return valid_window(session.owned.diff_win) == true
end

function M.show(session, workspace)
  if session.closed then
    return session
  end

  workspace = adopt_workspace(session, workspace)
  if not workspace.tab or not vim.api.nvim_tabpage_is_valid(workspace.tab) then
    error("Vigit workspace tab is unavailable", 0)
  end
  vim.api.nvim_set_current_tabpage(workspace.tab)

  if M.is_visible(session) then
    M.resize(session)
    vim.api.nvim_set_current_win(session.owned.diff_win)
    workspace.mode = "review"
    return session
  end

  ensure_buffers(session)
  session.view.changes_overlay_visible =
    session.view.changes_overlay_visible ~= false
  session.owned.diff_win = vim.api.nvim_open_win(
    session.owned.diff_buf,
    true,
    diff_float_config(session)
  )
  if session.view.changes_overlay_visible then
    session.owned.changes_win = vim.api.nvim_open_win(
      session.owned.changes_buf,
      false,
      changes_float_config()
    )
    M.configure_changes_window(session.owned.changes_win)
  end
  restore_cursor(session, "diff", session.owned.diff_win, session.owned.diff_buf)
  restore_cursor(
    session,
    "changes",
    session.owned.changes_win,
    session.owned.changes_buf
  )
  workspace.mode = "review"
  return session
end

function M.open(session)
  local workspace = adopt_workspace(session)
  local ok, message = xpcall(function()
    M.show(session, workspace)
  end, debug.traceback)
  if not ok then
    M.dispose(session)
    error(message, 0)
  end
  return session
end

function M.hide(session)
  if not session then
    return false
  end
  local visible = M.is_visible(session)
    or valid_window(session.owned.changes_win)
  save_cursor(session, "diff", session.owned.diff_win)
  save_cursor(session, "changes", session.owned.changes_win)
  close_window(session.owned.changes_win)
  close_window(session.owned.diff_win)
  session.owned.changes_win = nil
  session.owned.diff_win = nil

  local workspace = session.workspace
  if workspace then
    workspace.mode = "code"
    if workspace.tab and vim.api.nvim_tabpage_is_valid(workspace.tab) then
      vim.api.nvim_set_current_tabpage(workspace.tab)
      if valid_window(workspace.code_win) then
        vim.api.nvim_set_current_win(workspace.code_win)
      end
    end
  end
  return visible
end

function M.resize(session)
  if session.closed
      or not M.is_visible(session)
      or not session.owned.tab
      or not vim.api.nvim_tabpage_is_valid(session.owned.tab)
      or vim.api.nvim_get_current_tabpage() ~= session.owned.tab then
    return
  end

  vim.api.nvim_win_set_config(
    session.owned.diff_win,
    diff_float_config(session)
  )
  if valid_window(session.owned.changes_win) then
    vim.api.nvim_win_set_config(
      session.owned.changes_win,
      changes_float_config()
    )
    M.configure_changes_window(session.owned.changes_win)
  end
end

function M.toggle_changes(session)
  if session.closed or not M.is_visible(session) then
    return
  end

  if valid_window(session.owned.changes_win) then
    if vim.api.nvim_get_current_win() == session.owned.changes_win then
      vim.api.nvim_set_current_win(session.owned.diff_win)
    else
      vim.api.nvim_set_current_win(session.owned.changes_win)
    end
    return
  end

  session.view.changes_overlay_visible = true
  M.resize(session)
  session.owned.changes_win = vim.api.nvim_open_win(
    session.owned.changes_buf,
    true,
    changes_float_config()
  )
  M.configure_changes_window(session.owned.changes_win)
  restore_cursor(
    session,
    "changes",
    session.owned.changes_win,
    session.owned.changes_buf
  )
end

function M.focus_direction(session, direction)
  if session.closed or not M.is_visible(session) then
    return
  end

  local changes_on_left = config.get().ui.changes_side == "left"
  local focus_changes = direction == "left" and changes_on_left
    or direction == "right" and not changes_on_left
  if focus_changes then
    if not valid_window(session.owned.changes_win) then
      M.toggle_changes(session)
    else
      vim.api.nvim_set_current_win(session.owned.changes_win)
    end
  elseif valid_window(session.owned.diff_win) then
    vim.api.nvim_set_current_win(session.owned.diff_win)
  end
end

local function cancel_reads(session)
  for _, job in pairs(session.reads.jobs) do
    local handle = job.handle or job
    if type(handle) == "table" and type(handle.cancel) == "function" then
      pcall(handle.cancel)
    end
  end
  session.reads.jobs = {}
end

function M.dispose(session)
  if session.closed then
    return false
  end
  M.hide(session)
  session.closed = true
  session.reads.generation = session.reads.generation + 1
  cancel_reads(session)
  for _, key in ipairs({ "diff_buf", "changes_buf" }) do
    local buffer = session.owned[key]
    session.owned[key] = nil
    if valid_buffer(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
  return true
end

function M.abandon(session)
  return M.dispose(session)
end

function M.close(session)
  return M.hide(session)
end

return M
