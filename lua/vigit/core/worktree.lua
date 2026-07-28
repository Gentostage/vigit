local Result = require("vigit.core.result")

local M = {}

local function malformed(details)
  return Result.err(
    "malformed_worktree",
    "Malformed worktree porcelain output",
    details
  )
end

local function nul_fields(raw)
  if type(raw) ~= "string" or raw == "" or raw:sub(-1) ~= "\0" then
    return nil
  end

  local fields = {}
  local start = 1
  while start <= #raw do
    local finish = raw:find("\0", start, true)
    if not finish then
      return nil
    end
    fields[#fields + 1] = raw:sub(start, finish - 1)
    start = finish + 1
  end
  return fields
end

local function optional_reason(field, prefix)
  if field == prefix then
    return true
  end
  local reason = field:match("^" .. prefix .. " (.+)$")
  return reason
end

local function parsed_record(fields, kind)
  local first = fields[1]
  local path = first and first:match("^worktree (.+)$")
  if not path then
    return nil
  end

  local entry = { path = path }
  local seen = {}
  for index = 2, #fields do
    local field = fields[index]
    local name, value
    if field:sub(1, 5) == "HEAD " then
      name, value = "head", field:sub(6)
      if value == "" then return nil end
    elseif field:sub(1, 7) == "branch " then
      name, value = "branch_ref", field:sub(8)
      if value == "" then return nil end
    elseif field == "detached" then
      name, value = "detached", true
    elseif field == "bare" then
      name, value = "bare", true
    else
      value = optional_reason(field, "locked")
      if value then
        name = "locked"
      else
        value = optional_reason(field, "prunable")
        if value then name = "prunable" end
      end
    end

    if not name or seen[name] then
      return nil
    end
    seen[name] = true
    entry[name] = value
  end

  if entry.bare then
    if kind ~= "root" or entry.head or entry.branch_ref or entry.detached then
      return nil
    end
  elseif not entry.head or (entry.branch_ref and entry.detached) or not (entry.branch_ref or entry.detached) then
    return nil
  end
  if entry.branch_ref and entry.branch_ref:sub(1, 11) == "refs/heads/" then
    entry.branch = entry.branch_ref:sub(12)
  end
  return entry
end

function M.parse_porcelain(raw)
  local fields = nul_fields(raw)
  if not fields then
    return malformed("output must be non-empty and NUL-terminated")
  end

  local entries = {}
  local record = {}
  for _, field in ipairs(fields) do
    if field == "" then
      if #record == 0 then
        return malformed("empty worktree record")
      end
      local kind = #entries == 0 and "root" or "linked"
      local entry = parsed_record(record, kind)
      if not entry then
        return malformed("invalid worktree record")
      end
      entry.kind = kind
      entries[#entries + 1] = entry
      record = {}
    else
      record[#record + 1] = field
    end
  end

  if #record ~= 0 or #entries == 0 then
    return malformed("unterminated worktree record")
  end
  return Result.ok(entries)
end

local function changed_count(entry)
  if entry.dirty == true then
    return 1
  end
  local function count(source)
    if type(source) ~= "table" then return nil end
    local total = 0
    local found = false
    for _, key in ipairs({ "staged", "unstaged", "untracked" }) do
      if source[key] ~= nil then
        found = true
        total = total + math.max(0, tonumber(source[key]) or 0)
      end
    end
    return found and total or nil
  end

  local files = count(entry.files)
  if files ~= nil then return files end
  local status = count(entry.status)
  if status ~= nil then return status end
  return count(entry) or 0
end

local function loaded_within(entry_path, loaded_paths)
  if type(entry_path) ~= "string" or type(loaded_paths) ~= "table" then
    return false
  end
  local windows_path = entry_path:match("^%a:[/\\]") ~= nil
    or entry_path:sub(1, 2) == "\\\\"
  for key, value in pairs(loaded_paths) do
    local candidate = type(value) == "string" and value or key
    local boundary = type(candidate) == "string" and candidate:sub(#entry_path + 1, #entry_path + 1)
    if type(candidate) == "string" and candidate:sub(1, #entry_path) == entry_path
        and (boundary == "/" or (windows_path and boundary == "\\")) then
      return true
    end
  end
  return false
end

function M.removal_blocker(entry, loaded_paths)
  entry = entry or {}
  if entry.kind == "root" then return "root" end
  if entry.locked then return "locked" end
  if entry.prunable then return "prunable" end
  if changed_count(entry) > 0 then return "dirty" end
  local upstream = entry.upstream
  if type(upstream) ~= "table" or upstream.state ~= "tracking"
      or upstream.source ~= "local_refs" then
    return "no_upstream"
  end
  if (tonumber(upstream.ahead) or 0) > 0 then return "ahead" end
  if loaded_within(entry.path, loaded_paths) then return "loaded_source_buffer" end
  return nil
end

return M
