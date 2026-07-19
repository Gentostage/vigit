local parser = require("vigit.parser")

local M = {}

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command_in_cwd(command, cwd)
  if cwd and cwd ~= "" then
    return "git -C " .. shell_quote(cwd) .. " " .. command
  end
  return "git " .. command
end

local function close_code(handle)
  local ok, _, code = handle:close()
  if ok then
    return 0
  end
  return code or 1
end

local function run(command, cwd, input)
  local full_command = command_in_cwd(command, cwd)
  if input then
    local tmp = os.tmpname()
    local handle = assert(io.open(tmp, "w"))
    handle:write(input)
    handle:close()
    full_command = full_command .. " < " .. shell_quote(tmp)
    if vim then
      local output = vim.fn.system(full_command)
      os.remove(tmp)
      return output, vim.v.shell_error
    end

    local process = io.popen(full_command .. " 2>&1")
    local output = process:read("*a")
    local code = close_code(process)
    os.remove(tmp)
    return output, code
  end

  if vim then
    local output = vim.fn.system(full_command)
    return output, vim.v.shell_error
  end

  local handle = io.popen(full_command .. " 2>&1")
  local output = handle:read("*a")
  return output, close_code(handle)
end

local function result_or_error(output, code)
  if code ~= 0 then
    return nil, vim and vim.trim(output) or output:gsub("%s+$", "")
  end
  return output, nil
end

function M.is_repo(cwd)
  local output, code = run("rev-parse --is-inside-work-tree", cwd)
  if code ~= 0 then
    return false, output
  end
  return output:match("true") ~= nil, nil
end

function M.status(cwd)
  local output, err = result_or_error(run("status --porcelain=v1 --untracked-files=all", cwd))
  if err then
    return nil, err
  end
  return parser.parse_status(output), nil
end

local function untracked_diff(path, cwd, context)
  local unified = tonumber(context or 3) or 3
  local command = table.concat({
    "diff --no-index --no-ext-diff --unified=" .. unified,
    "-- /dev/null",
    shell_quote(path),
  }, " ")
  local output, code = run(command, cwd)
  if code ~= 0 and code ~= 1 then
    local _, err = result_or_error(output, code)
    return nil, err
  end

  local files = parser.parse_diff(output, "unstaged")
  for _, file in ipairs(files) do
    file.path = file.path or path
    file.new_header_path = file.new_header_path or ("b/" .. path)
    file.old_header_path = file.old_header_path or "/dev/null"
  end
  return files, nil
end

function M.diff(section, cwd, context, status_files)
  local unified = tonumber(context or 3) or 3
  local command = "diff --no-ext-diff --unified=" .. unified
  if section == "staged" then
    command = "diff --cached --no-ext-diff --unified=" .. unified
  end
  local output, err = result_or_error(run(command, cwd))
  if err then
    return nil, err
  end
  local files = parser.parse_diff(output, section)
  if section == "unstaged" then
    for _, status_file in ipairs(status_files or {}) do
      if status_file.status == "?" then
        local untracked, untracked_err = untracked_diff(status_file.path, cwd, unified)
        if untracked_err then
          return nil, untracked_err
        end
        for _, file in ipairs(untracked) do
          files[#files + 1] = file
        end
      end
    end
  end
  return files, nil
end

function M.diff_file(file, cwd, context)
  local unified = tonumber(context or 3) or 3
  if file.section == "unstaged" and file.status == "?" then
    return untracked_diff(file.path, cwd, unified)
  end
  local command = "diff --no-ext-diff --unified=" .. unified
  if file.section == "staged" then
    command = "diff --cached --no-ext-diff --unified=" .. unified
  end
  command = command .. " -- " .. shell_quote(file.path)
  local output, err = result_or_error(run(command, cwd))
  if err then
    return nil, err
  end
  return parser.parse_diff(output, file.section), nil
end

function M.stage_file(path, cwd)
  local _, err = result_or_error(run("add -- " .. shell_quote(path), cwd))
  return err == nil, err
end

function M.unstage_file(file, cwd)
  if not file or file.section ~= "staged" then
    return false, "Only staged files can be unstaged"
  end

  local paths = {}
  local seen = {}
  local function add_path(path)
    if path and path ~= "" and not seen[path] then
      seen[path] = true
      paths[#paths + 1] = shell_quote(path)
    end
  end
  add_path(file.old_path)
  add_path(file.path)
  if #paths == 0 then
    return false, "No file under cursor"
  end

  local _, err = result_or_error(run("restore --staged -- " .. table.concat(paths, " "), cwd))
  return err == nil, err
end

local function build_hunk_patch(file, hunk)
  local old_path = file.old_header_path or ("a/" .. (file.old_path or file.path))
  local new_path = file.new_header_path or ("b/" .. file.path)
  local old_git_path = (file.old_header_path and file.old_header_path ~= "/dev/null") and file.old_header_path
    or ("a/" .. (file.old_path or file.path))
  local new_git_path = (file.new_header_path and file.new_header_path ~= "/dev/null") and file.new_header_path
    or ("b/" .. (file.path or file.old_path))
  local lines = {
    "diff --git " .. old_git_path .. " " .. new_git_path,
  }
  for _, line in ipairs(file.extended_headers or {}) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = "--- " .. old_path
  lines[#lines + 1] = "+++ " .. new_path
  for _, line in ipairs(hunk.patch_lines) do
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.stage_hunk(file, hunk, cwd)
  if not file or file.section ~= "unstaged" then
    return false, "Only unstaged hunks can be staged"
  end
  if not hunk or not hunk.patch_lines then
    return false, "No hunk under cursor"
  end
  local patch = build_hunk_patch(file, hunk)
  local _, err = result_or_error(run("apply --cached --unidiff-zero -", cwd, patch))
  return err == nil, err
end

function M.unstage_hunk(file, hunk, cwd)
  if not file or file.section ~= "staged" then
    return false, "Only staged hunks can be unstaged"
  end
  if not hunk or not hunk.patch_lines then
    return false, "No hunk under cursor"
  end
  local patch = build_hunk_patch(file, hunk)
  local _, err = result_or_error(run("apply --cached --reverse --unidiff-zero -", cwd, patch))
  return err == nil, err
end

return M
