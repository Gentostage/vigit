local Result = require("vigit.core.result")

it("creates typed success and error results", function()
  assert_equal(Result.ok(42), { ok = true, value = 42 })
  assert_equal(Result.err("git_failed", "Git failed", "fatal", true), {
    ok = false,
    error = {
      code = "git_failed",
      message = "Git failed",
      details = "fatal",
      retryable = true,
    },
  })
end)

it("maps only successful results", function()
  assert_equal(Result.map(Result.ok(2), function(value)
    return value * 3
  end), Result.ok(6))
  local failure = Result.err("boom", "Boom")
  assert_equal(Result.map(failure, error), failure)
end)
