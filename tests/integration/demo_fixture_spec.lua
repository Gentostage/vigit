it("создаёт полный worktree и comments fixture для ручной проверки", function(done)
  local result = vim.system(
    { "bash", "scripts/demo.sh", "--check" },
    { text = true }
  ):wait()

  assert_equal(result.code, 0)
  assert_truthy((result.stdout or ""):find(
    "Demo fixture: safe · dirty · ahead · no upstream · tracked open/completed comments",
    1,
    true
  ) ~= nil)
  assert_truthy((result.stdout or ""):find(
    "Demo removable worktree: clean · upstream origin/demo-removable",
    1,
    true
  ) ~= nil)
  done()
end)
