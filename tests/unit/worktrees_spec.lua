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

it("переключает active Vigit-сессию по каноническому root", function()
  local Worktrees = require("vigit.application.worktrees")
  local switched = {}
  local session = { id = "first", root = "/repo/a", closed = false }
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      canonical_root = function(path, callback)
        callback(Result.ok(path:gsub("/$", "")))
      end,
    },
    switch_session = function(root)
      switched[#switched + 1] = root
      return Result.ok(session)
    end,
  })
  local result

  app:open({ path = "/repo/a/" }, function(value) result = value end)
  assert_equal(result.value, session)
  assert_equal(switched, { "/repo/a" })
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
  local switched = 0
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      canonical_root = function(_, callback)
        callback(Result.ok("/repo"))
        return { cancel = function() end }
      end,
    },
    switch_session = function()
      switched = switched + 1
      return Result.ok({ id = "unexpected" })
    end,
  })
  local result

  app:open({ path = "/repo/removed-linked" }, function(value) result = value end)
  assert_equal(result.error.code, "worktree_missing")
  assert_equal(switched, 0)
end)

it("отменяет pending open до resolver callback и не переключает session", function()
  local Worktrees = require("vigit.application.worktrees")
  local resolver_callback
  local resolver_cancelled = false
  local switched = 0
  local callback_count = 0
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      canonical_root = function(_, callback)
        resolver_callback = callback
        return { cancel = function() resolver_cancelled = true end }
      end,
    },
    switch_session = function()
      switched = switched + 1
      return Result.ok({ id = "unexpected" })
    end,
  })

  local request = app:open({ path = "/repo/wt" }, function() callback_count = callback_count + 1 end)
  request.cancel()
  resolver_callback(Result.ok("/repo/wt"))

  assert_equal(resolver_cancelled, true)
  assert_equal(switched, 0)
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
  local switched = 0
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      platform = "win32",
      canonical_root = function(_, callback)
        callback(Result.ok("C:\\Repo\\Feature\\"))
        return { cancel = function() end }
      end,
    },
    switch_session = function(root)
      switched = switched + 1
      assert_equal(root, "C:\\Repo\\Feature\\")
      return Result.ok({ root = root })
    end,
  })
  local result

  app:open({ path = "c:/repo/feature" }, function(value) result = value end)
  assert_equal(result.ok, true)
  assert_equal(switched, 1)
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

it("блокирует unsafe worktree до y/N confirmation и разрешает только безопасный behind", function()
  local worktree = require("vigit.core.worktree")
  local safe = {
    kind = "linked",
    path = "/repo/wt-two",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 3 },
  }
  local function with(overrides)
    local value = {}
    for key, item in pairs(safe) do value[key] = item end
    for key, item in pairs(overrides) do value[key] = item end
    return value
  end
  local cases = {
    { entry = { kind = "root" }, want = "root" },
    { entry = with({ locked = "hold" }), want = "locked" },
    { entry = with({ prunable = "stale" }), want = "prunable" },
    { entry = with({ files = { staged = 1, unstaged = 0, untracked = 0 } }), want = "dirty" },
    { entry = with({ upstream = { state = "no_upstream" } }), want = "no_upstream" },
    { entry = with({ upstream = { state = "tracking", source = "local_refs", ahead = 1, behind = 0 } }), want = "ahead" },
  }

  for _, case in ipairs(cases) do
    assert_equal(worktree.removal_blocker(case.entry, {}), case.want)
  end
  assert_equal(worktree.removal_blocker(safe, { "/repo/wt-two-old/source.lua" }), nil)
  assert_equal(worktree.removal_blocker(safe, { "/repo/wt-two/source.lua" }), "loaded_source_buffer")
  assert_equal(worktree.removal_blocker(safe, {}), nil)
end)

it("повторно проверяет worktree после confirmation до remove", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local entry = {
    kind = "linked",
    path = "/repo/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local git = fake_git({ entry })
  local confirmation
  local removed = 0
  git.worktrees = function(_, _, callback)
    callback(Result.ok({ {
      kind = "root", path = "/repo", branch = "main",
    }, {
      kind = "linked", path = "/repo/linked", branch = "linked",
    } }))
    return { cancel = function() end }
  end
  git.worktree_status = function(_, _, callback)
    callback(Result.ok({ staged = 0, unstaged = 1, untracked = 0 }))
    return { cancel = function() end }
  end
  git.upstream = function(_, _, callback)
    callback(Result.ok({ state = "tracking", source = "local_refs", ahead = 0, behind = 0 }))
    return { cancel = function() end }
  end
  git.remove_worktree = function()
    removed = removed + 1
    return { cancel = function() end }
  end
  local app = Worktrees.new({
    git = git,
    neovim = { loaded_source_buffers = function() return Result.ok({}) end },
    confirm = function(message, callback)
      assert_equal(message, "Remove /repo/linked? Branch will be kept.")
      confirmation = callback
    end,
  })
  local result

  app:remove(entry, function(value) result = value end)
  assert_truthy(confirmation ~= nil)
  confirmation(true)

  assert_equal(removed, 0)
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "dirty")
end)

