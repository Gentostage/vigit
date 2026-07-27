local M = {}

local tests = {}

local function value_text(value)
  if type(value) == "string" then
    return string.format("%q", value)
  end
  return tostring(value)
end

local function table_difference(actual, expected, path, seen)
  if type(actual) ~= type(expected) then
    return string.format("%s: expected %s, got %s", path, value_text(expected), value_text(actual))
  end

  if type(actual) ~= "table" then
    if actual ~= expected then
      return string.format("%s: expected %s, got %s", path, value_text(expected), value_text(actual))
    end
    return nil
  end

  seen = seen or {}
  if seen[actual] == expected then
    return nil
  end
  seen[actual] = expected

  for key, expected_value in pairs(expected) do
    local difference = table_difference(actual[key], expected_value, path .. "[" .. value_text(key) .. "]", seen)
    if difference then
      return difference
    end
  end
  for key, actual_value in pairs(actual) do
    if expected[key] == nil and actual_value ~= nil then
      return string.format("%s[%s]: unexpected %s", path, value_text(key), value_text(actual_value))
    end
  end
end

local function install_globals()
  _G.describe = function(_, fn)
    fn()
  end

  _G.it = function(name, fn)
    tests[#tests + 1] = { name = name, fn = fn }
  end

  _G.assert_equal = function(actual, expected)
    local difference = table_difference(actual, expected, "value")
    if difference then
      error(difference, 2)
    end
  end

  _G.assert_truthy = function(value)
    if not value then
      error("expected truthy value", 2)
    end
  end
end

function M.load(files)
  install_globals()
  for _, file in ipairs(files) do
    local ok, err = pcall(dofile, file)
    if not ok and not tostring(err):match("No such file") then
      error(err, 0)
    end
  end
end

function M.execute()
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
  return failed == 0
end

return M
