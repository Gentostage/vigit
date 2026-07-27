package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local testlib = dofile("tests/testlib.lua")

local default_files = {
  "tests/parser_spec.lua",
  "tests/state_spec.lua",
  "tests/git_spec.lua",
  "tests/worktrees_spec.lua",
  "tests/worktree_picker_spec.lua",
  "tests/keymaps_spec.lua",
  "tests/confirm_spec.lua",
  "tests/review_ui_spec.lua",
  "tests/ui_spec.lua",
  "tests/actions_spec.lua",
  "tests/unit/result_spec.lua",
  "tests/unit/config_spec.lua",
  "tests/unit/status_spec.lua",
  "tests/unit/diff_spec.lua",
  "tests/unit/registry_spec.lua",
  "tests/unit/changes_spec.lua",
}

local files = #arg > 0 and arg or default_files
testlib.load({})

local test_count = 0
local register_test = _G.it
_G.it = function(name, fn)
  test_count = test_count + 1
  register_test(name, fn)
end

for _, file in ipairs(files) do
  dofile(file)
end

assert(test_count > 0, "test runner loaded zero tests")

local success = testlib.execute()
print(string.format(
  "SUMMARY %d tests, %s",
  test_count,
  success and "0 failures" or "failures present"
))
if not success then
  os.exit(1)
end
