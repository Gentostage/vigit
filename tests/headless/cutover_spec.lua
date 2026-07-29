local Fixture = require("tests.fixtures.git_repo")
local controller = require("vigit.ui.controller")

local expected_commands = {
  "Vigit",
  "VigitComments",
  "VigitHelp",
  "VigitInstallCodexSkill",
  "VigitLog",
  "VigitMigrateReviews",
  "VigitV2",
  "VigitWorktrees",
}

local function close_session(session)
  if session and not session.closed then
    controller.dispatch(session, "close")
  end
end

local function command_names(calls)
  local names = {}
  for name in pairs(calls) do names[#names + 1] = name end
  table.sort(names)
  return names
end

it("cuts every public command over once to the shared v2 lifecycle", function()
  local repo = Fixture.new()
  local session
  local calls = {}
  local original_create_user_command = vim.api.nvim_create_user_command
  local ok, message = xpcall(function()
    vim.api.nvim_create_user_command = function(name, callback, opts)
      calls[name] = (calls[name] or 0) + 1
      return original_create_user_command(name, callback, opts)
    end

    local plugin = require("vigit")
    assert_equal(plugin.setup({ refresh = { debounce_ms = 25 } }), true)
    assert_equal(plugin.setup({ refresh = { debounce_ms = 25 } }), true)
    assert_equal(
      table.concat(command_names(calls), "\n"),
      table.concat(expected_commands, "\n")
    )
    for _, name in ipairs(expected_commands) do
      assert_equal(calls[name], 1)
      assert_equal(vim.fn.exists(":" .. name), 2)
    end
    assert_equal(#vim.api.nvim_get_autocmds({ group = "VigitRefreshObservers" }), 2)

    repo:write("README.md", { "fixture" })
    repo:git({ "add", "--", "README.md" })
    repo:commit("initial")
    vim.fn.mkdir(repo.root .. "/nested", "p")

    vim.cmd("Vigit " .. vim.fn.fnameescape(repo.root))
    session = assert(plugin.active_session())
    vim.cmd("VigitV2 " .. vim.fn.fnameescape(repo.root .. "/nested"))

    local alias = require("vigit.v2")
    assert_equal(alias, plugin)
    assert_equal(alias.active_session(), session)
    assert_equal(plugin.open({ cwd = repo.root }), session)

    vim.cmd("VigitComments")
    assert_equal(vim.bo[0].filetype, "vigit-comments")
    vim.api.nvim_feedkeys("q", "x", false)
    assert_truthy(vim.wait(1000, function()
      return session.owned.comments_win == nil
    end, 10))

    vim.cmd("VigitWorktrees")
    assert_equal(vim.bo[0].filetype, "vigit-worktrees")
    vim.api.nvim_feedkeys("q", "x", false)

    vim.cmd("VigitHelp")
    assert_equal(vim.bo[0].filetype, "vigit-help")
    vim.api.nvim_feedkeys("q", "x", false)
  end, debug.traceback)

  vim.api.nvim_create_user_command = original_create_user_command
  close_session(session)
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("keeps the compatibility command on independent canonical-root sessions", function()
  local first = Fixture.new()
  local second = Fixture.new()
  local sessions = {}
  local ok, message = xpcall(function()
    for _, repo in ipairs({ first, second }) do
      repo:write("README.md", { "fixture" })
      repo:git({ "add", "--", "README.md" })
      repo:commit("initial")
    end
    vim.fn.mkdir(first.root .. "/nested", "p")

    local vigit = require("vigit.v2")
    vim.cmd("VigitV2 " .. vim.fn.fnameescape(first.root))
    sessions[1] = assert(vigit.active_session())
    vim.cmd("VigitV2 " .. vim.fn.fnameescape(second.root))
    sessions[2] = assert(vigit.active_session())
    assert_truthy(sessions[1] ~= sessions[2])

    vim.cmd("VigitV2 " .. vim.fn.fnameescape(first.root .. "/nested"))
    assert_equal(vigit.active_session(), sessions[1])
    assert_equal(sessions[2].closed, false)
  end, debug.traceback)

  for _, session in ipairs(sessions) do close_session(session) end
  first:cleanup()
  second:cleanup()
  if not ok then error(message, 0) end
end)
