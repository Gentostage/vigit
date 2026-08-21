local SyntaxCache = require("vigit.ui.syntax_cache")

it("вытесняет least-recently-used syntax entry", function()
  local cache = SyntaxCache.new(2)
  cache:put("first", { value = 1 })
  cache:put("second", { value = 2 })
  assert_equal(cache:get("first"), { value = 1 })

  cache:put("third", { value = 3 })

  assert_equal(cache:get("second"), nil)
  assert_equal(cache:get("first"), { value = 1 })
  assert_equal(cache:get("third"), { value = 3 })
end)
