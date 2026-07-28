local Result = require("vigit.core.result")
local Changes = require("vigit.application.changes")
local Session = require("vigit.ui.session")

local function fake_git()
  local fake = {
    status_callbacks = {},
    status_handles = {},
    diff_callbacks = {},
    diff_calls = {},
    diff_handles = {},
  }

  function fake:status(_, callback)
    self.status_callbacks[#self.status_callbacks + 1] = callback
    local handle = { cancelled = 0 }
    handle.cancel = function()
      handle.cancelled = handle.cancelled + 1
    end
    self.status_handles[#self.status_handles + 1] = handle
    return handle
  end

  function fake:diff(_, change, context, max_bytes, callback)
    self.diff_calls[#self.diff_calls + 1] = {
      change = change,
      context = context,
      max_bytes = max_bytes,
    }
    self.diff_callbacks[#self.diff_callbacks + 1] = callback
    local handle = { cancelled = 0 }
    handle.cancel = function()
      handle.cancelled = handle.cancelled + 1
    end
    self.diff_handles[#self.diff_handles + 1] = handle
    return handle
  end

  return fake
end

local function status(change)
  return {
    branch = {},
    staged = {},
    unstaged = change and { change } or {},
  }
end

local function change(id)
  return {
    id = id,
    section = "unstaged",
    status = "M",
    path = "src/a.lua",
  }
end

it("игнорирует устаревшее завершение обновления статуса", function()
  local fake = fake_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local old_status = status()
  local new_status = status()

  changes:refresh(session)
  local first = fake.status_callbacks[1]
  changes:refresh(session)
  local second = fake.status_callbacks[2]

  second(Result.ok(new_status))
  first(Result.ok(old_status))

  assert_equal(session.data.status, new_status)
  assert_equal(session.reads.generation, 2)
end)

it("не меняет закрытую сессию после завершения чтения", function()
  local fake = fake_git()
  local changed = 0
  local changes = Changes.new({
    git = fake,
    on_change = function()
      changed = changed + 1
    end,
  })
  local session = Session.new({ id = "a", root = "/repo" })

  changes:refresh(session)
  changed = 0
  session.closed = true
  fake.status_callbacks[1](Result.ok(status()))

  assert_equal(session.data.status, nil)
  assert_equal(changed, 0)
end)

it("сохраняет последний успешный статус при ошибке обновления", function()
  local fake = fake_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local successful_status = status()

  changes:refresh(session)
  fake.status_callbacks[1](Result.ok(successful_status))
  changes:refresh(session)
  fake.status_callbacks[2](Result.err("git_status_failed", "Git status failed"))

  assert_equal(session.data.status, successful_status)
  assert_equal(session.error, {
    code = "git_status_failed",
    message = "Git status failed",
    details = nil,
    retryable = false,
  })
end)

it("сохраняет выбранное изменение до запроса diff", function()
  local fake = fake_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local selected = change("unstaged\0src/a.lua")
  session.data.status = status(selected)

  changes:select(session, selected.id)

  assert_equal(session.view.selected_change_id, selected.id)
  assert_equal(fake.diff_calls[1].change, selected)
end)

it("загружает diff для всех видимых изменений", function()
  local fake = fake_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local first = change("unstaged\0src/a.lua")
  local second = {
    id = "unstaged\0src/b.lua",
    section = "unstaged",
    status = "M",
    path = "src/b.lua",
  }
  session.data.status = {
    branch = {},
    staged = {},
    unstaged = { first, second },
  }

  changes:load_all_visible(session, { first.id, second.id })

  assert_equal(fake.diff_calls[1].change, first)
  assert_equal(fake.diff_calls[2].change, second)
end)

it("сбрасывает pending diff после неуспешного обновления статуса", function()
  local fake = fake_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local selected = change("unstaged\0src/a.lua")
  session.data.status = status(selected)

  changes:select(session, selected.id)
  local pending_diff = fake.diff_callbacks[1]
  changes:refresh(session)
  fake.status_callbacks[1](Result.err("git_status_failed", "Git status failed"))
  pending_diff(Result.ok({ id = selected.id, version = "stale" }))

  assert_equal(session.busy.diff[selected.id], nil)
  assert_equal(session.view.all_files.loading[selected.id], nil)
  assert_equal(session.reads.jobs["diff:" .. selected.id], nil)
  assert_equal(session.data.diffs[selected.id], nil)
end)

it("игнорирует старый diff запрос того же изменения", function()
  local fake = fake_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local selected = change("unstaged\0src/a.lua")
  session.data.status = status(selected)

  changes:select(session, selected.id)
  local first = fake.diff_callbacks[1]
  changes:select(session, selected.id)
  local second = fake.diff_callbacks[2]
  second(Result.ok({ id = selected.id, version = "new" }))
  first(Result.ok({ id = selected.id, version = "old" }))

  assert_equal(session.data.diffs[selected.id], { id = selected.id, version = "new" })
  assert_equal(session.busy.diff[selected.id], nil)
  assert_equal(session.view.all_files.loading[selected.id], nil)
end)

it("уведомляет UI и очищает selection, исчезнувший из обновлённого статуса", function()
  local fake = fake_git()
  local changed = 0
  local changes = Changes.new({
    git = fake,
    on_change = function()
      changed = changed + 1
    end,
  })
  local session = Session.new({ id = "a", root = "/repo" })
  local selected = change("unstaged\0src/a.lua")
  session.data.status = status(selected)
  session.view.selected_change_id = selected.id

  changes:refresh(session)
  changed = 0
  fake.status_callbacks[1](Result.ok(status()))

  assert_equal(session.view.selected_change_id, nil)
  assert_equal(changed, 1)
end)

it("не очищает ошибку первого diff при более позднем успехе второго", function()
  local fake = fake_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local first = change("unstaged\0src/a.lua")
  local second = {
    id = "unstaged\0src/b.lua",
    section = "unstaged",
    status = "M",
    path = "src/b.lua",
  }
  session.data.status = {
    branch = {},
    staged = {},
    unstaged = { first, second },
  }

  changes:load_all_visible(session, { first.id, second.id })
  fake.diff_callbacks[1](Result.err("git_diff_failed", "First diff failed"))
  fake.diff_callbacks[2](Result.ok({ id = second.id }))

  assert_equal(session.error.code, "git_diff_failed")
  assert_equal(session.error.message, "First diff failed")
  assert_equal(session.errors.diffs[first.id], session.error)
  assert_equal(session.errors.diffs[second.id], nil)
end)

it("показывает ту же ошибку независимо от обратного порядка diff callbacks", function()
  local fake = fake_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local first = change("unstaged\0src/a.lua")
  local second = {
    id = "unstaged\0src/b.lua",
    section = "unstaged",
    status = "M",
    path = "src/b.lua",
  }
  session.data.status = {
    branch = {},
    staged = {},
    unstaged = { first, second },
  }

  changes:load_all_visible(session, { first.id, second.id })
  fake.diff_callbacks[2](Result.ok({ id = second.id }))
  fake.diff_callbacks[1](Result.err("git_diff_failed", "First diff failed"))

  assert_equal(session.error.code, "git_diff_failed")
  assert_equal(session.error.message, "First diff failed")
  assert_equal(session.errors.diffs[first.id], session.error)
  assert_equal(session.errors.diffs[second.id], nil)
end)

it("отменяет заменённые status и diff reads до перезаписи handles", function()
  local fake = fake_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local selected = change("unstaged\0src/a.lua")
  session.data.status = status(selected)

  changes:refresh(session)
  changes:refresh(session)
  assert_equal(fake.status_handles[1].cancelled, 1)

  fake.status_callbacks[2](Result.ok(status(selected)))
  changes:select(session, selected.id)
  changes:select(session, selected.id)
  assert_equal(fake.diff_handles[1].cancelled, 1)

  changes:refresh(session)
  assert_equal(fake.diff_handles[2].cancelled, 1)
  assert_equal(fake.status_handles[2].cancelled, 0)
end)

it("сохраняет comments error, когда Git error очищается", function()
  local session = Session.new({ id = "errors", root = "/repo" })
  session.errors.comments = { code = "comments_failed", message = "Comment file is malformed" }
  session.errors.diffs = {}

  Changes.expose_error(session)

  assert_equal(session.error.code, "comments_failed")
  session.errors.status = { code = "git_failed", message = "Git failed" }
  Changes.expose_error(session)
  assert_equal(session.error.code, "git_failed")
  session.errors.status = nil
  Changes.expose_error(session)
  assert_equal(session.error.code, "comments_failed")

  session.errors.diffs = {
    ["z-change"] = { code = "z_diff", message = "Z diff" },
    ["a-change"] = { code = "a_diff", message = "A diff" },
  }
  session.errors.mutation = { code = "mutation_failed", message = "Mutation failed" }
  session.errors.handler = { code = "handler_failed", message = "Handler failed" }
  session.view.selected_change_id = "z-change"
  Changes.expose_error(session)
  assert_equal(session.error.code, "z_diff")
  session.view.selected_change_id = nil
  Changes.expose_error(session)
  assert_equal(session.error.code, "a_diff")
  session.errors.diffs = {}
  Changes.expose_error(session)
  assert_equal(session.error.code, "comments_failed")
  session.errors.comments = nil
  Changes.expose_error(session)
  assert_equal(session.error.code, "mutation_failed")
  session.errors.mutation = nil
  Changes.expose_error(session)
  assert_equal(session.error.code, "handler_failed")
end)
