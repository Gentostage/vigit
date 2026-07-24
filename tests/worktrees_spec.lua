local worktrees = require("vigit.worktrees")

it("blocks unsafe worktree removal with an exact reason", function()
  assert_truthy(worktrees.removal_blocker({
    primary = true,
    changed = 0,
    ahead = 0,
    upstream = "origin/main",
  }):match("ROOT"))
  assert_truthy(worktrees.removal_blocker({
    changed = 2,
    ahead = 0,
    upstream = "origin/feature",
  }):match("2 changed files"))
  assert_truthy(worktrees.removal_blocker({
    changed = 0,
    detached = true,
  }):match("detached"))
  assert_truthy(worktrees.removal_blocker({
    changed = 0,
    upstream = nil,
  }):match("upstream"))
  assert_truthy(worktrees.removal_blocker({
    changed = 0,
    upstream = "origin/feature",
    ahead = 3,
  }):match("3 unpushed commits"))
end)

it("allows a clean worktree whose commits are on upstream", function()
  assert_equal(worktrees.removal_blocker({
    changed = 0,
    upstream = "origin/feature",
    ahead = 0,
    behind = 4,
  }), nil)
end)
