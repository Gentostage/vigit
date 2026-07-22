local git = require("vigit.git")
local worktrees = require("vigit.worktrees")

local M = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Vigit" })
end

local function close(picker)
  if picker.win and vim.api.nvim_win_is_valid(picker.win) then
    vim.api.nvim_win_close(picker.win, true)
  end
end

local function display_width(value)
  return vim.fn.strdisplaywidth(tostring(value or ""))
end

local function take_display(value, width, from_right)
  if width <= 0 then
    return ""
  end
  local count = vim.fn.strchars(value)
  local parts = {}
  local used = 0
  local first = from_right and count - 1 or 0
  local last = from_right and 0 or count - 1
  local step = from_right and -1 or 1
  for index = first, last, step do
    local char = vim.fn.strcharpart(value, index, 1)
    local char_width = display_width(char)
    if used + char_width > width then
      break
    end
    if from_right then
      table.insert(parts, 1, char)
    else
      parts[#parts + 1] = char
    end
    used = used + char_width
  end
  return table.concat(parts)
end

local function display_truncate(value, width)
  value = tostring(value or "")
  if display_width(value) <= width then
    return value
  end
  if width <= 1 then
    return take_display(value, width, false)
  end
  local left = math.ceil((width - 1) / 2)
  local right = math.floor((width - 1) / 2)
  return take_display(value, left, false) .. "…" .. take_display(value, right, true)
end

local function display_pad(value, width)
  local truncated = display_truncate(value, width)
  return truncated .. string.rep(" ", math.max(width - display_width(truncated), 0))
end

local function status_text(entry)
  local stats = { entry.changed == 0 and "clean" or string.format("%d file%s", entry.changed, entry.changed == 1 and "" or "s") }
  if entry.staged > 0 then
    stats[#stats + 1] = "S:" .. entry.staged
  end
  if entry.untracked > 0 then
    stats[#stats + 1] = "?:" .. entry.untracked
  end
  if entry.review_count > 0 then
    stats[#stats + 1] = "C:" .. entry.review_count
  end
  if entry.open then
    stats[#stats + 1] = "OPEN"
  end
  return table.concat(stats, " · ")
end

local function table_layout(width, entries)
  local gap_width = 2
  local fixed_width = 1 + 4 + gap_width * 4
  local available = math.max(width - fixed_width, 3)
  local status_natural = display_width("STATUS")
  for _, entry in ipairs(entries) do
    status_natural = math.max(status_natural, display_width(status_text(entry)))
  end
  local status_width = math.min(status_natural, math.max(8, math.floor(available * 0.28)))
  local flexible = math.max(available - status_width, 2)
  local name_width = math.max(math.floor(flexible * 0.45), 1)
  return {
    marker = 1,
    kind = 4,
    name = name_width,
    branch = math.max(flexible - name_width, 1),
    status = status_width,
    separator = string.rep(" ", gap_width),
  }
end

local function table_line(layout, values)
  return table.concat({
    display_pad(values.marker, layout.marker),
    display_pad(values.kind, layout.kind),
    display_pad(values.name, layout.name),
    display_pad(values.branch, layout.branch),
    display_pad(values.status, layout.status),
  }, layout.separator)
end

local function entry_line(entry, layout)
  return table_line(layout, {
    marker = entry.current and "●" or "",
    kind = entry.primary and "ROOT" or "WT",
    name = entry.name,
    branch = entry.branch,
    status = status_text(entry),
  })
end

local function selected_entry(picker)
  if not picker.win or not vim.api.nvim_win_is_valid(picker.win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(picker.win)[1]
  return picker.entries[row - 2]
end

local render

local function remove_selected(picker)
  local entry = selected_entry(picker)
  if not entry then
    return
  end
  if entry.primary then
    notify("ROOT is the primary checkout and cannot be removed", vim.log.levels.WARN)
    return
  end
  if entry.open then
    notify("Close the Vigit tab for " .. entry.name .. " before removing it", vim.log.levels.WARN)
    return
  end

  local changes = entry.changed == 1 and "1 changed file" or string.format("%d changed files", entry.changed)
  vim.ui.input({
    prompt = string.format(
      "Remove WT %s (%s, %s)? Branch will be kept. Type DELETE: ",
      entry.name,
      entry.branch,
      changes
    ),
  }, function(answer)
    if answer ~= "DELETE" then
      notify("Worktree removal cancelled")
      return
    end
    local ok, err = git.remove_worktree(picker.session.root, entry.path, entry.changed > 0)
    if not ok then
      notify(err, vim.log.levels.ERROR)
      return
    end
    notify("Removed WT; branch kept: " .. entry.branch)
    render(picker, picker.session.root)
  end)
end

render = function(picker, selected_path)
  local ui = require("vigit.ui")
  local entries, err = worktrees.list(picker.session.root, {
    is_open = function(path)
      return ui.session_for(path) ~= nil
    end,
  })
  if err then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  picker.entries = entries
  local layout = table_layout(picker.width, entries)

  local lines = {
    " WORKTREES",
    table_line(layout, {
      marker = "",
      kind = "TYPE",
      name = "NAME",
      branch = "BRANCH",
      status = "STATUS",
    }),
  }
  local selected_row = 3
  for index, entry in ipairs(entries) do
    lines[#lines + 1] = entry_line(entry, layout)
    if entry.path == selected_path then
      selected_row = index + 2
    end
  end
  if #entries == 0 then
    lines[#lines + 1] = "  No worktrees"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  ↵ open · d delete WT · r refresh · q close · [w/]w cycle open tabs"

  vim.bo[picker.buf].modifiable = true
  vim.api.nvim_buf_set_lines(picker.buf, 0, -1, false, lines)
  vim.bo[picker.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(picker.buf, picker.namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(picker.buf, picker.namespace, "VigitPanelTitle", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(picker.buf, picker.namespace, "Comment", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(picker.buf, picker.namespace, "Comment", #lines - 1, 0, -1)
  for index, entry in ipairs(entries) do
    local row = index + 1
    local row_text = lines[index + 2]
    if entry.current then
      vim.api.nvim_buf_add_highlight(picker.buf, picker.namespace, "DiagnosticInfo", row, 0, #"●")
    end
    if entry.review_count > 0 then
      vim.api.nvim_buf_add_highlight(picker.buf, picker.namespace, "DiagnosticWarn", row, 0, -1)
    elseif entry.open then
      vim.api.nvim_buf_add_highlight(picker.buf, picker.namespace, "DiagnosticOk", row, 0, -1)
    end
    local kind = entry.primary and "ROOT" or "WT"
    local kind_start = row_text:find(kind, 1, true)
    if kind_start then
      vim.api.nvim_buf_add_highlight(
        picker.buf,
        picker.namespace,
        entry.primary and "VigitPanelTitle" or "Comment",
        row,
        kind_start - 1,
        kind_start - 1 + #kind
      )
    end
  end

  local max_row = math.max(#entries + 2, 3)
  vim.api.nvim_win_set_cursor(picker.win, { math.min(selected_row, max_row), 0 })
  return true
end

function M.open(session)
  local columns = math.max(vim.o.columns, 40)
  local screen_lines = math.max(vim.o.lines - vim.o.cmdheight, 10)
  local width = math.max(36, math.min(140, math.floor(columns * 0.9), columns - 4))
  local height = math.max(6, math.min(20, screen_lines - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  local namespace = vim.api.nvim_create_namespace("vigit-worktrees-" .. buf)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(math.floor((screen_lines - height) / 2), 0),
    col = math.max(math.floor((columns - width) / 2), 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Vigit Worktrees ",
    title_pos = "center",
  })
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "vigit-worktrees"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:VigitPanelBorder,CursorLine:VigitCursorLine"

  local picker = {
    session = session,
    buf = buf,
    win = win,
    width = width,
    entries = {},
    namespace = namespace,
  }

  local function map(lhs, callback)
    vim.keymap.set("n", lhs, callback, { buffer = buf, silent = true, nowait = true })
  end
  map("q", function()
    close(picker)
  end)
  map("<Esc>", function()
    close(picker)
  end)
  map("r", function()
    local selected = selected_entry(picker)
    render(picker, selected and selected.path or session.root)
  end)
  map("d", function()
    remove_selected(picker)
  end)
  map("<CR>", function()
    local entry = selected_entry(picker)
    if not entry then
      return
    end
    close(picker)
    require("vigit.ui").focus_worktree(entry.path)
  end)

  render(picker, session.root)
  return picker
end

return M
