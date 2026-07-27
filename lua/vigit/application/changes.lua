local config = require("vigit.config")

local M = {}

local Changes = {}
Changes.__index = Changes

local function change_for(status, change_id)
  if not status then
    return nil
  end
  for _, section in ipairs({ "unstaged", "staged" }) do
    for _, change in ipairs(status[section] or {}) do
      if change.id == change_id then
        return change
      end
    end
  end
  return nil
end

local function cancel_job(job)
  local handle = job and (job.handle or job)
  if type(handle) == "table" and type(handle.cancel) == "function" then
    pcall(handle.cancel)
  end
end

local function ensure_errors(session)
  session.errors = session.errors or {}
  session.errors.diffs = session.errors.diffs or {}
  return session.errors
end

local function expose_error(session)
  local errors = ensure_errors(session)
  if errors.status then
    session.error = errors.status
    return
  end

  local selected = session.view.selected_change_id
  if selected and errors.diffs[selected] then
    session.error = errors.diffs[selected]
    return
  end

  local first_id
  for change_id in pairs(errors.diffs) do
    if not first_id or change_id < first_id then
      first_id = change_id
    end
  end
  session.error = first_id and errors.diffs[first_id] or nil
end

local function clear_pending_diffs(session)
  session.busy.diff = {}
  session.view.all_files.loading = {}
  ensure_errors(session).diffs = {}
  for key in pairs(session.reads.jobs) do
    if key:sub(1, 5) == "diff:" then
      cancel_job(session.reads.jobs[key])
      session.reads.jobs[key] = nil
    end
  end
  expose_error(session)
end

function M.new(opts)
  return setmetatable({
    git = assert(opts.git),
    on_change = opts.on_change or function() end,
  }, Changes)
end

function Changes:notify(session)
  self.on_change(session)
end

function Changes:current(session, generation)
  return not session.closed and session.reads.generation == generation
end

function Changes:load_diff(session, change_id, generation)
  if session.closed then
    return
  end

  local change = change_for(session.data.status, change_id)
  if not change then
    return
  end

  generation = generation or session.reads.generation
  local job_key = "diff:" .. change_id
  cancel_job(session.reads.jobs[job_key])
  local request = {}
  session.busy.diff = session.busy.diff or {}
  session.busy.diff[change_id] = true
  session.view.all_files.loading[change_id] = true
  ensure_errors(session).diffs[change_id] = nil
  expose_error(session)
  session.reads.jobs[job_key] = request
  self:notify(session)

  local ui = config.get().ui
  local handle = self.git:diff(
    session.root,
    change,
    ui.context_lines,
    ui.max_diff_bytes,
    function(result)
      if not self:current(session, generation) or session.reads.jobs[job_key] ~= request then
        return
      end

      session.busy.diff[change_id] = nil
      session.view.all_files.loading[change_id] = nil
      session.reads.jobs[job_key] = nil
      if result.ok then
        session.data.diffs[change_id] = result.value
        session.view.all_files.loaded[change_id] = true
        ensure_errors(session).diffs[change_id] = nil
      else
        ensure_errors(session).diffs[change_id] = result.error
      end
      expose_error(session)
      self:notify(session)
    end
  )
  if session.reads.jobs[job_key] == request then
    request.handle = handle
  end
end

function Changes:refresh(session)
  if session.closed then
    return
  end

  cancel_job(session.reads.jobs.status)
  session.reads.jobs.status = nil
  clear_pending_diffs(session)
  session.reads.generation = session.reads.generation + 1
  local generation = session.reads.generation
  local request = {}
  session.busy.status = true
  session.reads.jobs.status = request
  self:notify(session)

  local handle = self.git:status(session.root, function(result)
    if not self:current(session, generation)
        or session.reads.jobs.status ~= request then
      return
    end

    session.reads.jobs.status = nil
    session.busy.status = nil
    if result.ok then
      session.data.status = result.value
      session.data.diffs = {}
      session.view.all_files.loaded = {}
      session.view.all_files.loading = {}
      ensure_errors(session).status = nil
      expose_error(session)
      local selected_change_id = session.view.selected_change_id
      if selected_change_id and change_for(session.data.status, selected_change_id) then
        self:load_diff(session, selected_change_id, generation)
      else
        session.view.selected_change_id = nil
        self:notify(session)
      end
    else
      ensure_errors(session).status = result.error
      expose_error(session)
      self:notify(session)
    end
  end)
  if session.reads.jobs.status == request then
    request.handle = handle
  end
end

function Changes:select(session, change_id)
  if session.closed then
    return
  end

  session.view.selected_change_id = change_id
  self:load_diff(session, change_id)
end

function Changes:load_all_visible(session, ids)
  if session.closed then
    return
  end

  for _, change_id in ipairs(ids) do
    self:load_diff(session, change_id)
  end
end

return M
