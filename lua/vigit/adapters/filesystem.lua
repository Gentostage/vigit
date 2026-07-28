local Result = require("vigit.core.result")
local SecureUnlink = require("vigit.adapters.secure_unlink")

local M = {}
local Filesystem = {}
Filesystem.__index = Filesystem

local O_RDONLY = 0
local O_WRONLY = 1
local O_RDWR = 2
local O_CREAT = 64
local O_EXCL = 128
local O_NOFOLLOW = 131072
local O_DIRECTORY = 65536
local O_CLOEXEC = 524288
local EEXIST = 17
local ENOENT = 2
local EINTR = 4
local S_IFMT = 61440
local S_IFREG = 32768
local O_TMPFILE = 4259840
local AT_EMPTY_PATH = 4096

local function err(code, message, details)
  return Result.err(code, message, details)
end

local function valid_relative(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true)
      or path:sub(1, 1) == "/" or path:match("^%a:[/\\]")
      or path:find("\\", 1, true) or path:find("//", 1, true)
      or path:sub(-1) == "/" then
    return false
  end
  for component in path:gmatch("[^/]+") do
    if component == "." or component == ".." then return false end
  end
  return true
end

local function within(root, candidate)
  root = root:gsub("/+$", "")
  candidate = candidate:gsub("/+$", "")
  return root == "/" or candidate == root or candidate:sub(1, #root + 1) == root .. "/"
end

local function realpath_root(uv, root)
  if type(root) ~= "string" or root == "" or not uv or type(uv.fs_realpath) ~= "function" then
    return nil
  end
  return uv.fs_realpath(root)
end

local function components(path)
  local result = {}
  for part in path:gmatch("[^/]+") do result[#result + 1] = part end
  return result
end

local function resolve_under(uv, root, relative)
  if not valid_relative(relative) then
    return err("invalid_path", "Path must be a safe repository-relative path", relative)
  end
  local canonical_root = realpath_root(uv, root)
  if not canonical_root then
    return err("root_unavailable", "Repository root cannot be resolved", root)
  end
  local current = canonical_root
  local parts = components(relative)
  for index, part in ipairs(parts) do
    local candidate = current .. "/" .. part
    local stat = uv.fs_lstat(candidate)
    if not stat then
      for rest = index + 1, #parts do candidate = candidate .. "/" .. parts[rest] end
      return Result.ok(candidate)
    end
    if stat.type == "link" or stat.type == "directory" then
      local canonical = uv.fs_realpath(candidate)
      if not canonical or not within(canonical_root, canonical) then
        return err("path_outside_root", "Path resolves outside the repository root", candidate)
      end
      current = canonical
    elseif index == #parts then
      if not within(canonical_root, candidate) then
        return err("path_outside_root", "Path resolves outside the repository root", candidate)
      end
      return Result.ok(candidate)
    else
      return err("path_open_failed", "A parent path component is not a directory", candidate)
    end
  end
  return Result.ok(current)
end

local cached_linux_backend

local function linux_backend()
  if cached_linux_backend then return cached_linux_backend end
  local loaded, ffi = pcall(require, "ffi")
  if not loaded then return nil, tostring(ffi) end
  for _, declaration in ipairs({
    [[struct vigit_stat {
      unsigned long st_dev; unsigned long st_ino; unsigned long st_nlink;
      unsigned int st_mode; unsigned int st_uid; unsigned int st_gid; int __pad0;
      unsigned long st_rdev; long st_size; long st_blksize; long st_blocks;
      long st_atim_sec; long st_atim_nsec; long st_mtim_sec; long st_mtim_nsec;
      long st_ctim_sec; long st_ctim_nsec; long __reserved[3];
    };]],
    "int openat(int dirfd, const char *pathname, int flags, ...);",
    "int mkdirat(int dirfd, const char *pathname, unsigned int mode);",
    "int renameat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath);",
    "int renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);",
    "int fsync(int fd);",
    "long write(int fd, const char *buf, unsigned long count);",
    "int unlinkat(int dirfd, const char *pathname, int flags);",
    "int linkat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, int flags);",
    "int close(int fd);",
    "int fstat(int fd, struct vigit_stat *statbuf);",
  }) do
    -- Declarations can already be present when secure_unlink was loaded first.
    pcall(ffi.cdef, declaration)
  end
  local function errno() return tonumber(ffi.errno()) end
  local function stat_identity(stat)
    return { dev = tonumber(stat.st_dev), ino = tonumber(stat.st_ino), mode = tonumber(stat.st_mode) }
  end
  local function inspect(call)
    local stat = ffi.new("struct vigit_stat[1]")
    if call(stat) == -1 then return nil, errno() end
    return stat_identity(stat[0])
  end
  cached_linux_backend = {
    open_root = function(path)
      local fd = ffi.C.openat(-100, path, O_RDONLY + O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW)
      return tonumber(fd), errno()
    end,
    open_directory = function(parent, name)
      local fd = ffi.C.openat(parent, name, O_RDONLY + O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW)
      return tonumber(fd), errno()
    end,
    mkdir = function(parent, name)
      local result = ffi.C.mkdirat(parent, name, 493)
      return result == 0, errno()
    end,
    open_anonymous = function(parent)
      local fd = ffi.C.openat(parent, ".", O_RDWR + O_TMPFILE + O_CLOEXEC, ffi.new("unsigned int", 384))
      return tonumber(fd), errno()
    end,
    write = function(fd, content)
      local written = tonumber(ffi.C.write(fd, content, #content))
      return written, errno()
    end,
    fsync = function(fd)
      return ffi.C.fsync(fd) == 0, errno()
    end,
    rename = function(parent, old_name, new_name)
      return ffi.C.renameat(parent, old_name, parent, new_name) == 0, errno()
    end,
    rename_noreplace = function(parent, old_name, new_name)
      return ffi.C.renameat2(parent, old_name, parent, new_name, 1) == 0, errno()
    end,
    unlink = function(parent, name)
      return ffi.C.unlinkat(parent, name, 0) == 0, errno()
    end,
    close = function(fd)
      return ffi.C.close(fd) == 0, errno()
    end,
    link_anonymous = function(fd, parent, name)
      return ffi.C.linkat(fd, "", parent, name, AT_EMPTY_PATH) == 0, errno()
    end,
    inspect_target = function(parent, name)
      local fd = ffi.C.openat(parent, name, O_RDONLY + O_CLOEXEC + O_NOFOLLOW + 2048)
      if fd < 0 then return nil, errno() end
      local result, inspect_error = inspect(function(stat) return ffi.C.fstat(fd, stat) end)
      ffi.C.close(fd)
      return result, inspect_error
    end,
  }
  return cached_linux_backend
end

local function native_atomic_write(uv, root, relative, content, backend_override, platform, arch)
  local canonical_root = realpath_root(uv, root)
  if not canonical_root then return nil, "root", root end
  local uname = uv.os_uname and uv.os_uname() or {}
  platform = platform or (uname and uname.sysname)
  arch = arch or (jit and jit.arch)
  if platform ~= "Linux" or arch ~= "x64" then
    return nil, "unavailable", "fd-relative atomic writes require Linux x64 LuaJIT FFI"
  end
  local backend, backend_error = backend_override, nil
  if not backend then backend, backend_error = linux_backend() end
  if not backend then return nil, "unavailable", backend_error end

  local descriptors = {}
  local function close_all()
    for index = #descriptors, 1, -1 do backend.close(descriptors[index]) end
    descriptors = {}
  end
  local root_fd, root_error = backend.open_root(canonical_root)
  if not root_fd or root_fd < 0 then return nil, "path", root_error end
  descriptors[#descriptors + 1] = root_fd
  local parent = root_fd
  local parts = components(relative)
  for index = 1, #parts - 1 do
    local part = parts[index]
    local opened, open_error = backend.open_directory(parent, part)
    if not opened or opened < 0 then
      local created, mkdir_error = backend.mkdir(parent, part)
      if not created and mkdir_error ~= EEXIST then
        close_all()
        return nil, open_error == 40 and "containment" or "path", mkdir_error
      end
      opened, open_error = backend.open_directory(parent, part)
      if not opened or opened < 0 then
        close_all()
        return nil, open_error == 40 and "containment" or "path", open_error
      end
    end
    descriptors[#descriptors + 1] = opened
    parent = opened
  end
  local leaf = parts[#parts]
  local target, target_error = backend.inspect_target(parent, leaf)
  if target and (target.mode - (target.mode % 4096)) ~= S_IFREG then
    close_all()
    return nil, "target", target.mode
  end
  if not target and target_error ~= ENOENT then
    close_all()
    return nil, target_error == 40 and "target" or "path", target_error
  end
  local source_fd, source_error = backend.open_anonymous(parent)
  if not source_fd or source_fd < 0 then
    close_all()
    return nil, "unavailable", source_error or "O_TMPFILE is unavailable"
  end
  local offset = 1
  while offset <= #content do
    local written, write_error = backend.write(source_fd, content:sub(offset))
    if written == -1 and write_error == EINTR then
      -- Retry interrupted writes without changing the offset.
    elseif not written or written <= 0 then
      backend.close(source_fd)
      close_all()
      return nil, "write", write_error or "zero-length write"
    else
      offset = offset + written
    end
  end
  local synced, sync_error = backend.fsync(source_fd)
  if not synced then
    backend.close(source_fd)
    close_all()
    return nil, "write", sync_error
  end
  local temporary, link_error
  for attempt = 1, 32 do
    temporary = string.format(".%s.vigit-tmp-%d-%d-%d", leaf, vim.fn.getpid(), uv.hrtime(), attempt)
    local linked
    linked, link_error = backend.link_anonymous(source_fd, parent, temporary)
    if linked then break end
    if link_error ~= EEXIST then
      backend.close(source_fd)
      close_all()
      return nil, "rename", link_error
    end
    temporary = nil
  end
  if not temporary then
    backend.close(source_fd)
    close_all()
    return nil, "rename", link_error or "temporary name collision"
  end
  local closed, close_error = backend.close(source_fd)
  if not closed then
    close_all()
    return nil, "cleanup_required", { path = temporary, reason = close_error }
  end
  local renamed, rename_error
  if target then
    renamed, rename_error = backend.rename(parent, temporary, leaf)
  else
    renamed, rename_error = backend.rename_noreplace(parent, temporary, leaf)
  end
  if not renamed then
    close_all()
    local details = { path = temporary, reason = rename_error }
    if not target and rename_error == EEXIST then
      return nil, "conflict", details
    end
    return nil, "cleanup_required", details
  end
  close_all()
  return true
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    uv = opts.uv or vim.uv,
    backend = opts.backend,
    platform = opts.platform,
    arch = opts.arch,
    secure_unlink = opts.secure_unlink or SecureUnlink.new(),
  }, Filesystem)
end

function Filesystem:resolve_under(root, relative)
  return resolve_under(self.uv, root, relative)
end

function Filesystem:read(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
    return err("invalid_path", "Read path is invalid", path)
  end
  local descriptor, open_error = self.uv.fs_open(path, "r", 438)
  if not descriptor then return err("read_failed", "Unable to open file", open_error) end
  local stat, stat_error = self.uv.fs_fstat(descriptor)
  if not stat then
    self.uv.fs_close(descriptor)
    return err("read_failed", "Unable to inspect file", stat_error)
  end
  local content, read_error = self.uv.fs_read(descriptor, stat.size, 0)
  self.uv.fs_close(descriptor)
  if content == nil then return err("read_failed", "Unable to read file", read_error) end
  return Result.ok(content)
end

function Filesystem:atomic_write(root, relative, content)
  if type(content) ~= "string" then return err("invalid_content", "Atomic content must be a string") end
  local resolved = self:resolve_under(root, relative)
  if not resolved.ok then return resolved end
  local ok, phase, details = native_atomic_write(self.uv, root, relative, content, self.backend, self.platform, self.arch)
  if ok then return Result.ok(true) end
  if phase == "containment" then return err("path_outside_root", "Parent path cannot be opened safely", details) end
  if phase == "target" then return err("unsupported_file_type", "Atomic target must be a regular file", details) end
  if phase == "path" then return err("path_open_failed", "Parent path cannot be opened safely", details) end
  if phase == "root" then return err("root_unavailable", "Repository root cannot be resolved", details) end
  if phase == "unavailable" then return err("secure_write_unavailable", "Safe atomic writes are unavailable", details) end
  if phase == "cleanup_required" then return err("cleanup_required", "Linked temporary file requires manual cleanup", details) end
  if phase == "conflict" then return err("path_conflict", "Final path was created concurrently", details) end
  return err(phase == "rename" and "rename_failed" or "write_failed", "Atomic write failed", details)
end

function Filesystem:unlink_under(root, relative)
  if not valid_relative(relative) then return err("invalid_path", "Path must be a safe repository-relative path", relative) end
  local resolved = self:resolve_under(root, relative)
  if not resolved.ok then return resolved end
  if type(self.secure_unlink.unlink_sync) ~= "function" then
    return err("secure_unlink_unavailable", "Synchronous secure unlink is unavailable")
  end
  return self.secure_unlink:unlink_sync(root, relative)
end

local default = nil
local function instance()
  default = default or M.new()
  return default
end

function M.resolve_under(root, relative) return instance():resolve_under(root, relative) end
function M.read(path) return instance():read(path) end
function M.atomic_write(root, relative, content) return instance():atomic_write(root, relative, content) end
function M.unlink_under(root, relative) return instance():unlink_under(root, relative) end

return M
