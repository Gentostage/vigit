local M = {}

function M.run(items, opts)
  items = items or {}
  opts = assert(opts)
  local concurrency = assert(opts.concurrency)
  local next_index = 1
  local active = 0
  local completed = 0
  local first_wave = math.min(#items, concurrency)
  local first_wave_done = 0
  local preview_sent = false
  local cancelled = false

  local pump
  pump = function()
    while not cancelled and active < concurrency and next_index <= #items do
      local index = next_index
      local item = items[index]
      next_index = next_index + 1
      active = active + 1
      local settled = false
      opts.start(item, function(result)
        if cancelled or settled then return end
        settled = true
        active = active - 1
        completed = completed + 1
        if index <= first_wave then
          first_wave_done = first_wave_done + 1
        end
        if opts.settle then opts.settle(item, result) end
        if not preview_sent and first_wave_done == first_wave then
          preview_sent = true
          opts.phase("preview")
        end
        if completed == #items then
          opts.phase("complete")
        else
          pump()
        end
      end)
    end
  end

  opts.phase("loading")
  if #items == 0 then
    opts.phase("complete")
  else
    pump()
  end

  return {
    cancel = function()
      cancelled = true
    end,
  }
end

return M
