local Result = require("vigit.core.result")

local function fresh_log()
  package.loaded["vigit.ui.log"] = nil
  return require("vigit.ui.log")
end

it("keeps the newest 200 diagnostic errors with their context", function()
  local log = fresh_log()
  for index = 1, 201 do
    log.push({
      session_id = "vigit-7",
      code = "failure_" .. index,
      message = "Failure " .. index,
      details = { args = { "git", "status" }, cwd = "/repo", exit_code = 17 },
    })
  end

  local entries = log.entries()
  assert_equal(#entries, 200)
  assert_equal(entries[1].code, "failure_2")
  assert_equal(entries[#entries].session_id, "vigit-7")
  assert_equal(entries[#entries].details.exit_code, 17)
  assert_truthy(type(entries[#entries].timestamp) == "string")
end)

it("does not turn a successful Result into a diagnostic", function()
  local log = fresh_log()
  assert_equal(log.push(Result.ok("not an error")), nil)
  assert_equal(#log.entries(), 0)

  log.push(Result.err("git_failed", "Git failed", { args = { "git", "status" } }))
  assert_equal(log.entries()[1].code, "git_failed")
end)

it("renders escaped diagnostic details without control bytes", function()
  local log = fresh_log()
  log.push({
    code = "process_failed",
    message = "Process failed\7",
    details = { stderr = "bad\0output", args = { "git", "status" } },
  })

  local rendered = table.concat(log.lines(), "\n")
  assert_truthy(rendered:find("\\x07", 1, true) ~= nil)
  assert_truthy(rendered:find("\\x00", 1, true) ~= nil)
  assert_equal(rendered:find("\7", 1, true), nil)
  assert_equal(rendered:find("\0", 1, true), nil)
end)

it("records structured process failure details before callbacks", function()
  local log = fresh_log()
  local old_vim = _G.vim
  local completed
  _G.vim = {
    schedule = function(callback) callback() end,
    schedule_wrap = function(callback) return callback end,
    system = function(args, opts, callback)
      callback({ code = 17, stderr = "fatal: failed" })
      return { is_closing = function() return true end }
    end,
  }
  local ok, message = pcall(function()
    require("vigit.adapters.process").run({ "git", "status" }, { cwd = "/repo" }, function(result)
      completed = result
    end)
  end)
  _G.vim = old_vim
  if not ok then error(message, 0) end

  assert_equal(completed.ok, false)
  assert_equal(completed.error.details, {
    args = { "git", "status" }, cwd = "/repo", exit_code = 17, stderr = "fatal: failed",
  })
  assert_equal(log.entries()[1].details, completed.error.details)
end)
