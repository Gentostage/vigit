local config = require("vigit.config")

local M = {}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function changes_width()
  return clamp(config.get().ui.changes_width, 24, 36)
end

local function configure_buffer(buffer, name, filetype)
  vim.api.nvim_buf_set_name(buffer, name)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = filetype
end

local function float_config()
  local width = math.min(changes_width(), math.max(1, vim.o.columns - 2))
  local height = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  return {
    relative = "editor",
    row = 1,
    col = math.max(0, vim.o.columns - width - 1),
    width = width,
    height = height,
    style = "minimal",
    border = "single",
    zindex = 50,
  }
end

local function open_changes_float(session, enter)
  session.owned.changes_win = vim.api.nvim_open_win(
    session.owned.changes_buf,
    enter,
    float_config()
  )
  return session.owned.changes_win
end

local function open_changes_split(session, enter)
  local previous = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(session.owned.diff_win)
  if config.get().ui.changes_side == "left" then
    vim.cmd("topleft vsplit")
  else
    vim.cmd("botright vsplit")
  end
  session.owned.changes_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(session.owned.changes_win, session.owned.changes_buf)
  vim.api.nvim_win_set_width(session.owned.changes_win, changes_width())
  if not enter and valid_window(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  return session.owned.changes_win
end

local function close_changes_window(session)
  if not valid_window(session.owned.changes_win) then
    return
  end

  local buffer = session.owned.changes_buf
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    vim.bo[buffer].bufhidden = "hide"
  end
  vim.api.nvim_win_close(session.owned.changes_win, true)
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    vim.bo[buffer].bufhidden = "wipe"
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

local function rollback_open(session, original_tab)
  local owned_tab = session.owned.tab
  if owned_tab
      and owned_tab ~= original_tab
      and vim.api.nvim_tabpage_is_valid(owned_tab) then
    pcall(vim.api.nvim_set_current_tabpage, owned_tab)
    pcall(vim.cmd, "tabclose")
  end

  for _, key in ipairs({ "diff_buf", "changes_buf" }) do
    local buffer = session.owned[key]
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
  if original_tab and vim.api.nvim_tabpage_is_valid(original_tab) then
    pcall(vim.api.nvim_set_current_tabpage, original_tab)
  end
end

function M.open(session)
  local original_tab = vim.api.nvim_get_current_tabpage()
  local ok, message = xpcall(function()
    session.view.changes_overlay_visible = true
    vim.cmd("tabnew")
    session.owned.tab = vim.api.nvim_get_current_tabpage()
    session.owned.diff_win = vim.api.nvim_get_current_win()
    session.owned.diff_buf = vim.api.nvim_get_current_buf()
    configure_buffer(
      session.owned.diff_buf,
      string.format("vigit://%s/diff", session.id),
      "vigit-diff"
    )

    session.owned.changes_buf = vim.api.nvim_create_buf(false, true)
    configure_buffer(
      session.owned.changes_buf,
      string.format("vigit://%s/changes", session.id),
      "vigit-changes"
    )

    if vim.o.columns < 80 then
      open_changes_float(session, true)
    else
      open_changes_split(session, true)
    end
  end, debug.traceback)
  if not ok then
    rollback_open(session, original_tab)
    error(message, 0)
  end
  return session
end

function M.resize(session)
  if session.closed
      or not valid_window(session.owned.diff_win)
      or vim.api.nvim_get_current_tabpage() ~= session.owned.tab then
    return
  end

  local changes_win = session.owned.changes_win
  local changes_valid = valid_window(changes_win)
  local current_float = changes_valid
    and vim.api.nvim_win_get_config(changes_win).relative ~= ""
  local narrow = vim.o.columns < 80
  local was_changes = changes_valid and vim.api.nvim_get_current_win() == changes_win

  if narrow then
    if session.view.changes_overlay_visible == false then
      if changes_valid then
        close_changes_window(session)
      end
      return
    end
    if changes_valid and current_float then
      vim.api.nvim_win_set_config(changes_win, float_config())
      return
    end
    if changes_valid then
      close_changes_window(session)
    end
    open_changes_float(session, was_changes)
    return
  end

  if changes_valid and not current_float then
    vim.api.nvim_win_set_width(changes_win, changes_width())
    return
  end
  if changes_valid then
    close_changes_window(session)
  end
  open_changes_split(session, was_changes)
end

function M.toggle_changes(session)
  if session.closed or not valid_window(session.owned.diff_win) then
    return
  end

  if vim.o.columns < 80 then
    if valid_window(session.owned.changes_win) then
      if vim.api.nvim_get_current_win() == session.owned.changes_win then
        session.view.changes_overlay_visible = false
        close_changes_window(session)
        vim.api.nvim_set_current_win(session.owned.diff_win)
      else
        session.view.changes_overlay_visible = true
        vim.api.nvim_set_current_win(session.owned.changes_win)
      end
    else
      session.view.changes_overlay_visible = true
      open_changes_float(session, true)
    end
    return
  end

  M.resize(session)
  if not valid_window(session.owned.changes_win) then
    return
  end
  if vim.api.nvim_get_current_win() == session.owned.changes_win then
    vim.api.nvim_set_current_win(session.owned.diff_win)
  else
    vim.api.nvim_set_current_win(session.owned.changes_win)
  end
end

local function dispose(session)
  if session.closed then
    return false
  end

  session.closed = true
  session.reads.generation = session.reads.generation + 1
  cancel_reads(session)
  return true
end

function M.abandon(session)
  dispose(session)
end

function M.close(session)
  if not dispose(session) then
    return
  end

  if session.owned.tab and vim.api.nvim_tabpage_is_valid(session.owned.tab) then
    local current = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.cmd("tabclose")
    if current ~= session.owned.tab and vim.api.nvim_tabpage_is_valid(current) then
      vim.api.nvim_set_current_tabpage(current)
    end
  end
end

return M
