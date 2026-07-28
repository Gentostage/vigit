local Result = require("vigit.core.result")
local ErrorState = require("vigit.application.error_state")

local M = {}
local Mutations = {}
Mutations.__index = Mutations

local function state_for(session)
  session.mutations = session.mutations or {}
  session.mutations.active = session.mutations.active == true
  session.mutations.queue = session.mutations.queue or {}
  session.mutations.ids = session.mutations.ids or {}
  session.busy = session.busy or {}
  session.errors = session.errors or {}
  return session.mutations
end

local function set_error(session, error)
  local errors = session.errors
  if error then
    errors.mutation = error
  else
    errors.mutation = nil
  end
  ErrorState.resolve(session)
end

function Mutations:notify(session)
  self.on_change(session)
end

local function drain(self, session)
  local state = state_for(session)
  if session.closed or state.active then
    return
  end

  local operation = table.remove(state.queue, 1)
  if not operation then
    return
  end

  state.active = true
  session.busy.mutation = true
  set_error(session, nil)
  self:notify(session)

  local completed = false
  local function done(result)
    if completed then
      return
    end
    completed = true

    if not Result.is(result) then
      result = Result.err(
        "malformed_mutation_result",
        "Mutation completion must receive a Result",
        result
      )
    end

    state.active = false
    session.busy.mutation = nil
    set_error(session, result.ok and nil or result.error)
    self:notify(session)

    if result.ok and not session.closed and operation.after_success then
      local ok, err = pcall(operation.after_success, result)
      if not ok then
        set_error(session, Result.err(
          "mutation_after_success_failed",
          "Mutation after-success callback failed",
          err
        ).error)
        self:notify(session)
      end
    end

    drain(self, session)
  end

  local ok, err = pcall(operation.run, done)
  if not ok then
    done(Result.err("mutation_failed", "Mutation operation failed", err))
  end
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    on_change = opts.on_change or function() end,
  }, Mutations)
end

function Mutations:enqueue(session, operation)
  local state = state_for(session)
  if session.closed or state.ids[operation.id] then
    return false
  end

  state.ids[operation.id] = true
  state.queue[#state.queue + 1] = {
    id = operation.id,
    run = operation.run,
    after_success = operation.after_success,
  }
  drain(self, session)
  return true
end

return M
