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
  session.busy.diff = session.busy.diff or {}
  session.busy.diff[change_id] = true
  session.view.all_files.loading[change_id] = true
  self:notify(session)

  local ui = config.get().ui
  session.reads.jobs["diff:" .. change_id] = self.git:diff(
    session.root,
    change,
    ui.context_lines,
    ui.max_diff_bytes,
    function(result)
      if not self:current(session, generation) then
        return
      end

      session.busy.diff[change_id] = nil
      session.view.all_files.loading[change_id] = nil
      if result.ok then
        session.data.diffs[change_id] = result.value
        session.view.all_files.loaded[change_id] = true
        session.error = nil
      else
        session.error = result.error
      end
      self:notify(session)
    end
  )
end

function Changes:refresh(session)
  if session.closed then
    return
  end

  session.reads.generation = session.reads.generation + 1
  local generation = session.reads.generation
  session.busy.status = true
  self:notify(session)

  session.reads.jobs.status = self.git:status(session.root, function(result)
    if not self:current(session, generation) then
      return
    end

    session.busy.status = nil
    if result.ok then
      session.data.status = result.value
      session.data.diffs = {}
      session.view.all_files.loaded = {}
      session.view.all_files.loading = {}
      session.error = nil
      if session.view.selected_change_id then
        self:load_diff(session, session.view.selected_change_id, generation)
      else
        self:notify(session)
      end
    else
      session.error = result.error
      self:notify(session)
    end
  end)
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
