local Result = require("vigit.core.result")

local M = {}

local Workspace = {}
Workspace.__index = Workspace

local function valid_result(result, code, message)
  if Result.is(result) then
    return result
  end
  return Result.err(code, message, result)
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    canonicalize = assert(opts.canonicalize),
    inspect = assert(opts.inspect),
    set_root = assert(opts.set_root),
    create_session = assert(opts.create_session),
    mount = assert(opts.mount),
    show = opts.show or opts.mount,
    hide = assert(opts.hide),
    dispose = assert(opts.dispose),
    tab = opts.tab,
    code_win = opts.code_win,
    root = nil,
    session = nil,
    sessions = {},
    session_order = {},
    mode = "closed",
  }, Workspace)
end

function Workspace:active_session()
  return self.session
end

function Workspace:all_sessions()
  local sessions = {}
  for _, root in ipairs(self.session_order) do
    local session = self.sessions[root]
    if session and not session.closed then
      sessions[#sessions + 1] = session
    end
  end
  return sessions
end

function Workspace:mode_name()
  return self.mode
end

function Workspace:_set_root(root)
  return valid_result(
    self.set_root(self, root),
    "workspace_root_failed",
    "Unable to set workspace root"
  )
end

function Workspace:_show(session)
  return valid_result(
    self.show(session, self),
    "workspace_mount_failed",
    "Unable to show Vigit review"
  )
end

function Workspace:_activate(root)
  local rooted = self:_set_root(root)
  if not rooted.ok then
    return rooted
  end

  local existing = self.sessions[root]
  if existing and not existing.closed then
    existing.workspace = self
    self.session = existing
    self.root = root
    local shown = self:_show(existing)
    if not shown.ok then
      self.session = nil
      self.root = nil
      return shown
    end
    self.mode = "review"
    return Result.ok(existing)
  end

  local created = valid_result(
    self.create_session(root),
    "workspace_session_failed",
    "Unable to create Vigit session"
  )
  if not created.ok then
    return created
  end

  local session = created.value
  session.workspace = self
  self.session = session
  self.root = root
  local mounted = valid_result(
    self.mount(session, self),
    "workspace_mount_failed",
    "Unable to mount Vigit review"
  )
  if not mounted.ok then
    self.session = nil
    self.root = nil
    self.dispose(session)
    return mounted
  end

  self.sessions[root] = session
  self.session_order[#self.session_order + 1] = root
  self.mode = "review"
  return Result.ok(session)
end

function Workspace:_restore(previous, failure)
  if not previous or previous.closed then
    self.session = nil
    self.root = nil
    self.mode = "code"
    return failure
  end

  local rooted = self:_set_root(previous.root)
  if rooted.ok then
    previous.workspace = self
    self.session = previous
    self.root = previous.root
    local shown = self:_show(previous)
    if shown.ok then
      self.mode = "review"
      return failure
    end
  end

  self.session = nil
  self.root = nil
  self.mode = "code"
  return failure
end

function Workspace:open(root)
  root = self.canonicalize(root)
  if self.session and self.root == root then
    return self:show_review()
  end
  if self.session then
    return self:switch(root)
  end
  return self:_activate(root)
end

function Workspace:show_review()
  if not self.session then
    return Result.err(
      "workspace_session_missing",
      "No active Vigit session"
    )
  end
  local rooted = self:_set_root(self.root)
  if not rooted.ok then return rooted end
  local shown = self:_show(self.session)
  if shown.ok then
    self.mode = "review"
    return Result.ok(self.session)
  end
  return shown
end

function Workspace:show_code()
  if not self.session then
    return Result.err(
      "workspace_session_missing",
      "No active Vigit session"
    )
  end
  local rooted = self:_set_root(self.root)
  if not rooted.ok then return rooted end
  self.hide(self.session)
  self.mode = "code"
  return Result.ok(self.session)
end

function Workspace:switch(root)
  root = self.canonicalize(root)
  if not self.session then
    return self:_activate(root)
  end
  if self.root == root then
    return self:show_review()
  end

  local inspected = valid_result(
    self.inspect(self),
    "workspace_inspection_failed",
    "Unable to inspect workspace resources"
  )
  if not inspected.ok then
    return inspected
  end

  local previous = self.session
  self.hide(previous)
  self.session = nil
  self.root = nil
  self.mode = "code"

  local activated = self:_activate(root)
  if activated.ok then
    return activated
  end
  return self:_restore(previous, activated)
end

function Workspace:remove_session(root)
  root = self.canonicalize(root)
  if self.root == root then
    return false
  end
  local session = self.sessions[root]
  if not session then
    return false
  end
  if not session.closed then
    self.dispose(session)
  end
  self.sessions[root] = nil
  for index, candidate in ipairs(self.session_order) do
    if candidate == root then
      table.remove(self.session_order, index)
      break
    end
  end
  return true
end

function Workspace:close()
  if #self.session_order == 0 then
    return false
  end
  if self.session then
    self.hide(self.session)
  end
  for _, root in ipairs(self.session_order) do
    local session = self.sessions[root]
    if session and not session.closed then
      self.dispose(session)
    end
  end
  self.sessions = {}
  self.session_order = {}
  self.session = nil
  self.root = nil
  self.mode = "closed"
  return true
end

return M
