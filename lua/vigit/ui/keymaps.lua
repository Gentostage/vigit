local controller = require("vigit.ui.controller")

local M = {}

M.entries = {
  {
    id = "view.toggle_focus",
    modes = { "n" },
    lhs = "<Tab>",
    contexts = { "diff", "changes" },
    description = "Switch diff and changes",
    intent = "toggle_focus",
  },
  {
    id = "change.activate",
    modes = { "n" },
    lhs = "<CR>",
    contexts = { "changes" },
    description = "Select change",
    intent = "activate",
  },
  {
    id = "change.next_file",
    modes = { "n" },
    lhs = "]f",
    contexts = { "diff", "changes" },
    description = "Select next file",
    intent = "next_file",
  },
  {
    id = "navigation.open_file",
    modes = { "n" },
    lhs = "e",
    contexts = { "diff", "changes" },
    description = "Open source file",
    intent = "open_file",
  },
  {
    id = "navigation.goto_definition",
    modes = { "n" },
    lhs = "gd",
    contexts = { "diff", "changes" },
    description = "Go to source definition",
    intent = "goto_definition",
  },
  {
    id = "navigation.open_terminal",
    modes = { "n" },
    lhs = "T",
    contexts = { "diff", "changes" },
    description = "Open worktree terminal",
    intent = "open_terminal",
  },
  {
    id = "view.toggle_context",
    modes = { "n" },
    lhs = "f",
    contexts = { "diff" },
    description = "Toggle full hunk context",
    intent = "toggle_context",
  },
  {
    id = "change.toggle_index",
    modes = { "n" },
    lhs = "s",
    contexts = { "diff", "changes" },
    description = "Stage or unstage current file",
    intent = "toggle_file_index",
  },
  {
    id = "hunk.toggle_index",
    modes = { "n" },
    lhs = "S",
    contexts = { "diff" },
    description = "Stage or unstage current hunk",
    intent = "toggle_hunk_index",
  },
  {
    id = "hunk.restore",
    modes = { "n" },
    lhs = "x",
    contexts = { "diff" },
    description = "Discard current unstaged hunk",
    intent = "restore_hunk",
  },
  {
    id = "change.restore",
    modes = { "n" },
    lhs = "X",
    contexts = { "diff", "changes" },
    description = "Restore current file to HEAD",
    intent = "restore_file",
  },
  {
    id = "change.previous_file",
    modes = { "n" },
    lhs = "[f",
    contexts = { "diff", "changes" },
    description = "Select previous file",
    intent = "previous_file",
  },
  {
    id = "view.toggle_all_files",
    modes = { "n" },
    lhs = "a",
    contexts = { "diff", "changes" },
    description = "Toggle one or all files",
    intent = "toggle_all_files",
  },
  {
    id = "view.toggle_changes_mode",
    modes = { "n" },
    lhs = "t",
    contexts = { "diff", "changes" },
    description = "Toggle tree or list",
    intent = "toggle_changes_mode",
  },
  {
    id = "session.refresh",
    modes = { "n" },
    lhs = "r",
    contexts = { "diff", "changes" },
    description = "Refresh changes",
    intent = "refresh",
  },
  {
    id = "comment.add_or_edit",
    modes = { "n" },
    lhs = "c",
    contexts = { "diff" },
    description = "Add or edit comment at diff anchor",
    intent = "add_comment",
  },
  {
    id = "comment.open_list",
    modes = { "n" },
    lhs = "C",
    contexts = { "diff", "changes" },
    description = "Open comments list",
    intent = "open_comments",
  },
  {
    id = "comment.prepare_prompt",
    modes = { "n" },
    lhs = "P",
    contexts = { "diff", "changes" },
    description = "Copy or show open-comments prompt",
    intent = "prepare_prompt",
  },
  {
    id = "comments.jump",
    modes = { "n" },
    lhs = "<CR>",
    contexts = { "comments" },
    description = "Jump to comment anchor",
    intent = "select_comment",
  },
  {
    id = "comments.edit",
    modes = { "n" },
    lhs = "e",
    contexts = { "comments" },
    description = "Edit selected comment",
    intent = "edit_comment",
  },
  {
    id = "comments.delete",
    modes = { "n" },
    lhs = "d",
    contexts = { "comments" },
    description = "Delete selected comment (y/N)",
    intent = "delete_comment",
  },
  {
    id = "comments.close",
    modes = { "n" },
    lhs = "q",
    contexts = { "comments", "prompt" },
    description = "Close Vigit popup",
    intent = "close",
  },
  {
    id = "comment_editor.save",
    modes = { "n", "i" },
    lhs = "<C-s>",
    contexts = { "comment_editor" },
    description = "Save comment",
    intent = "save_comment",
  },
  {
    id = "comment_editor.close",
    modes = { "n" },
    lhs = "q",
    contexts = { "comment_editor" },
    description = "Close comment editor",
    intent = "close",
  },
  {
    id = "comment_editor.escape",
    modes = { "n" },
    lhs = "<Esc>",
    contexts = { "comment_editor" },
    description = "Close comment editor",
    intent = "close",
  },
  {
    id = "session.close",
    modes = { "n" },
    lhs = "q",
    contexts = { "diff", "changes" },
    description = "Close current review",
    intent = "close",
  },
  {
    id = "worktrees.open",
    modes = { "n" },
    lhs = "W",
    contexts = { "diff", "changes", "comments", "prompt", "comment_editor" },
    description = "Open worktree picker",
    intent = "open_worktrees",
  },
  {
    id = "worktrees.select",
    modes = { "n" },
    lhs = "<CR>",
    contexts = { "worktrees" },
    description = "Open selected worktree",
    intent = "select_worktree",
  },
  {
    id = "worktrees.previous",
    modes = { "n" },
    lhs = "[w",
    contexts = { "worktrees" },
    description = "Previous worktree",
    intent = "previous_worktree",
  },
  {
    id = "worktrees.next",
    modes = { "n" },
    lhs = "]w",
    contexts = { "worktrees" },
    description = "Next worktree",
    intent = "next_worktree",
  },
  {
    id = "worktrees.refresh",
    modes = { "n" },
    lhs = "r",
    contexts = { "worktrees" },
    description = "Refresh worktrees",
    intent = "refresh_worktrees",
  },
  {
    id = "worktrees.fetch",
    modes = { "n" },
    lhs = "F",
    contexts = { "worktrees" },
    description = "Fetch selected worktree",
    intent = "fetch_worktree",
  },
  {
    id = "worktrees.remove",
    modes = { "n" },
    lhs = "d",
    contexts = { "worktrees" },
    description = "Remove selected worktree safely",
    intent = "remove_worktree",
  },
  {
    id = "worktrees.close",
    modes = { "n" },
    lhs = "q",
    contexts = { "worktrees" },
    description = "Close worktree picker",
    intent = "close",
  },
}

