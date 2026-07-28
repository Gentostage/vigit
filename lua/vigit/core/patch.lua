local Result = require("vigit.core.result")

local M = {}

local function unsupported(details)
  return Result.err(
    "unsupported_hunk",
    "This change cannot be staged or unstaged by hunk",
    details
  )
end

local function current_hunk(file_diff, hunk)
  if type(file_diff) ~= "table" or type(hunk) ~= "table" then
    return nil
  end
  if type(file_diff.id) ~= "string" or type(hunk.id) ~= "string" then
    return nil
  end
  local prefix = file_diff.id .. "\0"
  if hunk.id:sub(1, #prefix) ~= prefix then
    return nil
  end
  for _, candidate in ipairs(file_diff.hunks or {}) do
    if candidate.id == hunk.id and candidate.patch == hunk.patch then
      return candidate
    end
  end
end

local function quoted_patch_path(path)
  local escaped = {}
  for index = 1, #path do
    local byte = path:byte(index)
    if byte == 34 or byte == 92 then
      escaped[#escaped + 1] = "\\" .. string.char(byte)
    elseif byte == 9 then
      escaped[#escaped + 1] = "\\t"
    elseif byte == 10 then
      escaped[#escaped + 1] = "\\n"
    elseif byte == 13 then
      escaped[#escaped + 1] = "\\r"
    elseif byte < 32 or byte == 127 or byte >= 128 then
      escaped[#escaped + 1] = string.format("\\%03o", byte)
    else
      escaped[#escaped + 1] = string.char(byte)
    end
  end
  return '"' .. table.concat(escaped) .. '"'
end

local function reverse_rename_patch(file_diff, selected)
  if type(file_diff.path) ~= "string" or file_diff.path == "" then
    return unsupported("rename target path is missing")
  end
  local current_path = file_diff.path
  local headers = {
    "diff --git " .. quoted_patch_path("a/" .. current_path)
      .. " " .. quoted_patch_path("b/" .. current_path),
  }
  for _, header in ipairs(file_diff.headers) do
    if header:match("^index ") then
      headers[#headers + 1] = header
    end
  end
  headers[#headers + 1] = "--- " .. quoted_patch_path("a/" .. current_path)
  headers[#headers + 1] = "+++ " .. quoted_patch_path("b/" .. current_path)
  return Result.ok(table.concat(headers, "\n") .. "\n" .. selected.patch .. "\n")
end

function M.needs_unidiff_zero(hunk)
  if type(hunk) ~= "table" or type(hunk.patch) ~= "string" then
    return false
  end
  for line in (hunk.patch .. "\n"):gmatch("(.-)\n") do
    if line:sub(1, 1) == " " then
      return false
    end
  end
  return true
end

function M.for_hunk(file_diff, hunk, options)
  if type(file_diff) ~= "table" or file_diff.binary then
    return unsupported("binary or malformed file diff")
  end
  if type(file_diff.hunks) ~= "table" or #file_diff.hunks == 0 then
    return unsupported("file diff has no textual hunks")
  end
  if type(file_diff.headers) ~= "table" or #file_diff.headers == 0 then
    return unsupported("file diff has no patch headers")
  end
  if file_diff.status == "?" then
    return unsupported("untracked files must be staged as a whole")
  end

  local selected = current_hunk(file_diff, hunk)
  if not selected then
    return Result.err("stale_hunk", "Selected hunk is missing or stale")
  end
  if type(selected.patch) ~= "string" or selected.patch == "" then
    return unsupported("selected hunk has no patch")
  end

  local headers = table.concat(file_diff.headers, "\n")
  if not headers:match("^diff %-%-git ")
      or not headers:match("\n%-%-%- ")
      or not headers:match("\n%+%+%+ ") then
    return unsupported("file diff is missing unified patch headers")
  end
  if options and options.normalize_rename_for_reverse
      and file_diff.section == "staged"
      and file_diff.status == "R" then
    return reverse_rename_patch(file_diff, selected)
  end
  return Result.ok(headers .. "\n" .. selected.patch .. "\n")
end

return M
