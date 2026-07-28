local Result = require("vigit.core.result")

local M = {}

local Worktrees = {}
Worktrees.__index = Worktrees

local function basename(path)
  return tostring(path or ""):gsub("/+$", ""):match("([^/]+)$")
    or tostring(path or "")
end

local function copy_row(entry, registry)
  local row = {}
  for key, value in pairs(entry) do row[key] = value end
  row.name = row.name or basename(row.path)
  row.files = nil
  row.upstream = nil
  row.probes = {
    status = { state = "pending", error = nil },
    upstream = { state = "pending", error = nil },
  }
  row.loading = true
  row.open = registry and registry:get(row.path) ~= nil or false
  return row
end

local function normalized_path(path, windows)
  local value = tostring(path or "")
  if windows then
    value = value:gsub("\\", "/"):lower()
  end
  return value:gsub("/+$", "")
end

local function alive(self, request)
  return self.request == request
    and not request.cancelled
    and not (request.origin and request.origin.closed)
end

local function finish(callback, result)
  if callback and not callback.called then
    callback.called = true
    callback.fn(result)
  end
end

local function once(callback)
  local called = false
  return function(...)
    if called then return end
    called = true
    return callback(...)
  end
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    git = assert(opts.git),
    registry = opts.registry,
    neovim = opts.neovim,
    concurrency = math.max(1, math.min(4, tonumber(opts.concurrency) or 4)),
    open_session = opts.open_session,
    on_update = opts.on_update,
    clock = opts.clock or function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
    fetched_at = {},
    rows = {},
    request = nil,
    subscriber = nil,
  }, Worktrees)
end

function Worktrees:set_on_update(callback, owner)
  self.on_update = callback
  self.subscriber = owner or callback
end

function Worktrees:detach(owner)
  if owner == nil or self.subscriber == owner then
    self.on_update = nil
    self.subscriber = nil
  end
end

function Worktrees:dispose(origin, owner)
  if owner == nil or self.subscriber ~= owner then return false end
  self:cancel(origin)
  self:detach(owner)
  return true
end

function Worktrees:_emit(request)
  if alive(self, request) and self.on_update then
    self.on_update(self.rows, request)
  end
end

function Worktrees:cancel(origin)
  local request = self.request
  if not request or (origin and request.origin ~= origin) then return end
  request.cancelled = true
  for _, handle in ipairs(request.handles) do
    if handle and handle.cancel then pcall(handle.cancel) end
  end
  request.handles = {}
  if self.request == request then self.request = nil end
end

function Worktrees:_release(request)
  request.handles = {}
  if self.request == request then self.request = nil end
end

function Worktrees:_apply_fetched_at(row)
  local upstream = row and row.upstream
  local fetched = row and self.fetched_at[row.path]
  if upstream and upstream.state == "tracking" and fetched and fetched.name == upstream.name then
    upstream.fetched_at = fetched.at
  end
end

