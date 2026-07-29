local Result = require("vigit.core.result")
local DescriptorPath = require("vigit.adapters.descriptor_path")
local status_parser = require("vigit.core.status")
local worktree_parser = require("vigit.core.worktree")
local diff_parser = require("vigit.core.diff")
local patch = require("vigit.core.patch")
local SecureUnlink = require("vigit.adapters.secure_unlink")

local M = {}

local Git = {}
Git.__index = Git
local is_windows = package.config:sub(1, 1) == "\\"

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

local function normalized_path(path)
  if is_windows then
    path = path:gsub("\\", "/"):lower()
  end
  path = path:gsub("/+$", "")
  return path == "" and "/" or path
end

local function is_within(root, candidate)
  root = normalized_path(root)
  candidate = normalized_path(candidate)
  if root == "/" then
    return candidate:sub(1, 1) == "/"
  end
  return candidate == root
    or candidate:sub(1, #root + 1) == root .. "/"
end

local function read_file(path, canonical_root, descriptor_paths, callback)
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

      local closed = false
      local function close_descriptor()
        if not closed then
          closed = true
          vim.uv.fs_close(descriptor)
        end
      end

      descriptor_paths:verify(descriptor, canonical_root, function(path_result)
        if cancelled then
          close_descriptor()
          return
        end
        if not path_result.ok then
          close_descriptor()
          complete(path_result)
          return
        end

        vim.uv.fs_fstat(descriptor, function(fstat_error, opened_stat)
          if cancelled then
            close_descriptor()
            return
          end
          if fstat_error then
            close_descriptor()
            complete(Result.err(
              "file_read_failed",
              "Unable to inspect opened file",
              fstat_error
            ))
            return
          end
          if not same_file(stat, opened_stat) then
            close_descriptor()
            complete(Result.err(
              "file_changed",
              "File changed while it was being opened"
            ))
            return
          end

          vim.uv.fs_read(descriptor, opened_stat.size, 0, function(read_error, data)
            close_descriptor()
            if read_error then
              complete(Result.err("file_read_failed", "Unable to read file", read_error))
            else
              complete(Result.ok(data or ""))
            end
          end)
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

  local component_pattern
  if is_windows then
    if path:match("^[/\\]") or path:match("^%a:") then
      return path_error(path, "path is absolute")
    end
    if path:match("[/\\]$") or path:match("[/\\][/\\]") then
      return path_error(path, "path contains an empty component")
    end
    component_pattern = "[^/\\]+"
  else
    if path:sub(1, 1) == "/" then
      return path_error(path, "path is absolute")
    end
    if path:sub(-1) == "/" or path:find("//", 1, true) then
      return path_error(path, "path contains an empty component")
    end
    component_pattern = "[^/]+"
  end

  local count = 0
  for component in path:gmatch(component_pattern) do
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

local function path_parent_and_leaf(path)
  if is_windows then
    return path:match("^(.*)[/\\][^/\\]+$") or "",
      path:match("([^/\\]+)$")
  end
  return path:match("^(.*)/[^/]+$") or "", path:match("([^/]+)$")
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

    local parent, leaf = path_parent_and_leaf(path)
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
      complete(Result.ok({
        path = canonical_parent .. "/" .. leaf,
        root = canonical_root,
      }))
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
    read_handle = reader(
      path_result.value.path,
      path_result.value.root,
      function(result)
        if not cancelled then
          callback(result)
        end
      end
    )
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

function M.new(process, filesystem, descriptor_paths, secure_unlink)
  local reader = filesystem and filesystem.read_file
  if not reader then
    descriptor_paths = descriptor_paths or DescriptorPath.new()
    reader = function(path, root, callback)
      return read_file(path, root, descriptor_paths, callback)
    end
  end

  return setmetatable({
    process = assert(process),
    read_file = reader,
    secure_unlink = secure_unlink or SecureUnlink.new(),
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

function Git:worktrees(root, callback)
  return self.process.run({
    "git",
    "-C",
    root,
    "worktree",
    "list",
    "--porcelain",
    "-z",
  }, {}, function(result)
    if not result.ok then
      callback(git_error("worktrees", result))
      return
    end
    callback(worktree_parser.parse_porcelain(result.value.stdout or ""))
  end)
end

function Git:remove_worktree(primary_root, target_root, callback)
  local cancelled = false
  local completed = false
  local function complete(result)
    if cancelled or completed then return end
    completed = true
    callback(result)
  end
  local handle = self.process.run({
    "git",
    "-C",
    primary_root,
    "worktree",
    "remove",
    "--",
    target_root,
  }, {}, function(result)
    if not result.ok then
      complete(Result.err(
        "git_failed",
        "Git worktree removal failed",
        result.error and (result.error.details or result.error.message)
      ))
      return
    end
    complete(Result.ok(true))
  end)
  return {
    cancel = function()
      if cancelled then return end
      cancelled = true
      if handle and handle.cancel then handle.cancel() end
    end,
  }
end

function Git:worktree_status(root, callback)
  return self.process.run({
    "git",
    "-C",
    root,
    "status",
    "--porcelain=v2",
    "--branch",
    "-z",
    "--untracked-files=all",
  }, {}, function(result)
    if not result.ok then
      callback(git_error("worktree_status", result))
      return
    end
    local raw = result.value.stdout or ""
    if raw == "" or raw:sub(-1) ~= "\0" then
      callback(Result.err(
        "malformed_status",
        "Worktree status output must be NUL-terminated"
      ))
      return
    end
    local parsed = status_parser.parse(raw)
    if not parsed.ok then
      callback(parsed)
      return
    end
    local staged = #parsed.value.staged
    local unstaged = 0
    local untracked = 0
    for _, change in ipairs(parsed.value.unstaged) do
      if change.status == "?" then
        untracked = untracked + 1
      else
        unstaged = unstaged + 1
      end
    end
    callback(Result.ok({
      staged = staged,
      unstaged = unstaged,
      untracked = untracked,
      dirty = staged + unstaged + untracked > 0,
    }))
  end)
end

local function line_value(value)
  return (value or ""):gsub("[\r\n]+$", "")
end

local function callback_once(callback)
  local called = false
  return function(result)
    if called then return end
    called = true
    callback(result)
  end
end

local function is_exit_code(result, code)
  local error = result.error or {}
  return error.code == "process_failed"
    and error.message == "Process exited with code " .. code
end

function Git:upstream(root, callback)
  local cancelled = false
  local handles = {}
  local complete = callback_once(function(result)
    if not cancelled then callback(result) end
  end)
  local function run(args, handler)
    local handle = self.process.run(args, {}, handler)
    handles[#handles + 1] = handle
    return handle
  end
  local function no_upstream()
    complete(Result.ok({ state = "no_upstream" }))
  end
  run({
    "git",
    "-C",
    root,
    "symbolic-ref",
    "--quiet",
    "--short",
    "HEAD",
  }, function(branch_result)
    if cancelled then return end
    if not branch_result.ok then
      if is_exit_code(branch_result, 1) then
        complete(Result.ok({ state = "detached" }))
      else
        complete(git_error("upstream", branch_result))
      end
      return
    end
    local branch = line_value(branch_result.value.stdout)
    if branch == "" or branch == "HEAD" then
      complete(Result.ok({ state = "detached" }))
      return
    end
    run({
      "git",
      "-C",
      root,
      "for-each-ref",
      "--format=%(upstream)%09%(upstream:short)%09%(upstream:remotename)",
      "refs/heads/" .. branch,
    }, function(metadata_result)
      if cancelled then return end
      if not metadata_result.ok then
        complete(git_error("upstream", metadata_result))
        return
      end
      local full_name, confirmation_name, remote = line_value(metadata_result.value.stdout):match("^(.-)\t(.-)\t(.*)$")
      if not full_name or full_name == "" or confirmation_name == "" or remote == "" or remote == "." then
        no_upstream()
        return
      end
      local canonical_prefix = "refs/remotes/" .. remote .. "/"
      if full_name:sub(1, #canonical_prefix) ~= canonical_prefix
          or #full_name == #canonical_prefix then
        complete(Result.err(
          "malformed_upstream",
          "Upstream metadata is not a remote-tracking ref",
          full_name
        ))
        return
      end
      local name = full_name:sub(#"refs/remotes/" + 1)
      run({
        "git",
        "-C",
        root,
        "rev-parse",
        "--abbrev-ref",
        "--symbolic-full-name",
        "@{upstream}",
      }, function(confirmation_result)
        if cancelled then return end
        if not confirmation_result.ok then
          complete(git_error("upstream", confirmation_result))
          return
        end
        local confirmed_name = line_value(confirmation_result.value.stdout)
        if confirmed_name == "" or confirmed_name ~= confirmation_name then
          complete(Result.err(
            "malformed_upstream",
            "Upstream confirmation does not match remote-tracking metadata",
            confirmed_name
          ))
          return
        end
        run({
          "git",
          "-C",
          root,
        "rev-list",
        "--left-right",
        "--count",
        "@{upstream}...HEAD",
        }, function(count_result)
          if cancelled then return end
          if not count_result.ok then
            complete(git_error("upstream", count_result))
            return
          end
          local behind, ahead = line_value(count_result.value.stdout):match("^(%d+)%s+(%d+)$")
          if not behind or not ahead then
            complete(Result.err(
              "malformed_upstream",
              "Upstream commit counts are malformed",
              count_result.value.stdout
            ))
            return
          end
          complete(Result.ok({
            state = "tracking",
            source = "local_refs",
            name = name,
            remote = remote,
            ahead = tonumber(ahead),
            behind = tonumber(behind),
          }))
        end)
      end)
    end)
  end)

  return {
    cancel = function()
      cancelled = true
      for _, handle in ipairs(handles) do
        if handle and handle.cancel then handle.cancel() end
      end
    end,
  }
end

function Git:fetch(root, callback)
  local cancelled = false
  local complete = callback_once(function(result)
    if not cancelled then callback(result) end
  end)
  local fetch_handle
  local upstream_handle = self:upstream(root, function(upstream_result)
    if cancelled then
      return
    end
    if not upstream_result.ok then
      complete(upstream_result)
      return
    end
    if upstream_result.value.state ~= "tracking" then
      complete(Result.err(
        "no_upstream",
        "Cannot fetch because this worktree has no tracking upstream"
      ))
      return
    end
    fetch_handle = self.process.run({
      "git",
      "-C",
      root,
      "fetch",
      "--prune",
      upstream_result.value.remote,
    }, {}, function(result)
      if cancelled then
        return
      end
      if not result.ok then
        complete(git_error("fetch", result))
        return
      end
      complete(Result.ok(true))
    end)
  end)

  return {
    cancel = function()
      cancelled = true
      for _, handle in ipairs({ upstream_handle, fetch_handle }) do
        if handle and handle.cancel then handle.cancel() end
      end
    end,
  }
end

local function stale_change(callback, details)
  return async_result(callback, Result.err(
    "stale_change",
    "File change is missing or stale",
    details
  ))
end

local function mutation_paths(change, include_old_path)
  if type(change) ~= "table" then
    return nil, "change is missing"
  end

  local invalid = validate_relative_path(change.path)
  if invalid then
    return nil, invalid.error.details
  end

  local paths = { change.path }
  if include_old_path and change.status == "R" then
    if not change.old_path or change.old_path == change.path then
      return nil, "rename old path is missing or unchanged"
    end
    invalid = validate_relative_path(change.old_path)
    if invalid then
      return nil, invalid.error.details
    end
    table.insert(paths, 1, change.old_path)
  end
  return paths
end

local function verified_mutation_status(result, section, path)
  if not result.ok then
    return result
  end
  for _, change in ipairs(result.value[section] or {}) do
    if change.path == path then
      return Result.err("stale_change", "File change is missing or stale")
    end
  end
  return result
end

function Git:stage_file(root, change, callback)
  local paths, validation_error = mutation_paths(change, true)
  if not paths then
    return stale_change(callback, validation_error)
  end

  local args = { "git", "--literal-pathspecs", "add", "-A", "--" }
  vim.list_extend(args, paths)
  local cancelled = false
  local status_handle
  local add_handle = self.process.run(args, {
    cwd = root,
  }, function(result)
    if cancelled then
      return
    end
    if not result.ok then
      callback(Result.err(
        "stale_change",
        "File change is missing or stale",
        result.error and result.error.details
      ))
      return
    end
    status_handle = self:status(root, function(status_result)
      if not cancelled then
        callback(verified_mutation_status(status_result, "unstaged", change.path))
      end
    end)
  end)

  return {
    cancel = function()
      cancelled = true
      if add_handle and add_handle.cancel then
        add_handle.cancel()
      end
      if status_handle and status_handle.cancel then
        status_handle.cancel()
      end
    end,
  }
end

function Git:unstage_file(root, change, callback)
  local paths, validation_error = mutation_paths(change, true)
  if not paths then
    return stale_change(callback, validation_error)
  end

  local cancelled = false
  local check_handle
  local apply_handle
  local status_handle
  local diff_args = {
    "git",
    "--literal-pathspecs",
    "diff",
    "--cached",
    "--binary",
    "--full-index",
    "--",
  }
  vim.list_extend(diff_args, paths)
  local diff_handle = self.process.run(diff_args, {
    cwd = root,
  }, function(diff_result)
    if cancelled then
      return
    end
    if not diff_result.ok then
      callback(git_error("unstage_file", diff_result))
      return
    end

    local patch = diff_result.value.stdout or ""
    if patch == "" then
      callback(Result.err("stale_change", "File change is missing or stale"))
      return
    end

    local check_args = { "git", "apply", "--cached", "--reverse", "--check" }
    check_handle = self.process.run(check_args, {
      cwd = root,
      stdin = patch,
    }, function(check_result)
      if cancelled then
        return
      end
      if not check_result.ok then
        callback(git_error("unstage_file", check_result))
        return
      end

      apply_handle = self.process.run({
        "git", "apply", "--cached", "--reverse",
      }, {
        cwd = root,
        stdin = patch,
      }, function(apply_result)
        if cancelled then
          return
        end
        if not apply_result.ok then
          callback(git_error("unstage_file", apply_result))
          return
        end
        status_handle = self:status(root, function(status_result)
          if not cancelled then
            callback(verified_mutation_status(status_result, "staged", change.path))
          end
        end)
      end)
    end)
  end)

  return {
    cancel = function()
      cancelled = true
      for _, handle in ipairs({ diff_handle, check_handle, apply_handle, status_handle }) do
        if handle and handle.cancel then
          handle.cancel()
        end
      end
    end,
  }
end

local function patch_conflict(callback, result)
  local error = result.error or {}
  callback(Result.err(
    "patch_conflict",
    "Selected hunk no longer applies cleanly",
    error.details or error.message
  ))
end

local function unstage_first(callback)
  return async_result(callback, Result.err(
    "unstage_first",
    "Unstage this hunk before discarding it"
  ))
end

local function mutate_hunk(git, root, file_diff, hunk, reverse, callback)
  local patch_result = patch.for_hunk(file_diff, hunk, {
    normalize_rename_for_reverse = reverse,
  })
  if not patch_result.ok then
    return async_result(callback, patch_result)
  end

  local stdin = patch_result.value
  local unidiff_zero = patch.needs_unidiff_zero(hunk)
  local check_args = { "git", "apply", "--cached" }
  if reverse then
    check_args[#check_args + 1] = "--reverse"
  end
  if unidiff_zero then
    check_args[#check_args + 1] = "--unidiff-zero"
  end
  vim.list_extend(check_args, { "--recount", "--check", "-" })

  local apply_args = { "git", "apply", "--cached" }
  if reverse then
    apply_args[#apply_args + 1] = "--reverse"
  end
  if unidiff_zero then
    apply_args[#apply_args + 1] = "--unidiff-zero"
  end
  vim.list_extend(apply_args, { "--recount", "-" })

  local cancelled = false
  local apply_handle
  local check_handle = git.process.run(check_args, {
    cwd = root,
    stdin = stdin,
  }, function(check_result)
    if cancelled then
      return
    end
    if not check_result.ok then
      patch_conflict(callback, check_result)
      return
    end
    apply_handle = git.process.run(apply_args, {
      cwd = root,
      stdin = stdin,
    }, function(apply_result)
      if cancelled then
        return
      end
      if not apply_result.ok then
        patch_conflict(callback, apply_result)
        return
      end
      callback(Result.ok(true))
    end)
  end)

  return {
    cancel = function()
      cancelled = true
      for _, handle in ipairs({ check_handle, apply_handle }) do
        if handle and handle.cancel then
          handle.cancel()
        end
      end
    end,
  }
end

function Git:stage_hunk(root, file_diff, hunk, callback)
  return mutate_hunk(self, root, file_diff, hunk, false, callback)
end

function Git:unstage_hunk(root, file_diff, hunk, callback)
  return mutate_hunk(self, root, file_diff, hunk, true, callback)
end

function Git:restore_hunk(root, file_diff, hunk, callback)
  if not file_diff or file_diff.section ~= "unstaged" then
    return unstage_first(callback)
  end

  local patch_result = patch.for_hunk(file_diff, hunk)
  if not patch_result.ok then
    return async_result(callback, patch_result)
  end

  local stdin = patch_result.value
  local check_args = { "git", "apply", "--reverse" }
  if patch.needs_unidiff_zero(hunk) then
    check_args[#check_args + 1] = "--unidiff-zero"
  end
  vim.list_extend(check_args, { "--recount", "--check", "-" })

  local apply_args = { "git", "apply", "--reverse" }
  if patch.needs_unidiff_zero(hunk) then
    apply_args[#apply_args + 1] = "--unidiff-zero"
  end
  vim.list_extend(apply_args, { "--recount", "-" })

  local cancelled = false
  local apply_handle
  local check_handle = self.process.run(check_args, {
    cwd = root,
    stdin = stdin,
  }, function(check_result)
    if cancelled then
      return
    end
    if not check_result.ok then
      patch_conflict(callback, check_result)
      return
    end
    apply_handle = self.process.run(apply_args, {
      cwd = root,
      stdin = stdin,
    }, function(apply_result)
      if cancelled then
        return
      end
      if not apply_result.ok then
        patch_conflict(callback, apply_result)
        return
      end
      callback(Result.ok(true))
    end)
  end)

  return {
    cancel = function()
      cancelled = true
      for _, handle in ipairs({ check_handle, apply_handle }) do
        if handle and handle.cancel then
          handle.cancel()
        end
      end
    end,
  }
end

local function unlink_repository_file(git, root, path, callback)
  return git.secure_unlink:unlink(root, path, callback)
end

local function has_identity(change, identities)
  return identities[change.path] or (change.old_path and identities[change.old_path])
end

local function coalesced_changes(status, selected)
  local identities = { [selected.path] = true }
  if selected.old_path then identities[selected.old_path] = true end
  local rows = {}
  local changed = true
  while changed do
    changed = false
    for _, section in ipairs({ "staged", "unstaged" }) do
      for _, candidate in ipairs(status[section] or {}) do
        if has_identity(candidate, identities) and not rows[candidate] then
          rows[candidate] = true
          if not identities[candidate.path] then identities[candidate.path], changed = true, true end
          if candidate.old_path and not identities[candidate.old_path] then
            identities[candidate.old_path], changed = true, true
          end
        end
      end
    end
  end
  local ordered, paths, seen = {}, {}, {}
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, candidate in ipairs(status[section] or {}) do
      if rows[candidate] then
        ordered[#ordered + 1] = candidate
        if candidate.old_path and not seen[candidate.old_path] then
          seen[candidate.old_path] = true
          paths[#paths + 1] = candidate.old_path
        end
        if not seen[candidate.path] then
          seen[candidate.path] = true
          paths[#paths + 1] = candidate.path
        end
      end
    end
  end
  return ordered, paths, identities
end

local function expected_existence(rows, head_restore)
  local expected = {}
  local function set(path, exists)
    if path and expected[path] == nil then expected[path] = exists end
  end
  for _, row in ipairs(rows) do
    if row.status == "R" then
      set(row.old_path, true)
      set(row.path, false)
    elseif row.status == "A" then
      set(row.path, false)
    elseif row.status == "D" then
      set(row.path, true)
    elseif row.status ~= "?" then
      set(row.path, true)
    elseif not head_restore then
      set(row.path, false)
    end
  end
  return expected
end

local function inspect_unborn_additions(raw, paths)
  local function rejected(message, details)
    return Result.err("unsupported_unborn_restore", message, details)
  end
  if type(raw) ~= "string" or raw == "" then
    return rejected("Unborn rollback index preflight is empty or malformed")
  end
  if raw:sub(-1) ~= "\0" then
    return rejected("Unborn rollback index preflight is not NUL-terminated")
  end
  local expected, seen = {}, {}
  for _, path in ipairs(paths) do expected[path] = true end
  local start = 1
  while start <= #raw do
    local finish = raw:find("\0", start, true)
    if not finish then
      return rejected("Unborn rollback index preflight is not NUL-framed")
    end
    local record = raw:sub(start, finish - 1)
    start = finish + 1
    local mode, object_id, stage, path = record:match("^([0-7][0-7][0-7][0-7][0-7][0-7]) ([0-9a-f]+) ([0-3])\t(.*)$")
    if not mode or not object_id or (#object_id ~= 40 and #object_id ~= 64)
        or not path or not expected[path] or seen[path] or stage ~= "0" then
      return rejected("Unborn rollback requires exact ordinary index entries")
    end
    if mode == "160000" then
      return Result.err(
        "unsupported_unborn_gitlink",
        "Unborn rollback does not remove submodules or gitlinks"
      )
    end
    if mode ~= "100644" and mode ~= "100755" and mode ~= "120000" then
      return rejected("Unborn rollback requires ordinary files or symbolic links")
    end
    seen[path] = true
  end
  for _, path in ipairs(paths) do
    if not seen[path] then
      return rejected(
        "Unborn rollback index entry is missing",
        path
      )
    end
  end
  return Result.ok(true)
end

local function verify_restore(git, root, identities, expected, callback)
  return git:status(root, function(status_result)
    if not status_result.ok then
      callback(status_result)
      return
    end
    for _, section in ipairs({ "staged", "unstaged" }) do
      for _, remaining in ipairs(status_result.value[section] or {}) do
        if has_identity(remaining, identities) then
          callback(Result.err("restore_verification_failed", "Rollback did not remove the expected change", remaining.path))
          return
        end
      end
    end
    local pending = {}
    for path, exists in pairs(expected) do pending[#pending + 1] = { path = path, exists = exists } end
    local function verify_path(index)
      local item = pending[index]
      if not item then
        callback(Result.ok(true))
        return
      end
      vim.uv.fs_lstat(root .. "/" .. item.path, function(_, stat)
        if (stat ~= nil) ~= item.exists then
          callback(Result.err("restore_verification_failed", "Rollback produced unexpected path existence", item.path))
        else
          verify_path(index + 1)
        end
      end)
    end
    verify_path(1)
  end)
end

function Git:restore_file(root, change, callback)
  local _, validation_error = mutation_paths(change, true)
  if validation_error then return stale_change(callback, validation_error) end
  local cancelled = false
  local operation_handle
  local verification_handle
  local unborn_index_handle
  local status_handle = self:status(root, function(status_result)
    if cancelled then return end
    if not status_result.ok then callback(status_result); return end
    local rows, paths, identities = coalesced_changes(status_result.value, change)
    if #rows == 0 then callback(Result.err("stale_change", "File change is missing or stale")); return end
    local staged, tracked, renamed = false, false, false
    for _, row in ipairs(rows) do
      staged = staged or row.section == "staged"
      tracked = tracked or row.status ~= "?"
      renamed = renamed or row.status == "R" or row.old_path ~= nil
    end
    local unborn = status_result.value.branch and status_result.value.branch.oid == nil
    local unborn_addition = false
    if unborn then
      unborn_addition = true
      for _, row in ipairs(rows) do
        if row.unmerged or row.old_path or row.status == "?" or row.status == "D" or row.status == "R" or row.status == "C" then
          unborn_addition = false
          break
        end
        unborn_addition = unborn_addition or (row.section == "staged" and row.status == "A")
      end
    end
    local head_restore = tracked and (staged or renamed)
    if unborn and tracked and not unborn_addition then
      callback(Result.err(
        "unsupported_unborn_restore",
        "Cannot restore a non-addition identity without an initial commit"
      ))
      return
    end
    local expected = expected_existence(rows, head_restore)
    local function complete_mutation(result)
      if cancelled then return end
      if not result.ok then callback(result); return end
      verification_handle = verify_restore(self, root, identities, expected, callback)
    end
    if not tracked then
      operation_handle = unlink_repository_file(self, root, change.path, complete_mutation)
      return
    end
    if unborn then
      local index_args = { "git", "--literal-pathspecs", "ls-files", "--stage", "-z", "--" }
      vim.list_extend(index_args, paths)
      unborn_index_handle = self.process.run(index_args, { cwd = root }, function(index_result)
        if cancelled then return end
        if not index_result.ok then
          callback(git_error("restore_file", index_result))
          return
        end
        local inspected = inspect_unborn_additions(index_result.value.stdout or "", paths)
        if not inspected.ok then
          callback(inspected)
          return
        end
        local args = { "git", "--literal-pathspecs", "rm", "-f", "--" }
        vim.list_extend(args, paths)
        operation_handle = self.process.run(args, { cwd = root }, function(result)
          if cancelled then return end
          if result.ok then complete_mutation(Result.ok(true)) else callback(git_error("restore_file", result)) end
        end)
      end)
      return
    end
    local args = { "git", "--literal-pathspecs", "restore" }
    if head_restore then
      vim.list_extend(args, { "--source=HEAD", "--staged", "--worktree" })
    else
      args[#args + 1] = "--worktree"
    end
    vim.list_extend(args, { "--" })
    vim.list_extend(args, paths)
    operation_handle = self.process.run(args, { cwd = root }, function(result)
      if cancelled then return end
      if result.ok then complete_mutation(Result.ok(true)) else callback(git_error("restore_file", result)) end
    end)
  end)
  return {
    cancel = function()
      cancelled = true
      for _, handle in ipairs({ status_handle, unborn_index_handle, operation_handle, verification_handle }) do
        if handle and handle.cancel then handle.cancel() end
      end
    end,
  }
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

  local args = { "git", "--literal-pathspecs", "diff" }
  if change.section == "staged" then
    args[#args + 1] = "--cached"
  end
  vim.list_extend(args, {
    "--no-ext-diff",
    "--full-index",
    "--unified=" .. context,
    "--",
  })
  if change.status == "R" and change.old_path and change.old_path ~= change.path then
    args[#args + 1] = change.old_path
  end
  args[#args + 1] = change.path

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
