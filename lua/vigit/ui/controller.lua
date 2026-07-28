local anchor = require("vigit.core.anchor")
local Result = require("vigit.core.result")
local layout = require("vigit.ui.layout")
local renderer = require("vigit.ui.renderer")
local diff_view = require("vigit.ui.views.diff")

local M = {}

local context = {}
local handler_requests = setmetatable({}, { __mode = "k" })
local refresh_requests = setmetatable({}, { __mode = "k" })
local source_target_kinds = {
  add = true,
  context = true,
  delete = true,
  file_placeholder = true,
}

function M.configure(opts)
  context = {
    changes = assert(opts.changes),
    registry = assert(opts.registry),
    config = opts.config,
    open_file = opts.open_file,
    goto_definition = opts.goto_definition,
    open_terminal = opts.open_terminal,
  }
end

local function cursor_target(session)
  local window = session.owned.changes_win
  if not window or not vim.api.nvim_win_is_valid(window) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(window)[1]
  return renderer.target_at(session.owned.changes_buf, row)
end

local function capture_diff_anchor(session)
  local window = session.owned.diff_win
  if not window or not vim.api.nvim_win_is_valid(window) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(window)
  local row = renderer.target_at(session.owned.diff_buf, cursor[1])
  if not row or not row.change_id or not row.hunk_id then
    return nil
  end
  return {
    change_id = row.change_id,
    hunk_id = row.hunk_id,
    source_anchor = anchor.from_row(row, cursor[2]),
  }
end

local function restore_diff_anchor(session, source_anchor, reconcile_context)
  local window = session.owned.diff_win
  if session.closed or not window or not vim.api.nvim_win_is_valid(window) then
    return
  end

  local rendered = diff_view.render(
    session,
    vim.api.nvim_win_get_width(window)
  )
  local row = anchor.match(rendered.rows, source_anchor)
  if reconcile_context and row and source_anchor.context then
    local candidate = anchor.from_row(rendered.rows[row], source_anchor.column)
    if candidate.context ~= source_anchor.context then
      local contextual = {}
      for key, value in pairs(source_anchor) do
        contextual[key] = value
      end
      contextual.source_line = nil
      row = anchor.match(rendered.rows, contextual) or row
    end
  end
  if row then
    vim.api.nvim_win_set_cursor(window, {
      row,
      source_anchor.column or 0,
    })
    return anchor.from_row(rendered.rows[row], source_anchor.column)
  end
end

local function same_source_position(first, second)
  return first
    and second
    and first.path == second.path
    and first.section == second.section
    and first.side == second.side
    and first.source_line == second.source_line
end

local function active_target(session)
  local current_window = vim.api.nvim_get_current_win()
  local window
  local buffer
  if current_window == session.owned.changes_win then
    window = session.owned.changes_win
    buffer = session.owned.changes_buf
  else
    window = session.owned.diff_win
    buffer = session.owned.diff_buf
  end
  if not window
      or not vim.api.nvim_win_is_valid(window)
      or not buffer
      or not vim.api.nvim_buf_is_valid(buffer) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(window)
  return renderer.target_at(buffer, cursor[1]), cursor
end

local function readonly(values)
  return setmetatable({}, {
    __index = values,
    __newindex = function()
      error("HandlerContext is read-only", 2)
    end,
    __pairs = function()
      return next, values, nil
    end,
    __metatable = "HandlerContext",
  })
end

local function handler_context(session)
  local target, cursor = active_target(session)
  if not target then
    return nil
  end

  local relative_path
  local source_line
  if target.kind == "change" and target.change then
    relative_path = target.change.path
  elseif source_target_kinds[target.kind] and target.source_line then
    relative_path = target.path
    source_line = target.source_line
  end
  if not relative_path then
    return nil
  end

  local candidate = vim.fs.joinpath(session.root, relative_path)
  local path = vim.uv.fs_realpath(candidate) or vim.fs.normalize(candidate)
  return readonly({
    session_id = session.id,
    root = session.root,
    branch = session.branch,
    path = path,
    relative_path = relative_path,
    line = source_line or 1,
    column = source_line and cursor[2] or 0,
  })
