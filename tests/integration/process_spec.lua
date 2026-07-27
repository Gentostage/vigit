local process = require("vigit.adapters.process")

it("runs argument arrays with cwd and captures stderr", function(done)
  process.run({ "git", "rev-parse", "--show-toplevel" }, {
    cwd = fixture.root,
  }, function(result)
    assert_truthy(result.ok)
    assert_equal(vim.trim(result.value.stdout), fixture.root)
    done()
  end)
end)

it("rejects a shell string before spawning", function(done)
  process.run("git status", {}, function(result)
    assert_equal(result.error.code, "invalid_command")
    done()
  end)
end)

it("returns stderr for a failed process", function(done)
  process.run({ "git", "rev-parse", "--verify", "does-not-exist" }, {
    cwd = fixture.root,
  }, function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "process_failed")
    assert_equal(result.error.retryable, true)
    assert_truthy(type(result.error.details) == "string" and #result.error.details > 0)
    done()
  end)
end)
