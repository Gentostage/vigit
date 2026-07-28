local Result = require("vigit.core.result")

local M = {}
local SecureRead = {}
SecureRead.__index = SecureRead

local O_RDONLY, O_NONBLOCK, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC = 0, 2048, 65536, 131072, 524288
local LEAF_FLAGS = O_RDONLY + O_NONBLOCK + O_NOFOLLOW + O_CLOEXEC
local EINTR, ELOOP, S_IFREG = 4, 40, 32768
local cached_backend

local function safe_relative(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or path:find("\\", 1, true) then return false end
  for part in path:gmatch("[^/]+") do if part == "." or part == ".." then return false end end
  return not path:find("//", 1, true) and path:sub(-1) ~= "/"
end

local function unavailable(details)
  return Result.err("secure_read_unavailable", "Secure fd-relative reads are unavailable", details)
end

local function backend()
  if cached_backend then return cached_backend end
  local ok, ffi = pcall(require, "ffi")
  if not ok then return nil, ffi end
  pcall(ffi.cdef, [[
    struct vigit_stat { unsigned long st_dev; unsigned long st_ino; unsigned long st_nlink; unsigned int st_mode; unsigned int st_uid; unsigned int st_gid; int __pad0; unsigned long st_rdev; long st_size; long st_blksize; long st_blocks; long st_atim_sec; long st_atim_nsec; long st_mtim_sec; long st_mtim_nsec; long st_ctim_sec; long st_ctim_nsec; long __reserved[3]; };
    int openat(int dirfd, const char *pathname, int flags, ...); int close(int fd); int fstat(int fd, struct vigit_stat *statbuf); long read(int fd, void *buf, unsigned long count);
  ]])
  for _, declaration in ipairs({
    "int openat(int dirfd, const char *pathname, int flags, ...);",
    "int close(int fd);",
    "int fstat(int fd, struct vigit_stat *statbuf);",
    "long read(int fd, void *buf, unsigned long count);",
  }) do pcall(ffi.cdef, declaration) end
  cached_backend = {
    open_root = function() return tonumber(ffi.C.openat(-100, "/", O_RDONLY + O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC)), ffi.errno() end,
    open_dir = function(fd, name) return tonumber(ffi.C.openat(fd, name, O_RDONLY + O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC)), ffi.errno() end,
    open_leaf = function(fd, name, flags) return tonumber(ffi.C.openat(fd, name, flags or LEAF_FLAGS)), ffi.errno() end,
    stat = function(fd)
      local stat = ffi.new("struct vigit_stat[1]")
      if ffi.C.fstat(fd, stat) == -1 then return nil, ffi.errno() end
      return { mode = tonumber(stat[0].st_mode), size = tonumber(stat[0].st_size) }
    end,
    read = function(fd, size)
      local buffer = ffi.new("char[?]", size)
      local count = tonumber(ffi.C.read(fd, buffer, size))
      return count, count >= 0 and ffi.string(buffer, count) or nil, ffi.errno()
    end,
    close = function(fd) return ffi.C.close(fd) == 0 end,
  }
  return cached_backend
end

function M.new(opts)
  opts = opts or {}
  local uname = vim.uv.os_uname()
  return setmetatable({
    backend = opts.backend,
    platform = opts.platform or uname.sysname,
    arch = opts.arch or (jit and jit.arch),
    uv = opts.uv or vim.uv,
    after_open_directory = opts.after_open_directory,
  }, SecureRead)
end

function SecureRead:read(root, relative)
  if not safe_relative(relative) then return Result.err("unsafe_legacy_path", "Legacy path is unsafe", relative) end
  if self.platform ~= "Linux" or self.arch ~= "x64" then return unavailable("unsupported platform or architecture") end
  local ops, reason = self.backend, nil
  if not ops then ops, reason = backend() end
  if not ops then return unavailable(reason) end
  local canonical = self.uv.fs_realpath(root)
  if not canonical then return Result.err("legacy_path_unavailable", "Legacy Git common directory cannot be resolved") end
  local fds = {}
  local function close_all() for index = #fds, 1, -1 do ops.close(fds[index]) end; fds = {} end
  local function fail(code, message, details) close_all(); return Result.err(code, message, details) end
  local fd, open_error = ops.open_root()
  if not fd or fd < 0 then return fail("unsafe_legacy_path", "Legacy root cannot be opened safely", open_error) end
  fds[#fds + 1] = fd
  local root_parts = {}
  for part in canonical:gmatch("[^/]+") do root_parts[#root_parts + 1] = part end
  for index, part in ipairs(root_parts) do
    fd, open_error = ops.open_dir(fds[#fds], part)
    if not fd or fd < 0 then return fail("unsafe_legacy_path", "Legacy root component cannot be opened safely", open_error) end
    fds[#fds + 1] = fd
    if self.after_open_directory then self.after_open_directory(fd, part, index, #root_parts) end
  end
  local parts = {}
  for part in relative:gmatch("[^/]+") do parts[#parts + 1] = part end
  for index = 1, #parts - 1 do
    fd, open_error = ops.open_dir(fds[#fds], parts[index])
    if not fd or fd < 0 then return fail("unsafe_legacy_path", "Legacy path component cannot be opened safely", open_error) end
    fds[#fds + 1] = fd
    if self.after_open_directory then self.after_open_directory(fd, parts[index], index, #parts) end
  end
  fd, open_error = ops.open_leaf(fds[#fds], parts[#parts], LEAF_FLAGS)
  if not fd or fd < 0 then
    if open_error == ELOOP then
      return fail("unsafe_legacy_path", "Legacy review source is a symbolic link", open_error)
    end
    return fail("legacy_not_found", "Legacy review source does not exist", open_error)
  end
  fds[#fds + 1] = fd
  local stat, stat_error = ops.stat(fd)
  if not stat or (stat.mode - (stat.mode % 4096)) ~= S_IFREG then return fail("unsafe_legacy_path", "Legacy review source is not a regular file", stat_error) end
  local remaining, chunks = stat.size, {}
  while remaining > 0 do
    local count, bytes, read_error = ops.read(fd, math.min(remaining, 65536))
    if count == -1 and read_error == EINTR then
    elseif not count or count <= 0 then return fail("legacy_read_failed", "Legacy review source cannot be read", read_error)
    else chunks[#chunks + 1] = bytes; remaining = remaining - count end
  end
  close_all()
  return Result.ok({ relative_path = relative, bytes = table.concat(chunks) })
end

return M
