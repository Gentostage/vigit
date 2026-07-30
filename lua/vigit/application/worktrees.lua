local Result = require("vigit.core.result")
local worktree_policy = require("vigit.core.worktree")
local confirm_worktree = require("vigit.ui.confirm").ask

local M = {}

local Worktrees = {}
Worktrees.__index = Worktrees

local removal_messages = {
  root = "Cannot remove the primary worktree",
  locked = "Cannot remove: worktree is locked",
  prunable = "Cannot remove: worktree metadata is stale",
  dirty = "Cannot remove: commit, stash, or discard local changes first",
  no_upstream = "Cannot remove: push the branch and set its upstream first",
  ahead = "Cannot remove: push local commits first",
  loaded_source_buffer = "Cannot remove: close source buffers from this worktree first",
}

local function basename(path)
  return tostring(path or ""):gsub("/+$", ""):match("([^/]+)$")
    or tostring(path or "")
end

local function normalized_path(path, windows)
  local value = tostring(path or "")
  if windows then
    value = value:gsub("\\", "/"):lower()
  end
  return value:gsub("/+$", "")
end

local function is_windows(platform)
  platform = tostring(platform or ""):lower()
  return platform == "win32" or platform == "windows" or platform == "windows_nt"
end

local function same_root(first, second, platform)
  local windows = is_windows(platform)
  return normalized_path(first, windows) == normalized_path(second, windows)
end

local function copy_row(entry, active_root, platform)
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
  row.active = active_root ~= nil and same_root(row.path, active_root, platform)
  return row
end

local function session_at_root(registry, root, platform)
  if not registry or type(registry.all) ~= "function" then
    return nil
  end
  local ok, sessions = pcall(registry.all, registry)
  if not ok or type(sessions) ~= "table" then
    return nil
  end
  for _, session in ipairs(sessions) do
    if type(session) == "table" and same_root(session.root, root, platform) then
      return session
    end
  end
  return nil
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
    switch_session = opts.switch_session,
    active_root = opts.active_root,
    on_update = opts.on_update,
    confirm = opts.confirm or confirm_worktree,
    close_session = opts.close_session,
    clock = opts.clock or function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
    fetched_at = {},
    rows = {},
    request = nil,
    subscriber = nil,
  }, Worktrees)
end

function Worktrees:_active_root()
  if type(self.active_root) ~= "function" then
    return nil
  end
  local ok, root = pcall(self.active_root)
  return ok and root or nil
end