function Worktrees:list(origin, callback)
  self:cancel()
  local request = {
    origin = origin,
    handles = {},
    cancelled = false,
    active = 0,
    next_index = 1,
    remaining = 0,
    callback = callback and { fn = callback } or nil,
  }
  self.request = request
  self.rows = {}

  local handle = self.git:worktrees(origin.root, once(function(result)
    if not alive(self, request) then return end
    if not result.ok then
      finish(request.callback, result)
      self:_release(request)
      return
    end

    for index, entry in ipairs(result.value) do
      self.rows[index] = copy_row(entry, self.registry)
    end
    request.remaining = #self.rows
    request.queue = {}
    for index, row in ipairs(self.rows) do
      request.queue[#request.queue + 1] = { index = index, kind = "status" }
      request.queue[#request.queue + 1] = { index = index, kind = "upstream" }
    end
    self:_emit(request)
    if request.remaining == 0 then
      finish(request.callback, Result.ok(self.rows))
      self:_release(request)
      return
    end

    local function schedule()
      if not alive(self, request) then return end
      while request.active < self.concurrency and request.next_index <= #request.queue do
        local task = request.queue[request.next_index]
        request.next_index = request.next_index + 1
        request.active = request.active + 1
        local row = self.rows[task.index]
        local function complete_probe(result)
          if not alive(self, request) then return end
          local probe = row.probes[task.kind]
          if task.kind == "status" and result.ok then
            row.files = {
              staged = tonumber(result.value.staged) or 0,
              unstaged = tonumber(result.value.unstaged) or 0,
              untracked = tonumber(result.value.untracked) or 0,
            }
            probe.state = "ok"
            probe.error = nil
          elseif task.kind == "upstream" and result.ok then
            row.upstream = result.value
            self:_apply_fetched_at(row)
            probe.state = "ok"
            probe.error = nil
          else
            probe.state = "error"
            probe.error = result.error
          end
          row.loading = row.probes.status.state == "pending" or row.probes.upstream.state == "pending"
          if not row.loading then
            row.open = self.registry and self.registry:get(row.path) ~= nil or false
            request.remaining = request.remaining - 1
          end
          request.active = request.active - 1
          self:_emit(request)
          if request.remaining == 0 then
            finish(request.callback, Result.ok(self.rows))
            self:_release(request)
          else
            schedule()
          end
        end
        local callback = once(complete_probe)
        local handle
        if task.kind == "status" then
          handle = self.git:worktree_status(row.path, callback)
        else
          handle = self.git:upstream(row.path, callback)
        end
        request.handles[#request.handles + 1] = handle
      end
    end
    schedule()
  end))
  request.handles[#request.handles + 1] = handle
  return {
    cancel = function()
      if self.request == request then self:cancel(origin) end
    end,
  }
end

function Worktrees:open(entry, callback)
  local function complete(result)
    if callback then callback(result) end
  end
  local done = once(complete)
  if not entry or type(entry.path) ~= "string" then
    done(Result.err("worktree_missing", "Selected worktree is unavailable"))
    return { cancel = function() end }
  end
  local resolver = self.neovim and self.neovim.canonical_root
  if type(resolver) ~= "function" then
    done(Result.err("worktree_unavailable", "Worktree resolver is unavailable"))
    return { cancel = function() end }
  end
  local cancelled = false
  local resolver_handle
  local function cancel()
    if cancelled then return end
    cancelled = true
    if resolver_handle and resolver_handle.cancel then pcall(resolver_handle.cancel) end
  end
  resolver_handle = resolver(entry.path, once(function(root_result)
    if cancelled then return end
    if not root_result.ok then
      done(root_result)
      return
    end
    local root = root_result.value
    local platform = self.neovim and tostring(self.neovim.platform or ""):lower() or ""
    local windows = platform == "win32" or platform == "windows" or platform == "windows_nt"
    if normalized_path(root, windows) ~= normalized_path(entry.path, windows) then
      done(Result.err("worktree_missing", "Selected worktree no longer resolves to its own root"))
      return
    end
    local existing = self.registry and self.registry:get(root)
    if existing and not existing.closed then
      local focused = not self.neovim.focus_session or self.neovim.focus_session(existing)
      if focused then
        done(Result.ok(existing))
      else
        done(Result.err("worktree_focus_failed", "Unable to focus existing Vigit session"))
      end
      return
    end
    if type(self.open_session) ~= "function" then
      done(Result.err("worktree_open_unavailable", "Worktree session opener is unavailable"))
      return
    end
    local session, open_error = self.open_session(root)
    if not session then
      done(Result.err(
        (open_error and open_error.code) or "worktree_missing",
        (open_error and open_error.message) or "Worktree no longer exists",
        open_error
      ))
      return
    end
    done(Result.ok(session))
  end))
  return { cancel = cancel }
end

function Worktrees:fetch(entry, callback)
  if not entry or type(entry.path) ~= "string" then
    local result = Result.err("worktree_missing", "Selected worktree is unavailable")
    if callback then callback(result) end
    return { cancel = function() end }
  end
  return self.git:fetch(entry.path, once(function(result)
    if result.ok then
      local fetched_at = self.clock()
      local upstream = entry.upstream
      if not (upstream and upstream.state == "tracking") then
        for _, row in ipairs(self.rows) do
          if row.path == entry.path and row.upstream and row.upstream.state == "tracking" then
            upstream = row.upstream
            break
          end
        end
      end
      if upstream and upstream.state == "tracking" and upstream.name then
        self.fetched_at[entry.path] = { name = upstream.name, at = fetched_at }
      end
      for _, row in ipairs(self.rows) do
        if row.path == entry.path then self:_apply_fetched_at(row) end
      end
    end
    if callback then callback(result) end
  end))
end

return M
