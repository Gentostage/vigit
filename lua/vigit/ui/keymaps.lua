local M = {}

local hint_labels = {
  ["worktrees.select"] = "open", ["worktrees.previous"] = "prev",
  ["worktrees.next"] = "next", ["worktrees.refresh"] = "refresh",
  ["worktrees.fetch"] = "fetch", ["worktrees.remove"] = "remove",
  ["worktrees.close"] = "close", ["comments.jump"] = "jump",
  ["comments.edit"] = "edit", ["comments.delete"] = "delete",
  ["comments.close"] = "close", ["help.close"] = "close",
  ["help.escape"] = "close", ["help.open"] = "help",
}

local entries = {
  { id = "view.toggle_focus", modes = { "n" }, lhs = "<Tab>", contexts = { "diff", "changes" }, group = "view", description = "Switch diff and changes", intent = "toggle_focus" },
  { id = "change.activate", modes = { "n" }, lhs = "<CR>", contexts = { "changes" }, group = "navigation", description = "Select change", intent = "activate" },
  { id = "change.next_file", modes = { "n" }, lhs = "]f", contexts = { "diff", "changes" }, group = "navigation", description = "Select next file", intent = "next_file" },
  { id = "navigation.open_file", modes = { "n" }, lhs = "e", contexts = { "diff", "changes" }, group = "navigation", description = "Open source file", intent = "open_file" },
  { id = "navigation.goto_definition", modes = { "n" }, lhs = "gd", contexts = { "diff", "changes" }, group = "navigation", description = "Go to source definition", intent = "goto_definition" },
  { id = "navigation.open_terminal", modes = { "n" }, lhs = "T", contexts = { "diff", "changes" }, group = "lifecycle", description = "Open worktree terminal", intent = "open_terminal" },
  { id = "view.toggle_context", modes = { "n" }, lhs = "f", contexts = { "diff" }, group = "view", description = "Toggle full hunk context", intent = "toggle_context" },
  { id = "change.toggle_index", modes = { "n" }, lhs = "s", contexts = { "diff", "changes" }, group = "git", description = "Stage or unstage current file", intent = "toggle_file_index" },
  { id = "hunk.toggle_index", modes = { "n" }, lhs = "S", contexts = { "diff" }, group = "git", description = "Stage or unstage current hunk", intent = "toggle_hunk_index" },
  { id = "hunk.restore", modes = { "n" }, lhs = "x", contexts = { "diff" }, group = "git", description = "Discard current unstaged hunk", intent = "restore_hunk" },
  { id = "change.restore", modes = { "n" }, lhs = "X", contexts = { "diff", "changes" }, group = "git", description = "Restore current file to HEAD", intent = "restore_file" },
  { id = "change.previous_file", modes = { "n" }, lhs = "[f", contexts = { "diff", "changes" }, group = "navigation", description = "Select previous file", intent = "previous_file" },
  { id = "view.toggle_all_files", modes = { "n" }, lhs = "a", contexts = { "diff", "changes" }, group = "view", description = "Toggle one or all files", intent = "toggle_all_files" },
  { id = "view.toggle_changes_mode", modes = { "n" }, lhs = "t", contexts = { "diff", "changes" }, group = "view", description = "Toggle tree or list", intent = "toggle_changes_mode" },
  { id = "session.refresh", modes = { "n" }, lhs = "r", contexts = { "diff", "changes" }, group = "lifecycle", description = "Refresh changes", intent = "refresh" },
  { id = "comment.add_or_edit", modes = { "n" }, lhs = "c", contexts = { "diff" }, group = "comments", description = "Add or edit comment at diff anchor", intent = "add_comment" },
  { id = "comment.open_list", modes = { "n" }, lhs = "C", contexts = { "diff", "changes" }, group = "comments", description = "Open comments list", intent = "open_comments" },
  { id = "comment.prepare_prompt", modes = { "n" }, lhs = "P", contexts = { "diff", "changes" }, group = "comments", description = "Copy or show open-comments prompt", intent = "prepare_prompt" },
  { id = "comments.jump", modes = { "n" }, lhs = "<CR>", contexts = { "comments" }, group = "comments", description = "Jump to comment anchor", intent = "select_comment" },
  { id = "comments.edit", modes = { "n" }, lhs = "e", contexts = { "comments" }, group = "comments", description = "Edit selected comment", intent = "edit_comment" },
  { id = "comments.delete", modes = { "n" }, lhs = "d", contexts = { "comments" }, group = "comments", description = "Delete selected comment (y/N)", intent = "delete_comment" },
  { id = "comments.close", modes = { "n" }, lhs = "q", contexts = { "comments", "prompt" }, group = "lifecycle", description = "Close Vigit popup", intent = "close" },
  { id = "comment_editor.save", modes = { "n", "i" }, lhs = "<C-s>", contexts = { "comment_editor" }, group = "comments", description = "Save comment", intent = "save_comment" },
  { id = "comment_editor.close", modes = { "n" }, lhs = "q", contexts = { "comment_editor" }, group = "lifecycle", description = "Close comment editor", intent = "close" },
  { id = "comment_editor.escape", modes = { "n" }, lhs = "<Esc>", contexts = { "comment_editor" }, group = "lifecycle", description = "Close comment editor", intent = "close" },
  { id = "session.close", modes = { "n" }, lhs = "q", contexts = { "diff", "changes" }, group = "lifecycle", description = "Return to code mode", intent = "close" },
  { id = "worktrees.open", modes = { "n" }, lhs = "W", contexts = { "diff", "changes", "comments", "prompt", "comment_editor" }, group = "worktrees", description = "Open worktree picker", intent = "open_worktrees" },
  { id = "worktrees.select", modes = { "n" }, lhs = "<CR>", contexts = { "worktrees" }, group = "worktrees", description = "Open selected worktree", intent = "select_worktree" },
  { id = "worktrees.previous", modes = { "n" }, lhs = "[w", contexts = { "worktrees" }, group = "worktrees", description = "Previous worktree", intent = "previous_worktree" },
  { id = "worktrees.next", modes = { "n" }, lhs = "]w", contexts = { "worktrees" }, group = "worktrees", description = "Next worktree", intent = "next_worktree" },
  { id = "worktrees.refresh", modes = { "n" }, lhs = "r", contexts = { "worktrees" }, group = "worktrees", description = "Refresh worktrees", intent = "refresh_worktrees" },
  { id = "worktrees.fetch", modes = { "n" }, lhs = "F", contexts = { "worktrees" }, group = "worktrees", description = "Fetch selected worktree", intent = "fetch_worktree" },
  { id = "worktrees.remove", modes = { "n" }, lhs = "d", contexts = { "worktrees" }, group = "worktrees", description = "Remove selected worktree safely", intent = "remove_worktree" },
  { id = "worktrees.close", modes = { "n" }, lhs = "q", contexts = { "worktrees" }, group = "lifecycle", description = "Close worktree picker", intent = "close" },
  { id = "hunk.next", modes = { "n" }, lhs = "]h", contexts = { "diff" }, group = "navigation", description = "Select next hunk", intent = "next_hunk" },
  { id = "hunk.previous", modes = { "n" }, lhs = "[h", contexts = { "diff" }, group = "navigation", description = "Select previous hunk", intent = "previous_hunk" },
  { id = "help.open", modes = { "n" }, lhs = "?", contexts = { "diff", "changes", "comments", "prompt", "comment_editor", "worktrees" }, group = "lifecycle", description = "Show Vigit help", intent = "show_help" },
  { id = "help.close", modes = { "n" }, lhs = "q", contexts = { "help" }, group = "lifecycle", description = "Close Vigit help", intent = "close" },
  { id = "help.escape", modes = { "n" }, lhs = "<Esc>", contexts = { "help" }, group = "lifecycle", description = "Close Vigit help", intent = "close" },
}

