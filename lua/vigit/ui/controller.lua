local layout = require("vigit.ui.layout")
local renderer = require("vigit.ui.renderer")

local M = {}

local context = {}

function M.configure(opts)
  context = {
    changes = assert(opts.changes),
    registry = assert(opts.registry),
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
  elseif name == "refresh" then
    context.changes:refresh(session)
  elseif name == "resize" then
    layout.resize(session)
    renderer.render(session)
  elseif name == "abandon" then
    renderer.clear(session)
    layout.abandon(session)
    context.registry:remove(session.id)
  elseif name == "close" then
    renderer.clear(session)
    layout.close(session)
    context.registry:remove(session.id)
  end
end

return M
