local Result = require("vigit.core.result")
local DescriptorPath = require("vigit.adapters.descriptor_path")

local M = {}
local SecureUnlink = {}
SecureUnlink.__index = SecureUnlink

local S_IFMT = 61440
local S_IFREG = 32768
local S_IFLNK = 40960
local AT_SYMLINK_NOFOLLOW = 256
local O_RDONLY = 0
local O_DIRECTORY = 65536
local O_CLOEXEC = 524288
local cached_linux_backend

local function unavailable(details)
  return Result.err(
    "secure_unlink_unavailable",
    "Secure fd-relative unlink is unavailable",
    details
  )
end

local function unsafe(details)
  return Result.err("unsafe_path", "Unsafe repository-relative path", details)
end

local function relative_parent_and_leaf(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/"
      or path:find("\0", 1, true) or path:find("//", 1, true)
      or path:sub(-1) == "/" then
    return nil
  end
  local parent, leaf = path:match("^(.*)/([^/]+)$")
  parent = parent or ""
  leaf = leaf or path
  if leaf == "." or leaf == ".." then
    return nil
  end
  for component in path:gmatch("[^/]+") do
    if component == "." or component == ".." then
      return nil
    end
  end
  return parent, leaf
end

local function normalize(path)
  path = path:gsub("/+$", "")
  return path == "" and "/" or path
end

local function within(root, candidate)
  root = normalize(root)
  candidate = normalize(candidate)
  return root == "/" or candidate == root
    or candidate:sub(1, #root + 1) == root .. "/"
end

local function linux_backend()
  if cached_linux_backend then
    return cached_linux_backend
  end
  local loaded, ffi = pcall(require, "ffi")
  if not loaded then
    return nil, tostring(ffi)
  end
  local declarations = {
    [[
    typedef unsigned long int __vigit_ulong;
    typedef long int __vigit_long;
    struct vigit_stat {
      __vigit_ulong st_dev;
      __vigit_ulong st_ino;
      __vigit_ulong st_nlink;
      unsigned int st_mode;
      unsigned int st_uid;
      unsigned int st_gid;
      int __pad0;
      __vigit_ulong st_rdev;
      __vigit_long st_size;
      __vigit_long st_blksize;
      __vigit_long st_blocks;
      __vigit_long st_atim_sec;
      __vigit_long st_atim_nsec;
      __vigit_long st_mtim_sec;
      __vigit_long st_mtim_nsec;
      __vigit_long st_ctim_sec;
      __vigit_long st_ctim_nsec;
      __vigit_long __reserved[3];
    };
    int open(const char *pathname, int flags, ...);
    int close(int fd);
    int fstatat(int dirfd, const char *pathname, struct vigit_stat *statbuf, int flags);
    int unlinkat(int dirfd, const char *pathname, int flags);
    ]],
  }
  local declared = true
  for _, declaration in ipairs(declarations) do
    -- filesystem may have declared the shared ABI structs first.
    declared = pcall(ffi.cdef, declaration) and declared
  end
  if not declared then
    for _, declaration in ipairs({
      "int open(const char *pathname, int flags, ...);",
      "int close(int fd);",
      "int fstatat(int dirfd, const char *pathname, struct vigit_stat *statbuf, int flags);",
      "int unlinkat(int dirfd, const char *pathname, int flags);",
    }) do
      pcall(ffi.cdef, declaration)
    end
  end
  local available, err = pcall(function() return ffi.C.open end)
  if not available or not err then return nil, "Linux unlink syscalls are unavailable" end
  cached_linux_backend = {
    open_parent = function(path)
      local fd = ffi.C.open(path, O_RDONLY + O_DIRECTORY + O_CLOEXEC)
      return tonumber(fd), ffi.errno()
    end,
    inspect_leaf = function(fd, leaf)
      local stat = ffi.new("struct vigit_stat[1]")
      if ffi.C.fstatat(fd, leaf, stat, AT_SYMLINK_NOFOLLOW) == -1 then
        return nil, ffi.errno()
      end
      return tonumber(stat[0].st_mode), nil
    end,
    unlink_leaf = function(fd, leaf)
      if ffi.C.unlinkat(fd, leaf, 0) == -1 then
        return nil, ffi.errno()
      end
      return true
    end,
    close = function(fd)
      ffi.C.close(fd)
    end,
  }
  return cached_linux_backend
end

function M.new(opts)
  opts = opts or {}
  local uname = vim.uv.os_uname()
  return setmetatable({
    descriptors = opts.descriptor_paths or DescriptorPath.new(),
    after_parent_verified = opts.after_parent_verified,
    platform = opts.platform or uname.sysname,
    arch = opts.arch or (jit and jit.arch),
    backend = opts.backend,
  }, SecureUnlink)
end

function SecureUnlink:unlink(root, path, callback)
  local parent, leaf = relative_parent_and_leaf(path)
  if not parent then
    vim.schedule(function() callback(unsafe(tostring(path))) end)
    return { cancel = function() end }
  end
  if self.platform ~= "Linux" then
    vim.schedule(function() callback(unavailable("unsupported platform: " .. tostring(self.platform))) end)
    return { cancel = function() end }
  end
  if self.arch ~= "x64" then
    vim.schedule(function()
      callback(unavailable(
        "unsupported Linux FFI architecture: " .. tostring(self.arch)
      ))
    end)
    return { cancel = function() end }
  end
  local backend, backend_error = self.backend, nil
  if not backend then
    backend, backend_error = linux_backend()
  end
  if not backend then
    vim.schedule(function() callback(unavailable(backend_error)) end)
    return { cancel = function() end }
  end

  local cancelled = false
  local descriptor
  local function finish(result)
    if descriptor and descriptor >= 0 then
      backend.close(descriptor)
      descriptor = nil
    end
    if not cancelled then
      vim.schedule(function()
        if not cancelled then callback(result) end
      end)
    end
  end

  vim.uv.fs_realpath(root, function(root_error, canonical_root)
    if cancelled then return end
    if root_error or not canonical_root then
      finish(unsafe(root_error or root))
      return
    end
    local parent_path = parent == "" and canonical_root or canonical_root .. "/" .. parent
    vim.uv.fs_realpath(parent_path, function(parent_error, canonical_parent)
      if cancelled then return end
      if parent_error or not canonical_parent or not within(canonical_root, canonical_parent) then
        finish(unsafe(parent_error or parent_path))
        return
      end
      descriptor = backend.open_parent(canonical_parent)
      if not descriptor or descriptor < 0 then
        finish(unavailable("open parent failed"))
        return
      end
      self.descriptors:verify(descriptor, canonical_root, function(verified)
        if cancelled then return end
        if not verified.ok then
          finish(verified)
          return
        end
        if self.after_parent_verified then
          local ok, hook_error = pcall(self.after_parent_verified)
          if not ok then
            finish(Result.err("secure_unlink_hook_failed", "Secure unlink test hook failed", hook_error))
            return
          end
        end
        local mode, stat_error = backend.inspect_leaf(descriptor, leaf)
        if not mode then
          finish(Result.err("stale_change", "File change is missing or stale", stat_error))
          return
        end
        local file_type = mode - (mode % 4096)
        if file_type ~= S_IFREG and file_type ~= S_IFLNK then
          finish(Result.err("unsupported_file_type", "Rollback only deletes regular files or symbolic links", file_type))
          return
        end
        local ok, unlink_error = backend.unlink_leaf(descriptor, leaf)
        if not ok then
          finish(Result.err("file_unlink_failed", "Unable to delete file", unlink_error))
        else
          finish(Result.ok(true))
        end
      end)
    end)
  end)
  return {
    cancel = function()
      cancelled = true
      if descriptor and descriptor >= 0 then
        backend.close(descriptor)
        descriptor = nil
      end
    end,
  }
end

function SecureUnlink:unlink_sync(root, path)
  local parent, leaf = relative_parent_and_leaf(path)
  if not parent then return unsafe(tostring(path)) end
  if self.platform ~= "Linux" then return unavailable("unsupported platform: " .. tostring(self.platform)) end
  if self.arch ~= "x64" then
    return unavailable("unsupported Linux FFI architecture: " .. tostring(self.arch))
  end
  local backend, backend_error = self.backend, nil
  if not backend then backend, backend_error = linux_backend() end
  if not backend then return unavailable(backend_error) end
  local canonical_root = vim.uv.fs_realpath(root)
  if not canonical_root then return unsafe(root) end
  local parent_path = parent == "" and canonical_root or canonical_root .. "/" .. parent
  local canonical_parent = vim.uv.fs_realpath(parent_path)
  if not canonical_parent or not within(canonical_root, canonical_parent) then
    return unsafe(parent_path)
  end
  local descriptor = backend.open_parent(canonical_parent)
  if not descriptor or descriptor < 0 then return unavailable("open parent failed") end
  local function finish(result)
    backend.close(descriptor)
    return result
  end
  local descriptor_path = vim.uv.fs_realpath("/proc/self/fd/" .. tostring(descriptor))
  if not descriptor_path or not within(canonical_root, descriptor_path) then
    return finish(unavailable("opened parent descriptor cannot be verified"))
  end
  local mode, stat_error = backend.inspect_leaf(descriptor, leaf)
  if not mode then return finish(Result.err("stale_change", "File change is missing or stale", stat_error)) end
  local file_type = mode - (mode % 4096)
  if file_type ~= S_IFREG and file_type ~= S_IFLNK then
    return finish(Result.err("unsupported_file_type", "Rollback only deletes regular files or symbolic links", file_type))
  end
  local ok, unlink_error = backend.unlink_leaf(descriptor, leaf)
  if not ok then return finish(Result.err("file_unlink_failed", "Unable to delete file", unlink_error)) end
  return finish(Result.ok(true))
end

return M
