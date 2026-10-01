local Fixture = require("tests.fixtures.git_repo")
local config = require("vigit.config")
local controller = require("vigit.ui.controller")
local layout = require("vigit.ui.layout")
local vigit = require("vigit")

local function with_repos(fn)
  local first, second = Fixture.new(), Fixture.new()
  local sessions, buffers = {}, {}
  local ok, message = xpcall(function() fn(first, second, sessions, buffers) end, debug.traceback)
  for _, session in ipairs(sessions) do
    if not session.closed then controller.dispatch(session, "abandon") end
  end
  for _, buffer in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then
      local job = vim.b[buffer].terminal_job_id
      if type(job) == "number" then pcall(vim.fn.jobstop, job) end
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  config.setup(nil)
  first:cleanup()
  second:cleanup()
  if not ok then error(message, 0) end
end

it("close освобождает только cached root и сохраняет active review, focus и cwd", function()
  with_repos(function(first, second, sessions)
    sessions[1] = assert(vigit.open({ cwd = first.root }))
    sessions[2] = assert(vigit.open({ cwd = second.root }))
    local window, buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local cwd, global_cwd = vim.fn.getcwd(), vim.fn.getcwd(-1, -1)

    assert_equal(vigit.close({ cwd = first.root }), true)

    assert_equal(sessions[1].closed, true)
    assert_equal(vigit.active_session(), sessions[2])
    assert_truthy(layout.is_visible(sessions[2]))
    assert_equal(sessions[2].workspace:mode_name(), "review")
    assert_equal(vim.api.nvim_get_current_win(), window)
    assert_equal(vim.api.nvim_get_current_buf(), buffer)
    assert_equal(vim.fn.getcwd(), cwd)
    assert_equal(vim.fn.getcwd(-1, -1), global_cwd)
    assert_equal(vigit.close({ cwd = first.root }), false)
    local reopened = assert(vigit.open({ cwd = first.root }))
    assert_truthy(reopened ~= sessions[1])
    sessions[3] = reopened
  end)
end)

it("close active root скрывает его UI и сохраняет source buffer, terminal и другие sessions", function()
  with_repos(function(first, second, sessions, buffers)
    second:write("source.lua", { "saved = true" })
    sessions[1] = assert(vigit.open({ cwd = first.root }))
    sessions[2] = assert(vigit.open({ cwd = second.root }))
    local buffer = vim.fn.bufadd(second.root .. "/source.lua")
    buffers[1] = buffer
    vim.fn.bufload(buffer)
    vim.api.nvim_win_set_buf(sessions[2].workspace.code_win, buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "unsaved = true" })
    controller.dispatch(sessions[2], "open_terminal")
    local terminal = sessions[2].resources.terminal
    buffers[2] = terminal.buf
    local cwd, global_cwd = vim.fn.getcwd(), vim.fn.getcwd(-1, -1)

    assert_equal(vigit.close({ cwd = second.root }), true)

    assert_equal(vigit.active_session(), nil)
    assert_equal(sessions[2].closed, true)
    assert_equal(sessions[1].closed, false)
    assert_equal(layout.is_visible(sessions[2]), false)
    assert_equal(vim.fn.getcwd(), cwd)
    assert_equal(vim.fn.getcwd(-1, -1), global_cwd)
    assert_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1], "unsaved = true")
    assert_equal(vim.bo[buffer].modified, true)
    assert_equal(vim.api.nvim_buf_is_valid(terminal.buf), true)
    assert_equal(vim.fn.jobwait({ terminal.job }, 0)[1], -1)
    assert_equal(vigit.open({ cwd = first.root }), sessions[1])
  end)
end)

it("close удалённого root не разрешает путь к родительскому repository", function()
  with_repos(function(first, _, sessions)
    first:write("initial.lua", { "return true" })
    first:git({ "add", "--", "initial.lua" })
    first:commit("initial")
    local linked = first.root .. "/linked"
    first:git({ "worktree", "add", "-q", "-b", "linked", linked })
    sessions[1] = assert(vigit.open({ cwd = first.root }))
    sessions[2] = assert(vigit.open({ cwd = linked }))
    assert_equal(vigit.open({ cwd = first.root }), sessions[1])
    first:git({ "worktree", "remove", "--", linked })

    sessions[2].mutations.active = true
    local allowed, guard_error = vigit.can_close({ cwd = linked .. "/" })
    assert_equal(allowed, nil)
    assert_equal(guard_error.code, "mutation_in_progress")
    sessions[2].mutations.active = false
    assert_equal(vigit.can_close({ cwd = linked }), true)

    assert_equal(vigit.close({ cwd = linked .. "/" }), true)

    assert_equal(sessions[2].closed, true)
    assert_equal(sessions[1].closed, false)
    assert_equal(vigit.active_session(), sessions[1])
    assert_equal(vigit.close({ cwd = linked }), false)
    assert_equal(vigit.can_close({ cwd = linked }), true)
  end)
end)

