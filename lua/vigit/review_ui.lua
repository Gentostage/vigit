local review_store = require("vigit.review")

local M = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Vigit" })
end

local function issue_target(issue)
  return {
    file = issue.file,
    line = issue.line,
    line_end = issue.line_end or issue.line,
    section = issue.section,
    hunk = issue.hunk,
    context = issue.context,
    selected_text = issue.selected_text,
  }
end

local function edit_comment(session, issue)
  require("vigit.review_editor").open(session, issue_target(issue), { issue = issue })
end

local function comments_at_cursor(session)
  if vim.api.nvim_get_current_buf() ~= session.diff_buf then
    return {}
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local comments = {}
  for _, comment in ipairs(session.review_comments or {}) do
    if session.state:diff_line_for_anchor(comment) == row then
      comments[#comments + 1] = comment
    end
  end
  return comments
end

local function target_at_cursor(session, opts)
  opts = opts or {}
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

  local first_row = row
  local last_row = row
  if opts.visual then
    if buffer_name ~= "diff" then
      return nil, "Select lines in the diff pane"
    end
    if vim.fn.mode():match("^[vV\22]") then
      first_row = vim.fn.line("v")
      last_row = vim.fn.line(".")
    else
      first_row = vim.fn.getpos("'<")[2]
      last_row = vim.fn.getpos("'>")[2]
    end
    if first_row > last_row then
      first_row, last_row = last_row, first_row
    end
  end

  local meta = buffer_name == "diff" and session.state.diff_map[row] or nil
  local first_meta = buffer_name == "diff" and session.state.diff_map[first_row] or nil
  local last_meta = buffer_name == "diff" and session.state.diff_map[last_row] or nil
  if opts.visual then
    if not first_meta or not last_meta or not first_meta.file or not last_meta.file then
      return nil, "Select code lines from one changed file"
    end
    if first_meta.file.path ~= last_meta.file.path or first_meta.file.section ~= last_meta.file.section then
      return nil, "A comment cannot span multiple files"
    end
    file = first_meta.file
  end

  local line_start = (first_meta and first_meta.target_line) or (meta and meta.target_line) or file.target_line or 1
  local line_end = (last_meta and last_meta.target_line) or line_start
  line_start, line_end = math.min(line_start, line_end), math.max(line_start, line_end)
  local context = {}
  if buffer_name == "diff" then
    for line = math.max(first_row - 2, 1), math.min(last_row + 2, #session.state.diff_lines) do
      local context_meta = session.state.diff_map[line]
      if context_meta and context_meta.file and context_meta.file.path == file.path then
        context[#context + 1] = session.state.diff_lines[line]
      end
    end
  end
  return {
    file = file.path,
    line = line_start,
    line_end = line_end,
    section = file.section,
    hunk = (first_meta and first_meta.hunk and first_meta.hunk.header)
      or (meta and meta.hunk and meta.hunk.header)
      or "",
    context = table.concat(context, "\n"),
    selected_text = buffer_name == "diff"
        and table.concat(vim.list_slice(session.state.diff_lines, first_row, last_row), "\n")
      or "",
  }, nil
end

function M.add_comment(session, opts)
  opts = opts or {}
  if not opts.visual then
    local anchored = comments_at_cursor(session)
    if #anchored == 1 then
      edit_comment(session, anchored[1])
      return
    elseif #anchored > 1 then
      vim.ui.select(anchored, {
        prompt = "Edit comment",
        format_item = function(issue)
          local preview = vim.trim(tostring(issue.comment or ""):gsub("%s+", " "))
          return issue.id .. " · " .. preview
        end,
      }, function(issue)
        if issue then
          edit_comment(session, issue)
        end
      end)
      return
    end
  end
  local target, target_err = target_at_cursor(session, opts)
  if not target then
    notify(target_err or "No changed file under cursor", vim.log.levels.WARN)
    return
  end
  require("vigit.review_editor").open(session, target)
end

M.target_at_cursor = target_at_cursor

local function open_prompt(result)
  local columns = math.max(vim.o.columns, 50)
  local screen_lines = math.max(vim.o.lines - vim.o.cmdheight, 12)
  local width = math.max(46, math.min(100, columns - 6))
  local height = math.max(10, math.min(22, screen_lines - 6))
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(math.floor((screen_lines - height) / 2), 0),
    col = math.max(math.floor((columns - width) / 2), 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Codex Prompt · comments.md ",
    title_pos = "center",
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.prompt, "\n", { plain = true }))
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:VigitPanelBorder"
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "y", function()
    local ok = pcall(vim.fn.setreg, "+", result.prompt)
    notify(ok and "Prompt copied" or ("Prompt saved at " .. result.comments_path), ok and nil or vim.log.levels.WARN)
  end, { buffer = buf, silent = true, nowait = true })
end

function M.prepare(session)
  local result, err = review_store.simple_prompt(session.root)
  if not result then
    notify(err, vim.log.levels.WARN)
    return nil
  end
  local copied = vim.fn.has("clipboard") == 1 and pcall(vim.fn.setreg, "+", result.prompt)
  if copied then
    notify("Codex prompt copied")
  else
    notify("Clipboard unavailable; copy the prompt with y")
    open_prompt(result)
  end
  return result
end

local function issue_line(issue, width)
  local range = tostring(issue.line or 1)
  if issue.line_end and issue.line_end ~= issue.line then
    range = range .. "-" .. tostring(issue.line_end)
  end
  local prefix = string.format(" %-10s %s:%s  ", issue.id, issue.file, range)
  local remaining = math.max(width - #prefix, 1)
  local comment = tostring(issue.comment or ""):gsub("\n", " ")
  if #comment > remaining then
    comment = comment:sub(1, math.max(remaining - 1, 1)) .. "…"
  end
  return prefix .. comment
end

local function current_diff_file(session, issue)
  local sections = {}
  if issue.section then
    sections[#sections + 1] = issue.section
  end
  for _, fallback in ipairs({ "unstaged", "staged" }) do
    if fallback ~= issue.section then
      sections[#sections + 1] = fallback
    end
  end
  for _, section in ipairs(sections) do
    for _, file in ipairs(session.state.diffs[section] or {}) do
      if file.path == issue.file then
        return file
      end
    end
  end
  return nil
end

local function jump_to_source(session, issue)
  local file = current_diff_file(session, issue)
  if not file then
    notify("Comment source is no longer in the Git diff: " .. issue.file, vim.log.levels.WARN)
    return false
  end
  local selected, select_err = session.state:select_file(file)
  if not selected then
    notify(select_err, vim.log.levels.WARN)
    return false
  end
  require("vigit.ui").render(session)
  local row = session.state:diff_line_for_anchor(issue) or session.state:diff_line_for_file(file)
  if not row then
    notify("Cannot locate comment anchor: " .. issue.id, vim.log.levels.WARN)
    return false
  end
  vim.api.nvim_set_current_win(session.diff_win)
  vim.api.nvim_win_set_cursor(session.diff_win, { row, 0 })
  vim.api.nvim_win_call(session.diff_win, function()
    vim.cmd("normal! zz")
  end)
  return true
end

function M.open(session)
  local comments, err = review_store.comments(session.root)
  if not comments then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  local columns = math.max(vim.o.columns, 40)
  local screen_lines = math.max(vim.o.lines - vim.o.cmdheight, 10)
  local width = math.max(40, math.min(110, columns - 4))
  local height = math.max(9, math.min(22, screen_lines - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(math.floor((screen_lines - height) / 2), 0),
    col = math.max(math.floor((columns - width) / 2), 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Vigit Comments · " .. session.worktree_name .. " ",
    title_pos = "center",
  })
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "vigit-comments"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:VigitPanelBorder,CursorLine:VigitCursorLine"

  local issue_map = {}
  local reload

  local function close()
    if session.review_panel_reload == reload then
      session.review_panel_reload = nil
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function selected_issue()
    return issue_map[vim.api.nvim_win_get_cursor(win)[1]]
  end

  local function render()
    local lines = { " COMMENTS · " .. tostring(#comments), "" }
    issue_map = {}
    for _, issue in ipairs(comments) do
      lines[#lines + 1] = issue_line(issue, width)
      issue_map[#lines] = issue
    end
    if #comments == 0 then
      lines[#lines + 1] = "  No comments. Close this window and press c on a changed line."
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Enter source · e edit · d delete · r refresh · q close"
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    if #comments > 0 then
      vim.api.nvim_win_set_cursor(win, { 3, 0 })
    end
  end

  reload = function()
    local refreshed, refresh_err = review_store.comments(session.root)
    if not refreshed then
      notify(refresh_err, vim.log.levels.ERROR)
      return
    end
    comments = refreshed
    require("vigit.ui").render(session)
    render()
  end

  vim.keymap.set("n", "q", close, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<CR>", function()
    local issue = selected_issue()
    if issue and jump_to_source(session, issue) then
      close()
    end
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "e", function()
    local issue = selected_issue()
    if not issue then
      return
    end
    close()
    edit_comment(session, issue)
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "d", function()
    local issue = selected_issue()
    if not issue then
      return
    end
    vim.ui.select({ "Cancel", "Delete" }, {
      prompt = "Delete " .. issue.id .. "?",
    }, function(choice)
      if choice ~= "Delete" then
        return
      end
      local deleted, delete_err = review_store.delete(session.root, issue.id)
      if not deleted then
        notify(delete_err, vim.log.levels.ERROR)
        return
      end
      notify(issue.id .. " deleted")
      reload()
    end)
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "r", function()
    local refreshed, refresh_err = session.state:refresh()
    if not refreshed then
      notify(refresh_err, vim.log.levels.ERROR)
      return
    end
    reload()
  end, { buffer = buf, silent = true, nowait = true })
  session.review_panel_reload = reload
  render()
  return { buf = buf, win = win }
end

return M