end

local function valid_handler_result(result)
  if not Result.is(result) then
    return false
  end
  if result.ok then
    return true
  end
  return type(result.error) == "table"
    and type(result.error.code) == "string"
    and result.error.code ~= ""
    and type(result.error.message) == "string"
    and result.error.message ~= ""
end

local function cancel_request(request)
  if not request or type(request.cancel) ~= "function" then
    return
  end
  local cancel = request.cancel
  request.cancel = nil
  pcall(cancel)
end

local function cancel_handler_request(session, action)
  local requests = handler_requests[session]
  if not requests then
    return
  end
  local request = requests[action]
  requests[action] = nil
  cancel_request(request)
end

local function cancel_handler_requests(session)
  local requests = handler_requests[session]
  handler_requests[session] = nil
  if not requests then
    return
  end
  for _, request in pairs(requests) do
    cancel_request(request)
  end
end

local function complete_handler(session, action, request, result)
  local requests = handler_requests[session]
  if session.closed or not requests or requests[action] ~= request then
    return
  end
  requests[action] = nil
  request.cancel = nil

  if not valid_handler_result(result) then
    result = Result.err(
      "invalid_handler_result",
      "Handler completion must receive a Result",
      result
    )
  end

  session.errors = session.errors or {}
  if result.ok then
    if session.error == session.errors.handler then
      session.error = nil
    end
    session.errors.handler = nil
  else
    session.errors.handler = result.error
    session.error = result.error
  end
  renderer.render(session)
end

local function invoke_handler(
  session,
  action,
  unavailable_message,
  failure_message
)
  local values = handler_context(session)
  if not values then
    return
  end
  local configured = context.config
    and context.config.get().handlers[action]
  local handler = configured or context[action]
  local requests = handler_requests[session]
  if not requests then
    requests = {}
    handler_requests[session] = requests
  end
  cancel_handler_request(session, action)
  if type(handler) ~= "function" then
    local request = {}
    requests[action] = request
    complete_handler(session, action, request, Result.err(
      "handler_unavailable",
      unavailable_message
    ))
    return
  end

  local request = {}
  requests[action] = request
  local completed = false
  local function done(result)
    if completed then
      return
    end
    completed = true
    complete_handler(session, action, request, result)
  end
  local returned_cancel
  local ok, message = xpcall(function()
    returned_cancel = handler(values, done)
  end, debug.traceback)
  if not ok then
    done(Result.err(
      "handler_failed",
      failure_message,
      message
    ))
  end
  if type(returned_cancel) == "function" and not completed then
    local current = handler_requests[session]
    if session.closed or not current or current[action] ~= request then
      pcall(returned_cancel)
    else
      request.cancel = returned_cancel
    end
  end
end

local function select_change(session, intent)
  local target
  if type(intent) == "table" and intent.change_id then
    target = {
      kind = "change",
      change_id = intent.change_id,
    }
  else
    target = cursor_target(session)
  end
  if not target or target.kind ~= "change"
      or target.change_id == session.view.selected_change_id then
    return
  end
  refresh_requests[session] = nil
  context.changes:select(session, target.change_id)
end

