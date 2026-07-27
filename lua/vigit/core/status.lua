local Result = require("vigit.core.result")

local M = {}

local function split_nul(raw)
  local records = {}
  local start = 1

  while start <= #raw do
    local separator = raw:find("\0", start, true)
    if not separator then
      records[#records + 1] = raw:sub(start)
      break
    end

    records[#records + 1] = raw:sub(start, separator - 1)
    start = separator + 1
  end

  return records
end

local function change(section, status, path, old_path, unmerged)
  local value = {
    id = section .. "\0" .. path,
    section = section,
    status = status,
    path = path,
  }
  if old_path then
    value.old_path = old_path
  end
  if unmerged then
    value.unmerged = true
  end
  return value
end

local function rename_source(status, old_path)
  if status == "R" or status == "C" then
    return old_path
  end
end

local function add_changes(parsed, xy, path, old_path, unmerged)
  local index_status = xy:sub(1, 1)
  local worktree_status = xy:sub(2, 2)

  if index_status ~= "." then
    parsed.staged[#parsed.staged + 1] = change(
      "staged",
      index_status,
      path,
      rename_source(index_status, old_path),
      unmerged
    )
  end
  if worktree_status ~= "." then
    parsed.unstaged[#parsed.unstaged + 1] = change(
      "unstaged",
      worktree_status,
      path,
      rename_source(worktree_status, old_path),
      unmerged
    )
  end
end

local function parse_branch(record, branch)
  local key, value = record:match("^# branch%.([^ ]+) (.*)$")
  if not key then
    return false
  end

  if key == "oid" then
    branch.oid = value ~= "(initial)" and value or nil
  elseif key == "head" then
    branch.head = value ~= "(detached)" and value or nil
  elseif key == "upstream" then
    branch.upstream = value
  elseif key == "ab" then
    local ahead, behind = value:match("^%+(%d+) %-(%d+)$")
    if not ahead then
      return false
    end
    branch.ahead = tonumber(ahead)
    branch.behind = tonumber(behind)
  end

  return true
end

local function malformed(record)
  return Result.err("malformed_status", "Malformed porcelain-v2 status record", record)
end

function M.parse(raw)
  if type(raw) ~= "string" then
    return Result.err("malformed_status", "Status output must be a string")
  end

  local parsed = {
    branch = {},
    staged = {},
    unstaged = {},
  }
  local records = split_nul(raw)
  local index = 1

  while index <= #records do
    local record = records[index]
    if record == "" then
      index = index + 1
    elseif record:sub(1, 2) == "# " then
      if not parse_branch(record, parsed.branch) then
        return malformed(record)
      end
      index = index + 1
    elseif record:sub(1, 2) == "1 " then
      local xy, path = record:match(
        "^1 (%S%S) %S+ %S+ %S+ %S+ %S+ %S+ (.*)$"
      )
      if not xy or path == "" then
        return malformed(record)
      end
      add_changes(parsed, xy, path)
      index = index + 1
    elseif record:sub(1, 2) == "2 " then
      local xy, path = record:match(
        "^2 (%S%S) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$"
      )
      local old_path = records[index + 1]
      if not xy or path == "" or old_path == nil or old_path == "" then
        return malformed(record)
      end
      add_changes(parsed, xy, path, old_path)
      index = index + 2
    elseif record:sub(1, 2) == "u " then
      local xy, path = record:match(
        "^u (%S%S) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$"
      )
      if not xy or path == "" then
        return malformed(record)
      end
      add_changes(parsed, xy, path, nil, true)
      index = index + 1
    elseif record:sub(1, 2) == "? " then
      local path = record:sub(3)
      if path == "" then
        return malformed(record)
      end
      parsed.unstaged[#parsed.unstaged + 1] = change("unstaged", "?", path)
      index = index + 1
    elseif record:sub(1, 2) == "! " then
      index = index + 1
    else
      return malformed(record)
    end
  end

  return Result.ok(parsed)
end

return M
