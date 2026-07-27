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

local function read_file(path, callback)
  local cancelled = false

  vim.uv.fs_open(path, "r", 438, function(open_error, descriptor)
    if cancelled then
      if descriptor then
        vim.uv.fs_close(descriptor)
      end
      return
    end
    if open_error then
      vim.schedule(function()
        callback(Result.err("file_read_failed", "Unable to open file", open_error))
      end)
      return
    end

    vim.uv.fs_fstat(descriptor, function(stat_error, stat)
      if cancelled then
        vim.uv.fs_close(descriptor)
        return
      end
      if stat_error then
        vim.uv.fs_close(descriptor)
        vim.schedule(function()
          callback(Result.err("file_read_failed", "Unable to inspect file", stat_error))
        end)
        return
      end

      vim.uv.fs_read(descriptor, stat.size, 0, function(read_error, data)
        vim.uv.fs_close(descriptor)
        if cancelled then
          return
        end
        vim.schedule(function()
          if read_error then
            callback(Result.err("file_read_failed", "Unable to read file", read_error))
          else
            callback(Result.ok(data or ""))
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
    return self.read_file(root .. "/" .. change.path, function(result)
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

  if (side == "old" and (change.status == "A" or change.status == "?"))
      or (side == "new" and change.status == "D") then
    return async_result(callback, Result.ok(""))
  end

  if change.section == "unstaged" and side == "new" then
    return self.read_file(root .. "/" .. change.path, function(result)
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
