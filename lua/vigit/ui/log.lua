local M = {}

local maximum_entries = 200
local ring = {}

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, nested in pairs(value) do result[copy(key, seen)] = copy(nested, seen) end
  return result
end

local function append(entry)
  ring[#ring + 1] = entry
  if #ring > maximum_entries then table.remove(ring, 1) end
  return copy(entry)
end

local function escape(value)
  return tostring(value or ""):gsub("[%z\1-\31\127]", function(byte)
    return string.format("\\x%02X", string.byte(byte))
  end)
end

local function describe(value, seen)
  if type(value) == "string" then return value end
  if type(value) ~= "table" then return tostring(value) end
  seen = seen or {}
  if seen[value] then return "<cycle>" end
  seen[value] = true
  local parts = {}
  for key, nested in pairs(value) do
    parts[#parts + 1] = tostring(key) .. "=" .. describe(nested, seen)
  end
  table.sort(parts)
  seen[value] = nil
  return "{" .. table.concat(parts, ", ") .. "}"
end

function M.push(value)
  if type(value) ~= "table" then return nil end
  if value.ok == true then return nil end
  local error = value.ok == false and value.error or value
  if type(error) ~= "table" or type(error.code) ~= "string" or error.code == "" then return nil end
  local entry = {
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"), session_id = error.session_id,
    level = "error", code = error.code, message = error.message,
    details = copy(error.details),
  }
  return append(entry)
end

function M.event(code, details)
  if type(code) ~= "string" or code == "" then return nil end
  return append({
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    level = "info",
    code = code,
    details = copy(details),
  })
end

function M.entries()
  return copy(ring)
end

function M.lines()
  local lines = { "VIGIT DIAGNOSTICS" }
  for _, entry in ipairs(ring) do
    local prefix = string.format(
      "%s [%s] %s%s",
      entry.timestamp,
      string.upper(entry.level or "error"),
      entry.session_id and ("[" .. entry.session_id .. "] ") or "",
      entry.code
    )
    lines[#lines + 1] = escape(prefix .. ": " .. tostring(entry.message or ""))
    if entry.details ~= nil then lines[#lines + 1] = "  " .. escape(describe(entry.details)) end
  end
  return lines
end

function M.open()
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, "vigit://log")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, M.lines())
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].readonly = true
  vim.bo[buffer].filetype = "vigit-log"
  vim.api.nvim_set_current_buf(buffer)
  return buffer
end

return M
