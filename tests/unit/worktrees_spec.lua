local Result = require("vigit.core.result")

local function fake_git(entries)
  local fake = {
    entries = entries,
    status_calls = {},
    upstream_calls = {},
    fetch_calls = {},
    active = 0,
    max_active = 0,
  }

  local function begin(bucket, path, callback)
    fake.active = fake.active + 1
    fake.max_active = math.max(fake.max_active, fake.active)
    local request = { path = path, callback = callback, done = false }
    bucket[#bucket + 1] = request
    return { cancel = function() request.cancelled = true end }
  end

  function fake:worktrees(_, callback)
    self.worktrees_callback = callback
    return { cancel = function() self.worktrees_cancelled = true end }
  end

  function fake:worktree_status(path, callback)
    return begin(self.status_calls, path, callback)
  end

  function fake:upstream(path, callback)
    return begin(self.upstream_calls, path, callback)
  end

  function fake:fetch(path, callback)
    self.fetch_calls[#self.fetch_calls + 1] = path
    callback(Result.ok({ remote = "origin" }))
    return { cancel = function() end }
  end

  function fake:complete(bucket, index, result)
    local request = bucket[index]
    assert_truthy(request)
    assert_equal(request.done, false)
    request.done = true
    self.active = self.active - 1
    request.callback(result)
  end

  return fake
end

local function entries(count)
  local result = {}
  for index = 1, count do
    result[index] = {
      kind = index == 1 and "root" or "linked",
      path = "/repo/wt-" .. index,
      branch = "feature/" .. index,
    }
  end
  return result
end

local function session()
  return { root = "/repo", closed = false }
end

it("ограничивает параллельные probes worktree четырьмя и рендерит прогрессивно", function()
  local Worktrees = require("vigit.application.worktrees")
  local git = fake_git(entries(10))
  local updates = {}
  local app = Worktrees.new({
    git = git,
    concurrency = 4,
    on_update = function(rows)
      updates[#updates + 1] = rows
    end,
  })
  local completed

  app:list(session(), function(result) completed = result end)
  git.worktrees_callback(Result.ok(git.entries))

  assert_equal(git.max_active, 4)
  assert_equal(#git.status_calls, 2)
  assert_equal(#git.upstream_calls, 2)
  assert_equal(updates[#updates][1].loading, true)

  git:complete(git.status_calls, 1, Result.ok({ staged = 1, unstaged = 2, untracked = 3 }))
  assert_equal(git.max_active, 4)
  assert_equal(#git.status_calls, 3)
  assert_equal(updates[#updates][1].loading, true)
  git:complete(git.upstream_calls, 1, Result.ok({ state = "tracking", ahead = 0, behind = 1 }))

  assert_equal(updates[#updates][1].loading, false)
  assert_equal(updates[#updates][1].files, { staged = 1, unstaged = 2, untracked = 3 })
  assert_equal(updates[#updates][1].upstream.behind, 1)
  assert_equal(completed, nil)
end)

it("сохраняет успешный upstream при ошибке status и эмитит каждое завершение", function()
  local Worktrees = require("vigit.application.worktrees")
  local git = fake_git(entries(1))
  local updates = 0
  local app = Worktrees.new({
    git = git,
    on_update = function() updates = updates + 1 end,
  })
  app:list(session())
  git.worktrees_callback(Result.ok(git.entries))
  local initial_updates = updates

  git:complete(git.upstream_calls, 1, Result.ok({
    state = "tracking", name = "origin/feature/1", source = "local_refs", ahead = 0, behind = 2,
  }))
  assert_equal(app.rows[1].loading, true)
  assert_equal(app.rows[1].upstream.name, "origin/feature/1")
  git:complete(git.status_calls, 1, Result.err("status_failed", "status unavailable"))

  assert_equal(app.rows[1].loading, false)
  assert_equal(app.rows[1].probes.status.error.code, "status_failed")
  assert_equal(app.rows[1].upstream.behind, 2)
  assert_equal(updates, initial_updates + 2)
end)

it("отбрасывает устаревшее поколение list и сохраняет строки после ошибки probe", function()
  local Worktrees = require("vigit.application.worktrees")
  local git = fake_git(entries(2))
  local app = Worktrees.new({ git = git, concurrency = 4 })
  local origin = session()
  local first_done
  local second_done

  app:list(origin, function(result) first_done = result end)
  local first_list = git.worktrees_callback
  app:list(origin, function(result) second_done = result end)
  local second_list = git.worktrees_callback
  first_list(Result.ok(entries(1)))
  assert_equal(#git.status_calls, 0)

  second_list(Result.ok(git.entries))
  git:complete(git.status_calls, 1, Result.err("status_failed", "status unavailable"))
  git:complete(git.upstream_calls, 1, Result.ok({ state = "tracking", ahead = 0, behind = 0 }))

  assert_equal(app.rows[1].probes.status.error.code, "status_failed")
  assert_equal(app.rows[1].loading, false)
  assert_equal(#app.rows, 2)
  assert_equal(first_done, nil)
  assert_equal(second_done, nil)
end)

it("не обновляет закрытый origin после late probe callbacks", function()
  local Worktrees = require("vigit.application.worktrees")
  local git = fake_git(entries(1))
  local changed = 0
  local done = 0
  local origin = session()
  local app = Worktrees.new({ git = git, on_update = function() changed = changed + 1 end })
  app:list(origin, function() done = done + 1 end)
  git.worktrees_callback(Result.ok(git.entries))
  local initial_changes = changed
  origin.closed = true
  git.status_calls[1].callback(Result.ok({ staged = 1, unstaged = 0, untracked = 0 }))
  git.upstream_calls[1].callback(Result.ok({ state = "tracking" }))

  assert_equal(changed, initial_changes)
  assert_equal(done, 0)
end)

it("dispose освобождает свой request и не стирает более нового subscriber", function()
  local Worktrees = require("vigit.application.worktrees")
  local git = fake_git(entries(1))
  local app = Worktrees.new({ git = git })
  local first_owner, second_owner = {}, {}
  local first_callback = function() end
  local second_callback = function() end
  app:set_on_update(first_callback, first_owner)
  app:set_on_update(second_callback, second_owner)
  app:detach(first_owner)
  assert_equal(app.on_update, second_callback)

  local origin = session()
  app:list(origin)
  assert_truthy(app.request ~= nil)
  app:dispose(origin, second_owner)

  assert_equal(git.worktrees_cancelled, true)
  assert_equal(app.request, nil)
  assert_equal(app.on_update, nil)
  assert_equal(app.subscriber, nil)
end)

it("старый picker dispose не отменяет новый owner и его request", function()
  local Worktrees = require("vigit.application.worktrees")
  local git = fake_git(entries(1))
  local app = Worktrees.new({ git = git })
  local origin = session()
  local old_owner, new_owner = {}, {}
  local updates = 0
  app:set_on_update(function() end, old_owner)
  app:list(origin)
  app:set_on_update(function() updates = updates + 1 end, new_owner)
  app:list(origin)
  local new_request = app.request

  app:dispose(origin, old_owner)
  assert_equal(app.request, new_request)
  assert_equal(app.subscriber, new_owner)
  git.worktrees_callback(Result.ok(git.entries))
  git:complete(git.status_calls, 1, Result.ok({ staged = 1, unstaged = 0, untracked = 0 }))
  git:complete(git.upstream_calls, 1, Result.ok({ state = "tracking", name = "origin/main" }))
  assert_truthy(updates >= 3)
end)

it("старый list cancel не отменяет более новое поколение того же origin", function()
  local Worktrees = require("vigit.application.worktrees")
  local app = Worktrees.new({ git = fake_git(entries(1)) })
  local origin = session()
  local first = app:list(origin)
  local second = app:list(origin)

  first.cancel()
  assert_truthy(app.request ~= nil)
  second.cancel()
  assert_equal(app.request, nil)
end)

it("открывает одну Vigit-сессию на канонический root и фокусирует существующую", function()
  local Worktrees = require("vigit.application.worktrees")
  local first = { id = "first", root = "/repo/a", closed = false }
  local registry = {
    get = function(_, root)
      return root == "/repo/a" and first or nil
    end,
  }
  local focused = 0
  local opened = 0
  local app = Worktrees.new({
    git = fake_git({}),
    registry = registry,
    neovim = {
      canonical_root = function(path, callback)
        callback(Result.ok(path:gsub("/$", "")))
      end,
      focus_session = function(value)
        assert_equal(value, first)
        focused = focused + 1
        return true
      end,
    },
    open_session = function(root)
      opened = opened + 1
      return { id = "new", root = root }
    end,
  })
  local result

  app:open({ path = "/repo/a/" }, function(value) result = value end)
  assert_equal(result.value, first)
  assert_equal(focused, 1)
  assert_equal(opened, 0)
end)

it("оставляет picker доступным, если worktree исчез до открытия", function()
  local Worktrees = require("vigit.application.worktrees")
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      canonical_root = function(_, callback)
        callback(Result.err("worktree_missing", "Worktree no longer exists"))
      end,
    },
  })
  local result

  app:open({ path = "/missing" }, function(value) result = value end)
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "worktree_missing")
end)

it("отклоняет resolved root, который не совпадает с выбранным worktree", function()
  local Worktrees = require("vigit.application.worktrees")
  local opened = 0
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      canonical_root = function(_, callback)
        callback(Result.ok("/repo"))
        return { cancel = function() end }
      end,
    },
    open_session = function()
      opened = opened + 1
      return { id = "unexpected" }
    end,
  })
  local result

  app:open({ path = "/repo/removed-linked" }, function(value) result = value end)
  assert_equal(result.error.code, "worktree_missing")
  assert_equal(opened, 0)
end)

it("отменяет pending open до resolver callback и не открывает session", function()
  local Worktrees = require("vigit.application.worktrees")
  local resolver_callback
  local resolver_cancelled = false
  local opened = 0
  local callback_count = 0
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      canonical_root = function(_, callback)
        resolver_callback = callback
        return { cancel = function() resolver_cancelled = true end }
      end,
    },
    open_session = function()
      opened = opened + 1
      return { id = "unexpected" }
    end,
  })

  local request = app:open({ path = "/repo/wt" }, function() callback_count = callback_count + 1 end)
  request.cancel()
  resolver_callback(Result.ok("/repo/wt"))

  assert_equal(resolver_cancelled, true)
  assert_equal(opened, 0)
  assert_equal(callback_count, 0)
end)

it("fetch вызывается только явно для выбранного worktree", function()
  local Worktrees = require("vigit.application.worktrees")
  local git = fake_git({})
  local app = Worktrees.new({ git = git })
  local result

  app:fetch({ path = "/repo/wt" }, function(value) result = value end)

  assert_equal(git.fetch_calls, { "/repo/wt" })
  assert_equal(result.ok, true)
end)

it("помечает только успешный explicit fetch временем local refs", function()
  local Worktrees = require("vigit.application.worktrees")
  local git = fake_git({})
  local app = Worktrees.new({ git = git, clock = function() return "2026-07-28T12:00:00Z" end })
  app.rows = {
    { path = "/repo/wt", upstream = { state = "tracking", name = "origin/main", source = "local_refs" } },
  }

  app:fetch(app.rows[1], function() end)
  assert_equal(app.rows[1].upstream.fetched_at, "2026-07-28T12:00:00Z")

  git.fetch = function(_, _, callback)
    callback(Result.err("fetch_failed", "network unavailable"))
    return { cancel = function() end }
  end
  app:fetch({ path = "/repo/failing" }, function() end)
  assert_equal(app.fetched_at["/repo/failing"], nil)
end)

it("не переносит время fetch на другой upstream той же worktree", function()
  local Worktrees = require("vigit.application.worktrees")
  local git = fake_git({})
  local app = Worktrees.new({ git = git, clock = function() return "2026-07-28T12:34:00Z" end })
  local row = {
    path = "/repo/wt",
    upstream = { state = "tracking", name = "origin/feature/old", source = "local_refs" },
  }
  app.rows = { row }

  app:fetch(row)
  assert_equal(row.upstream.fetched_at, "2026-07-28T12:34:00Z")

  row.upstream = { state = "tracking", name = "origin/feature/new", source = "local_refs" }
  assert_equal(row.upstream.fetched_at, nil)
  app.fetched_at["/repo/wt"] = { name = "origin/feature/old", at = "2026-07-28T12:34:00Z" }
  app:_apply_fetched_at(row)
  assert_equal(row.upstream.fetched_at, nil)
end)

it("сравнивает Windows worktree roots без учёта регистра и разделителя", function()
  local Worktrees = require("vigit.application.worktrees")
  local opened = 0
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      platform = "win32",
      canonical_root = function(_, callback)
        callback(Result.ok("C:\\Repo\\Feature\\"))
        return { cancel = function() end }
      end,
    },
    open_session = function(root)
      opened = opened + 1
      assert_equal(root, "C:\\Repo\\Feature\\")
      return { root = root }
    end,
  })
  local result

  app:open({ path = "c:/repo/feature" }, function(value) result = value end)
  assert_equal(result.ok, true)
  assert_equal(opened, 1)
end)

it("не ослабляет POSIX-сравнение worktree roots", function()
  local Worktrees = require("vigit.application.worktrees")
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      canonical_root = function(_, callback)
        callback(Result.ok("/Repo/feature"))
        return { cancel = function() end }
      end,
    },
  })
  local result

  app:open({ path = "/repo/feature" }, function(value) result = value end)
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "worktree_missing")
end)

it("принимает completion probes и fetch ровно один раз", function()
  local Worktrees = require("vigit.application.worktrees")
  local git = fake_git(entries(1))
  local app = Worktrees.new({ git = git })
  app:list(session())
  git.worktrees_callback(Result.ok(git.entries))

  local status_callback = git.status_calls[1].callback
  status_callback(Result.ok({ staged = 0, unstaged = 0, untracked = 0 }))
  status_callback(Result.ok({ staged = 0, unstaged = 0, untracked = 0 }))
  assert_equal(#git.upstream_calls, 1)

  local completed = 0
  git.fetch = function(_, _, callback)
    callback(Result.ok(true))
    callback(Result.ok(true))
    return { cancel = function() end }
  end
  app:fetch({ path = "/repo/wt-1" }, function() completed = completed + 1 end)
  assert_equal(completed, 1)
end)
