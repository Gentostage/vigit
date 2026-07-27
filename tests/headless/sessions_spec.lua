local Fixture = require("tests.fixtures.git_repo")
local v2 = require("vigit.v2")
local neovim = require("vigit.adapters.neovim")
local controller = require("vigit.ui.controller")
local layout = require("vigit.ui.layout")
local keymaps = require("vigit.ui.keymaps")
local changes_view = require("vigit.ui.views.changes")
local diff_view = require("vigit.ui.views.diff")

local function cleanup_fixtures(fixtures)
  for _, fixture in ipairs(fixtures) do
    fixture:cleanup()
  end
end

local function close_session(session)
  if session and not session.closed then
    controller.dispatch(session, "close")
  end
end

local function buffer_lines(buffer)
  return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
end

local function find_line(buffer, pattern)
  for row, line in ipairs(buffer_lines(buffer)) do
    if line:find(pattern, 1, true) then
      return row
    end
  end
end

local function owned_buffer_count(session)
  local count = 0
  for key, handle in pairs(session.owned) do
    if key:sub(-4) == "_buf" then
      count = count + 1
      assert_equal(vim.bo[handle].buftype, "nofile")
      assert_equal(vim.bo[handle].bufhidden, "wipe")
      assert_equal(vim.bo[handle].swapfile, false)
      assert_equal(vim.bo[handle].modifiable, false)
    end
  end
  return count
end

