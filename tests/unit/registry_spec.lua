local Registry = require("vigit.ui.registry")
local Session = require("vigit.ui.session")

it("изолирует сессии по каноническому корню", function()
  local registry = Registry.new(function(path)
    return path:gsub("/+$", "")
  end)
  local a = Session.new({ id = "a", root = "/repo/a/" })
  local b = Session.new({ id = "b", root = "/repo/b" })

  registry:put(a)
  registry:put(b)

  assert_equal(registry:get("/repo/a"), a)
  assert_equal(registry:get("/repo/b"), b)
end)

it("сохраняет существующую сессию при дублирующем каноническом корне", function()
  local registry = Registry.new(function(path)
    return path:gsub("/+$", "")
  end)
  local first = Session.new({ id = "first", root = "/repo/" })
  local duplicate = Session.new({ id = "duplicate", root = "/repo" })

  assert_equal(registry:put(first), first)
  assert_equal(registry:put(duplicate), first)
  assert_equal(registry:get("/repo/"), first)
  assert_equal(registry:all(), { first })
end)

it("удаляет только сессию с переданным ID", function()
  local registry = Registry.new(function(path)
    return path:gsub("/+$", "")
  end)
  local a = Session.new({ id = "a", root = "/repo/a" })
  local b = Session.new({ id = "b", root = "/repo/b" })
  registry:put(a)
  registry:put(b)

  assert_equal(registry:remove("a"), a)
  assert_equal(registry:get("/repo/a"), nil)
  assert_equal(registry:get("/repo/b"), b)
  assert_equal(registry:all(), { b })
end)

it("изолирует desired и applied context snapshots между сессиями", function()
  local a = Session.new({ id = "a", root = "/repo/a" })
  local b = Session.new({ id = "b", root = "/repo/b" })

  a.view.expanded_context.h1 = true
  a.view.applied_expanded_context.h2 = true

  assert_equal(next(b.view.expanded_context), nil)
  assert_equal(next(b.view.applied_expanded_context), nil)
  assert_truthy(a.view.expanded_context ~= a.view.applied_expanded_context)
  assert_truthy(a.view.applied_expanded_context ~= b.view.applied_expanded_context)
end)
