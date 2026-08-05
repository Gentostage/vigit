package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local testlib = dofile("tests/testlib.lua")

local default_files = {
  "tests/unit/result_spec.lua",
  "tests/unit/config_spec.lua",
  "tests/unit/status_spec.lua",
  "tests/unit/worktree_spec.lua",
  "tests/unit/worktrees_spec.lua",
  "tests/unit/diff_spec.lua",
  "tests/unit/anchor_spec.lua",
  "tests/unit/diff_view_spec.lua",
  "tests/unit/registry_spec.lua",
  "tests/unit/workspace_spec.lua",
  "tests/unit/changes_spec.lua",
  "tests/unit/descriptor_path_spec.lua",
  "tests/unit/patch_spec.lua",
  "tests/unit/review_spec.lua",
  "tests/unit/reviews_spec.lua",
  "tests/unit/mutations_spec.lua",
  "tests/unit/keymaps_spec.lua",
  "tests/unit/log_spec.lua",
  "tests/unit/skill_spec.lua",
}

local using_default_files = #arg == 0
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
if using_default_files then
  assert(
    test_count == 190,
    string.format("expected 190 default tests, loaded %d", test_count)
  )
end

local success = testlib.execute()
print(string.format(
  "SUMMARY %d tests, %s",
  test_count,
  success and "0 failures" or "failures present"
))
if not success then
  os.exit(1)
end
