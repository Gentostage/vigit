local function run(args, cwd)
  local result = vim.system(args, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    error((result.stderr or "") .. " for " .. table.concat(args, " "))
  end
end

it("loaded source inspection возвращает typed error вместо пустого списка", function()
  local neovim = require("vigit.adapters.neovim")
  local result = neovim.loaded_source_buffers(vim.fn.tempname())
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "repository_root_unavailable")
end)

it("loaded source inspection ignores missing outside paths and fails closed inside root", function()
  local Fixture = require("tests.fixtures.git_repo")
  local neovim = require("vigit.adapters.neovim")
  local repo = Fixture.new()
  local outside_buffer
  local inside_buffer
  local ok, message = xpcall(function()
    repo:write("tracked.lua", { "return true" })
    repo:git({ "add", "tracked.lua" })
    repo:commit("initial")
    outside_buffer = vim.fn.bufadd(vim.fn.tempname())
    vim.fn.bufload(outside_buffer)
    local outside = neovim.loaded_source_buffers(repo.root)
    assert_truthy(outside.ok)
    inside_buffer = vim.fn.bufadd(repo.root .. "/missing.lua")
    vim.fn.bufload(inside_buffer)
    local result = neovim.loaded_source_buffers(repo.root)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "source_buffer_unavailable")
  end, debug.traceback)

  for _, buffer in ipairs({ outside_buffer, inside_buffer }) do
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("picker blocks removing its own linked worktree before confirmation", function()
  local Fixture = require("tests.fixtures.git_repo")
  local v2 = require("vigit.v2")
  local controller = require("vigit.ui.controller")
  local repo = Fixture.new()
  local linked = vim.fn.tempname()
  local session
  local picker
  local ok, message = xpcall(function()
    repo:write("README.md", { "fixture" })
    repo:git({ "add", "README.md" })
    repo:commit("initial")
    repo:git({ "worktree", "add", "-q", "-b", "linked", linked })
    session = assert(v2.open({ cwd = linked }))
    picker = assert(v2.worktrees({ session = session }))
    assert_truthy(vim.wait(2000, function()
      return picker.row_by_path[vim.uv.fs_realpath(linked)] ~= nil
    end, 10))
    local target_row = picker.row_by_path[vim.uv.fs_realpath(linked)]
    local target = picker.targets[1]
    for _, candidate in ipairs(picker.targets) do
      if candidate.path == vim.uv.fs_realpath(linked) then target = candidate; break end
    end
    target.entry.files = { staged = 0, unstaged = 0, untracked = 0 }
    target.entry.upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 }
    local confirmations = 0
    picker.app.confirm = function() confirmations = confirmations + 1 end
    vim.api.nvim_win_set_cursor(picker.win, { target_row, 0 })
    picker:remove()
    assert_equal(picker.error.code, "picker_origin")
    assert_equal(confirmations, 0)
    assert_equal(session.closed, false)
    assert_truthy(vim.api.nvim_win_is_valid(picker.win))
  end, debug.traceback)

  if picker and not picker.closed then picker:close() end
  if session and not session.closed then controller.dispatch(session, "abandon") end
  vim.fn.delete(linked, "rf")
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("d закрывает только Vigit-сессию удалённого worktree и обновляет origin picker", function()
  local Fixture = require("tests.fixtures.git_repo")
  local v2 = require("vigit.v2")
  local controller = require("vigit.ui.controller")
  local repo = Fixture.new()
  local remote = vim.fn.tempname()
  local linked = vim.fn.tempname()
  local root_session
  local linked_session
  local picker
  local ok, message = xpcall(function()
    repo:write("README.md", { "fixture" })
    repo:git({ "add", "README.md" })
    repo:commit("initial")
    repo:git({ "branch", "-M", "main" })
    run({ "git", "init", "-q", "--bare", remote })
    repo:git({ "remote", "add", "origin", remote })
    repo:git({ "push", "-q", "-u", "origin", "main" })
    repo:git({ "worktree", "add", "-q", "-b", "linked", linked, "main" })
    run({ "git", "push", "-q", "-u", "origin", "linked" }, linked)

    root_session = assert(v2.open({ cwd = repo.root }))
    linked_session = assert(v2.open({ cwd = linked }))
    assert_equal(assert(v2.open({ cwd = repo.root })), root_session)
    picker = assert(v2.worktrees({ session = root_session }))
    assert_truthy(vim.wait(2000, function()
      local target_path = vim.uv.fs_realpath(linked)
      for _, row in ipairs(picker.rows) do
        if row.path == target_path then return row.loading == false end
      end
      return false
    end, 10))
    picker.app.confirm = function(_, callback)
      callback(true)
      return { cancel = function() end }
    end
    vim.api.nvim_win_set_cursor(picker.win, { picker.row_by_path[vim.uv.fs_realpath(linked)], 0 })
    picker:remove()
    assert_truthy(vim.wait(3000, function()
      return linked_session.closed
        and picker.row_by_path[vim.uv.fs_realpath(linked)] == nil
    end, 10))
    assert_truthy(vim.api.nvim_win_is_valid(picker.win))
    assert_equal(root_session.closed, false)
  end, debug.traceback)

  if picker and not picker.closed then picker:close() end
  if linked_session and not linked_session.closed then controller.dispatch(linked_session, "abandon") end
  if root_session and not root_session.closed then controller.dispatch(root_session, "abandon") end
  vim.fn.delete(linked, "rf")
  vim.fn.delete(remote, "rf")
  repo:cleanup()
  if not ok then error(message, 0) end
end)
