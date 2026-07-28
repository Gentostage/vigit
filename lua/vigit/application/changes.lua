local anchor = require("vigit.core.anchor")
local config = require("vigit.config")

local M = {}
local EXPANDED_CONTEXT_LINES = 9999

local Changes = {}
Changes.__index = Changes

local function status_changes(status)
  local changes = {}
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, change in ipairs(status and status[section] or {}) do
      changes[#changes + 1] = change
    end
  end
  return changes
end

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

local function has_expanded_context(session, change_id)
  local prefix = change_id .. "\0"
  for hunk_id, expanded in pairs(session.view.expanded_context) do
    if expanded
        and type(hunk_id) == "string"
        and hunk_id:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function context_lines_for(session, change_id)
  local default_context = config.get().ui.context_lines
  if has_expanded_context(session, change_id) then
    return math.max(EXPANDED_CONTEXT_LINES, default_context + 1)
  end
  return default_context
end

local function applied_context(session)
  session.view.applied_expanded_context =
    session.view.applied_expanded_context or {}
  return session.view.applied_expanded_context
end

local function context_belongs_to(key, change_id)
  if type(key) ~= "string" then
    return false
  end
  local prefix = change_id .. "\0logical:"
  return key:sub(1, #prefix) == prefix
end

local function copy_context(source)
  local result = {}
  for key, value in pairs(source or {}) do
    if value then
      result[key] = true
    end
  end
  return result
end

local function replace_change_context(destination, source, change_id)
  local result = {}
  for key, value in pairs(destination or {}) do
    if value and not context_belongs_to(key, change_id) then
      result[key] = true
    end
  end
  for key, value in pairs(source or {}) do
    if value and context_belongs_to(key, change_id) then
      result[key] = true
    end
  end
  return result
end

local function context_for_status(source, status)
  local result = {}
  for _, change in ipairs(status_changes(status)) do
    for key, value in pairs(source or {}) do
      if value and context_belongs_to(key, change.id) then
        result[key] = true
      end
    end
  end
  return result
end

local function diffs_for_status(source, status)
  local result = {}
  for _, change in ipairs(status_changes(status)) do
    if source[change.id] ~= nil then
      result[change.id] = source[change.id]
    end
  end
  return result
end

local function rollback_change_context(session, change_id)
  session.view.expanded_context = replace_change_context(
    session.view.expanded_context,
    applied_context(session),
    change_id
  )
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

function Changes:load_diff(
    session,
    change_id,
    generation,
    context_lines,
    on_complete,
    on_failure,
    previous_diff
)
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
  local applied_diff = previous_diff or session.data.diffs[change_id]
  local handle = self.git:diff(
    session.root,
    change,
    context_lines or context_lines_for(session, change_id),
    ui.max_diff_bytes,
    function(result)
      if not self:current(session, generation) or session.reads.jobs[job_key] ~= request then
        return
      end

      session.busy.diff[change_id] = nil
      session.view.all_files.loading[change_id] = nil
      session.reads.jobs[job_key] = nil
      if result.ok then
        local previous_logical_hunks = anchor.logical_hunks(
          change,
          applied_diff or { hunks = {} },
          ui.context_lines
        )
        local logical_hunks = anchor.logical_hunks(
          change,
          result.value,
          ui.context_lines
        )
        session.view.expanded_context = anchor.reconcile_logical_keys(
          session.view.expanded_context,
          change_id,
          logical_hunks,
          previous_logical_hunks,
          math.max(1, ui.context_lines * 2)
        )
        session.view.applied_expanded_context = replace_change_context(
          applied_context(session),
          session.view.expanded_context,
          change_id
        )
        session.data.diffs[change_id] = result.value
        session.view.all_files.loaded[change_id] = true
        ensure_errors(session).diffs[change_id] = nil
      else
        if on_failure then
          on_failure(result)
        end
        ensure_errors(session).diffs[change_id] = result.error
      end
      expose_error(session)
      self:notify(session)
      if on_complete then
        on_complete(result)
      end
    end
  )
  if session.reads.jobs[job_key] == request then
    request.handle = handle
  end
end

function Changes:toggle_context(session, change_id, hunk_id, on_complete)
  if session.closed or not change_for(session.data.status, change_id) or not hunk_id then
    return
  end

  local expanded = not session.view.expanded_context[hunk_id]
  local requested = expanded and true or nil
  session.view.expanded_context[hunk_id] = requested
  self:load_diff(session, change_id, nil, nil, on_complete, function()
    rollback_change_context(session, change_id)
  end)
  return expanded
end

function Changes:refresh(session, on_complete)
  if session.closed then
    return
  end

  local previous_diffs = {}
  for change_id, diff in pairs(session.data.diffs or {}) do
    previous_diffs[change_id] = diff
  end
  session.view.expanded_context = copy_context(applied_context(session))

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
      local selected_change_id = session.view.selected_change_id
      session.data.status = result.value
      session.data.diffs = diffs_for_status(
        previous_diffs,
        session.data.status
      )
      session.view.expanded_context = context_for_status(
        session.view.expanded_context,
        session.data.status
      )
      session.view.applied_expanded_context = context_for_status(
        applied_context(session),
        session.data.status
      )
      session.view.all_files.loaded = {}
      session.view.all_files.loading = {}
      ensure_errors(session).status = nil
      expose_error(session)

      local load_ids = {}
      local selected_retained = selected_change_id
        and change_for(session.data.status, selected_change_id)
      if not selected_retained then
        session.view.selected_change_id = nil
      end
      if session.view.diff_mode == "all_files" then
        for _, change in ipairs(status_changes(session.data.status)) do
          load_ids[#load_ids + 1] = change.id
        end
      elseif selected_retained then
        load_ids[1] = selected_change_id
      end

      for _, change_id in ipairs(load_ids) do
        local current_change_id = change_id
        self:load_diff(
          session,
          current_change_id,
          generation,
          nil,
          function(diff_result)
            if on_complete then
              on_complete({
                phase = "diff",
                generation = generation,
                change_id = current_change_id,
                result = diff_result,
              })
            end
          end,
          function()
            rollback_change_context(session, current_change_id)
          end,
          previous_diffs[current_change_id]
        )
      end
      if #load_ids == 0 then
        self:notify(session)
      end
      if on_complete then
        local loading = {}
        for _, change_id in ipairs(load_ids) do
          loading[change_id] = true
        end
        on_complete({
          phase = "status",
          generation = generation,
          load_ids = loading,
          result = result,
        })
      end
    else
      ensure_errors(session).status = result.error
      expose_error(session)
      self:notify(session)
      if on_complete then
        on_complete({
          phase = "status",
          generation = generation,
          load_ids = {},
          result = result,
        })
      end
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
