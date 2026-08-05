local project_root = vim.fn.getcwd()
package.path = table.concat({
  project_root .. "/lua/?.lua",
  project_root .. "/lua/?/init.lua",
  project_root .. "/?.lua",
  project_root .. "/?/init.lua",
  package.path,
}, ";")

local tests = {}
local failed = 0

_G.it = function(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

_G.assert_equal = function(actual, expected)
  if actual ~= expected then
    error(string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

_G.assert_truthy = function(value)
  if not value then
    error("expected truthy value", 2)
  end
end

local using_default_files = #arg == 0
local files = #arg > 0 and arg or {
  "tests/headless/cutover_spec.lua",
  "tests/headless/workspace_lifecycle_spec.lua",
  "tests/headless/sessions_spec.lua",
  "tests/headless/syntax_spec.lua",
  "tests/headless/handoff_spec.lua",
  "tests/headless/native_flow_spec.lua",
  "tests/headless/file_mutations_spec.lua",
  "tests/headless/hunk_mutations_spec.lua",
  "tests/headless/rollback_spec.lua",
  "tests/headless/comments_spec.lua",
  "tests/headless/confirm_spec.lua",
  "tests/headless/worktrees_spec.lua",
  "tests/headless/worktree_remove_spec.lua",
  "tests/headless/observers_spec.lua",
}
for _, file in ipairs(files) do
  dofile(file)
end

assert(#tests > 0, "headless test runner loaded zero tests")
if using_default_files then
  assert(
    #tests == 119,
    string.format("expected 119 default headless tests, loaded %d", #tests)
  )
end

for _, test in ipairs(tests) do
  local ok, message = xpcall(test.fn, debug.traceback)
  if ok then
    io.stdout:write("PASS " .. test.name .. "\n")
  else
    failed = failed + 1
    io.stdout:write(
      "FAIL " .. test.name .. "\n"
        .. (type(message) == "string" and message or vim.inspect(message))
        .. "\n"
    )
  end
  io.stdout:flush()
end

vim.cmd(failed == 0 and "qa!" or "cquit " .. failed)
