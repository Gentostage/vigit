it("создаёт clean tracked worktree для проверки безопасного удаления", function(done)
  local result = vim.system(
    { "bash", "scripts/demo.sh", "--check" },
    { text = true }
  ):wait()

  assert_equal(result.code, 0)
  assert_truthy((result.stdout or ""):find(
    "Demo removable worktree: clean · upstream origin/demo-removable",
    1,
    true
  ) ~= nil)
  done()
end)
