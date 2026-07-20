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

local function truncate(value, width)
  value = tostring(value or "")
  if #value <= width then
    return value
  end
  if width <= 2 then
    return value:sub(1, width)
  end
  local left = math.ceil((width - 1) / 2)
  local right = math.floor((width - 1) / 2)
  return value:sub(1, left) .. "…" .. value:sub(-right)
end

local function entry_line(entry, width)
  local marker = entry.current and "●" or " "
  local kind = entry.primary and "ROOT" or "WT"
  local stats = { entry.changed == 0 and "clean" or string.format("%d file%s", entry.changed, entry.changed == 1 and "" or "s") }
  if entry.staged > 0 then
    stats[#stats + 1] = "S:" .. entry.staged
  end
  if entry.untracked > 0 then
    stats[#stats + 1] = "?:" .. entry.untracked
  end
  if entry.review_count > 0 then
    stats[#stats + 1] = "R:" .. entry.review_count
  end
  if entry.open then
    stats[#stats + 1] = "OPEN"
  end
  local fixed =
    string.format("%s %-5s %-20s %-24s ", marker, kind, truncate(entry.name, 20), truncate(entry.branch, 24))
  return fixed .. truncate(table.concat(stats, " · "), math.max(width - #fixed, 1))
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

  local lines = {
    " WORKTREES",
    "   TYPE  NAME                 BRANCH                   STATUS",
  }
  local selected_row = 3
  for index, entry in ipairs(entries) do
    lines[#lines + 1] = entry_line(entry, picker.width)
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
    if entry.current then
      vim.api.nvim_buf_add_highlight(picker.buf, picker.namespace, "DiagnosticInfo", row, 0, 1)
    end
    if entry.review_count > 0 then
      vim.api.nvim_buf_add_highlight(picker.buf, picker.namespace, "DiagnosticWarn", row, 0, -1)
    elseif entry.open then
      vim.api.nvim_buf_add_highlight(picker.buf, picker.namespace, "DiagnosticOk", row, 0, -1)
    end
    vim.api.nvim_buf_add_highlight(
      picker.buf,
      picker.namespace,
      entry.primary and "VigitPanelTitle" or "Comment",
      row,
      2,
      entry.primary and 6 or 4
    )
  end

  local max_row = math.max(#entries + 2, 3)
  vim.api.nvim_win_set_cursor(picker.win, { math.min(selected_row, max_row), 0 })
  return true
end

function M.open(session)
  local columns = math.max(vim.o.columns, 40)
  local screen_lines = math.max(vim.o.lines - vim.o.cmdheight, 10)
  local width = math.max(36, math.min(100, columns - 4))
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
