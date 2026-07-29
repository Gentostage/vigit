local Fixture = require("tests.fixtures.git_repo")
local v2 = require("vigit.v2")
local neovim = require("vigit.adapters.neovim")
local controller = require("vigit.ui.controller")
local layout = require("vigit.ui.layout")
local keymaps = require("vigit.ui.keymaps")
local renderer = require("vigit.ui.renderer")
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
    for _, lhs in ipairs({
      "<Tab>",
      "<CR>",
      "]f",
      "e",
      "gd",
      "T",
      "[f",
      "a",
      "t",
      "r",
      "q",
    }) do
      assert_equal(vim.fn.maparg(lhs, "n", false, true).buffer, 1)
    end
    assert_equal(next(vim.fn.maparg("f", "n", false, true)), nil)
    vim.api.nvim_set_current_win(a.owned.diff_win)
    for _, lhs in ipairs({ "e", "gd", "T", "f", "q" }) do
      assert_equal(vim.fn.maparg(lhs, "n", false, true).buffer, 1)
    end
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

it("closes the last owned tab with q and cancels reads before disposal", function()
  local repo = Fixture.new()
  local session
  local reopened
  local owned_tab
  local cancelled = 0
  local ok, message = xpcall(function()
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function()
      return session.busy.status == nil
    end, 10))
    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.cmd("tabonly")
    owned_tab = session.owned.tab
    session.reads.jobs.probe = {
      handle = {
        cancel = function()
          cancelled = cancelled + 1
        end,
      },
    }

    vim.api.nvim_set_current_win(session.owned.diff_win)
    vim.api.nvim_feedkeys("q", "x", false)

    assert_truthy(vim.wait(1000, function()
      return session.closed
        and not vim.api.nvim_tabpage_is_valid(owned_tab)
    end, 10))
    assert_equal(cancelled, 1)
    assert_equal(#vim.api.nvim_list_tabpages(), 1)
    assert_truthy(vim.api.nvim_get_current_tabpage() ~= owned_tab)

    reopened = assert(v2.open({ cwd = repo.root }))
    assert_truthy(reopened.id ~= session.id)
  end, debug.traceback)

  if owned_tab and vim.api.nvim_tabpage_is_valid(owned_tab) then
    if #vim.api.nvim_list_tabpages() == 1 then
      vim.cmd("tabnew")
    end
    vim.api.nvim_set_current_tabpage(owned_tab)
    pcall(vim.cmd, "tabclose")
  end
  close_session(reopened)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("rolls back partial layout resources before returning an open error", function()
  local repo = Fixture.new()
  local reopened
  local original_create_buf = vim.api.nvim_create_buf
  local original_tabs = vim.api.nvim_list_tabpages()
  local original_tab_set = {}
  for _, tab in ipairs(original_tabs) do
    original_tab_set[tab] = true
  end

  local ok, message = xpcall(function()
    vim.api.nvim_create_buf = function()
      error("injected layout failure")
    end
    local session, open_error = v2.open({ cwd = repo.root })
    vim.api.nvim_create_buf = original_create_buf

    assert_equal(session, nil)
    assert_equal(open_error.code, "ui_open_failed")
    assert_equal(#vim.api.nvim_list_tabpages(), #original_tabs)
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      assert_truthy(not vim.api.nvim_buf_get_name(buffer):match("^vigit://"))
    end

    reopened = assert(v2.open({ cwd = repo.root }))
  end, debug.traceback)

  vim.api.nvim_create_buf = original_create_buf
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if not original_tab_set[tab] then
      vim.api.nvim_set_current_tabpage(tab)
      pcall(vim.cmd, "tabclose")
    end
  end
  close_session(reopened)
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

it("clears a stale branch after a successful detached status refresh", function()
  local repo = Fixture.new()
  local session
  local ok, message = xpcall(function()
    repo:write("tracked.lua", { "return true" })
    repo:git({ "add", "--", "tracked.lua" })
    repo:commit("initial")

    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function()
      return session.data.status ~= nil and session.busy.status == nil
    end, 10))
    assert_truthy(session.branch ~= nil)

    repo:git({ "checkout", "--detach", "-q" })
    local generation = session.reads.generation
    controller.dispatch(session, "refresh")
    assert_truthy(vim.wait(2000, function()
      return session.reads.generation > generation
        and session.busy.status == nil
    end, 10))
    assert_equal(session.data.status.branch.head, nil)
    assert_equal(session.branch, nil)
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
    local long_path = string.rep("long-name-", 12) .. ".lua"
    repo:write(long_path, { "return true" })
    vim.o.columns = 79
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(1000, function()
      return #renderer.file_targets(session) == 1
    end, 10))
    local config = vim.api.nvim_win_get_config(session.owned.changes_win)
    assert_equal(config.relative, "editor")
    assert_truthy(config.width >= 24 and config.width <= 36)

    vim.api.nvim_set_current_win(session.owned.changes_win)
    controller.dispatch(session, "toggle_focus")
    assert_equal(vim.api.nvim_win_is_valid(session.owned.changes_win), false)
    assert_equal(vim.api.nvim_get_current_win(), session.owned.diff_win)

    vim.api.nvim_exec_autocmds("VimResized", {})
    assert_equal(vim.api.nvim_win_is_valid(session.owned.changes_win), false)
    assert_equal(vim.api.nvim_get_current_win(), session.owned.diff_win)

    renderer.render(session)
    controller.dispatch(session, "toggle_focus")
    assert_truthy(vim.api.nvim_win_is_valid(session.owned.changes_win))
    assert_equal(vim.api.nvim_win_get_config(session.owned.changes_win).relative, "editor")
    local target = assert(renderer.file_targets(session)[1])
    local line = buffer_lines(session.owned.changes_buf)[target.row]
    assert_truthy(
      vim.fn.strdisplaywidth(line)
        <= vim.api.nvim_win_get_width(session.owned.changes_win)
    )

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

it("resizes hidden sessions on tab enter and repeated open", function()
  local repo_a = Fixture.new()
  local repo_b = Fixture.new()
  local sessions = {}
  local original_columns = vim.o.columns
  local ok, message = xpcall(function()
    vim.o.columns = 100
    local a = assert(v2.open({ cwd = repo_a.root }))
    local b = assert(v2.open({ cwd = repo_b.root }))
    sessions = { a, b }

    vim.o.columns = 79
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert_equal(vim.api.nvim_win_get_config(b.owned.changes_win).relative, "editor")
    assert_equal(vim.api.nvim_win_get_config(a.owned.changes_win).relative, "")

    vim.api.nvim_set_current_tabpage(a.owned.tab)
    assert_truthy(vim.wait(1000, function()
      return vim.api.nvim_win_get_config(a.owned.changes_win).relative == "editor"
    end, 10))

    vim.api.nvim_set_current_tabpage(b.owned.tab)
    vim.o.columns = 100
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert_equal(vim.api.nvim_win_get_config(b.owned.changes_win).relative, "")
    assert_equal(vim.api.nvim_win_get_config(a.owned.changes_win).relative, "editor")

    local again = assert(v2.open({ cwd = repo_a.root }))
    assert_equal(again.id, a.id)
    assert_truthy(vim.wait(1000, function()
      return vim.api.nvim_win_get_config(a.owned.changes_win).relative == ""
    end, 10))
  end, debug.traceback)

  vim.o.columns = original_columns
  for _, session in ipairs(sessions) do
    close_session(session)
  end
  cleanup_fixtures({ repo_a, repo_b })
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

it("keeps loaded code visible during refresh and renders typed file placeholders", function()
  local change = {
    id = "unstaged\0src/service.py",
    section = "unstaged",
    status = "M",
    path = "src/service.py",
  }
  local diff = {
    id = change.id,
    path = change.path,
    section = change.section,
    status = change.status,
    headers = {},
    hunks = {
      {
        header = "@@ -90 +90 @@",
        old_start = 90,
        old_count = 1,
        new_start = 90,
        new_count = 1,
        lines = {
          { kind = "delete", text = "value = \"old\"", old_line = 90 },
          { kind = "add", text = "value = \"new\"", new_line = 90 },
        },
      },
    },
  }
  local state = {
    view = {
      diff_mode = "one_file",
      selected_change_id = change.id,
      all_files = { loaded = {}, loading = {} },
    },
    data = {
      status = {
        staged = {},
        unstaged = { change },
      },
      diffs = {
        [change.id] = diff,
      },
    },
    busy = {
      status = true,
      diff = {
        [change.id] = true,
      },
    },
    errors = {
      diffs = {},
    },
  }

  local loading = diff_view.render(state, 100)
  assert_truthy(vim.tbl_contains(loading.lines, "Refreshing changes…"))
  assert_truthy(vim.tbl_contains(loading.lines, "Loading diff…"))
  assert_truthy(vim.tbl_contains(loading.lines, "value = \"old\""))
  assert_truthy(vim.tbl_contains(loading.lines, "value = \"new\""))

  state.busy.status = nil
  state.busy.diff[change.id] = nil
  state.errors.diffs[change.id] = {
    code = "diff_too_large",
    message = "Diff exceeds configured byte limit",
  }
  state.error = state.errors.diffs[change.id]

  local oversized = diff_view.render(state, 100)
  assert_equal(#oversized.lines, 2)
  assert_truthy(oversized.lines[2]:find("diff_too_large", 1, true))
  assert_truthy(oversized.lines[2]:find("Press e", 1, true))
  assert_equal(oversized.rows[2].kind, "file_placeholder")
  assert_equal(oversized.rows[2].path, change.path)
  assert_equal(oversized.rows[2].source_line, 1)
  assert_equal(oversized.rows[2].source_anchor.source_line, 1)
  assert_equal(oversized.rows[2].hunk_id, nil)
  assert_equal(vim.tbl_contains(oversized.lines, "value = \"old\""), false)
  assert_equal(vim.tbl_contains(oversized.lines, "value = \"new\""), false)
end)

it("renders a typed status failure in every diff mode without hiding retained rows", function()
  local change = {
    id = "unstaged\0src/service.py",
    section = "unstaged",
    status = "M",
    path = "src/service.py",
  }
  local status_error = {
    code = "git_status_failed",
    message = "Git status failed",
  }
  local stale_error = {
    code = "stale_error",
    message = "Must not be rendered",
  }
  local state = {
    view = {
      diff_mode = "all_files",
      selected_change_id = change.id,
      all_files = { loaded = {}, loading = {} },
    },
    data = {
      status = {
        staged = {},
        unstaged = { change },
      },
      diffs = {
        [change.id] = {
          id = change.id,
          path = change.path,
          section = change.section,
          status = change.status,
          headers = {},
          hunks = {
            {
              header = "@@ -1 +1 @@",
              old_start = 1,
              old_count = 1,
              new_start = 1,
              new_count = 1,
              lines = {
                { kind = "delete", text = "value = \"old\"", old_line = 1 },
                { kind = "add", text = "value = \"new\"", new_line = 1 },
              },
            },
          },
        },
      },
    },
    busy = { diff = {} },
    errors = {
      status = status_error,
      diffs = {},
    },
    error = status_error,
  }

  local all_files = diff_view.render(state, 100)
  assert_truthy(vim.tbl_contains(
    all_files.lines,
    "Error [git_status_failed]: Git status failed"
  ))
  assert_truthy(vim.tbl_contains(all_files.lines, "value = \"old\""))
  assert_truthy(vim.tbl_contains(all_files.lines, "value = \"new\""))
  assert_equal(vim.tbl_contains(all_files.lines, "Error [stale_error]: Must not be rendered"), false)

  state.view.diff_mode = "one_file"
  state.view.selected_change_id = "unstaged\0missing.py"
  local no_selection = diff_view.render(state, 100)
  assert_truthy(vim.tbl_contains(
    no_selection.lines,
    "Error [git_status_failed]: Git status failed"
  ))
  assert_truthy(vim.tbl_contains(no_selection.lines, "Select a change"))

  state.data.status = {
    staged = {},
    unstaged = {},
  }
  local empty = diff_view.render(state, 100)
  assert_truthy(vim.tbl_contains(
    empty.lines,
    "Error [git_status_failed]: Git status failed"
  ))
  assert_truthy(vim.tbl_contains(empty.lines, "No changes"))

  state.data.status = nil
  state.error = status_error
  local initial = diff_view.render(state, 100)
  assert_equal(
    initial.lines[1],
    "Error [git_status_failed]: Git status failed"
  )
end)

it("escapes control characters for display and preserves raw hit targets", function()
  local path = "dir/odd\nname\t" .. string.char(1) .. ".lua"
  local change = {
    id = "unstaged\0" .. path,
    section = "unstaged",
    status = "M",
    path = path,
  }
  local state = {
    view = {
      changes_mode = "list",
      diff_mode = "one_file",
      selected_change_id = change.id,
      all_files = { loaded = {}, loading = {} },
    },
    data = {
      status = {
        branch = {},
        staged = {},
        unstaged = { change },
      },
      diffs = {
        [change.id] = {
          path = path,
          section = "unstaged",
          status = "M",
          headers = {},
          hunks = {},
        },
      },
    },
    busy = { diff = {} },
  }

  local changes = changes_view.render(state, 80)
  local target = assert(changes.targets[1])
  assert_equal(changes.lines[target.row], "  M dir/odd\\nname\\t\\x01.lua")
  assert_equal(target.change.path, path)

  local diff = diff_view.render(state, 80)
  assert_equal(diff.lines[1], "[UNSTAGED] dir/odd\\nname\\t\\x01.lua")

  local newline_path = "name\n.lua"
  local literal_path = "name\\n.lua"
  local collision = changes_view.render({
    view = { changes_mode = "list" },
    data = {
      status = {
        staged = {},
        unstaged = {
          {
            id = "unstaged\0" .. newline_path,
            section = "unstaged",
            status = "M",
            path = newline_path,
          },
          {
            id = "unstaged\0" .. literal_path,
            section = "unstaged",
            status = "M",
            path = literal_path,
          },
        },
      },
    },
  }, 80)
  local first = collision.targets[1]
  local second = collision.targets[2]
  assert_truthy(collision.lines[first.row] ~= collision.lines[second.row])
  assert_equal(collision.lines[first.row], "  M name\\n.lua")
  assert_equal(collision.lines[second.row], "  M name\\\\n.lua")
  assert_equal(first.change.path, newline_path)
  assert_equal(second.change.path, literal_path)

  local error_state = {
    view = {},
    error = { message = "read failed\ntry again" },
  }
  assert_equal(
    changes_view.render(error_state, 80).lines[1],
    "Error: read failed\\ntry again"
  )
  assert_equal(
    diff_view.render(error_state, 80).lines[1],
    "Error: read failed\\ntry again"
  )
end)

it("shortens Unicode display text without splitting a codepoint", function()
  local path = "目录/файл-с-длинным-именем.lua"
  local change = {
    id = "unstaged\0" .. path,
    section = "unstaged",
    status = "M",
    path = path,
  }
  local state = {
    view = {
      changes_mode = "list",
      diff_mode = "one_file",
      selected_change_id = change.id,
      all_files = { loaded = {}, loading = {} },
    },
    data = {
      status = {
        branch = {},
        staged = {},
        unstaged = { change },
      },
      diffs = {
        [change.id] = {
          path = path,
          section = "unstaged",
          status = "M",
          headers = {},
          hunks = {},
        },
      },
    },
    busy = { diff = {} },
  }

  local changes_line = changes_view.render(state, 14).lines[2]
  local diff_line = diff_view.render(state, 14).lines[1]

  assert_truthy(pcall(vim.str_utfindex, changes_line))
  assert_truthy(pcall(vim.str_utfindex, diff_line))
  assert_truthy(vim.fn.strdisplaywidth(changes_line) <= 14)
  assert_truthy(vim.fn.strdisplaywidth(diff_line) <= 14)
  assert_truthy(changes_line:sub(-3) == "…")
  assert_truthy(diff_line:sub(-3) == "…")
end)

it("restores nomodifiable after a renderer exception", function()
  local repo = Fixture.new()
  local session
  local original_set_lines = vim.api.nvim_buf_set_lines
  local ok, message = xpcall(function()
    session = assert(v2.open({ cwd = repo.root }))
    vim.api.nvim_buf_set_lines = function(buffer, ...)
      if buffer == session.owned.changes_buf then
        error("injected render failure")
      end
      return original_set_lines(buffer, ...)
    end

    local rendered = pcall(renderer.render, session)
    vim.api.nvim_buf_set_lines = original_set_lines

    assert_equal(rendered, false)
    assert_equal(vim.bo[session.owned.changes_buf].modifiable, false)
  end, debug.traceback)

  vim.api.nvim_buf_set_lines = original_set_lines
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("clears stale hit targets after a partial renderer failure", function()
  local repo = Fixture.new()
  local session
  local original_clear_namespace = vim.api.nvim_buf_clear_namespace
  local ok, message = xpcall(function()
    repo:write("first.lua", { "return true" })
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(1000, function()
      return #renderer.file_targets(session) == 1
    end, 10))

    local old_target = renderer.file_targets(session)[1]
    session.data.status = {
      branch = {},
      staged = {},
      unstaged = {},
    }
    vim.api.nvim_buf_clear_namespace = function(buffer, ...)
      if buffer == session.owned.changes_buf then
        error("injected namespace failure")
      end
      return original_clear_namespace(buffer, ...)
    end

    local rendered = pcall(renderer.render, session)
    vim.api.nvim_buf_clear_namespace = original_clear_namespace

    assert_equal(rendered, false)
    assert_equal(buffer_lines(session.owned.changes_buf)[1], "No changes")
    assert_equal(#renderer.file_targets(session), 0)
    assert_equal(renderer.target_at(session.owned.changes_buf, old_target.row), nil)
    assert_equal(vim.bo[session.owned.changes_buf].modifiable, false)
  end, debug.traceback)

  vim.api.nvim_buf_clear_namespace = original_clear_namespace
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("publishes the basic normal-mode key registry", function()
  local expected = {
    "<Tab>",
    "<CR>",
    "]f",
    "e",
    "gd",
    "T",
    "f",
    "s",
    "S",
    "x",
    "X",
    "[f",
    "a",
    "t",
    "r",
    "c",
    "C",
    "P",
    "<CR>",
    "e",
    "d",
    "q",
    "<C-s>",
    "q",
    "<Esc>",
    "q",
    "W",
    "<CR>",
    "[w",
    "]w",
    "r",
    "F",
    "d",
    "q",
    "]h",
    "[h",
    "?",
    "q",
    "<Esc>",
  }
  assert_equal(#keymaps.entries, #expected)
  for index, entry in ipairs(keymaps.entries) do
    assert_equal(entry.lhs, expected[index])
    assert_equal(type(entry.modes), "table")
    assert_equal(entry.modes[1], "n")
    assert_truthy(type(entry.id) == "string" and entry.id ~= "")
    assert_truthy(type(entry.intent) == "string" and entry.intent ~= "")
  end
  assert_equal(keymaps.entries[9].intent, "toggle_hunk_index")
end)

it("validates setup options and registers commands only once", function()
  local repo = Fixture.new()
  local session
  local config = require("vigit.config")
  local command_calls = {}
  local original_create_user_command = vim.api.nvim_create_user_command
  local ok, message = xpcall(function()
    vim.api.nvim_create_user_command = function(name, callback, opts)
      command_calls[name] = (command_calls[name] or 0) + 1
      return original_create_user_command(name, callback, opts)
    end

    local plugin = require("vigit")
    local invalid, invalid_error = plugin.setup({
      ui = { changes_width = "wide" },
    })
    assert_equal(invalid, nil)
    assert_equal(invalid_error.code, "invalid_config")
    assert_equal(next(command_calls), nil)

    local configured, setup_error = plugin.setup({
      ui = { changes_width = 28 },
    })
    assert_equal(configured, true)
    assert_equal(setup_error, nil)
    assert_equal(config.get().ui.changes_width, 28)

    assert_equal(plugin.setup({ ui = { changes_width = 30 } }), true)
    assert_equal(config.get().ui.changes_width, 30)
    assert_equal(command_calls.Vigit, 1)
    assert_equal(command_calls.VigitV2, 1)
    assert_equal(command_calls.VigitMigrateReviews, 1)
    assert_equal(vim.fn.exists(":Vigit"), 2)
    assert_equal(vim.fn.exists(":VigitV2"), 2)
    assert_equal(vim.fn.exists(":VigitMigrateReviews"), 2)

    vim.cmd("VigitV2 " .. vim.fn.fnameescape(repo.root))
    session = assert(v2.open({ cwd = repo.root }))
    assert_equal(vim.api.nvim_get_current_tabpage(), session.owned.tab)
    if vim.o.columns >= 80 then
      assert_equal(vim.api.nvim_win_get_width(session.owned.changes_win), 30)
    end
  end, debug.traceback)

  vim.api.nvim_create_user_command = original_create_user_command
  config.setup(nil)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("notifies a typed VigitV2 command error outside a repository", function()
  local nonrepo = vim.fn.tempname()
  local notifications = {}
  local original_notify = vim.notify
  vim.fn.mkdir(nonrepo, "p")
  local ok, message = xpcall(function()
    vim.notify = function(text, level, opts)
      notifications[#notifications + 1] = {
        text = text,
        level = level,
        opts = opts,
      }
    end

    vim.cmd("VigitV2 " .. vim.fn.fnameescape(nonrepo))

    assert_equal(#notifications, 1)
    assert_truthy(notifications[1].text:find("not_repository", 1, true))
    assert_equal(notifications[1].level, vim.log.levels.ERROR)
    assert_equal(notifications[1].opts.title, "Vigit")
  end, debug.traceback)

  vim.notify = original_notify
  vim.fn.delete(nonrepo, "rf")
  if not ok then
    error(message, 0)
  end
end)
