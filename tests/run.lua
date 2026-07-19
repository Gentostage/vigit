local tests = {}

function _G.describe(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

function _G.it(name, fn)
  tests[#tests + 1] = { name = "  " .. name, fn = fn }
end

function _G.assert_equal(actual, expected)
  if actual ~= expected then
    error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
  end
end

function _G.assert_truthy(value)
  if not value then
    error("expected truthy value", 2)
  end
end

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local files = { "tests/parser_spec.lua", "tests/state_spec.lua", "tests/git_spec.lua", "tests/ui_spec.lua", "tests/actions_spec.lua" }
for _, file in ipairs(files) do
  local ok, err = pcall(dofile, file)
  if not ok and not tostring(err):match("No such file") then
    error(err)
  end
end

local failed = 0
for _, test in ipairs(tests) do
  local ok, err = pcall(test.fn)
  if ok then
    print("PASS " .. test.name)
  else
    failed = failed + 1
    print("FAIL " .. test.name)
    print(err)
  end
end

if failed > 0 then
  os.exit(1)
end
