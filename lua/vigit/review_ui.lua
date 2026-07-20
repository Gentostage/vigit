local review_store = require("vigit.review")

local M = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Vigit" })
end

local function target_at_cursor(session)
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local buffer_name = buf == session.changes_buf and "changes" or (buf == session.diff_buf and "diff" or nil)
  if not buffer_name then
    return nil
  end
  local file = session.state:file_at_line(buffer_name, row) or session.state:selected_file()
  if not file then
    return nil
  end

  local meta = buffer_name == "diff" and session.state.diff_map[row] or nil
  local context = {}
  if buffer_name == "diff" then
    for line = math.max(row - 2, 1), math.min(row + 2, #session.state.diff_lines) do
      local context_meta = session.state.diff_map[line]
      if context_meta and context_meta.file and context_meta.file.path == file.path then
        context[#context + 1] = session.state.diff_lines[line]
      end
    end
  end
  return {
    file = file.path,
    line = (meta and meta.target_line) or file.target_line or 1,
    section = file.section,
    hunk = meta and meta.hunk and meta.hunk.header or "",
    context = table.concat(context, "\n"),
  }
end

function M.add_comment(session)
  local target = target_at_cursor(session)
  if not target then
    notify("No changed file under cursor", vim.log.levels.WARN)
    return
  end
  vim.ui.input({
    prompt = string.format("Review %s:%d: ", target.file, target.line),
  }, function(comment)
    comment = comment and vim.trim(comment) or ""
    if comment == "" then
      return
    end
    target.comment = comment
    local issue, err = review_store.add(session.root, target)
    if not issue then
      notify(err, vim.log.levels.ERROR)
      return
    end
    session.review_count = review_store.open_count(session.root)
    require("vigit.ui").render(session)
    notify(issue.id .. " added")
  end)
end

local function issue_line(issue, width)
  local prefix = string.format(" %-10s %-8s %s:%d  ", issue.id, issue.status or "open", issue.file, issue.line or 1)
  local remaining = math.max(width - #prefix, 1)
  local comment = tostring(issue.comment or ""):gsub("\n", " ")
  if #comment > remaining then
    comment = comment:sub(1, math.max(remaining - 1, 1)) .. "…"
  end
  return prefix .. comment
end

function M.open(session)
  local review, err = review_store.load(session.root)
  if not review then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  local columns = math.max(vim.o.columns, 40)
  local screen_lines = math.max(vim.o.lines - vim.o.cmdheight, 10)
  local width = math.max(36, math.min(110, columns - 4))
  local height = math.max(6, math.min(20, screen_lines - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(math.floor((screen_lines - height) / 2), 0),
    col = math.max(math.floor((columns - width) / 2), 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Vigit Reviews · " .. session.worktree_name .. " ",
    title_pos = "center",
  })
  local lines = { " REVIEWS", "" }
  for _, issue in ipairs(review.issues or {}) do
    lines[#lines + 1] = issue_line(issue, width)
  end
  if #(review.issues or {}) == 0 then
    lines[#lines + 1] = "  No review issues"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  q close · c add from diff · run $vigit-review in Codex"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "vigit-review"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:VigitPanelBorder,CursorLine:VigitCursorLine"
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true })
  return { buf = buf, win = win }
end

return M
