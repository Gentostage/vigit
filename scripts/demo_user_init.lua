-- User config and plugins are already loaded when this file runs. Restore the
-- compact demo chrome without replacing a user-selected colorscheme.
vim.opt.termguicolors = true
vim.opt.laststatus = 3
vim.opt.showtabline = 0
vim.opt.cmdheight = 1

vim.cmd("syntax enable")
if not vim.g.colors_name then
  pcall(vim.cmd.colorscheme, "habamax")
end

if vim.fn.exists(":Vigit") == 0 then
  require("vigit").setup()
end

local session = require("vigit").open({ cwd = vim.env.VIGIT_DEMO_DIR })
if session then
  vim.api.nvim_set_current_win(session.changes_win)
end
