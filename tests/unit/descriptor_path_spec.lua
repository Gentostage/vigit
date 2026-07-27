local DescriptorPath = require("vigit.adapters.descriptor_path")

local function verify(options, descriptor, root)
  local result
  DescriptorPath.new(options):verify(descriptor, root, function(value)
    result = value
  end)
  assert_truthy(result)
  return result
end

it("resolves Linux descriptors through procfs", function()
  local requested_path
  local result = verify({
    platform = "Linux",
    uv = {
      fs_realpath = function(path, callback)
        requested_path = path
        callback(nil, "/repo/src/main.lua")
      end,
    },
  }, 42, "/repo")

  assert_equal(requested_path, "/proc/self/fd/42")
  assert_equal(result, {
    ok = true,
    value = "/repo/src/main.lua",
  })
end)

it("uses F_GETPATH with a MAXPATHLEN-sized Darwin buffer", function()
  local call
  local descriptor = {}
  local result = verify({
    platform = "Darwin",
    darwin = {
      get_path = function(opened_descriptor, command, buffer_size)
        call = {
          descriptor = opened_descriptor,
          command = command,
          buffer_size = buffer_size,
        }
        return "/repo/src/main.lua"
      end,
    },
  }, descriptor, "/repo")

  assert_equal(call.descriptor, descriptor)
  assert_equal(call.command, 50)
  assert_truthy(call.buffer_size >= 1024)
  assert_equal(result.value, "/repo/src/main.lua")
end)

it("fails closed when Darwin descriptor resolution fails", function()
  local result = verify({
    platform = "Darwin",
    darwin = {
      get_path = function()
        return nil, "fcntl failed"
      end,
    },
  }, 7, "/repo")

  assert_equal(result.ok, false)
  assert_equal(result.error.code, "descriptor_path_unavailable")
  assert_equal(result.error.details, "fcntl failed")
end)

it("resizes Windows path buffers and preserves the exact handle", function()
  local sizes = {}
  local descriptor = {}
  local result = verify({
    platform = "Windows_NT",
    windows = {
      get_final_path = function(opened_descriptor, buffer_size)
        assert_equal(opened_descriptor, descriptor)
        sizes[#sizes + 1] = buffer_size
        if #sizes == 1 then
          return { required = 640 }
        end
        return { path = [[\\?\C:\REPO\Dir\File.lua]] }
      end,
    },
  }, descriptor, [[c:\repo]])

  assert_equal(sizes, { 260, 640 })
  assert_equal(result.value, "c:/repo/dir/file.lua")
end)

it("normalizes extended Windows UNC paths", function()
  local result = verify({
    platform = "Windows_NT",
    windows = {
      get_final_path = function()
        return { path = [[\\?\UNC\Server\Share\Repo\File.lua]] }
      end,
    },
  }, {}, [[\\server\share\repo]])

  assert_equal(result.value, "//server/share/repo/file.lua")
end)

it("rejects Windows sibling prefixes case-insensitively", function()
  local result = verify({
    platform = "Windows_NT",
    windows = {
      get_final_path = function()
        return { path = [[\\?\C:\Repository\secret.txt]] }
      end,
    },
  }, {}, [[c:\REPO]])

  assert_equal(result.ok, false)
  assert_equal(result.error.code, "unsafe_path")
end)

it("fails closed when Windows descriptor resolution fails", function()
  local result = verify({
    platform = "Windows_NT",
    windows = {
      get_final_path = function()
        return nil, "GetFinalPathNameByHandleW failed"
      end,
    },
  }, {}, [[C:\repo]])

  assert_equal(result.ok, false)
  assert_equal(result.error.code, "descriptor_path_unavailable")
  assert_equal(result.error.details, "GetFinalPathNameByHandleW failed")
end)

it("fails closed on unsupported platforms", function()
  local result = verify({
    platform = "Plan9",
  }, 5, "/repo")

  assert_equal(result.ok, false)
  assert_equal(result.error.code, "descriptor_path_unavailable")
  assert_truthy(result.error.details:match("Plan9"))
end)