local function includes(values, expected)
  for _, value in ipairs(values) do
    if value == expected then return true end
  end
  return false
end

local function disabled(entry, configured)
  local keymaps = configured and (configured.keymaps or configured) or {}
  return keymaps[entry.id] == false
end

local function codepoint_at(value, index)
  local first = value:byte(index)
  if not first then return nil, index + 1 end
  if first < 0x80 then return first, index + 1 end
  local count = first < 0xE0 and 2 or (first < 0xF0 and 3 or 4)
  local codepoint = first % (count == 2 and 0x20 or (count == 3 and 0x10 or 0x08))
  for offset = 1, count - 1 do
    local byte = value:byte(index + offset)
    if not byte or byte < 0x80 or byte >= 0xC0 then return first, index + 1 end
    codepoint = codepoint * 0x40 + (byte % 0x40)
  end
  return codepoint, index + count
end

local function is_combining(codepoint)
  return (codepoint >= 0x300 and codepoint <= 0x36F)
    or (codepoint >= 0x1AB0 and codepoint <= 0x1AFF)
    or (codepoint >= 0x1DC0 and codepoint <= 0x1DFF)
    or (codepoint >= 0x20D0 and codepoint <= 0x20FF)
    or (codepoint >= 0xFE20 and codepoint <= 0xFE2F)
end

local function is_wide(codepoint)
  return codepoint >= 0x1100 and (
    codepoint <= 0x115F or codepoint == 0x2329 or codepoint == 0x232A
    or (codepoint >= 0x2E80 and codepoint <= 0xA4CF and codepoint ~= 0x303F)
    or (codepoint >= 0xAC00 and codepoint <= 0xD7A3)
    or (codepoint >= 0xF900 and codepoint <= 0xFAFF)
    or (codepoint >= 0xFE10 and codepoint <= 0xFE19)
    or (codepoint >= 0xFE30 and codepoint <= 0xFE6F)
    or (codepoint >= 0xFF00 and codepoint <= 0xFF60)
    or (codepoint >= 0xFFE0 and codepoint <= 0xFFE6)
    or (codepoint >= 0x1F300 and codepoint <= 0x1FAFF)
    or (codepoint >= 0x20000 and codepoint <= 0x3FFFD)
  )
