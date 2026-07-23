local M = {}

local function split_lines(output)
  local lines = {}
  if output == nil or output == "" then
    return lines
  end
  for line in tostring(output):gmatch("([^\n]*)\n?") do
    if line ~= "" then
      lines[#lines + 1] = line
    end
  end
  return lines
end

local function parse_path(raw)
  local old_path, new_path = raw:match("^(.-) %-> (.+)$")
  if old_path and new_path then
    return new_path, old_path
  end
  return raw, nil
end

function M.parse_status(output)
  local result = { staged = {}, unstaged = {} }

  for _, line in ipairs(split_lines(output)) do
    local index_status = line:sub(1, 1)
    local worktree_status = line:sub(2, 2)
    if not (index_status == "!" and worktree_status == "!") then
      local raw_path = line:sub(4)
      local path, old_path = parse_path(raw_path)

      if index_status ~= " " and index_status ~= "?" then
        result.staged[#result.staged + 1] = {
          path = path,
          old_path = old_path,
          status = index_status,
          section = "staged",
        }
      end

      if worktree_status ~= " " then
        result.unstaged[#result.unstaged + 1] = {
          path = path,
          old_path = old_path,
          status = worktree_status,
          section = "unstaged",
        }
      end
    end
  end

  return result
end

local function normalize_diff_path(path)
  if path == "/dev/null" then
    return nil
  end
  return path:gsub("^[ab]/", "")
end

local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  old_count = old_count == "" and "1" or old_count
  new_count = new_count == "" and "1" or new_count
  return tonumber(old_start), tonumber(old_count), tonumber(new_start), tonumber(new_count)
end

local function line_kind(line)
  local prefix = line:sub(1, 1)
  if prefix == "+" then
    return "added"
  end
  if prefix == "-" then
    return "removed"
  end
  return "context"
end

function M.parse_diff(output, section)
  local files = {}
  local current_file = nil
  local current_hunk = nil
  local current_old_line = nil
  local current_new_line = nil

  for _, line in ipairs(split_lines(output)) do
    if line:match("^diff %-%-git ") then
      current_file = { section = section, hunks = {}, lines = {}, extended_headers = {} }
      current_hunk = nil
      current_old_line = nil
      current_new_line = nil
      files[#files + 1] = current_file
    elseif current_file and line:match("^%-%-%- ") then
      current_file.old_header_path = line:sub(5)
      current_file.old_path = normalize_diff_path(current_file.old_header_path)
    elseif current_file and line:match("^%+%+%+ ") then
      current_file.new_header_path = line:sub(5)
      current_file.path = normalize_diff_path(current_file.new_header_path) or current_file.old_path
    elseif current_file and line:match("^@@ ") then
      local old_start, old_count, new_start, new_count = parse_hunk_header(line)
      current_hunk = {
        header = line,
        old_start = old_start,
        old_count = old_count,
        new_start = new_start,
        new_count = new_count,
        lines = {},
        patch_lines = { line },
      }
      current_old_line = old_start
      current_new_line = new_start
      current_file.hunks[#current_file.hunks + 1] = current_hunk
      current_file.lines[#current_file.lines + 1] = { kind = "hunk", text = line, hunk = current_hunk }
    elseif current_hunk and (line:match("^[ +%-]") or line:match("^\\")) then
      local parsed = { kind = line_kind(line), text = line, hunk = current_hunk }
      if line:match("^\\") then
        parsed.kind = "meta"
        parsed.target_line = math.max((current_new_line or 1) - 1, 1)
      elseif parsed.kind == "added" then
        parsed.new_line = math.max(current_new_line or 1, 1)
        parsed.target_line = parsed.new_line
        current_new_line = (current_new_line or 1) + 1
      elseif parsed.kind == "removed" then
        parsed.old_line = math.max(current_old_line or 1, 1)
        parsed.target_line = math.max(current_new_line or 1, 1)
        current_old_line = (current_old_line or 1) + 1
      else
        parsed.old_line = math.max(current_old_line or 1, 1)
        parsed.new_line = math.max(current_new_line or 1, 1)
        parsed.target_line = parsed.new_line
        current_old_line = (current_old_line or 1) + 1
        current_new_line = (current_new_line or 1) + 1
      end
      if not current_file.target_line and (parsed.kind == "added" or parsed.kind == "removed") then
        current_file.target_line = parsed.target_line
      end
      current_hunk.lines[#current_hunk.lines + 1] = parsed
      current_hunk.patch_lines[#current_hunk.patch_lines + 1] = line
      current_file.lines[#current_file.lines + 1] = parsed
    elseif current_file and not current_hunk then
      current_file.extended_headers[#current_file.extended_headers + 1] = line
    end
  end

  for _, file in ipairs(files) do
    local first_hunk = file.hunks[1]
    file.target_line = file.target_line or (first_hunk and math.max(first_hunk.new_start, 1)) or 1
  end

  return files
end

return M