it("оставляет Vigit-сессию открытой, если postcondition всё ещё видит worktree", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local entry = {
    kind = "linked",
    path = "/repo/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local lists = 0
  local closed = 0
  local session = { id = "linked", root = entry.path, closed = false }
  local git = {
    worktrees = function(_, _, callback)
      lists = lists + 1
      callback(Result.ok({ { kind = "root", path = "/repo" }, entry }))
      return { cancel = function() end }
    end,
    worktree_status = function(_, _, callback)
      callback(Result.ok({ staged = 0, unstaged = 0, untracked = 0 }))
      return { cancel = function() end }
    end,
    upstream = function(_, _, callback)
      callback(Result.ok({ state = "tracking", source = "local_refs", ahead = 0, behind = 0 }))
      return { cancel = function() end }
    end,
    remove_worktree = function(_, _, _, callback)
      callback(Result.ok(true))
      return { cancel = function() end }
    end,
  }
  local app = Worktrees.new({
    git = git,
    registry = { get = function() return session end },
    neovim = { loaded_source_buffers = function() return Result.ok({}) end },
    confirm = function(_, callback) callback(true) end,
    close_session = function() closed = closed + 1 end,
  })
  local result

  app:remove(entry, function(value) result = value end)

  assert_equal(lists, 2)
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "unsafe_worktree")
  assert_equal(closed, 0)
end)

it("не читает buffers и не спрашивает confirmation для каждого static removal blocker", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local loaded_calls = 0
  local confirmations = 0
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      loaded_source_buffers = function()
        loaded_calls = loaded_calls + 1
        return Result.ok({})
      end,
    },
    confirm = function()
      confirmations = confirmations + 1
    end,
  })
  local safe = {
    kind = "linked", path = "/repo/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local cases = {
    {
      kind = "root",
      want = "root",
      message = "Cannot remove the primary worktree",
    },
    {
      locked = "lock",
      want = "locked",
      message = "Cannot remove: worktree is locked",
    },
    {
      prunable = "gone",
      want = "prunable",
      message = "Cannot remove: worktree metadata is stale",
    },
    {
      files = { staged = 1, unstaged = 0, untracked = 0 },
      want = "dirty",
      message = "Cannot remove: commit, stash, or discard local changes first",
    },
    {
      upstream = { state = "no_upstream" },
      want = "no_upstream",
      message = "Cannot remove: push the branch and set its upstream first",
    },
    {
      upstream = { state = "tracking", source = "local_refs", ahead = 1, behind = 0 },
      want = "ahead",
      message = "Cannot remove: push local commits first",
    },
  }

  for _, override in ipairs(cases) do
    local entry = {}
    for key, value in pairs(safe) do entry[key] = value end
    for key, value in pairs(override) do entry[key] = value end
    local result
    app:remove(entry, function(value) result = value end)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, override.want)
    assert_equal(result.error.message, override.message)
  end
  assert_equal(loaded_calls, 0)
  assert_equal(confirmations, 0)
end)

it("отменяет remove, если same path после y получил другой worktree identity", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local entry = {
    kind = "linked", path = "/repo/linked", head = "old", branch_ref = "refs/heads/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local removes = 0
  local app = Worktrees.new({
    git = {
      worktrees = function(_, _, callback)
        callback(Result.ok({
          { kind = "root", path = "/repo", head = "main", branch_ref = "refs/heads/main" },
          { kind = "linked", path = "/repo/linked", head = "replacement", branch_ref = "refs/heads/linked" },
        }))
        return { cancel = function() end }
      end,
      worktree_status = function(_, _, callback)
        callback(Result.ok({ staged = 0, unstaged = 0, untracked = 0 }))
        return { cancel = function() end }
      end,
      upstream = function(_, _, callback)
        callback(Result.ok({ state = "tracking", source = "local_refs", ahead = 0, behind = 0 }))
        return { cancel = function() end }
      end,
      remove_worktree = function(_, _, _, callback)
        removes = removes + 1
        callback(Result.ok(true))
        return { cancel = function() end }
      end,
    },
    neovim = { loaded_source_buffers = function() return Result.ok({}) end },
    confirm = function(_, callback) callback(true) end,
  })
  local result

  app:remove(entry, function(value) result = value end)

  assert_equal(removes, 0)
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "stale_worktree")
end)

