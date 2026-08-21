local M = {}

function M.range(window, margin_screens)
  if not window or not vim.api.nvim_win_is_valid(window) then return nil, nil end
  local visible = vim.api.nvim_win_call(window, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  local height = math.max(1, vim.api.nvim_win_get_height(window))
  local margin = height * math.max(0, margin_screens or 0)
  local buffer = vim.api.nvim_win_get_buf(window)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(buffer))
  return math.max(1, visible[1] - margin), math.min(line_count, visible[2] + margin)
end

function M.change_ids(rendered, first_row, last_row)
  local result = {}
  local seen = {}
  local rows = rendered and rendered.rows or {}
  first_row = math.max(1, first_row or 1)
  last_row = math.min(#rows, last_row or #rows)
  for row = first_row, last_row do
    local change_id = rows[row] and rows[row].change_id
    if change_id and not seen[change_id] then
      seen[change_id] = true
      result[#result + 1] = change_id
    end
  end
  return result
end

return M