it("close валидирует root и возвращает false для отсутствующей session", function()
  for _, opts in ipairs({ false, {}, { cwd = "" }, { cwd = {} }, { cwd = "bad\0path" } }) do
    local returned, error = vigit.close(opts)
    assert_equal(returned, nil)
    assert_equal(error.code, "invalid_options")
  end
  local returned, error = vigit.close({ cwd = vim.fn.tempname() })
  assert_equal(returned, false)
  assert_equal(error, nil)
end)

it("close отменяет pending handoff только выбранной review session", function()
  with_repos(function(first, _, sessions)
    first:write("source.lua", { "old = true" })
    first:git({ "add", "--", "source.lua" })
    first:commit("initial")
    first:write("source.lua", { "new = true" })
    local completed, cancelled = nil, 0
    assert_equal(vigit.setup({ handlers = {
      open_file = function(_, done)
        completed = done
        return function() cancelled = cancelled + 1 end
      end,
    } }), true)
    sessions[1] = assert(vigit.open({ cwd = first.root }))
    assert_truthy(vim.wait(2000, function()
      return sessions[1].data.status and not sessions[1].busy.status
        and #require("vigit.ui.renderer").file_targets(sessions[1]) > 0
    end, 10))
    local target = require("vigit.ui.renderer").file_targets(sessions[1])[1]
    vim.api.nvim_set_current_win(sessions[1].owned.changes_win)
    vim.api.nvim_win_set_cursor(sessions[1].owned.changes_win, { target.row, 0 })
    controller.dispatch(sessions[1], "open_file")
    assert_equal(type(completed), "function")

    assert_equal(vigit.close({ cwd = first.root }), true)

    assert_equal(cancelled, 1)
    completed(require("vigit.core.result").ok(true))
    assert_equal(sessions[1].closed, true)
  end)
end)

it("close сохраняет busy mutation и unsaved comment editor", function()
  with_repos(function(first, _, sessions, buffers)
    sessions[1] = assert(vigit.open({ cwd = first.root }))
    sessions[1].mutations.active = true
    local returned, error = vigit.close({ cwd = first.root })
    assert_equal(returned, nil)
    assert_equal(error.code, "mutation_in_progress")
    assert_equal(sessions[1].closed, false)
    sessions[1].mutations.active = false
    local editor = vim.api.nvim_create_buf(false, false)
    buffers[1] = editor
    sessions[1].owned.comment_editor_buf = editor
    vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "unsaved comment" })
    returned, error = vigit.close({ cwd = first.root })
    assert_equal(returned, nil)
    assert_equal(error.code, "modified_comment_editor")
    assert_equal(sessions[1].closed, false)
    assert_equal(vim.api.nvim_buf_get_lines(editor, 0, -1, false)[1], "unsaved comment")
  end)
end)

it("can_close валидирует root и разрешает отсутствие matching session", function()
  local missing, missing_error = vigit.can_close()
  assert_equal(missing, nil)
  assert_equal(missing_error.code, "invalid_options")
  for _, opts in ipairs({ false, {}, { cwd = "" }, { cwd = {} }, { cwd = "bad\0path" } }) do
    local allowed, error = vigit.can_close(opts)
    assert_equal(allowed, nil)
    assert_equal(error.code, "invalid_options")
  end
  local allowed, error = vigit.can_close({ cwd = vim.fn.tempname() })
  assert_equal(allowed, true)
  assert_equal(error, nil)
end)

