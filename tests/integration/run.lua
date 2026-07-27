package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local tests = {}
local failed = 0
local fixture_root = vim.fn.tempname()
local finished = false
local default_files = {
  "tests/integration/process_spec.lua",
  "tests/integration/git_read_spec.lua",
}

local function print_result(prefix, name, message)
  io.stdout:write(prefix .. " " .. name .. "\n")
  if message then
    io.stdout:write(message .. "\n")
  end
  io.stdout:flush()
end

_G.fixture = { root = fixture_root }
_G.it = function(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end
_G.assert_equal = function(actual, expected)
  if actual ~= expected then
    error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
  end
end
_G.assert_truthy = function(value)
  if not value then
    error("expected truthy value", 2)
  end
end

local function finish()
  vim.fn.delete(fixture_root, "rf")
  print_result(
    "SUMMARY",
    string.format("%d tests, %d failures", #tests, failed)
  )
  finished = true
end

local function run_test(index)
  local test = tests[index]
  if not test then
    finish()
    return
  end

  local completed = false
  local timer = vim.uv.new_timer()
  local function complete(ok, err)
    if completed then
      failed = failed + 1
      print_result("FAIL", test.name, "done callback called more than once")
      return
    end
    completed = true
    timer:stop()
    timer:close()
    if ok then
      print_result("PASS", test.name)
    else
      failed = failed + 1
      print_result("FAIL", test.name, err)
    end
    vim.schedule(function()
      run_test(index + 1)
    end)
  end

  timer:start(2000, 0, vim.schedule_wrap(function()
    complete(false, "timed out after 2 seconds")
  end))

  local ok, err = xpcall(function()
    test.fn(function()
      complete(true)
    end)
  end, debug.traceback)
  if not ok then
    complete(false, err)
  end
end

assert(vim.fn.mkdir(fixture_root, "p") == 1)
vim.fn.system({ "git", "init", "-q", fixture_root })
assert_equal(vim.v.shell_error, 0)

local files = #arg > 0 and arg or default_files
for _, file in ipairs(files) do
  dofile(file)
end

assert(#tests > 0, "integration runner loaded zero tests")
run_test(1)

local completed = vim.wait(#tests * 2000 + 100, function()
  return finished
end, 10)

if not completed then
  failed = failed + 1
  print_result("FAIL", "integration runner", "did not finish all tests")
  vim.fn.delete(fixture_root, "rf")
end

vim.cmd(failed == 0 and "qa!" or "cquit " .. failed)
