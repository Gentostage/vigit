local M = {}

local function under(path, directory)
  return path == directory
    or path:sub(1, #directory + 1) == directory .. "/"
end

function M.under_directory(status, section, directory)
  if (section ~= "staged" and section ~= "unstaged")
      or type(directory) ~= "string"
      or directory == "" then
    return {}
  end
  local result = {}
  for _, change in ipairs(status and status[section] or {}) do
    if type(change.path) == "string" and under(change.path, directory) then
      result[#result + 1] = change
    end
  end
  return result
end

return M
