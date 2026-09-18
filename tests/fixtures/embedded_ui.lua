local M = {}

function M.new(root)
  local stdin = vim.uv.new_pipe(false)
  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)
  local replies, errors, sequence = {}, {}, 0
  local unpack = vim.mpack.Unpacker()
  local exited = false
  local handle
  handle = assert(vim.uv.spawn(vim.v.progpath, {
    args = { "--embed", "--clean", "-u", "NONE" },
    cwd = root,
    stdio = { stdin, stdout, stderr },
  }, function()
    exited = true
    if not handle:is_closing() then handle:close() end
  end))
  stdout:read_start(function(error, data)
    assert(not error, error)
    if not data then return end
    local position = 1
    while position <= #data do
      local message
      message, position = unpack(data, position)
      if message and message[1] == 1 then
        replies[message[2]] = message
      end
    end
  end)
  stderr:read_start(function(_, data)
    if data then errors[#errors + 1] = data end
  end)

  local ui = {}
  function ui:call(method, ...)
    sequence = sequence + 1
    local id = sequence
    stdin:write(vim.mpack.encode({ 0, id, method, { ... } }))
    local received = vim.wait(2000, function()
      return replies[id] ~= nil or exited
    end, 5)
    local reply = replies[id]
    replies[id] = nil
    assert(received and reply, "embedded Neovim did not reply: " .. table.concat(errors))
    if reply[3] ~= vim.NIL then error(vim.inspect(reply[3]), 2) end
    return reply[4]
  end
  function ui:lua(code, args)
    return self:call("nvim_exec_lua", code, args or {})
  end
  function ui:wait(timeout, condition)
    -- RPC calls use vim.wait too; nested vim.wait conditions can reset its timer.
    local deadline = vim.uv.hrtime() + timeout * 1000000
    repeat
      if condition() then return true end
      vim.wait(10)
    until vim.uv.hrtime() >= deadline
    return false
  end
  function ui:close()
    if not exited then
      stdin:write(vim.mpack.encode({ 2, "nvim_command", { "qa!" } }))
      if not vim.wait(1000, function() return exited end, 5) then
        handle:kill("sigterm")
        vim.wait(1000, function() return exited end, 5)
      end
    end
    for _, pipe in ipairs({ stdin, stdout, stderr }) do
      if not pipe:is_closing() then pipe:close() end
    end
  end
  ui:call("nvim_ui_attach", 100, 30, { rgb = true, ext_linegrid = true })
  return ui
end

return M
