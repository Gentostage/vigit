local Result = require("vigit.core.result")
local status_parser = require("vigit.core.status")
local diff_parser = require("vigit.core.diff")

local M = {}

local Git = {}
Git.__index = Git

local function async_result(callback, result)
  vim.schedule(function()
    callback(result)
  end)
  return { cancel = function() end }
end

local function same_file(original, opened)
  return original.type == "file"
    and opened.type == "file"
    and original.dev ~= nil
    and original.ino ~= nil
    and opened.dev == original.dev
    and opened.ino == original.ino
end

local function read_file(path, callback)
  local cancelled = false

  local function complete(result)
    if cancelled then
      return
    end
    vim.schedule(function()
      if cancelled then
        return
      end
      callback(result)
    end)
  end

  vim.uv.fs_lstat(path, function(lstat_error, stat)
    if cancelled then
      return
    end
    if lstat_error then
      complete(Result.err("file_read_failed", "Unable to inspect file", lstat_error))
      return
    end

    if stat.type == "link" then
      vim.uv.fs_readlink(path, function(readlink_error, target)
        if readlink_error then
          complete(Result.err(
            "file_read_failed",
            "Unable to read symbolic link",
            readlink_error
          ))
        else
          complete(Result.ok(target))
        end
      end)
      return
    end

    if stat.type ~= "file" then
      complete(Result.err(
        "unsupported_file_type",
        "Unsupported file type: " .. tostring(stat.type)
      ))
      return
    end

    vim.uv.fs_open(path, "r", 438, function(open_error, descriptor)
      if cancelled then
        if descriptor then
          vim.uv.fs_close(descriptor)
        end
        return
      end
      if open_error then
        complete(Result.err("file_read_failed", "Unable to open file", open_error))
        return
      end

      vim.uv.fs_fstat(descriptor, function(fstat_error, opened_stat)
        if cancelled then
          vim.uv.fs_close(descriptor)
          return
        end
        if fstat_error then
          vim.uv.fs_close(descriptor)
          complete(Result.err(
            "file_read_failed",
            "Unable to inspect opened file",
            fstat_error
          ))
          return
        end
        if not same_file(stat, opened_stat) then
          vim.uv.fs_close(descriptor)
          complete(Result.err(
            "file_changed",
            "File changed while it was being opened"
          ))
          return
        end

        vim.uv.fs_read(descriptor, opened_stat.size, 0, function(read_error, data)
          vim.uv.fs_close(descriptor)
          if read_error then
            complete(Result.err("file_read_failed", "Unable to read file", read_error))
          else
            complete(Result.ok(data or ""))
          end
        end)
      end)
    end)
  end)

  return {
    cancel = function()
      cancelled = true
    end,
  }
end

local function path_error(path, reason)
  return Result.err(
    "unsafe_path",
    "Unsafe repository-relative path",
    tostring(path) .. ": " .. reason
  )
end

local function validate_relative_path(path)
  if type(path) ~= "string" or path == "" then
    return path_error(path, "path is empty")
  end
  if path:find("\0", 1, true) then
    return path_error(path, "path contains NUL")
  end
  if path:match("^[/\\]") or path:match("^%a:") then
    return path_error(path, "path is absolute")
  end
  if path:match("[/\\]$") or path:match("[/\\][/\\]") then
    return path_error(path, "path contains an empty component")
  end

  local count = 0
  for component in path:gmatch("[^/\\]+") do
    count = count + 1
    if component == "." or component == ".." then
      return path_error(path, "path contains a traversal component")
    end
  end
  if count == 0 then
    return path_error(path, "path has no components")
  end
  return nil
end

local function normalized_path(path)
  return path:gsub("\\", "/"):gsub("/+$", "")
end

