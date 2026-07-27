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
    id = "session.close",
    modes = { "n" },
    lhs = "q",
    contexts = { "diff", "changes" },
    description = "Close current review",
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
  local resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
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

return M