it("can_close active и cached root сохраняет review state, dirty source и terminal", function()
  with_repos(function(first, second, sessions, buffers)
    first:write("source.lua", { "saved = true" })
    sessions[1] = assert(vigit.open({ cwd = first.root }))
    local buffer = vim.fn.bufadd(first.root .. "/source.lua")
    buffers[1] = buffer
    vim.fn.bufload(buffer)
    vim.api.nvim_win_set_buf(sessions[1].workspace.code_win, buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "unsaved = true" })
    controller.dispatch(sessions[1], "open_terminal")
    local terminal = sessions[1].resources.terminal
    buffers[2] = terminal.buf
    sessions[2] = assert(vigit.open({ cwd = second.root }))
    local window, current_buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local cwd, global_cwd = vim.fn.getcwd(), vim.fn.getcwd(-1, -1)
    local generation = sessions[2].reads.generation

    assert_equal(vigit.can_close({ cwd = first.root }), true)
    assert_equal(vigit.can_close({ cwd = second.root }), true)

    assert_equal(sessions[1].closed, false)
    assert_equal(sessions[2].closed, false)
    assert_equal(vigit.active_session(), sessions[2])
    assert_truthy(layout.is_visible(sessions[2]))
    assert_equal(sessions[2].workspace:mode_name(), "review")
    assert_equal(sessions[2].reads.generation, generation)
    assert_equal(vim.api.nvim_get_current_win(), window)
    assert_equal(vim.api.nvim_get_current_buf(), current_buffer)
    assert_equal(vim.fn.getcwd(), cwd)
    assert_equal(vim.fn.getcwd(-1, -1), global_cwd)
    assert_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1], "unsaved = true")
    assert_equal(vim.bo[buffer].modified, true)
    assert_equal(vim.fn.jobwait({ terminal.job }, 0)[1], -1)
    assert_equal(vim.api.nvim_buf_is_valid(terminal.buf), true)
  end)
end)

it("can_close блокирует чистый Git root с unsaved Vigit comment и сохраняет editor", function()
  with_repos(function(first, _, sessions)
    first:write("source.lua", { "return true" })
    first:git({ "add", "--", "source.lua" })
    first:commit("initial")
    sessions[1] = assert(vigit.open({ cwd = first.root }))
    local editor = require("vigit.ui.views.comments").open_editor(
      sessions[1],
      sessions[1].review_service,
      { anchor = { path = "source.lua", line = 1, side = "new", section = "unstaged" } }
    )
    vim.api.nvim_buf_set_lines(editor.buf, 0, -1, false, { "unsaved Vigit comment" })
    assert_equal(first:git({ "status", "--porcelain" }).stdout, "")
    assert_equal(vim.bo[editor.buf].modified, true)
    local window, cwd = vim.api.nvim_get_current_win(), vim.fn.getcwd()

    local allowed, guard_error = vigit.can_close({ cwd = first.root })
    local closed, close_error = vigit.close({ cwd = first.root })

    assert_equal(allowed, nil)
    assert_equal(guard_error.code, "modified_comment_editor")
    assert_equal(closed, nil)
    assert_equal(close_error.code, guard_error.code)
    assert_equal(vigit.active_session(), sessions[1])
    assert_equal(sessions[1].closed, false)
    assert_equal(vim.api.nvim_get_current_win(), window)
    assert_equal(vim.fn.getcwd(), cwd)
    assert_equal(vim.api.nvim_win_is_valid(editor.win), true)
    assert_equal(vim.api.nvim_buf_get_lines(editor.buf, 0, -1, false)[1], "unsaved Vigit comment")
    vim.bo[editor.buf].modified = false
    assert_equal(vigit.can_close({ cwd = first.root }), true)
    assert_equal(sessions[1].closed, false)
  end)
end)

it("can_close проверяет mutation только выбранного canonical root", function()
  with_repos(function(first, second, sessions)
    sessions[1] = assert(vigit.open({ cwd = first.root }))
    sessions[2] = assert(vigit.open({ cwd = second.root }))
    sessions[1].mutations.active = true
    local window = vim.api.nvim_get_current_win()

    local allowed, guard_error = vigit.can_close({ cwd = first.root .. "/" })
    local closed, close_error = vigit.close({ cwd = first.root })

    assert_equal(allowed, nil)
    assert_equal(guard_error.code, "mutation_in_progress")
    assert_equal(closed, nil)
    assert_equal(close_error.code, guard_error.code)
    assert_equal(vigit.can_close({ cwd = second.root }), true)
    assert_equal(vigit.active_session(), sessions[2])
    assert_truthy(layout.is_visible(sessions[2]))
    assert_equal(vim.api.nvim_get_current_win(), window)
    assert_equal(sessions[1].closed, false)
    assert_equal(sessions[1].mutations.active, true)
    sessions[1].mutations.active = false
    assert_equal(vigit.can_close({ cwd = first.root }), true)
  end)
end)
