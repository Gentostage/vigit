local Result = require("vigit.core.result")
local Session = require("vigit.ui.session")

local function change(section, path)
  return {
    id = section .. "\0" .. path,
    section = section,
    status = "M",
    path = path,
  }
end

local function status(staged, unstaged)
  return {
    branch = {},
    staged = staged or {},
    unstaged = unstaged or {},
  }
end

local function new_session(id, staged, unstaged)
  local session = Session.new({ id = id, root = "/repo" })
  session.owned.changes_win = id .. "-changes-win"
  session.owned.changes_buf = id .. "-changes-buf"
  session.owned.diff_win = id .. "-diff-win"
  session.owned.diff_buf = id .. "-diff-buf"
  session.data.status = status(staged, unstaged)
  return session
end

local function with_controller(body)
  local previous_controller = package.loaded["vigit.ui.controller"]
  local previous_renderer = package.loaded["vigit.ui.renderer"]
  local previous_layout = package.loaded["vigit.ui.layout"]
  local previous_diff_view = package.loaded["vigit.ui.views.diff"]
  local original_api = {
    current_win = vim.api.nvim_get_current_win,
    set_current_win = vim.api.nvim_set_current_win,
    win_is_valid = vim.api.nvim_win_is_valid,
    win_get_cursor = vim.api.nvim_win_get_cursor,
    win_set_cursor = vim.api.nvim_win_set_cursor,
    win_get_width = vim.api.nvim_win_get_width,
    buf_is_valid = vim.api.nvim_buf_is_valid,
  }
  local targets = {}
  local current_win
  local cursors = {}
  local renders = 0
  local changes

  local function selected_change(session)
    for _, section in ipairs({ "staged", "unstaged" }) do
      for _, item in ipairs(session.data.status[section] or {}) do
        if item.id == session.view.selected_change_id then
          return item
        end
      end
    end
  end

  package.loaded["vigit.ui.renderer"] = {
    target_at = function(buffer, row)
      return targets[buffer] and targets[buffer][row]
    end,
    render = function()
      renders = renders + 1
    end,
    file_targets = function(session)
      local result = {}
      for _, section in ipairs({ "staged", "unstaged" }) do
        for _, item in ipairs(session.data.status[section] or {}) do
          result[#result + 1] = {
            kind = "change",
            change_id = item.id,
            change = item,
          }
        end
      end
      return result
    end,
    clear = function() end,
  }
  package.loaded["vigit.ui.layout"] = {
    toggle_changes = function() end,
    resize = function() end,
    abandon = function() end,
    close = function() end,
  }
  package.loaded["vigit.ui.views.diff"] = {
    render = function(session)
      local item = selected_change(session)
      if not item then
        return { rows = {} }
      end
      return {
        rows = {
          {
            kind = "context",
            path = item.path,
            section = item.section,
            hunk_id = "hunk",
            side = "new",
            source_line = 7,
            text = "anchor line",
          },
        },
      }
    end,
  }
  package.loaded["vigit.ui.controller"] = nil

  vim.api.nvim_get_current_win = function()
    return current_win
  end
  vim.api.nvim_set_current_win = function(window)
    current_win = window
  end
  vim.api.nvim_win_is_valid = function(window)
    return window ~= nil
  end
  vim.api.nvim_win_get_cursor = function(window)
    return cursors[window] or { 1, 0 }
  end
  vim.api.nvim_win_set_cursor = function(window, cursor)
    cursors[window] = cursor
  end
  vim.api.nvim_win_get_width = function()
    return 80
  end
  vim.api.nvim_buf_is_valid = function(buffer)
    return buffer ~= nil
  end

  local function set_target(session, item)
    targets[session.owned.changes_buf] = {
      [1] = {
        kind = "change",
        change_id = item.id,
      },
    }
    targets[session.owned.diff_buf] = {
      [1] = {
        kind = "context",
        change_id = item.id,
        hunk_id = "hunk",
        path = item.path,
        section = item.section,
        side = "new",
        source_line = 7,
        text = "anchor line",
      },
    }
    cursors[session.owned.changes_win] = { 1, 0 }
    cursors[session.owned.diff_win] = { 1, 0 }
  end

  local function setup(fake_git)
    changes = {
      git = fake_git,
      refresh = function(_, session, callback)
        callback({ phase = "status", result = Result.ok(session.data.status) })
      end,
      load_diff = function(_, _, _, _, _, callback)
        callback(Result.ok({}))
      end,
    }
    local controller = require("vigit.ui.controller")
    controller.configure({
      changes = changes,
      registry = { remove = function() end },
    })
    return controller
  end

  local ok, message = xpcall(function()
    body({
      setup = setup,
      set_target = set_target,
      set_current = function(session, view)
        current_win = view == "diff" and session.owned.diff_win or session.owned.changes_win
      end,
      set_raw_current = function(window)
        current_win = window
      end,
      current = function()
        return current_win
      end,
      renders = function()
        return renders
      end,
      cursor = function(session)
        return cursors[session.owned.diff_win]
      end,
    })
  end, debug.traceback)

  vim.api.nvim_get_current_win = original_api.current_win
  vim.api.nvim_set_current_win = original_api.set_current_win
  vim.api.nvim_win_is_valid = original_api.win_is_valid
  vim.api.nvim_win_get_cursor = original_api.win_get_cursor
  vim.api.nvim_win_set_cursor = original_api.win_set_cursor
  vim.api.nvim_win_get_width = original_api.win_get_width
  vim.api.nvim_buf_is_valid = original_api.buf_is_valid
  package.loaded["vigit.ui.controller"] = previous_controller
  package.loaded["vigit.ui.renderer"] = previous_renderer
  package.loaded["vigit.ui.layout"] = previous_layout
  package.loaded["vigit.ui.views.diff"] = previous_diff_view
  if not ok then
    error(message, 0)
  end
