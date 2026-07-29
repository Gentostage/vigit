local M = {}

local loaded = false
local devicons

local function provider()
  if not loaded then
    loaded = true
    local ok, module = pcall(require, "nvim-web-devicons")
    if ok and type(module) == "table" then
      devicons = module
    end
  end
  return devicons
end

function M.directory()
  return "󰉋", "VigitChangesDirectory"
end

function M.file(name)
  local module = provider()
  if module and type(module.get_icon) == "function" then
    local ok, icon, group = pcall(
      module.get_icon,
      name,
      nil,
      { default = true }
    )
    if ok and type(icon) == "string" and icon ~= "" then
      return icon, group or "VigitChangesFile"
    end
  end
  return "󰈔", "VigitChangesFile"
end

return M