local function is_within(root, candidate)
  root = normalized_path(root)
  candidate = normalized_path(candidate)
  return candidate == root
    or candidate:sub(1, #root + 1) == root .. "/"
end

local function resolve_repository_path(root, path, callback)
  local function complete(result)
    vim.schedule(function()
      callback(result)
    end)
  end

  local invalid = validate_relative_path(path)
  if invalid then
    complete(invalid)
    return
  end

  vim.uv.fs_realpath(root, function(root_error, canonical_root)
    if root_error or not canonical_root then
      complete(Result.err(
        "unsafe_path",
        "Repository root cannot be canonicalized",
        root_error or root
      ))
      return
    end

    local parent = path:match("^(.*)[/\\][^/\\]+$") or ""
    local leaf = path:match("([^/\\]+)$")
    local parent_path = parent == "" and canonical_root
      or canonical_root .. "/" .. parent
    vim.uv.fs_realpath(parent_path, function(parent_error, canonical_parent)
      if parent_error or not canonical_parent then
        complete(path_error(path, parent_error or "parent cannot be canonicalized"))
        return
      end
      if not is_within(canonical_root, canonical_parent) then
        complete(path_error(path, "canonical parent escapes repository root"))
        return
      end
      complete(Result.ok(canonical_parent .. "/" .. leaf))
    end)
  end)
end

local function read_repository_file(reader, root, path, callback)
  local cancelled = false
  local read_handle

  resolve_repository_path(root, path, function(path_result)
    if cancelled then
      return
    end
    if not path_result.ok then
      callback(path_result)
      return
    end
    read_handle = reader(path_result.value, function(result)
      if not cancelled then
        callback(result)
      end
    end)
  end)

  return {
    cancel = function()
      cancelled = true
      if type(read_handle) == "table" and type(read_handle.cancel) == "function" then
        pcall(read_handle.cancel)
      end
    end,
  }
end

local function git_error(operation, result)
  local source = result.error or {}
  return Result.err(
    "git_" .. operation .. "_failed",
    "Git " .. operation .. " failed",
    source.details or source.message,
    source.retryable
  )
end

local function file_lines(content)
  local lines = {}
  local start = 1

  while start <= #content do
    local separator = content:find("\n", start, true)
    if not separator then
      lines[#lines + 1] = content:sub(start)
      break
    end
    lines[#lines + 1] = content:sub(start, separator - 1)
    start = separator + 1
  end

  return lines
end

local function synthetic_diff(change, content)
  local headers = {
    "diff --git /dev/null b/" .. change.path,
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/" .. change.path,
  }
  local parsed = {
    id = change.id,
    change = change,
    section = change.section,
    status = change.status,
    path = change.path,
    old_path = change.old_path,
    headers = headers,
    hunks = {},
    binary = content:find("\0", 1, true) ~= nil,
  }

  if parsed.binary then
    headers[#headers + 1] = "Binary files /dev/null and b/" .. change.path .. " differ"
    parsed.patch = table.concat(headers, "\n")
    return parsed
  end

  local lines = file_lines(content)
  if #lines == 0 then
    parsed.patch = table.concat(headers, "\n")
    return parsed
  end

  local header = "@@ -0,0 +1," .. #lines .. " @@"
  local hunk = {
    id = change.id .. "\0" .. "0:1",
    header = header,
    old_start = 0,
    old_count = 0,
    new_start = 1,
    new_count = #lines,
    lines = {},
  }
  local patch_lines = { header }
  for index, line in ipairs(lines) do
    hunk.lines[#hunk.lines + 1] = {
      kind = "add",
      text = line,
      old_line = nil,
      new_line = index,
    }
    patch_lines[#patch_lines + 1] = "+" .. line
  end
  hunk.patch = table.concat(patch_lines, "\n")
  parsed.hunks[1] = hunk
  parsed.patch = table.concat(headers, "\n") .. "\n" .. hunk.patch
  return parsed
end

function M.new(process, filesystem)
  return setmetatable({
    process = assert(process),
    read_file = filesystem and filesystem.read_file or read_file,
  }, Git)
end

function Git:status(root, callback)
  return self.process.run({
    "git",
    "status",
    "--porcelain=v2",
    "--branch",
    "-z",
    "--untracked-files=all",
  }, {
    cwd = root,
  }, function(result)
    if not result.ok then
      callback(git_error("status", result))
      return
    end
    callback(status_parser.parse(result.value.stdout or ""))
  end)
end

function Git:diff(root, change, context, max_bytes, callback)
  if change.status == "?" then
    return read_repository_file(self.read_file, root, change.path, function(result)
      if not result.ok then
        callback(git_error("diff", result))
        return
      end
      if #result.value > max_bytes then
        callback(Result.err("diff_too_large", "Diff exceeds configured byte limit"))
        return
      end
      callback(Result.ok(synthetic_diff(change, result.value)))
    end)
  end

  local args = { "git", "diff" }
  if change.section == "staged" then
    args[#args + 1] = "--cached"
  end
  vim.list_extend(args, {
    "--no-ext-diff",
    "--unified=" .. context,
    "--",
    change.path,
  })

  return self.process.run(args, {
    cwd = root,
  }, function(result)
    if not result.ok then
      callback(git_error("diff", result))
      return
    end

    local stdout = result.value.stdout or ""
    if #stdout > max_bytes then
      callback(Result.err("diff_too_large", "Diff exceeds configured byte limit"))
      return
    end
    callback(diff_parser.parse(stdout, change))
  end)
end

function Git:snapshot(root, change, side, callback)
  if side ~= "old" and side ~= "new" then
    return async_result(
      callback,
      Result.err("invalid_snapshot_side", "Snapshot side must be old or new")
    )
  end

  if change.unmerged then
    return async_result(
      callback,
      Result.err(
        "unsupported_conflict_snapshot",
        "Conflict snapshots are not supported"
      )
    )
  end

  if (side == "old" and (change.status == "A" or change.status == "?"))
      or (side == "new" and change.status == "D") then
    return async_result(callback, Result.ok(""))
  end

  if change.section == "unstaged" and side == "new" then
    return read_repository_file(self.read_file, root, change.path, function(result)
      if not result.ok then
        callback(git_error("snapshot", result))
        return
      end
      callback(result)
    end)
  end

  local revision
  if change.section == "staged" and side == "old" then
    revision = "HEAD:./" .. (change.old_path or change.path)
  else
    revision = ":./" .. (side == "old" and (change.old_path or change.path) or change.path)
  end

  return self.process.run({ "git", "show", revision }, {
    cwd = root,
  }, function(result)
    if not result.ok then
      callback(git_error("snapshot", result))
      return
    end
    callback(Result.ok(result.value.stdout or ""))
  end)
end

return M