it("y/N confirmation не добавляет boolean в cancellable remove handles", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local cancelled = 0
  local entry = {
    kind = "linked", path = "/repo/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local app = Worktrees.new({
    git = {
      worktrees = function()
        return { cancel = function() cancelled = cancelled + 1 end }
      end,
    },
    neovim = { loaded_source_buffers = function() return Result.ok({}) end },
    confirm = function(_, callback)
      callback(true)
      return true
    end,
  })

  local request = app:remove(entry, function() end)
  local ok = pcall(request.cancel)

  assert_equal(ok, true)
  assert_equal(cancelled, 1)
end)

it("после старта remove cancel отсоединяет UI, но завершает postcondition и close session", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local remove_callback
  local remove_cancelled = 0
  local list_calls = 0
  local closed = 0
  local callback_calls = 0
  local entry = {
    kind = "linked", path = "/repo/linked", head = "head", branch_ref = "refs/heads/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local git = {
    worktrees = function(_, _, callback)
      list_calls = list_calls + 1
      callback(Result.ok(list_calls == 1 and {
        { kind = "root", path = "/repo", head = "main", branch_ref = "refs/heads/main" }, entry,
      } or {
        { kind = "root", path = "/repo", head = "main", branch_ref = "refs/heads/main" },
      }))
      return { cancel = function() end }
    end,
    worktree_status = function(_, _, callback)
      callback(Result.ok({ staged = 0, unstaged = 0, untracked = 0 }))
      return { cancel = function() end }
    end,
    upstream = function(_, _, callback)
      callback(Result.ok({ state = "tracking", source = "local_refs", ahead = 0, behind = 0 }))
      return { cancel = function() end }
    end,
    remove_worktree = function(_, _, _, callback)
      remove_callback = callback
      return { cancel = function() remove_cancelled = remove_cancelled + 1 end }
    end,
  }
  local app = Worktrees.new({
    git = git,
    registry = {
      all = function() return { { id = "target", root = entry.path, closed = false } } end,
    },
    neovim = { loaded_source_buffers = function() return Result.ok({}) end },
    confirm = function(_, callback) callback(true) end,
    close_session = function() closed = closed + 1 end,
  })
  local request = app:remove(entry, function() callback_calls = callback_calls + 1 end)
  assert_truthy(remove_callback ~= nil)

  request.cancel()
  assert_equal(remove_cancelled, 0)
  remove_callback(Result.ok(true))

  assert_equal(list_calls, 2)
  assert_equal(closed, 1)
  assert_equal(callback_calls, 0)
end)

it("блокирует удаление worktree, из которого открыт picker", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local confirmations = 0
  local entry = {
    kind = "linked", path = "/repo/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = { loaded_source_buffers = function() return Result.ok({}) end },
    confirm = function() confirmations = confirmations + 1 end,
  })
  local result

  app:remove(entry, function(value) result = value end, { root = entry.path })

  assert_equal(result.ok, false)
  assert_equal(result.error.code, "picker_origin")
  assert_equal(confirmations, 0)
end)

it("сравнивает picker origin Windows worktree без учёта case и разделителя", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local confirmations = 0
  local entry = {
    kind = "linked", path = "C:\\Repo\\Feature",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local app = Worktrees.new({
    git = fake_git({}),
    neovim = {
      platform = "win32",
      loaded_source_buffers = function() return Result.ok({}) end,
    },
    confirm = function() confirmations = confirmations + 1 end,
  })
  local result

  app:remove(entry, function(value) result = value end, { root = "c:/repo/feature/" })

  assert_equal(result.ok, false)
  assert_equal(result.error.code, "picker_origin")
  assert_equal(confirmations, 0)
end)

it("rejects every malformed BufferInfo before confirmation", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local entry = {
    kind = "linked", path = "/repo/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  for _, buffers in ipairs({
    { false },
    { "not-buffer-info" },
    { {} },
    { { path = "" } },
    { { path = "/repo/linked/file.lua" } },
    { { buf = "1", path = "/repo/linked/file.lua" } },
    { { buf = 0, path = "/repo/linked/file.lua" } },
    { { buf = 1.5, path = "/repo/linked/file.lua" } },
  }) do
    local confirmations = 0
    local app = Worktrees.new({
      git = fake_git({}),
      neovim = { loaded_source_buffers = function() return Result.ok(buffers) end },
      confirm = function() confirmations = confirmations + 1 end,
    })
    local result
    app:remove(entry, function(value) result = value end)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "loaded_source_buffers_failed")
    assert_equal(confirmations, 0)
  end
