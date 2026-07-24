local M = {}

function M.ask(prompt, callback)
  local choice = vim.fn.confirm(prompt, "&Yes\n&No", 2, "Question")
  if choice ~= 1 then
    return false
  end
  callback()
  return true
end

return M