local function includes(values, expected)
  for _, value in ipairs(values) do
    if value == expected then
      return true
    end
  end
  return false
end

local function apply_context(session, buffer, name)
  for _, entry in ipairs(M.entries) do
    if includes(entry.contexts, name) then
      vim.keymap.set(entry.modes, entry.lhs, function()
        controller.dispatch(session, entry.intent)
      end, {
        buffer = buffer,
        desc = "Vigit: " .. entry.description,
        noremap = true,
        silent = true,
      })
    end
  end
end

function M.apply(session)
  apply_context(session, session.owned.diff_buf, "diff")
  apply_context(session, session.owned.changes_buf, "changes")
  local resize_autocmd = vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
    callback = function()
      if not session.closed
          and session.owned.tab
          and vim.api.nvim_tabpage_is_valid(session.owned.tab)
          and vim.api.nvim_get_current_tabpage() == session.owned.tab then
        controller.dispatch(session, "resize")
      end
    end,
    desc = "Resize the active Vigit layout",
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = session.owned.changes_buf,
    callback = function()
      if not session.closed and session.view.diff_mode == "one_file" then
        controller.dispatch(session, "select_change")
      end
    end,
    desc = "Select the Vigit change under the cursor",
  })
  local function on_owned_buffer_wipe()
    pcall(vim.api.nvim_del_autocmd, resize_autocmd)
    if not session.closed then
      vim.schedule(function()
        if session.closed then
          return
        end
        if session.owned.tab
            and vim.api.nvim_tabpage_is_valid(session.owned.tab) then
          controller.dispatch(session, "close")
        else
          controller.dispatch(session, "abandon")
        end
      end)
    end
  end
  for _, buffer in ipairs({ session.owned.diff_buf, session.owned.changes_buf }) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buffer,
      once = true,
      callback = on_owned_buffer_wipe,
      desc = "Dispose the Vigit session with its owned tab",
    })
  end
end

function M.apply_aux(session, buffer, name, handlers)
  for _, entry in ipairs(M.entries) do
    if includes(entry.contexts, name) and handlers[entry.intent] then
      vim.keymap.set(entry.modes, entry.lhs, handlers[entry.intent], {
        buffer = buffer,
        desc = "Vigit: " .. entry.description,
        noremap = true,
        silent = true,
      })
    end
  end
end

return M