end)

it("отклоняет non-string и разреженные BufferInfo до confirmation", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local entry = {
    kind = "linked", path = "/repo/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local cases = {
    { buffers = { { buf = 1, path = false } } },
    { buffers = { { buf = 1, path = 7 } } },
    { buffers = { [2] = { buf = 1, path = "/repo/linked/file.lua" } } },
  }

  for _, case in ipairs(cases) do
    local confirmations = 0
    local app = Worktrees.new({
      git = fake_git({}),
      neovim = { loaded_source_buffers = function() return Result.ok(case.buffers) end },
      confirm = function() confirmations = confirmations + 1 end,
    })
    local result
    app:remove(entry, function(value) result = value end)
    assert_truthy(result ~= nil)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "loaded_source_buffers_failed")
    assert_equal(confirmations, 0)
  end
end)

it("сверяет Windows spelling в fresh list и postcondition worktree", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local entry = {
    kind = "linked", path = "C:\\Repo\\Feature", head = "head", branch_ref = "refs/heads/feature",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local list_calls = 0
  local removes = 0
  local app = Worktrees.new({
    git = {
      worktrees = function(_, _, callback)
        list_calls = list_calls + 1
        callback(Result.ok(list_calls == 1 and {
          { kind = "root", path = "C:\\Repo", head = "root", branch_ref = "refs/heads/main" },
          { kind = "linked", path = "c:/repo/feature/", head = "head", branch_ref = "refs/heads/feature" },
        } or {
          { kind = "root", path = "C:/Repo", head = "root", branch_ref = "refs/heads/main" },
          { kind = "linked", path = "c:\\REPO\\FEATURE", head = "head", branch_ref = "refs/heads/feature" },
        }))
        return { cancel = function() end }
      end,
      worktree_status = function(_, _, callback)
        callback(Result.ok({ staged = 0, unstaged = 0, untracked = 0 }))
        return { cancel = function() end }
      end,
      upstream = function(_, _, callback)
        callback(Result.ok({ state = "tracking", source = "local_refs", ahead = 0, behind = 0 }))
        return { cancel = function() end }
      end,
      remove_worktree = function(_, _, _, callback)
        removes = removes + 1
        callback(Result.ok(true))
        return { cancel = function() end }
      end,
    },
    neovim = {
      platform = "win32",
      loaded_source_buffers = function() return Result.ok({}) end,
    },
    confirm = function(_, callback) callback(true) end,
  })
  local result

  app:remove(entry, function(value) result = value end)

  assert_equal(removes, 1)
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "unsafe_worktree")
end)

it("закрывает удалённую Windows Vigit-сессию через platform-aware registry lookup", function()
  local Worktrees = require("vigit.application.worktrees")
  local Result = require("vigit.core.result")
  local entry = {
    kind = "linked", path = "C:\\Repo\\Linked", head = "head", branch_ref = "refs/heads/linked",
    files = { staged = 0, unstaged = 0, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }
  local session = { id = "linked", root = "c:/repo/linked/", closed = false }
  local closed = 0
  local lists = 0
  local app = Worktrees.new({
    git = {
      worktrees = function(_, _, callback)
        lists = lists + 1
        callback(Result.ok(lists == 1 and {
          { kind = "root", path = "C:\\Repo", head = "root", branch_ref = "refs/heads/main" },
          entry,
        } or {
          { kind = "root", path = "c:/repo/", head = "root", branch_ref = "refs/heads/main" },
        }))
        return { cancel = function() end }
      end,
      worktree_status = function(_, _, callback)
        callback(Result.ok({ staged = 0, unstaged = 0, untracked = 0 }))
        return { cancel = function() end }
      end,
      upstream = function(_, _, callback)
        callback(Result.ok({ state = "tracking", source = "local_refs", ahead = 0, behind = 0 }))
        return { cancel = function() end }
      end,
      remove_worktree = function(_, _, _, callback)
        callback(Result.ok(true))
        return { cancel = function() end }
      end,
    },
    registry = {
      get = function() return nil end,
      all = function() return { session } end,
    },
    neovim = {
      platform = "win32",
      loaded_source_buffers = function() return Result.ok({}) end,
    },
    confirm = function(_, callback) callback(true) end,
    close_session = function(value)
      assert_equal(value, session)
      closed = closed + 1
    end,
  })
  local result

  app:remove(entry, function(value) result = value end)

  assert_equal(result.ok, true)
  assert_equal(closed, 1)
end)
