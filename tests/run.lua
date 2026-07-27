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
}

local files = #arg > 0 and arg or default_files
testlib.load(files)

if not testlib.execute() then
  os.exit(1)
end
