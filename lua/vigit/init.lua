local M = {}

function M.setup()
  vim.api.nvim_create_user_command("Vigit", function()
    require("vigit.ui").open()
  end, {})
end

function M.open(opts)
  return require("vigit.ui").open(opts)
end

return M
