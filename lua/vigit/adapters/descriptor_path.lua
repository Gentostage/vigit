local Result = require("vigit.core.result")

local M = {}

local Resolver = {}
Resolver.__index = Resolver

local DARWIN_F_GETPATH = 50
local DARWIN_BUFFER_SIZE = 4096
local WINDOWS_INITIAL_BUFFER_SIZE = 260
local WINDOWS_MAX_BUFFER_SIZE = 65536

local darwin_backend
local windows_backend
local windows_handle_converter

local function unavailable(details)
  return Result.err(
    "descriptor_path_unavailable",
    "Opened file path cannot be verified",
    details
  )
end

local function platform_name(source)
  if type(source) == "function" then
    local ok, value = pcall(source)
    return ok and value or nil, ok and nil or value
  end
  if source ~= nil then
    return source
  end

  local uv = type(vim) == "table" and vim.uv or nil
  if not uv or type(uv.os_uname) ~= "function" then
    return nil, "platform detection is unavailable"
  end
  local ok, uname = pcall(uv.os_uname)
  if not ok then
    return nil, uname
  end
  return uname and uname.sysname or nil,
    uname and nil or "platform detection returned no result"
end

local function normalize_posix(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  path = path:gsub("/+$", "")
  return path == "" and "/" or path
end

local function normalize_windows(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local lower_prefix = path:sub(1, 8):lower()
  if lower_prefix == [[\\?\unc\]] then
    path = [[\\]] .. path:sub(9)
  elseif path:sub(1, 4) == [[\\?\]] then
    path = path:sub(5)
  end

  path = path:gsub("\\", "/"):lower()
  if not path:match("^%a:/$") then
    path = path:gsub("/+$", "")
  end
  return path
end

local function normalize(path, platform)
  if platform == "Windows_NT" then
    return normalize_windows(path)
  end
  return normalize_posix(path)
end

local function is_absolute(path, platform)
  if platform == "Windows_NT" then
    return path:match("^%a:/") ~= nil or path:match("^//[^/]") ~= nil
  end
  return path:sub(1, 1) == "/"
end

local function is_within(root, candidate, platform)
  root = normalize(root, platform)
  candidate = normalize(candidate, platform)
  if not root or not candidate
      or not is_absolute(root, platform)
      or not is_absolute(candidate, platform) then
    return false, candidate
  end

  if root == "/" then
    return candidate:sub(1, 1) == "/", candidate
  end
  if root:sub(-1) == "/" then
    return candidate:sub(1, #root) == root, candidate
  end
  return candidate == root
    or candidate:sub(1, #root + 1) == root .. "/",
    candidate
end

local function verify_containment(root, target, platform, callback)
  local within, normalized_target = is_within(root, target, platform)
  if not within then
    callback(Result.err(
      "unsafe_path",
      "Opened file is outside the repository root",
      target
    ))
    return
  end
  callback(Result.ok(normalized_target))
end

local function load_darwin_backend()
  if darwin_backend then
    return darwin_backend
  end

  local loaded, ffi = pcall(require, "ffi")
  if not loaded then
    return nil, "LuaJIT FFI is unavailable: " .. tostring(ffi)
  end
  local declared, declaration_error = pcall(ffi.cdef, [[
    int fcntl(int descriptor, int command, ...);
  ]])
  if not declared then
    return nil, "fcntl declaration failed: " .. tostring(declaration_error)
  end

  darwin_backend = {
    get_path = function(descriptor, command, buffer_size)
      local buffer = ffi.new("char[?]", buffer_size)
      if ffi.C.fcntl(descriptor, command, buffer) == -1 then
        return nil, string.format(
          "fcntl(F_GETPATH) failed with errno %d",
          ffi.errno()
        )
      end
      return ffi.string(buffer)
    end,
  }
  return darwin_backend
end

local function load_windows_backend()
  if windows_backend then
    return windows_backend
  end

  local loaded, ffi = pcall(require, "ffi")
  if not loaded then
    return nil, "LuaJIT FFI is unavailable: " .. tostring(ffi)
  end
  local declared, declaration_error = pcall(ffi.cdef, [[
    unsigned long __stdcall GetFinalPathNameByHandleW(
      void *file,
      unsigned short *path,
      unsigned long path_size,
      unsigned long flags
    );
    int __stdcall WideCharToMultiByte(
      unsigned int code_page,
      unsigned long flags,
      const unsigned short *wide,
      int wide_size,
      char *multibyte,
      int multibyte_size,
      const char *default_character,
      int *used_default_character
    );
    unsigned long __stdcall GetLastError(void);
  ]])
  if not declared then
    return nil, "Kernel32 declarations failed: " .. tostring(declaration_error)
  end

  local library_loaded, kernel32 = pcall(ffi.load, "Kernel32")
  if not library_loaded then
    return nil, "Kernel32 is unavailable: " .. tostring(kernel32)
  end

  local function last_error(operation)
    return string.format(
      "%s failed with Windows error %d",
      operation,
      tonumber(kernel32.GetLastError())
    )
  end

  windows_backend = {
    get_final_path = function(descriptor, buffer_size)
      local wide_path = ffi.new("unsigned short[?]", buffer_size)
      local length = tonumber(kernel32.GetFinalPathNameByHandleW(
        ffi.cast("void *", descriptor),
        wide_path,
        buffer_size,
        0
      ))
      if length == 0 then
        return nil, last_error("GetFinalPathNameByHandleW")
      end
      if length >= buffer_size then
        return { required = length }
      end

      local utf8_size = tonumber(kernel32.WideCharToMultiByte(
        65001,
        128,
        wide_path,
        length,
        nil,
        0,
        nil,
        nil
      ))
      if utf8_size == 0 then
        return nil, last_error("WideCharToMultiByte")
      end
      local utf8_path = ffi.new("char[?]", utf8_size)
      local converted = tonumber(kernel32.WideCharToMultiByte(
        65001,
        128,
        wide_path,
        length,
        utf8_path,
        utf8_size,
        nil,
        nil
      ))
      if converted ~= utf8_size then
        return nil, last_error("WideCharToMultiByte")
      end
      return { path = ffi.string(utf8_path, utf8_size) }
    end,
  }
  return windows_backend
end

local function load_windows_handle_converter()
  if windows_handle_converter then
    return windows_handle_converter
  end

  local loaded, ffi = pcall(require, "ffi")
  if not loaded then
    return nil, "LuaJIT FFI is unavailable: " .. tostring(ffi)
  end
  local declared, declaration_error = pcall(ffi.cdef, [[
    void *uv_get_osfhandle(int descriptor);
    intptr_t _get_osfhandle(int descriptor);
  ]])
  if not declared then
    return nil, "file handle declarations failed: " .. tostring(declaration_error)
  end

  local function bind(symbol)
    local bound, callable = pcall(function()
      return ffi.C[symbol]
    end)
    return bound and callable or nil
  end

  local operation = "uv_get_osfhandle"
  local convert = bind(operation)
  if not convert then
    -- ffi.C selects the CRT linked with LuaJIT instead of guessing between
    -- ucrtbase and msvcrt descriptor tables.
    operation = "_get_osfhandle"
    convert = bind(operation)
  end
  if not convert then
    return nil, "uv_get_osfhandle and linked CRT _get_osfhandle are unavailable"
  end

  windows_handle_converter = {
    operation = operation,
    to_handle = function(descriptor)
      return convert(descriptor)
    end,
    is_invalid = function(handle)
      local cast, integer_handle = pcall(ffi.cast, "intptr_t", handle)
      return not cast or integer_handle == -1 or integer_handle == -2
    end,
  }
  return windows_handle_converter
end

local function verify_linux(self, descriptor, root, callback)
  if not self.uv or type(self.uv.fs_realpath) ~= "function" then
    callback(unavailable("libuv realpath is unavailable"))
    return
  end

  local proc_path = "/proc/self/fd/" .. tostring(descriptor)
  local called, call_error = pcall(
    self.uv.fs_realpath,
    proc_path,
    function(realpath_error, target)
      if realpath_error or not target then
        callback(unavailable(realpath_error or "procfs returned no path"))
        return
      end
      verify_containment(root, target, "Linux", callback)
    end
  )
  if not called then
    callback(unavailable(call_error))
  end
end

local function verify_darwin(self, descriptor, root, callback)
  local backend, backend_error
  if self.darwin then
    backend = self.darwin
  else
    backend, backend_error = load_darwin_backend()
  end
  if not backend then
    callback(unavailable(backend_error))
    return
  end

  local called, target, resolution_error = pcall(
    backend.get_path,
    descriptor,
    DARWIN_F_GETPATH,
    DARWIN_BUFFER_SIZE
  )
  if not called then
    callback(unavailable(target))
    return
  end
  if not target then
    callback(unavailable(resolution_error or "fcntl returned no path"))
    return
  end
  verify_containment(root, target, "Darwin", callback)
end

local function verify_windows(self, descriptor, root, callback)
  local converter, converter_error
  if self.windows_handle then
    converter = self.windows_handle
  else
    converter, converter_error = load_windows_handle_converter()
  end
  if not converter then
    callback(unavailable(converter_error))
    return
  end

  local converted, handle, conversion_error = pcall(
    converter.to_handle,
    descriptor
  )
  if not converted then
    callback(unavailable(handle))
    return
  end

  local invalid_handle = handle == nil or handle == -1 or handle == -2
  if not invalid_handle and type(converter.is_invalid) == "function" then
    local checked, invalid = pcall(converter.is_invalid, handle)
    if not checked then
      conversion_error = invalid
      invalid_handle = true
    else
      invalid_handle = invalid == true
    end
  end
  if invalid_handle then
    callback(unavailable(
      conversion_error
        or (converter.operation or "file descriptor conversion")
          .. " returned INVALID_HANDLE_VALUE"
    ))
    return
  end

  local backend, backend_error
  if self.windows then
    backend = self.windows
  else
    backend, backend_error = load_windows_backend()
  end
  if not backend then
    callback(unavailable(backend_error))
    return
  end

  local buffer_size = WINDOWS_INITIAL_BUFFER_SIZE
  for _ = 1, 8 do
    local called, response, resolution_error = pcall(
      backend.get_final_path,
      handle,
      buffer_size
    )
    if not called then
      callback(unavailable(response))
      return
    end
    if not response then
      callback(unavailable(
        resolution_error or "GetFinalPathNameByHandleW returned no path"
      ))
      return
    end
    if type(response.path) == "string" then
      verify_containment(root, response.path, "Windows_NT", callback)
      return
    end

    local required = tonumber(response.required)
    if not required or required <= buffer_size
        or required > WINDOWS_MAX_BUFFER_SIZE then
      callback(unavailable("GetFinalPathNameByHandleW returned an invalid size"))
      return
    end
    buffer_size = required
  end

  callback(unavailable("GetFinalPathNameByHandleW resizing did not converge"))
end

function M.new(options)
  options = options or {}
  local default_uv = type(vim) == "table" and vim.uv or nil
  return setmetatable({
    platform = options.platform,
    uv = options.uv or default_uv,
    darwin = options.darwin,
    windows = options.windows,
    windows_handle = options.windows_handle,
  }, Resolver)
end

function Resolver:verify(descriptor, canonical_root, callback)
  local platform, detection_error = platform_name(self.platform)
  if platform == "Linux" then
    verify_linux(self, descriptor, canonical_root, callback)
  elseif platform == "Darwin" then
    verify_darwin(self, descriptor, canonical_root, callback)
  elseif platform == "Windows_NT" then
    verify_windows(self, descriptor, canonical_root, callback)
  else
    callback(unavailable(
      detection_error or "unsupported platform: " .. tostring(platform)
    ))
  end
end

return M
