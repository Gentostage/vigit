local config = require("vigit.config")

it("deep merges supported options", function()
  local result = config.resolve({
    ui = { changes_width = 28 },
    refresh = { debounce_ms = 50 },
  })

  assert_truthy(result.ok)
  assert_equal(result.value.ui.changes_width, 28)
  assert_equal(result.value.ui.changes_side, "right")
  assert_equal(result.value.refresh.debounce_ms, 50)
end)

it("rejects unknown and invalid options with a full path", function()
  local unknown = config.resolve({ ui = { mystery = true } })
  assert_equal(unknown.error.code, "invalid_config")
  assert_truthy(unknown.error.message:match("ui%.mystery"))

  local invalid = config.resolve({ ui = { changes_width = "wide" } })
  assert_truthy(invalid.error.message:match("ui%.changes_width"))
end)

it("rejects a fractional changes width", function()
  local result = config.resolve({ ui = { changes_width = 31.5 } })

  assert_equal(result.ok, false)
  assert_equal(result.error.code, "invalid_config")
  assert_truthy(result.error.message:match("ui%.changes_width"))
  assert_truthy(result.error.message:match("integer"))
end)

it("keeps a resolved snapshot isolated from callers", function()
  local setup = config.setup({ ui = { changes_width = 28 } })
  assert_truthy(setup.ok)

  local first = config.get()
  first.ui.changes_width = 99

  assert_equal(config.get().ui.changes_width, 28)
end)

it("accepts only a safe repository-relative review path", function()
  local accepted = config.resolve({ review = { path = ".custom/review.md" } })
  assert_truthy(accepted.ok)
  assert_equal(accepted.value.review.path, ".custom/review.md")

  for _, path in ipairs({ "", "/tmp/review.md", "../review.md", "nested/../review.md", "nested\\review.md", "nested/", "review\0.md" }) do
    local rejected = config.resolve({ review = { path = path } })
    assert_equal(rejected.ok, false)
    assert_equal(rejected.error.code, "invalid_config")
    assert_truthy(rejected.error.message:find("review.path", 1, true) ~= nil)
  end
end)
