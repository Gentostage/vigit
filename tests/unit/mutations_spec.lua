local Result = require("vigit.core.result")
local Mutations = require("vigit.application.mutations")
local Session = require("vigit.ui.session")

local function new_session()
  return Session.new({ id = "session", root = "/repo" })
end

local function operation(id, run, after_success)
  return {
    id = id,
    run = run,
    after_success = after_success,
  }
end

it("выполняет mutation operations строго в FIFO порядке", function()
  local queue = Mutations.new({})
  local session = new_session()
  local first_done
  local second_started

  queue:enqueue(session, operation("first", function(done)
    first_done = done
  end))
  queue:enqueue(session, operation("second", function(done)
    second_started = true
    done(Result.ok(true))
  end))

  assert_equal(session.mutations.active, true)
  assert_equal(second_started, nil)

  first_done(Result.ok(true))

  assert_equal(second_started, true)
  assert_equal(session.mutations.active, false)
end)

it("продолжает FIFO очередь после failed operation", function()
  local queue = Mutations.new({})
  local session = new_session()
  local started = {}
  local first_done

  queue:enqueue(session, operation("first", function(done)
    started[#started + 1] = "first"
    first_done = done
  end))
  queue:enqueue(session, operation("second", function(done)
    started[#started + 1] = "second"
    done(Result.ok(true))
  end))

  assert_equal(started, { "first" })

  first_done(Result.err("git_failed", "Git failed"))

  assert_equal(started, { "first", "second" })
  assert_equal(session.error, nil)
  assert_equal(session.mutations.active, false)
end)

it("не вызывает after_success для закрытой session", function()
  local changes = 0
  local queue = Mutations.new({
    on_change = function()
      changes = changes + 1
    end,
  })
  local session = new_session()
  local done
  local successes = 0

  queue:enqueue(session, operation("first", function(callback)
    done = callback
  end, function()
    successes = successes + 1
  end))
  assert_equal(changes, 1)
  session.closed = true

  done(Result.ok(true))

  assert_equal(successes, 0)
  assert_equal(changes, 2)
end)

it("не выполняет operation с duplicate ID дважды", function()
  local queue = Mutations.new({})
  local session = new_session()
  local runs = 0
  local op = operation("same", function(done)
    runs = runs + 1
    done(Result.ok(true))
  end)

  queue:enqueue(session, op)
  queue:enqueue(session, op)

  assert_equal(runs, 1)
end)

it("принимает completion только один раз", function()
  local queue = Mutations.new({})
  local session = new_session()
  local done
  local successes = 0

  queue:enqueue(session, operation("first", function(callback)
    done = callback
  end, function()
    successes = successes + 1
  end))

  done(Result.ok(true))
  done(Result.err("late_failure", "Late failure"))

  assert_equal(successes, 1)
  assert_equal(session.error, nil)
  assert_equal(session.mutations.active, false)
end)

it("уведомляет об изменениях busy и error", function()
  local notifications = {}
  local queue = Mutations.new({
    on_change = function(session)
      notifications[#notifications + 1] = {
        active = session.mutations.active,
        busy = session.busy.mutation,
        error = session.error and session.error.code,
      }
    end,
  })
  local session = new_session()
  local done

  queue:enqueue(session, operation("first", function(callback)
    done = callback
  end))

  assert_equal(notifications, {
    { active = true, busy = true, error = nil },
  })

  done(Result.err("git_failed", "Git failed"))

  assert_equal(notifications, {
    { active = true, busy = true, error = nil },
    { active = false, busy = nil, error = "git_failed" },
  })
  assert_equal(session.error, Result.err("git_failed", "Git failed").error)
end)
