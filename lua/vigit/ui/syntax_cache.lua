local M = {}

local SyntaxCache = {}
SyntaxCache.__index = SyntaxCache

function M.new(limit)
  assert(type(limit) == "number" and limit > 0 and limit % 1 == 0)
  return setmetatable({
    limit = limit,
    entries = {},
    size = 0,
    tick = 0,
  }, SyntaxCache)
end

function SyntaxCache:get(key)
  local entry = self.entries[key]
  if not entry then return nil end
  self.tick = self.tick + 1
  entry.tick = self.tick
  return entry.value
end

function SyntaxCache:put(key, value)
  self.tick = self.tick + 1
  local existing = self.entries[key]
  if existing then
    existing.value = value
    existing.tick = self.tick
    return
  end
  if self.size >= self.limit then
    local oldest_key, oldest_tick
    for candidate, entry in pairs(self.entries) do
      if oldest_tick == nil or entry.tick < oldest_tick then
        oldest_key, oldest_tick = candidate, entry.tick
      end
    end
    if oldest_key ~= nil then
      self.entries[oldest_key] = nil
      self.size = self.size - 1
    end
  end
  self.entries[key] = { value = value, tick = self.tick }
  self.size = self.size + 1
end

return M
