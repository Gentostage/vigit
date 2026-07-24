local M = {}

local common = {
  { key = "<CR>", action = "select_file", desc = "Focus selected file" },
  { key = "e", action = "edit_file", desc = "Edit selected file" },
  { key = "s", action = "stage", desc = "Stage or unstage file or hunk" },
  { key = "x", action = "discard", desc = "Discard unstaged file or hunk" },
  { key = "X", action = "restore_file", desc = "Restore to HEAD or delete untracked file" },
  { key = "r", action = "refresh", desc = "Refresh Git state" },
  { key = "f", action = "toggle_context", desc = "Toggle diff context" },
  { key = "a", action = "show_all", desc = "Show all changed files" },
  { key = "c", action = "comment", desc = "Add or edit review comment" },
  { key = "C", action = "comments", desc = "Open review comments" },
  { key = "P", action = "prompt", desc = "Prepare Codex review prompt" },
  { key = "w", action = "worktrees", desc = "Open worktree picker" },
  { key = "T", action = "terminal", desc = "Open worktree terminal" },
  { key = "[w", action = "previous_worktree", desc = "Previous open worktree" },
  { key = "]w", action = "next_worktree", desc = "Next open worktree" },
  { key = "?", action = "show_help", desc = "Show Vigit help" },
  { key = "q", action = "close", desc = "Close Vigit" },
}

local contexts = {
  {
    id = "changes",
    title = "Changes",
    entries = {
      { key = "t", action = "toggle_tree", desc = "Toggle list and tree view" },
      { key = "h", action = "collapse_directory", desc = "Collapse directory" },
      { key = "l", action = "expand_directory", desc = "Expand directory" },
    },
    common = true,
  },
  {
    id = "diff",
    title = "Diff",
    entries = {
      { key = "gd", action = "definition", desc = "Go to LSP definition" },
      { key = "c", mode = "x", action = "visual_comment", desc = "Comment selected range" },
    },
    common = true,
  },
  {
    id = "worktrees",
    title = "Worktrees",
    entries = {
      { key = "<CR>", action = "open", desc = "Open selected worktree" },
      { key = "d", action = "delete", desc = "Delete selected worktree" },
      { key = "r", action = "refresh", desc = "Refresh worktrees" },
      { key = "?", action = "show_help", desc = "Show Vigit help" },
      { key = "q", action = "close", desc = "Close worktree picker" },
      { key = "<Esc>", action = "close", desc = "Close worktree picker" },
    },
  },
  {
    id = "comments",
    title = "Comments",
    entries = {
      { key = "<CR>", action = "open", desc = "Jump to comment source" },
      { key = "e", action = "edit", desc = "Edit selected comment" },
      { key = "d", action = "delete", desc = "Delete selected comment" },
      { key = "r", action = "refresh", desc = "Refresh comments" },
      { key = "?", action = "show_help", desc = "Show Vigit help" },
      { key = "q", action = "close", desc = "Close comments" },
      { key = "<Esc>", action = "close", desc = "Close comments" },
    },
  },
  {
    id = "comment_editor",
    title = "Comment editor",
    entries = {
      { key = "<C-s>", mode = { "n", "i" }, action = "save", desc = "Save comment" },
      { key = "q", action = "close", desc = "Close comment editor" },
      { key = "<Esc>", action = "close", desc = "Close comment editor" },
      { key = "?", action = "show_help", desc = "Show Vigit help" },
    },
  },
  {
    id = "review_prompt",
    title = "Review prompt",
    entries = {
      { key = "y", action = "copy", desc = "Copy Codex prompt" },
      { key = "?", action = "show_help", desc = "Show Vigit help" },
      { key = "q", action = "close", desc = "Close prompt" },
      { key = "<Esc>", action = "close", desc = "Close prompt" },
    },
  },
  {
    id = "editor",
    title = "Editor",
    entries = {
      { key = ":w", action = "save", desc = "Save file", document_only = true },
      { key = "Q", action = "back", desc = "Return to Vigit" },
      { key = ":VigitHelp", action = "show_help", desc = "Show Vigit help", document_only = true },
    },
  },
  {
    id = "terminal",
    title = "Terminal",
    entries = {
      { key = "Q", action = "back", desc = "Return to Vigit from Normal mode" },
      { key = "<C-q>", mode = "t", action = "back", desc = "Return to Vigit from Terminal mode" },
      { key = "exit", action = "exit", desc = "Close shell and return to Vigit", document_only = true },
      { key = ":VigitHelp", action = "show_help", desc = "Show Vigit help", document_only = true },
    },
  },
  {
    id = "help",
    title = "Help",
    entries = {
      { key = "q", action = "close", desc = "Close help" },
      { key = "<Esc>", action = "close", desc = "Close help" },
    },
  },
}

local by_id = {}
for _, context in ipairs(contexts) do
  by_id[context.id] = context
end

function M.contexts()
  return contexts
end

function M.context(id)
  return by_id[id]
end

function M.entries(id)
  local context = by_id[id]
  if not context then
    return {}
  end
  local entries = {}
  if context.common then
    for _, entry in ipairs(common) do
      entries[#entries + 1] = entry
    end
  end
  for _, entry in ipairs(context.entries or {}) do
    entries[#entries + 1] = entry
  end
  return entries
end

function M.mark(buf, context)
  vim.b[buf].vigit_keymap_context = context
end

function M.context_for_buffer(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return vim.b[buf].vigit_keymap_context
end

function M.bind(buf, context, handlers)
  M.mark(buf, context)
  handlers = handlers or {}
  for _, entry in ipairs(M.entries(context)) do
    local callback = handlers[entry.action]
    if callback and not entry.document_only then
      vim.keymap.set(entry.mode or "n", entry.key, callback, {
        buffer = buf,
        silent = true,
        nowait = true,
        desc = "Vigit: " .. entry.desc,
      })
    end
  end
end

return M
