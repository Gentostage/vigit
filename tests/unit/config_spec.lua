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

it("keeps a resolved snapshot isolated from callers", function()
  local setup = config.setup({ ui = { changes_width = 28 } })
  assert_truthy(setup.ok)

  local first = config.get()
  first.ui.changes_width = 99

  assert_equal(config.get().ui.changes_width, 28)
end)
