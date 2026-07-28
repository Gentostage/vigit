local M = {}

function M.ask(message, callback)
  local answer = vim.fn.confirm(message, "&Yes\n&No", 2)
  local accepted = answer == 1
  callback(accepted)
  return accepted
end

return M
