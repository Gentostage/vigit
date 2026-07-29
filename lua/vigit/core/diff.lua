local Result = require("vigit.core.result")

local M = {}

local function split_lines(raw)
  local lines = {}
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count = line:match(
    "^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@"
  )
  if not old_start then
    return nil
  end

  return {
    old_start = tonumber(old_start),
    old_count = tonumber(old_count ~= "" and old_count or "1"),
    new_start = tonumber(new_start),
    new_count = tonumber(new_count ~= "" and new_count or "1"),
  }
end

local function finish_hunk(hunk)
  if hunk then
    hunk.patch = table.concat(hunk.patch_lines, "\n")
    hunk.patch_lines = nil
  end
end

function M.parse(raw, change)
  if type(raw) ~= "string" or type(change) ~= "table" or type(change.id) ~= "string" then
    return Result.err("malformed_diff", "Diff output and change model are required")
  end

  local parsed = {
    id = change.id,
    change = change,
    section = change.section,
    status = change.status,
    path = change.path,
    old_path = change.old_path,
    headers = {},
    hunks = {},
    binary = false,
    patch = raw,
  }
  local hunk
  local old_line
  local new_line

  for _, line in ipairs(split_lines(raw)) do
    local display_line = line:gsub("\r$", "")
    if display_line:match("^diff %-%-cc ")
        or display_line:match("^diff %-%-combined ")
        or display_line:sub(1, 4) == "@@@ " then
      return Result.err(
        "unsupported_combined_diff",
        "Combined conflict diffs are not supported",
        display_line
      )
    elseif display_line:sub(1, 3) == "@@ " then
      finish_hunk(hunk)
      local range = parse_hunk_header(display_line)
      if not range then
        return Result.err(
          "malformed_diff",
          "Malformed unified diff hunk",
          display_line
        )
      end

      hunk = {
        id = change.id .. "\0" .. range.old_start .. ":" .. range.new_start,
        header = display_line,
        old_start = range.old_start,
        old_count = range.old_count,
        new_start = range.new_start,
        new_count = range.new_count,
        lines = {},
        patch_lines = { line },
      }
      parsed.hunks[#parsed.hunks + 1] = hunk
      old_line = range.old_start
      new_line = range.new_start
    elseif hunk and display_line:match("^[ +%-\\]") then
      local marker = display_line:sub(1, 1)
      local diff_line

      if marker == "-" then
        diff_line = {
          kind = "delete",
          text = display_line:sub(2),
          old_line = old_line,
          new_line = nil,
        }
        old_line = old_line + 1
      elseif marker == "+" then
        diff_line = {
          kind = "add",
          text = display_line:sub(2),
          old_line = nil,
          new_line = new_line,
        }
        new_line = new_line + 1
      elseif marker == " " then
        diff_line = {
          kind = "context",
          text = display_line:sub(2),
          old_line = old_line,
          new_line = new_line,
        }
        old_line = old_line + 1
        new_line = new_line + 1
      else
        diff_line = {
          kind = "meta",
          text = display_line,
          old_line = nil,
          new_line = nil,
        }
      end

      hunk.lines[#hunk.lines + 1] = diff_line
      hunk.patch_lines[#hunk.patch_lines + 1] = line
    elseif not hunk and display_line ~= "" then
      parsed.headers[#parsed.headers + 1] = line
      if display_line:match("^Binary files .+ differ$")
          or display_line == "GIT binary patch" then
        parsed.binary = true
      end
    elseif hunk and display_line:sub(1, 5) == "diff " then
      return Result.err(
        "malformed_diff",
        "Diff output contains multiple files",
        display_line
      )
    end
  end

  finish_hunk(hunk)
  return Result.ok(parsed)
end

return M
