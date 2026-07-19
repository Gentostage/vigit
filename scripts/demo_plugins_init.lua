local project_root = assert(vim.env.VIGIT_ROOT, "VIGIT_ROOT is required")
local demo_dir = assert(vim.env.VIGIT_DEMO_DIR, "VIGIT_DEMO_DIR is required")

if vim.fn.has("nvim-0.12") == 0 then
  error("Vigit --plugins requires Neovim 0.12+")
end

vim.g.mapleader = " "
vim.opt.runtimepath:prepend(project_root)
vim.opt.background = "dark"
vim.opt.termguicolors = true
vim.opt.laststatus = 3
vim.opt.showtabline = 0
vim.opt.cmdheight = 1

vim.cmd("syntax enable")
pcall(vim.cmd.colorscheme, "habamax")

vim.pack.add({
  { src = "https://github.com/nvim-lua/plenary.nvim" },
  {
    src = "https://github.com/nvim-telescope/telescope.nvim",
    version = "v0.2.1",
  },
}, { confirm = false })

require("telescope").setup({})
local telescope = require("telescope.builtin")
local mapping_group = vim.api.nvim_create_augroup("VigitDemoTelescopeMappings", { clear = true })

local function attach_telescope_mappings(buf)
  if vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == "" then
    return
  end

  local opts = { buffer = buf, silent = true }
  vim.keymap.set("n", "<leader>ff", telescope.find_files, vim.tbl_extend("force", opts, {
    desc = "Telescope find files",
  }))
  vim.keymap.set("n", "<leader>fg", telescope.live_grep, vim.tbl_extend("force", opts, {
    desc = "Telescope live grep",
  }))
  vim.keymap.set("n", "<leader>fb", telescope.buffers, vim.tbl_extend("force", opts, {
    desc = "Telescope buffers",
  }))
end

vim.api.nvim_create_autocmd("BufEnter", {
  group = mapping_group,
  callback = function(args)
    attach_telescope_mappings(args.buf)
  end,
})

require("vigit").setup()

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local session = require("vigit").open({ cwd = demo_dir })
    if session then
      vim.api.nvim_set_current_win(session.changes_win)
    end
  end,
})
