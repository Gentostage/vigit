local M = {}

local RenderQueue = {}
RenderQueue.__index = RenderQueue

local function cancel_handle(handle)
  if type(handle) ~= "table" and type(handle) ~= "userdata" then return end
  if type(handle.cancel) == "function" then
    pcall(handle.cancel, handle)
    return
  end
  if type(handle.is_closing) == "function" and handle:is_closing() then return end
  if type(handle.stop) == "function" then pcall(handle.stop, handle) end
  if type(handle.close) == "function" then pcall(handle.close, handle) end
end

function M.new(opts)
  opts = assert(opts)
  return setmetatable({
    render = assert(opts.render),
    schedule = opts.schedule or function(delay_ms, callback)
      return vim.defer_fn(callback, delay_ms)
    end,
    delay_ms = assert(opts.delay_ms),
    pending = setmetatable({}, { __mode = "k" }),
  }, RenderQueue)
end

function RenderQueue:request(session)
  if not session or session.closed or self.pending[session] then return end
  local request = {}
  self.pending[session] = request
  request.handle = self.schedule(self.delay_ms, function()
    if self.pending[session] ~= request then return end
    self.pending[session] = nil
    if not session.closed then self.render(session) end
  end)
end

function RenderQueue:flush(session)
  if not session or session.closed then
    self:cancel(session)
    return
  end
  local request = self.pending[session]
  if request then
    self.pending[session] = nil
    cancel_handle(request.handle)
  end
  self.render(session)
end

function RenderQueue:cancel(session)
  if not session then return end
  local request = self.pending[session]
  self.pending[session] = nil
  if request then cancel_handle(request.handle) end
end

return M