local function move_file(session, delta)
  local targets = renderer.file_targets(session)
  if #targets == 0 then
    return
  end

  local index = 0
  for candidate, target in ipairs(targets) do
    if target.change_id == session.view.selected_change_id then
      index = candidate
      break
    end
  end
  if index == 0 then
    index = delta > 0 and 0 or 1
  end
  index = ((index - 1 + delta) % #targets) + 1

  if session.owned.changes_win
      and vim.api.nvim_win_is_valid(session.owned.changes_win) then
    vim.api.nvim_win_set_cursor(session.owned.changes_win, { targets[index].row, 0 })
  end
  select_change(session, targets[index])
end

local function all_change_ids(session)
  local ids = {}
  local status = session.data.status or {}
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, change in ipairs(status[section] or {}) do
      if not session.view.all_files.loaded[change.id]
          and not session.view.all_files.loading[change.id] then
        ids[#ids + 1] = change.id
      end
    end
  end
  return ids
end

function M.dispatch(session, intent)
  if not session or session.closed then
    return
  end
  local name = type(intent) == "table" and (intent.name or intent.intent) or intent

  if name == "toggle_focus" then
    layout.toggle_changes(session)
    renderer.render(session)
  elseif name == "activate" or name == "select_change" then
    select_change(session, intent)
  elseif name == "next_file" then
    move_file(session, 1)
  elseif name == "previous_file" then
    move_file(session, -1)
  elseif name == "toggle_all_files" then
    refresh_requests[session] = nil
    session.view.diff_mode = session.view.diff_mode == "one_file"
      and "all_files"
      or "one_file"
    renderer.render(session)
    if session.view.diff_mode == "all_files" then
      context.changes:load_all_visible(session, all_change_ids(session))
    end
  elseif name == "toggle_changes_mode" then
    session.view.changes_mode = session.view.changes_mode == "tree" and "list" or "tree"
    renderer.render(session)
  elseif name == "open_file" then
    invoke_handler(
      session,
      "open_file",
      "Open-file handler is unavailable",
      "Open-file handler failed"
    )
  elseif name == "goto_definition" then
    invoke_handler(
      session,
      "goto_definition",
      "Go-to-definition handler is unavailable",
      "Go-to-definition handler failed"
    )
  elseif name == "open_terminal" then
    invoke_handler(
      session,
      "open_terminal",
      "Terminal handler is unavailable",
      "Terminal handler failed"
    )
  elseif name == "toggle_context" or name == "f" then
    refresh_requests[session] = nil
    local captured = capture_diff_anchor(session)
    if captured then
      local previous = session.view.anchor
      if previous
          and previous.hunk_id
          and session.view.expanded_context[previous.hunk_id]
          and same_source_position(previous, captured.source_anchor) then
        captured.hunk_id = previous.hunk_id
        captured.source_anchor.hunk_id = previous.hunk_id
      end
      session.view.anchor = captured.source_anchor
      context.changes:toggle_context(
        session,
        captured.change_id,
        captured.hunk_id,
        function()
          if session.view.anchor == captured.source_anchor then
            session.view.anchor = restore_diff_anchor(
              session,
              captured.source_anchor
            ) or captured.source_anchor
          end
        end
      )
    end
  elseif name == "refresh" then
    local captured = capture_diff_anchor(session)
    if not captured then
      refresh_requests[session] = nil
      context.changes:refresh(session)
    else
      local request = {
        change_id = captured.change_id,
        source_anchor = captured.source_anchor,
      }
      refresh_requests[session] = request
      session.view.anchor = request.source_anchor
      context.changes:refresh(session, function(event)
        if session.closed
            or refresh_requests[session] ~= request
            or session.view.anchor ~= request.source_anchor then
          return
        end

        local ready = event.phase == "diff"
            and event.change_id == request.change_id
          or event.phase == "status"
            and (not event.result.ok
              or not event.load_ids[request.change_id])
        if not ready then
          return
        end

        refresh_requests[session] = nil
        local window = session.owned.diff_win
        if not window or not vim.api.nvim_win_is_valid(window) then
          return
        end
        local current = renderer.target_at(
          session.owned.diff_buf,
          vim.api.nvim_win_get_cursor(window)[1]
        )
        if current and current.change_id ~= request.change_id then
          return
        end
        session.view.anchor = restore_diff_anchor(
          session,
          request.source_anchor,
          true
        ) or request.source_anchor
      end)
    end
  elseif name == "resize" then
    layout.resize(session)
    renderer.render(session)
  elseif name == "abandon" then
    refresh_requests[session] = nil
    cancel_handler_requests(session)
    renderer.clear(session)
    layout.abandon(session)
    context.registry:remove(session.id)
  elseif name == "close" then
    refresh_requests[session] = nil
    cancel_handler_requests(session)
    renderer.clear(session)
    layout.close(session)
    context.registry:remove(session.id)
  end
end

return M
