local changes_view = require("vigit.ui.views.changes")
local diff_view = require("vigit.ui.views.diff")

local M = {}

local namespaces = {
  changes = vim.api.nvim_create_namespace("vigit-v2-changes"),
  diff = vim.api.nvim_create_namespace("vigit-v2-diff"),
}
local targets = {}

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function window_width(window)
  if window and vim.api.nvim_win_is_valid(window) then
    return vim.api.nvim_win_get_width(window)
  end
  return vim.o.columns
end

local function apply(buffer, namespace, output)
  if not valid_buffer(buffer) then
    return
  end

  targets[buffer] = nil
  vim.bo[buffer].modifiable = true
  local ok, message = xpcall(function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, output.lines)
    vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)

    for _, highlight in ipairs(output.highlights or {}) do
      vim.api.nvim_buf_set_extmark(buffer, namespace, highlight.row - 1, 0, {
        end_row = highlight.row,
        hl_group = highlight.group,
        hl_eol = true,
        strict = false,
      })
    end
    for _, target in ipairs(output.targets or {}) do
      vim.api.nvim_buf_set_extmark(buffer, namespace, target.row - 1, 0, {
        strict = false,
      })
    end

    targets[buffer] = output.targets or {}
  end, debug.traceback)
  if valid_buffer(buffer) then
    vim.bo[buffer].modifiable = false
  end
  if not ok then
    error(message, 0)
  end
end

function M.render(session)
  if session.closed
      or not session.owned.tab
      or not vim.api.nvim_tabpage_is_valid(session.owned.tab) then
    return
  end

  local changes = changes_view.render(
    session,
    window_width(session.owned.changes_win)
  )
  local diff = diff_view.render(
    session,
    window_width(session.owned.diff_win)
  )
  apply(session.owned.changes_buf, namespaces.changes, changes)
  apply(session.owned.diff_buf, namespaces.diff, diff)
end

function M.target_at(buffer, row)
  for _, target in ipairs(targets[buffer] or {}) do
    if target.row == row then
      return target
    end
  end
end

function M.file_targets(session)
  local result = {}
  for _, target in ipairs(targets[session.owned.changes_buf] or {}) do
    if target.kind == "change" then
      result[#result + 1] = target
    end
  end
  return result
end

function M.clear(session)
  if session.owned.diff_buf then
    targets[session.owned.diff_buf] = nil
  end
  if session.owned.changes_buf then
    targets[session.owned.changes_buf] = nil
  end
end

return M
