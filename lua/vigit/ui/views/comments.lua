local confirm = require("vigit.ui.confirm")
local keymaps = require("vigit.ui.keymaps")

local M = {}

local function valid(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function ordered(comments)
  local open, done = {}, {}
  for _, comment in ipairs(comments or {}) do
    local group = comment.done and done or open
    group[#group + 1] = comment
  end
  for _, comment in ipairs(done) do open[#open + 1] = comment end
  return open
end

local function preview(comment)
  local text = vim.trim(tostring(comment.body or ""):gsub("%s+", " "))
  if #text > 60 then text = text:sub(1, 59) .. "…" end
  return text ~= "" and text or "(empty comment)"
end

local function popup(title)
  local buffer = vim.api.nvim_create_buf(false, true)
  local width = math.max(48, math.min(100, vim.o.columns - 6))
  local height = math.max(8, math.min(22, vim.o.lines - 6))
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor", style = "minimal", border = "rounded", title = title,
    title_pos = "center", width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "vigit-comments"
  vim.wo[window].cursorline = true
  return buffer, window
end

function M.open(session, reviews, opts)
  opts = opts or {}
  if valid(session.owned.comments_win) then
    vim.api.nvim_set_current_win(session.owned.comments_win)
    return { buf = session.owned.comments_buf, win = session.owned.comments_win }
  end
  local buffer, window = popup(" Vigit Comments ")
  session.owned.comments_buf, session.owned.comments_win = buffer, window
  vim.api.nvim_buf_set_name(buffer, "vigit://" .. session.id .. "/comments")
  local rows = {}

  local function close()
    if valid(window) then vim.api.nvim_win_close(window, true) end
    if session.owned.comments_win == window then
      session.owned.comments_win, session.owned.comments_buf = nil, nil
    end
  end

  local function render()
    rows = {}
    local lines = { " COMMENTS · open first", "" }
    local allowed = {}
    for _, id in ipairs(opts.focus_ids or {}) do allowed[id] = true end
    for _, comment in ipairs(ordered(session.data.comments)) do
      if next(allowed) == nil or allowed[comment.id] then
      local state = comment.done and "[x]" or "[ ]"
      lines[#lines + 1] = string.format(" %s %s · %s:%d · %s", state, comment.id, comment.path, comment.line, preview(comment))
      rows[#lines] = comment
      end
    end
    if #session.data.comments == 0 then lines[#lines + 1] = " No comments." end
    lines[#lines + 1] = ""
    lines[#lines + 1] = keymaps.hints(
      "comments",
      vim.api.nvim_win_get_width(window),
      require("vigit.config").get()
    )
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    if rows[3] and valid(window) then vim.api.nvim_win_set_cursor(window, { 3, 0 }) end
  end

  local function selected()
    return rows[vim.api.nvim_win_get_cursor(window)[1]]
  end

  require("vigit.ui.keymaps").apply_aux(session, buffer, "comments", {
    close = close,
    select_comment = function()
      local comment = selected()
      if comment then
        close()
        if opts.select then opts.select(comment) end
      end
    end,
    edit_comment = function()
      local comment = selected()
      if not comment then return end
      M.open_editor(session, reviews, {
        comment = comment,
        changed = function()
          if opts.changed then opts.changed() end
          render()
        end,
        failed = opts.failed,
      })
    end,
    delete_comment = function()
      local comment = selected()
      if not comment then return end
      confirm.ask("Delete " .. comment.id .. "?", function(accepted)
        if not accepted then return end
        local result = reviews:delete(session, comment.id)
        if result.ok then
          if opts.changed then opts.changed() end
          render()
        elseif opts.failed then
          opts.failed(result.error)
        end
      end)
    end,
    open_worktrees = function()
      require("vigit.ui.controller").dispatch(session, "open_worktrees")
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer, once = true,
    callback = function()
      if session.owned.comments_buf == buffer then
        session.owned.comments_win, session.owned.comments_buf = nil, nil
      end
    end,
  })
  render()
  return { buf = buffer, win = window }
end

function M.open_editor(session, reviews, opts)
  opts = opts or {}
  local requested_id = opts.comment and opts.comment.id
    or (opts.anchor and table.concat({ opts.anchor.path or "", opts.anchor.section or "", opts.anchor.side or "", tostring(opts.anchor.source_line or opts.anchor.line or "") }, "\0"))
  if valid(session.owned.comment_editor_win) then
    if session.owned.comment_editor_id ~= requested_id then
      local error = { code = "editor_busy", message = "Finish or discard the open Vigit comment editor first" }
      if opts.failed then opts.failed(error) end
      return nil, error
    end
    vim.api.nvim_set_current_win(session.owned.comment_editor_win)
    return { buf = session.owned.comment_editor_buf, win = session.owned.comment_editor_win }
  end
  local buffer, window = popup(" Vigit Comment ")
  session.owned.comment_editor_buf, session.owned.comment_editor_win = buffer, window
  session.owned.comment_editor_id = requested_id
  vim.api.nvim_buf_set_name(buffer, "vigit://" .. session.id .. "/comment-editor")
  vim.bo[buffer].filetype = "markdown"
  local comment = opts.comment
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(comment and comment.body or "", "\n", { plain = true }))
  vim.bo[buffer].modified = false

  local function close(force)
    if not valid(window) then return end
    if not force and vim.bo[buffer].modified then
      confirm.ask("Discard unsaved Vigit comment?", function(accepted)
        if accepted and valid(window) then vim.api.nvim_win_close(window, true) end
      end)
      return
    end
    vim.api.nvim_win_close(window, true)
  end

  local function save()
    if session.closed then return end
    local body = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    body = vim.trim(body)
    if body == "" then return end
    local result = comment
      and reviews:update(session, comment.id, body)
      or reviews:add(session, opts.anchor, body)
    if not result.ok then
      if opts.failed then opts.failed(result.error) end
      return
    end
    if opts.changed then opts.changed() end
    close(true)
  end

  require("vigit.ui.keymaps").apply_aux(session, buffer, "comment_editor", {
    save_comment = save,
    close = function() close(false) end,
    open_worktrees = function()
      require("vigit.ui.controller").dispatch(session, "open_worktrees")
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer, once = true,
    callback = function()
      if session.owned.comment_editor_buf == buffer then
        session.owned.comment_editor_win, session.owned.comment_editor_buf, session.owned.comment_editor_id = nil, nil, nil
      end
    end,
  })
  return { buf = buffer, win = window }
end

function M.open_prompt(session, prompt)
  if valid(session.owned.prompt_win) and vim.api.nvim_buf_is_valid(session.owned.prompt_buf) then
    vim.api.nvim_set_current_win(session.owned.prompt_win)
    vim.bo[session.owned.prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(session.owned.prompt_buf, 0, -1, false, vim.split(prompt, "\n", { plain = true }))
    vim.bo[session.owned.prompt_buf].modifiable = false
    return { buf = session.owned.prompt_buf, win = session.owned.prompt_win }
  end
  local buffer, window = popup(" Vigit Prompt ")
  session.owned.prompt_buf, session.owned.prompt_win = buffer, window
  vim.api.nvim_buf_set_name(buffer, "vigit://" .. session.id .. "/prompt")
  vim.bo[buffer].filetype = "markdown"
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(prompt, "\n", { plain = true }))
  vim.bo[buffer].modifiable = false
  require("vigit.ui.keymaps").apply_aux(session, buffer, "prompt", {
    close = function()
      if valid(window) then vim.api.nvim_win_close(window, true) end
    end,
    open_worktrees = function()
      require("vigit.ui.controller").dispatch(session, "open_worktrees")
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer, once = true,
    callback = function()
      if session.owned.prompt_buf == buffer then
        session.owned.prompt_win, session.owned.prompt_buf = nil, nil
      end
    end,
  })
  return { buf = buffer, win = window }
end

return M