local function paths_from_buffers(buffers, windows)
  local paths = {}
  local count = 0
  for key in pairs(buffers) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil end
    count = count + 1
  end
  for index = 1, count do
    local buffer = buffers[index]
    local path = type(buffer) == "table" and buffer.path or nil
    local buffer_id = type(buffer) == "table" and buffer.buf or nil
    local absolute = type(path) == "string" and path ~= "" and (
      windows and (
        path:match("^%a:[/\\]") ~= nil
        or path:sub(1, 2) == "\\\\"
        or path:sub(1, 2) == "//"
      )
        or not windows and path:sub(1, 1) == "/"
    )
    if type(buffer_id) ~= "number" or buffer_id < 1 or buffer_id % 1 ~= 0 or not absolute then
      return nil
    end
    paths[#paths + 1] = path
  end
  return paths
end

local function worktree_identity(entry)
  return {
    path = entry.path,
    head = entry.head,
    branch_ref = entry.branch_ref,
    detached = entry.detached == true,
  }
end

local function same_identity(first, second, platform)
  return same_root(first.path, second.path, platform)
    and first.head == second.head
    and first.branch_ref == second.branch_ref
    and first.detached == (second.detached == true)
end

function Worktrees:_loaded_paths(root)
  if not self.neovim or type(self.neovim.loaded_source_buffers) ~= "function" then
    return Result.err("loaded_source_buffers_unavailable", "Loaded source buffer inspection is unavailable")
  end
  local ok, inspected = pcall(self.neovim.loaded_source_buffers, root)
  if not ok then
    return Result.err("loaded_source_buffers_failed", "Unable to inspect loaded source buffers", inspected)
  end
  if not Result.is(inspected) then
    return Result.err("loaded_source_buffers_failed", "Loaded source buffer inspection returned invalid data")
  end
  if not inspected.ok then return inspected end
  if type(inspected.value) ~= "table" then
    return Result.err("loaded_source_buffers_failed", "Loaded source buffer inspection returned invalid data")
  end
  local paths = paths_from_buffers(inspected.value, is_windows(self.neovim.platform))
  if not paths then
    return Result.err("loaded_source_buffers_failed", "Loaded source buffer inspection returned invalid data")
  end
  return Result.ok(paths)
end

function Worktrees:_removal_blocker(entry, root)
  local platform = self.neovim and self.neovim.platform
  local static = worktree_policy.removal_blocker(entry, {}, platform)
  if static then return static, nil end
  local loaded = self:_loaded_paths(root or entry.path)
  if not loaded.ok then return nil, loaded end
  return worktree_policy.removal_blocker(entry, loaded.value, platform), nil
end

function Worktrees:remove(entry, callback, origin)
  local cancelled = false
  local mutation_started = false
  local detached = false
  local handles = {}
  local completed = false
  local function complete(result)
    if completed then return end
    completed = true
    if not detached and callback then callback(result) end
  end
  local function add_handle(handle)
    if type(handle) == "table" and type(handle.cancel) == "function" then
      handles[#handles + 1] = handle
    end
    return handle
  end
  local function cancel()
    if mutation_started then
      detached = true
      return
    end
    if cancelled then return end
    cancelled = true
    for _, handle in ipairs(handles) do
      if handle and handle.cancel then pcall(handle.cancel) end
    end
  end
  local function fail_blocker(blocker)
    complete(Result.err(
      blocker,
      removal_messages[blocker] or "Worktree cannot be removed safely"
    ))
  end

  if type(entry) ~= "table" or type(entry.path) ~= "string" then
    complete(Result.err("worktree_missing", "Selected worktree is unavailable"))
    return { cancel = cancel }
  end
  local static_blocker = worktree_policy.removal_blocker(
    entry,
    {},
    self.neovim and self.neovim.platform
  )
  if static_blocker then
    fail_blocker(static_blocker)
    return { cancel = cancel }
  end
  if origin and same_root(origin.root, entry.path, self.neovim and self.neovim.platform) then
    complete(Result.err(
      "picker_origin",
      "Open the worktree picker from another surviving worktree before removing this one"
    ))
    return { cancel = cancel }
  end
  local initial_blocker, initial_error = self:_removal_blocker(entry, entry.path)
  if initial_error then
    complete(initial_error)
    return { cancel = cancel }
  end
  if initial_blocker then
    fail_blocker(initial_blocker)
    return { cancel = cancel }
  end
  local confirmed_identity = worktree_identity(entry)

  local confirmation = self.confirm(
    "Remove " .. entry.path .. "? Branch will be kept.",
    once(function(accepted)
      if cancelled then return end
      if accepted ~= true then
        complete(Result.err("confirmation_cancelled", "Worktree removal was cancelled"))
        return
      end
      add_handle(self.git:worktrees(entry.path, once(function(list_result)
        if cancelled then return end
        if not list_result.ok then complete(list_result); return end
        local primary = list_result.value[1]
        local target
        for _, candidate in ipairs(list_result.value) do
          if same_root(candidate.path, entry.path, self.neovim and self.neovim.platform) then
            target = candidate
            break
          end
        end
        if not primary or primary.kind ~= "root" or not target then
          complete(Result.err("worktree_missing", "Selected worktree no longer exists"))
          return
        end
        if not same_identity(
          confirmed_identity,
          worktree_identity(target),
          self.neovim and self.neovim.platform
        ) then
          complete(Result.err("stale_worktree", "Selected worktree identity changed before removal"))
          return
        end
        add_handle(self.git:worktree_status(target.path, once(function(status_result)
          if cancelled then return end
          if not status_result.ok then complete(status_result); return end
          add_handle(self.git:upstream(target.path, once(function(upstream_result)
            if cancelled then return end
            if not upstream_result.ok then complete(upstream_result); return end
            target.files = {
              staged = tonumber(status_result.value.staged) or 0,
              unstaged = tonumber(status_result.value.unstaged) or 0,
              untracked = tonumber(status_result.value.untracked) or 0,
            }
            target.upstream = upstream_result.value
            local blocker, blocker_error = self:_removal_blocker(target, target.path)
            if blocker_error then complete(blocker_error); return end
            if blocker then fail_blocker(blocker); return end
            mutation_started = true
            add_handle(self.git:remove_worktree(primary.path, target.path, once(function(remove_result)
              if cancelled then return end
              if not remove_result.ok then complete(remove_result); return end
              add_handle(self.git:worktrees(primary.path, once(function(postcondition)
                if cancelled then return end
                if not postcondition.ok then complete(postcondition); return end
                for _, candidate in ipairs(postcondition.value) do
                  if same_root(candidate.path, target.path, self.neovim and self.neovim.platform) then
                    complete(Result.err("unsafe_worktree", "Worktree remains registered after removal"))
                    return
                  end
                end
                local session = session_at_root(
                  self.registry,
                  target.path,
                  self.neovim and self.neovim.platform
                )
                if session and not session.closed and type(self.close_session) == "function" then
                  local closed, close_error = pcall(self.close_session, session)
                  if not closed then
                    complete(Result.err("session_close_failed", "Removed worktree Vigit session could not be closed", close_error))
                    return
                  end
                end
                complete(Result.ok({ path = target.path }))
              end)))
            end)))
          end)))
        end)))
      end)))
    end)
  )
  add_handle(confirmation)
  return { cancel = cancel }
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
      self.rows[index] = copy_row(
        entry,
        self:_active_root(),
        self.neovim and self.neovim.platform
      )
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
            row.active = same_root(
              row.path,
              self:_active_root(),
              self.neovim and self.neovim.platform
            )
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
    if type(self.switch_session) ~= "function" then
      done(Result.err("worktree_open_unavailable", "Worktree switcher is unavailable"))
      return
    end
    local switched = self.switch_session(root)
    if not Result.is(switched) then
      done(Result.err("worktree_open_failed", "Unable to switch Vigit worktree", switched))
      return
    end
    done(switched)
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
