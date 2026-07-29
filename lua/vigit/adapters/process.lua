local Result = require("vigit.core.result")

local M = {}

function M.run(args, opts, callback)
  local called = false
  local function complete(result)
    if called then
      return
    end
    called = true
    if not result.ok then require("vigit.ui.log").push(result) end
    callback(result)
  end

  if type(args) ~= "table" or type(args[1]) ~= "string" then
    vim.schedule(function()
      complete(Result.err("invalid_command", "Command must be an argument array", {
        args = args, cwd = opts and opts.cwd,
      }))
    end)
    return { cancel = function() end }
  end

  opts = opts or {}
  local ok, system_or_error = pcall(vim.system, args, {
    cwd = opts.cwd,
    stdin = opts.stdin,
    text = false,
    timeout = opts.timeout_ms,
  }, vim.schedule_wrap(function(output)
    if output.code == 0 then
      complete(Result.ok(output))
    else
      complete(Result.err(
        "process_failed",
        "Process exited with code " .. output.code,
        {
          args = args,
          cwd = opts.cwd,
          exit_code = output.code,
          stderr = output.stderr,
        },
        true
      ))
    end
  end))

  if not ok then
    vim.schedule(function()
      complete(Result.err("process_unavailable", "Unable to start process", {
        args = args, cwd = opts.cwd, error = system_or_error,
      }))
    end)
    return { cancel = function() end }
  end

  local system = system_or_error
  return {
    cancel = function()
      if not system:is_closing() then
        system:kill("sigterm")
      end
    end,
  }
end

return M
