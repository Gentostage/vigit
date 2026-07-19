local init_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(init_path, ":p:h:h")

vim.opt.runtimepath:prepend(project_root)
vim.opt.background = "dark"
vim.opt.termguicolors = true
vim.opt.laststatus = 3
vim.opt.showtabline = 0
vim.opt.cmdheight = 1

vim.cmd("syntax enable")
pcall(vim.cmd.colorscheme, "habamax")

require("vigit").setup()

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local session = require("vigit").open()
    if session then
      vim.api.nvim_set_current_win(session.changes_win)
    end
  end,
})
