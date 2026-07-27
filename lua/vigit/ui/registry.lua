local M = {}

local Registry = {}
Registry.__index = Registry

function M.new(canonicalize)
  return setmetatable({
    canonicalize = assert(canonicalize),
    by_root = {},
    by_id = {},
    sessions = {},
  }, Registry)
end

function Registry:get(root)
  return self.by_root[self.canonicalize(root)]
end

function Registry:put(session)
  local root = self.canonicalize(session.root)
  local existing = self.by_root[root] or self.by_id[session.id]
  if existing then
    return existing
  end

  session.root = root
  self.by_root[root] = session
  self.by_id[session.id] = session
  self.sessions[#self.sessions + 1] = session
  return session
end

function Registry:remove(session_id)
  local session = self.by_id[session_id]
  if not session then
    return nil
  end

  self.by_id[session_id] = nil
  if self.by_root[session.root] == session then
    self.by_root[session.root] = nil
  end
  for index, candidate in ipairs(self.sessions) do
    if candidate == session then
      table.remove(self.sessions, index)
      break
    end
  end
  return session
end

function Registry:all()
  local sessions = {}
  for index, session in ipairs(self.sessions) do
    sessions[index] = session
  end
  return sessions
end

return M