end

function M.display_width(value)
  local width, index = 0, 1
  value = tostring(value or "")
  while index <= #value do
    local codepoint
    codepoint, index = codepoint_at(value, index)
    if codepoint >= 0x20 and codepoint ~= 0x7F and not is_combining(codepoint) then
      width = width + (is_wide(codepoint) and 2 or 1)
    end
  end
  return width
end

function M.for_context(context, configured)
  local result = {}
  for _, entry in ipairs(entries) do
    if includes(entry.contexts, context) and not disabled(entry, configured) then
      result[#result + 1] = entry
    end
  end
  return result
end

function M.active_entries(configured)
  local result = {}
  for _, entry in ipairs(entries) do
    if not disabled(entry, configured) then result[#result + 1] = entry end
  end
  return result
end

setmetatable(entries, {
  __call = function(_, context, configured)
    if context == nil then return entries end
    return M.for_context(context, configured)
  end,
})
M.entries = entries

local group_order = { "navigation", "view", "git", "comments", "worktrees", "lifecycle" }
local group_titles = {
  navigation = "Navigation", view = "View", git = "Git", comments = "Comments",
  worktrees = "Worktrees", lifecycle = "Lifecycle",
}

function M.hints(context, maximum, configured)
  local hints = {}
  maximum = maximum or math.huge
  for _, entry in ipairs(M.for_context(context, configured)) do
    local lhs = entry.lhs == "<CR>" and "↵"
      or entry.lhs == "<Esc>" and "Esc"
      or entry.lhs == "<Tab>" and "Tab"
      or entry.lhs
    local text = lhs .. " " .. (hint_labels[entry.id] or entry.description)
    local candidate = #hints == 0 and text or (table.concat(hints, " · ") .. " · " .. text)
    if M.display_width(candidate) > maximum then break end
    hints[#hints + 1] = text
  end
  return table.concat(hints, " · ")
end

function M.render_markdown(configured)
  local lines = { "# Vigit keymaps", "", "Generated by `lua scripts/generate-keymaps.lua`; do not edit manually.", "" }
  for _, group in ipairs(group_order) do
    lines[#lines + 1] = "## " .. group_titles[group]
    lines[#lines + 1] = ""
    lines[#lines + 1] = "| Context | Mode | Key | Action |"
    lines[#lines + 1] = "| --- | --- | --- | --- |"
    for _, entry in ipairs(entries) do
      if entry.group == group and not disabled(entry, configured) then
        lines[#lines + 1] = string.format(
          "| %s | %s | `%s` | %s |",
          table.concat(entry.contexts, ", "), table.concat(entry.modes, "/"),
          entry.lhs, entry.description
        )
      end
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

local function mapping_config()
  return require("vigit.config").get()
end

local function apply_context(session, buffer, name)
  for _, entry in ipairs(M.for_context(name, mapping_config())) do
    vim.keymap.set(entry.modes, entry.lhs, function()
      require("vigit.ui.controller").dispatch(session, entry.intent)
    end, {
      buffer = buffer, desc = "Vigit: " .. entry.description, noremap = true, silent = true,
    })
  end
end

function M.apply(session)
  apply_context(session, session.owned.diff_buf, "diff")
  apply_context(session, session.owned.changes_buf, "changes")
  local resize_autocmd = vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
    callback = function()
      if not session.closed and session.owned.tab
          and vim.api.nvim_tabpage_is_valid(session.owned.tab)
          and vim.api.nvim_get_current_tabpage() == session.owned.tab then
        require("vigit.ui.controller").dispatch(session, "resize")
      end
    end,
    desc = "Resize the active Vigit layout",
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = session.owned.changes_buf,
    callback = function()
      if not session.closed and session.view.diff_mode == "one_file" then
        require("vigit.ui.controller").dispatch(session, "select_change")
      end
    end,
    desc = "Select the Vigit change under the cursor",
  })
  local function on_owned_buffer_wipe()
    pcall(vim.api.nvim_del_autocmd, resize_autocmd)
    if not session.closed then
      vim.schedule(function()
        if session.closed then return end
        require("vigit.ui.controller").dispatch(session, "abandon")
      end)
    end
  end
  for _, buffer in ipairs({ session.owned.diff_buf, session.owned.changes_buf }) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buffer, once = true, callback = on_owned_buffer_wipe,
      desc = "Dispose the Vigit session with its owned buffers",
    })
  end
end

function M.apply_aux(session, buffer, name, handlers)
  handlers = handlers or {}
  for _, entry in ipairs(M.for_context(name, mapping_config())) do
    local callback = handlers[entry.intent]
    if not callback and entry.intent == "show_help" then
      callback = function() require("vigit.ui.views.help").open(name) end
    end
    if callback then
      vim.keymap.set(entry.modes, entry.lhs, callback, {
        buffer = buffer, desc = "Vigit: " .. entry.description, noremap = true, silent = true,
      })
    end
  end
end

return M