it("resolves root, nested and symlink paths to one canonical repository", function()
  local repo = Fixture.new()
  local link = vim.fn.tempname()
  local worktree = vim.fn.tempname()
  local nonrepo = vim.fn.tempname()
  local ok, message = xpcall(function()
    vim.fn.mkdir(repo.root .. "/src/nested", "p")
    assert_equal(vim.uv.fs_symlink(repo.root, link, { dir = true }), true)
    vim.fn.mkdir(nonrepo, "p")
    repo:write("README.md", { "fixture" })
    repo:git({ "add", "--", "README.md" })
    repo:commit("initial")
    repo:git({ "worktree", "add", "-q", "-b", "linked-test", worktree })

    local canonical = assert(vim.uv.fs_realpath(repo.root))
    assert_equal(neovim.find_repo_root(repo.root).value, canonical)
    assert_equal(neovim.find_repo_root(repo.root .. "/src/nested").value, canonical)
    assert_equal(neovim.find_repo_root(link).value, canonical)
    assert_equal(vim.uv.fs_stat(worktree .. "/.git").type, "file")
    assert_equal(
      neovim.find_repo_root(worktree).value,
      assert(vim.uv.fs_realpath(worktree))
    )

    local missing = neovim.find_repo_root(nonrepo)
    assert_equal(missing.ok, false)
    assert_equal(missing.error.code, "not_repository")
  end, debug.traceback)

  vim.fn.delete(link)
  vim.fn.delete(worktree, "rf")
  vim.fn.delete(nonrepo, "rf")
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("owns one isolated review tab and two nofile buffers per canonical root", function()
  local repo_a = Fixture.new()
  local repo_b = Fixture.new()
  local sessions = {}
  local original_cwd = vim.fn.getcwd(-1, -1)
  local ok, message = xpcall(function()
    local a = assert(v2.open({ cwd = repo_a.root }))
    local b = assert(v2.open({ cwd = repo_b.root }))
    sessions = { a, b }

    assert_truthy(a.id ~= b.id)
    assert_truthy(a.root ~= b.root)
    assert_truthy(vim.api.nvim_tabpage_is_valid(a.owned.tab))
    assert_truthy(vim.api.nvim_tabpage_is_valid(b.owned.tab))
    assert_equal(owned_buffer_count(a), 2)
    assert_equal(owned_buffer_count(b), 2)
    assert_equal(#vim.api.nvim_tabpage_list_wins(a.owned.tab), 2)
    assert_equal(#vim.api.nvim_tabpage_list_wins(b.owned.tab), 2)
    assert_truthy(a.owned.diff_buf ~= b.owned.diff_buf)
    assert_truthy(a.owned.changes_buf ~= b.owned.changes_buf)

    local again = assert(v2.open({ cwd = repo_a.root .. "/" }))
    assert_equal(again.id, a.id)
    assert_equal(vim.api.nvim_get_current_tabpage(), a.owned.tab)
    assert_equal(vim.fn.getcwd(-1, -1), original_cwd)
    assert_equal(vim.fn.getcwd(0, 0), original_cwd)

    vim.api.nvim_set_current_win(a.owned.changes_win)
    for _, lhs in ipairs({ "<Tab>", "<CR>", "]f", "[f", "a", "t", "r", "q" }) do
      assert_equal(vim.fn.maparg(lhs, "n", false, true).buffer, 1)
    end
    vim.api.nvim_set_current_win(a.owned.diff_win)
    assert_equal(vim.fn.maparg("q", "n", false, true).buffer, 1)
    vim.api.nvim_feedkeys("q", "x", false)
    assert_truthy(vim.wait(1000, function()
      return a.closed
    end, 10))

    assert_equal(vim.api.nvim_tabpage_is_valid(a.owned.tab), false)
    assert_truthy(vim.api.nvim_tabpage_is_valid(b.owned.tab))
    assert_equal(b.closed, false)
    assert_equal(vim.fn.getcwd(-1, -1), original_cwd)
  end, debug.traceback)

  for _, session in ipairs(sessions) do
    close_session(session)
  end
  cleanup_fixtures({ repo_a, repo_b })
  if not ok then
    error(message, 0)
  end
end)

it("disposes a session when its owned tab is closed manually", function()
  local repo = Fixture.new()
  local session
  local reopened
  local ok, message = xpcall(function()
    session = assert(v2.open({ cwd = repo.root }))
    local generation = session.reads.generation
    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.cmd("tabclose")

    assert_truthy(vim.wait(1000, function()
      return session.closed
    end, 10))
    assert_truthy(session.reads.generation > generation)
    assert_equal(next(session.reads.jobs), nil)

    reopened = assert(v2.open({ cwd = repo.root }))
    assert_truthy(reopened.id ~= session.id)
  end, debug.traceback)

  close_session(reopened)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("closes the remaining owned tab when either owned buffer is wiped directly", function()
  local repo = Fixture.new()
  local session
  local owned_tab
  local ok, message = xpcall(function()
    for _, key in ipairs({ "diff_buf", "changes_buf" }) do
      session = assert(v2.open({ cwd = repo.root }))
      owned_tab = session.owned.tab
      vim.api.nvim_buf_delete(session.owned[key], { force = true })

      assert_truthy(vim.wait(1000, function()
        return session.closed and not vim.api.nvim_tabpage_is_valid(owned_tab)
      end, 10))
    end
  end, debug.traceback)

  if owned_tab and vim.api.nvim_tabpage_is_valid(owned_tab) then
    vim.api.nvim_set_current_tabpage(owned_tab)
    vim.cmd("tabclose")
  end
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("renders status before an explicitly selected diff and dispatches cursor selection", function()
  local repo = Fixture.new()
  local session
  local ok, message = xpcall(function()
    repo:write("tracked.lua", { "return 'old'" })
    repo:git({ "add", "--", "tracked.lua" })
    repo:commit("initial")
    repo:write("tracked.lua", { "return 'new'" })

    session = assert(v2.open({ cwd = repo.root }))
    assert_equal(buffer_lines(session.owned.diff_buf)[1], "Loading changes…")
    assert_truthy(vim.wait(2000, function()
      return session.data.status ~= nil and session.busy.status == nil
    end, 10))
    assert_equal(next(session.data.diffs), nil)

    local row = assert(find_line(session.owned.changes_buf, "tracked.lua"))
    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.api.nvim_set_current_win(session.owned.changes_win)
    vim.api.nvim_win_set_cursor(session.owned.changes_win, { row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = session.owned.changes_buf })

    assert_truthy(vim.wait(2000, function()
      return session.view.selected_change_id == "unstaged\0tracked.lua"
        and session.data.diffs[session.view.selected_change_id] ~= nil
    end, 10))
    assert_truthy(find_line(session.owned.diff_buf, "@@"))

    vim.api.nvim_set_current_win(session.owned.diff_win)
    controller.dispatch(session, "next_file")
    assert_equal(vim.api.nvim_get_current_win(), session.owned.diff_win)
    controller.dispatch(session, "previous_file")
    assert_equal(vim.api.nvim_get_current_win(), session.owned.diff_win)
  end, debug.traceback)

  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("loads all diffs when all-files is selected before initial status completes", function()
  local repo = Fixture.new()
  local session
  local ok, message = xpcall(function()
    repo:write("tracked.lua", { "return 'old'" })
    repo:git({ "add", "--", "tracked.lua" })
    repo:commit("initial")
    repo:write("tracked.lua", { "return 'new'" })

    session = assert(v2.open({ cwd = repo.root }))
    controller.dispatch(session, "toggle_all_files")
    assert_equal(session.view.diff_mode, "all_files")
    assert_truthy(vim.wait(2000, function()
      return session.data.status ~= nil
        and session.data.diffs["unstaged\0tracked.lua"] ~= nil
    end, 10))

    local first_diff = session.data.diffs["unstaged\0tracked.lua"]
    local generation = session.reads.generation
    controller.dispatch(session, "refresh")
    assert_truthy(vim.wait(2000, function()
      return session.reads.generation > generation
        and session.data.diffs["unstaged\0tracked.lua"] ~= nil
        and session.data.diffs["unstaged\0tracked.lua"] ~= first_diff
    end, 10))
  end, debug.traceback)

  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("keeps changes in a toggleable overlay below eighty columns", function()
  local repo = Fixture.new()
  local session
  local original_columns = vim.o.columns
  local ok, message = xpcall(function()
    vim.o.columns = 79
    session = assert(v2.open({ cwd = repo.root }))
    local config = vim.api.nvim_win_get_config(session.owned.changes_win)
    assert_equal(config.relative, "editor")
    assert_truthy(config.width >= 24 and config.width <= 36)

    vim.api.nvim_set_current_win(session.owned.changes_win)
    controller.dispatch(session, "toggle_focus")
    assert_equal(vim.api.nvim_win_is_valid(session.owned.changes_win), false)
    assert_equal(vim.api.nvim_get_current_win(), session.owned.diff_win)

    controller.dispatch(session, "toggle_focus")
    assert_truthy(vim.api.nvim_win_is_valid(session.owned.changes_win))
    assert_equal(vim.api.nvim_win_get_config(session.owned.changes_win).relative, "editor")

    vim.o.columns = 100
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert_truthy(vim.wait(1000, function()
      return vim.api.nvim_win_is_valid(session.owned.changes_win)
        and vim.api.nvim_win_get_config(session.owned.changes_win).relative == ""
    end, 10))
    assert_equal(vim.api.nvim_win_get_config(session.owned.changes_win).relative, "")
    assert_equal(vim.api.nvim_get_current_win(), session.owned.changes_win)

    vim.o.columns = 79
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert_truthy(vim.wait(1000, function()
      return vim.api.nvim_win_is_valid(session.owned.changes_win)
        and vim.api.nvim_win_get_config(session.owned.changes_win).relative == "editor"
    end, 10))
    assert_equal(vim.api.nvim_get_current_win(), session.owned.changes_win)
  end, debug.traceback)

  vim.o.columns = original_columns
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("returns file hit targets and marker-free view models", function()
  local long_line = string.rep("x", 120)
  local state = {
    view = {
      changes_mode = "list",
      diff_mode = "one_file",
      selected_change_id = "unstaged\0src/a.lua",
      all_files = { loaded = {}, loading = {} },
    },
    data = {
      status = {
        branch = { head = "feature/ui" },
        staged = {},
        unstaged = {
          {
            id = "unstaged\0src/a.lua",
            section = "unstaged",
            status = "M",
            path = "src/a.lua",
          },
        },
      },
      diffs = {
        ["unstaged\0src/a.lua"] = {
          path = "src/a.lua",
          section = "unstaged",
          status = "M",
          headers = {},
          hunks = {
            {
              header = "@@ -1 +1 @@",
              lines = {
                { kind = "delete", text = "return false", old_line = 1 },
                { kind = "add", text = "return true", new_line = 1 },
                { kind = "context", text = long_line, old_line = 2, new_line = 2 },
              },
            },
          },
        },
      },
    },
    busy = { diff = {} },
  }

  local changes = changes_view.render(state, 32)
  assert_equal(#changes.targets, 1)
  assert_equal(changes.targets[1].change_id, "unstaged\0src/a.lua")
  assert_truthy(changes.lines[changes.targets[1].row]:find("src/a.lua", 1, true))

  local diff = diff_view.render(state, 20)
  local hunk_row
  for row, line in ipairs(diff.lines) do
    if line == "@@ -1 +1 @@" then
      hunk_row = row
      break
    end
  end
  assert_truthy(hunk_row)
  assert_equal(diff.lines[hunk_row + 1], "return false")
  assert_equal(diff.lines[hunk_row + 2], "return true")
  assert_equal(diff.lines[hunk_row + 3], long_line)
end)

it("publishes the basic normal-mode key registry", function()
  local expected = { "<Tab>", "<CR>", "]f", "[f", "a", "t", "r", "q" }
  assert_equal(#keymaps.entries, #expected)
  for index, entry in ipairs(keymaps.entries) do
    assert_equal(entry.lhs, expected[index])
    assert_equal(type(entry.modes), "table")
    assert_equal(entry.modes[1], "n")
    assert_truthy(type(entry.id) == "string" and entry.id ~= "")
    assert_truthy(type(entry.intent) == "string" and entry.intent ~= "")
  end
end)

it("registers VigitV2 without replacing the legacy Vigit command", function()
  local repo = Fixture.new()
  local session
  local ok, message = xpcall(function()
    require("vigit").setup()
    assert_equal(vim.fn.exists(":Vigit"), 2)
    assert_equal(vim.fn.exists(":VigitV2"), 2)

    vim.cmd("VigitV2 " .. vim.fn.fnameescape(repo.root))
    session = assert(v2.open({ cwd = repo.root }))
    assert_equal(vim.api.nvim_get_current_tabpage(), session.owned.tab)
  end, debug.traceback)

  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)