end

it("toggle_file_index chooses stage and unstage and restores the closest anchor", function()
  with_controller(function(harness)
    local unstaged = change("unstaged", "file.txt")
    local session = new_session("one", {}, { unstaged })
    local calls = {}
    local git = {}
    function git:stage_file(_, item, done)
      calls[#calls + 1] = "stage:" .. item.path
      session.data.status = status({ change("staged", item.path) }, {})
      done(Result.ok(true))
    end
    function git:unstage_file(_, item, done)
      calls[#calls + 1] = "unstage:" .. item.path
      session.data.status = status({}, { change("unstaged", item.path) })
      done(Result.ok(true))
    end
    local controller = harness.setup(git)

    harness.set_target(session, unstaged)
    harness.set_current(session, "diff")
    controller.dispatch(session, "toggle_file_index")
    assert_equal(calls[1], "stage:file.txt")
    assert_equal(session.view.selected_change_id, "staged\0file.txt")
    assert_equal(harness.cursor(session)[1], 1)
    assert_equal(harness.cursor(session)[2], 0)

    local staged = session.data.status.staged[1]
    harness.set_target(session, staged)
    controller.dispatch(session, "toggle_file_index")
    assert_equal(calls[2], "unstage:file.txt")
    assert_equal(session.view.selected_change_id, "unstaged\0file.txt")
  end)
end)

it("toggle_file_index restores the owned pane after an asynchronous redraw", function()
  with_controller(function(harness)
    local unstaged = change("unstaged", "file.txt")
    local session = new_session("focus", {}, { unstaged })
    local git = {
      stage_file = function(_, _, _, done)
        session.data.status = status({ change("staged", "file.txt") }, {})
        harness.set_raw_current("background-win")
        done(Result.ok(true))
      end,
    }
    local controller = harness.setup(git)
    harness.set_target(session, unstaged)
    harness.set_current(session, "changes")

    controller.dispatch(session, "toggle_file_index")

    assert_equal(harness.current(), session.owned.changes_win)
  end)
end)

it("toggle_file_index rejects a stale renderer target before enqueue", function()
  with_controller(function(harness)
    local stale = change("unstaged", "stale.txt")
    local session = new_session("stale", {}, {})
    local calls = 0
    local git = {
      stage_file = function()
        calls = calls + 1
      end,
    }
    local controller = harness.setup(git)
    harness.set_target(session, stale)
    harness.set_current(session, "changes")

    controller.dispatch(session, "toggle_file_index")

    assert_equal(calls, 0)
    assert_equal(session.error.code, "stale_change")
  end)
end)

it("toggle_file_index clears a stale selection and anchor when the file becomes clean", function()
  with_controller(function(harness)
    local unstaged = change("unstaged", "clean.txt")
    local session = new_session("clean", {}, { unstaged })
    session.view.selected_change_id = unstaged.id
    session.view.anchor = { path = unstaged.path, section = unstaged.section }
    local git = {
      stage_file = function(_, _, _, done)
        session.data.status = status({}, {})
        done(Result.ok(true))
      end,
    }
    local controller = harness.setup(git)
    harness.set_target(session, unstaged)
    harness.set_current(session, "changes")

    controller.dispatch(session, "toggle_file_index")

    assert_equal(session.view.selected_change_id, nil)
    assert_equal(session.view.anchor, nil)
    assert_truthy(harness.renders() > 0)
  end)
end)

it("toggle_file_index chooses the next target when a middle file becomes clean", function()
  with_controller(function(harness)
    local first = change("unstaged", "first.txt")
    local middle = change("unstaged", "middle.txt")
    local last = change("unstaged", "last.txt")
    local session = new_session("middle", {}, { first, middle, last })
    local git = {
      stage_file = function(_, _, _, done)
        session.data.status = status({}, { first, last })
        done(Result.ok(true))
      end,
    }
    local controller = harness.setup(git)
    harness.set_target(session, middle)
    harness.set_current(session, "changes")

    controller.dispatch(session, "toggle_file_index")

    assert_equal(session.view.selected_change_id, last.id)
    assert_equal(session.view.anchor.path, last.path)
    assert_equal(session.view.anchor.section, last.section)
  end)
end)

it("toggle_file_index leaves another session unblocked", function()
  with_controller(function(harness)
    local first = change("unstaged", "first.txt")
    local second = change("unstaged", "second.txt")
    local session_one = new_session("one", {}, { first })
    local session_two = new_session("two", {}, { second })
    local calls = {}
    local first_done
    local git = {}
    function git:stage_file(_, item, done)
      calls[#calls + 1] = item.path
      if item.path == "first.txt" then
        first_done = done
        return
      end
      session_two.data.status = status({ change("staged", item.path) }, {})
      done(Result.ok(true))
    end
    local controller = harness.setup(git)

    harness.set_target(session_one, first)
    harness.set_current(session_one, "changes")
    controller.dispatch(session_one, "toggle_file_index")
    assert_equal(session_one.busy.mutation, true)

    harness.set_target(session_two, second)
    harness.set_current(session_two, "changes")
    controller.dispatch(session_two, "toggle_file_index")
    assert_equal(#calls, 2)
    assert_equal(calls[1], "first.txt")
    assert_equal(calls[2], "second.txt")
    assert_equal(session_two.busy.mutation, nil)

    session_one.data.status = status({ change("staged", first.path) }, {})
    first_done(Result.ok(true))
  end)
end)
