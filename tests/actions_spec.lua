local function with_fake_vim(vim_api, fn)
  local old_vim = _G.vim
  _G.vim = vim_api
  local ok, err = pcall(fn)
  _G.vim = old_vim
  if not ok then
    error(err, 0)
  end
end

local function reset_actions()
  package.loaded["vigit.actions"] = nil
  package.loaded["vigit.ui"] = nil
end

it("refresh refreshes state and renders the session", function()
  reset_actions()
  local rendered = false
  package.loaded["vigit.ui"] = {
    render = function(session)
      rendered = session.name == "session"
    end,
  }

  with_fake_vim({
    api = {
      nvim_get_current_buf = function() return 1 end,
      nvim_win_get_cursor = function() return { 1, 0 } end,
    },
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function() end,
  }, function()
    local refreshed = false
    local actions = require("vigit.actions")
    actions.refresh({
      name = "session",
      state = {
        refresh = function()
          refreshed = true
          return true, nil
        end,
      },
    })

    assert_equal(refreshed, true)
    assert_equal(rendered, true)
  end)

  reset_actions()
end)

it("selects file under cursor from the current buffer", function()
  reset_actions()
  local focused_file = nil
  local rendered = false
  package.loaded["vigit.ui"] = {
    render = function() rendered = true end,
    focus_file = function(_, file) focused_file = file end,
  }

  with_fake_vim({
    api = {
      nvim_get_current_buf = function() return 7 end,
      nvim_win_get_cursor = function() return { 3, 0 } end,
    },
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function() end,
  }, function()
    local file = { path = "a.txt", section = "unstaged" }
    local actions = require("vigit.actions")
    actions.open_file({
      changes_buf = 7,
      diff_buf = 8,
      state = {
        changes_node_at_line = function()
          return nil
        end,
        file_at_line = function(_, buffer_name, line)
          assert_equal(buffer_name, "changes")
          assert_equal(line, 3)
          return file
        end,
        select_file = function(_, actual)
          assert_equal(actual, file)
          return true, nil
        end,
        selected_file = function()
          return file
        end,
      },
    })

    assert_equal(rendered, true)
    assert_equal(focused_file, file)
  end)

  reset_actions()
end)

it("stages an unstaged file from the changes buffer", function()
  reset_actions()
  local staged_path = nil
  local refreshes = 0
  package.loaded["vigit.ui"] = {
    render = function() end,
  }

  with_fake_vim({
    api = {
      nvim_get_current_buf = function() return 5 end,
      nvim_win_get_cursor = function() return { 2, 0 } end,
    },
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function() end,
  }, function()
    local actions = require("vigit.actions")
    actions.stage({
      changes_buf = 5,
      diff_buf = 6,
      state = {
        cwd = "/tmp/repo",
        file_at_line = function(_, buffer_name, line)
          assert_equal(buffer_name, "changes")
          assert_equal(line, 2)
          return { path = "a.txt", section = "unstaged" }
        end,
        git = {
          stage_file = function(path, cwd)
            staged_path = path
            assert_equal(cwd, "/tmp/repo")
            return true, nil
          end,
        },
        refresh = function()
          refreshes = refreshes + 1
          return true, nil
        end,
      },
    })

    assert_equal(staged_path, "a.txt")
    assert_equal(refreshes, 1)
  end)

  reset_actions()
end)

it("stages an unstaged hunk from the diff buffer", function()
  reset_actions()
  local staged_hunk = nil
  package.loaded["vigit.ui"] = { render = function() end }

  with_fake_vim({
    api = {
      nvim_get_current_buf = function() return 9 end,
      nvim_win_get_cursor = function() return { 4, 0 } end,
    },
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function() end,
  }, function()
    local file = { path = "a.txt", section = "unstaged" }
    local hunk = { header = "@@ -1 +1 @@" }
    local actions = require("vigit.actions")
    actions.stage({
      changes_buf = 8,
      diff_buf = 9,
      state = {
        cwd = "/tmp/repo",
        hunk_at_line = function(_, line)
          assert_equal(line, 4)
          return { file = file, hunk = hunk }
        end,
        git = {
          stage_hunk = function(actual_file, actual_hunk, cwd)
            assert_equal(actual_file, file)
            assert_equal(cwd, "/tmp/repo")
            staged_hunk = actual_hunk
            return true, nil
          end,
        },
        refresh = function()
          return true, nil
        end,
      },
    })

    assert_equal(staged_hunk, hunk)
  end)

  reset_actions()
end)

it("discards an unstaged hunk after confirmation", function()
  reset_actions()
  local discarded_hunk = nil
  local refreshes = 0
  package.loaded["vigit.ui"] = { render = function() end }

  with_fake_vim({
    api = {
      nvim_get_current_buf = function() return 9 end,
      nvim_win_get_cursor = function() return { 4, 0 } end,
    },
    ui = {
      select = function(choices, opts, callback)
        assert_equal(choices[2], "Discard hunk")
        assert_truthy(opts.prompt:match("a%.txt"))
        callback("Discard hunk")
      end,
    },
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function() end,
  }, function()
    local file = { path = "a.txt", section = "unstaged" }
    local hunk = { header = "@@ -1 +1 @@" }
    local actions = require("vigit.actions")
    actions.discard({
      changes_buf = 8,
      diff_buf = 9,
      state = {
        cwd = "/tmp/repo",
        hunk_at_line = function(_, line)
          assert_equal(line, 4)
          return { file = file, hunk = hunk }
        end,
        git = {
          discard_hunk = function(actual_file, actual_hunk, cwd)
            assert_equal(actual_file, file)
            assert_equal(actual_hunk, hunk)
            assert_equal(cwd, "/tmp/repo")
            discarded_hunk = actual_hunk
            return true, nil
          end,
        },
        refresh = function()
          refreshes = refreshes + 1
          return true, nil
        end,
      },
    })

    assert_equal(discarded_hunk, hunk)
    assert_equal(refreshes, 1)
  end)

  reset_actions()
end)

it("requires staged hunks to be unstaged before discarding", function()
  reset_actions()
  local warning = nil
  local prompted = false

  with_fake_vim({
    api = {
      nvim_get_current_buf = function() return 9 end,
      nvim_win_get_cursor = function() return { 4, 0 } end,
    },
    ui = {
      select = function()
        prompted = true
      end,
    },
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function(message)
      warning = message
    end,
  }, function()
    local actions = require("vigit.actions")
    actions.discard({
      changes_buf = 8,
      diff_buf = 9,
      state = {
        hunk_at_line = function()
          return {
            file = { path = "a.txt", section = "staged" },
            hunk = { header = "@@ -1 +1 @@" },
          }
        end,
      },
    })

    assert_equal(prompted, false)
    assert_truthy(warning:match("Unstage"))
  end)

  reset_actions()
end)

it("does not discard an implicit hunk from a collapsed gap", function()
  reset_actions()
  local warning = nil
  local prompted = false

  with_fake_vim({
    api = {
      nvim_get_current_buf = function() return 9 end,
      nvim_win_get_cursor = function() return { 4, 0 } end,
    },
    ui = {
      select = function()
        prompted = true
      end,
    },
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function(message)
      warning = message
    end,
  }, function()
    local actions = require("vigit.actions")
    actions.discard({
      changes_buf = 8,
      diff_buf = 9,
      state = {
        diff_map = {
          [4] = {
            kind = "gap",
            file = { path = "a.txt", section = "unstaged" },
          },
        },
        hunk_at_line = function()
          error("gap must not resolve to a hunk")
        end,
        file_at_line = function()
          error("gap must not resolve to a whole-file discard")
        end,
      },
    })

    assert_equal(prompted, false)
    assert_truthy(warning:match("changed line"))
  end)

  reset_actions()
end)

it("restores a whole file to HEAD after confirmation", function()
  reset_actions()
  local restored_file = nil
  local refreshes = 0
  package.loaded["vigit.ui"] = { render = function() end }

  with_fake_vim({
    api = {
      nvim_get_current_buf = function() return 5 end,
      nvim_win_get_cursor = function() return { 2, 0 } end,
    },
    ui = {
      select = function(choices, opts, callback)
        assert_equal(choices[2], "Restore file")
        assert_truthy(opts.prompt:match("a%.txt"))
        callback("Restore file")
      end,
    },
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function() end,
  }, function()
    local file = { path = "a.txt", section = "staged" }
    local actions = require("vigit.actions")
    actions.restore_file({
      changes_buf = 5,
      diff_buf = 6,
      state = {
        cwd = "/tmp/repo",
        file_at_line = function(_, buffer_name, line)
          assert_equal(buffer_name, "changes")
          assert_equal(line, 2)
          return file
        end,
        git = {
          restore_file_to_head = function(actual_file, cwd)
            assert_equal(actual_file, file)
            assert_equal(cwd, "/tmp/repo")
            restored_file = actual_file
            return true, nil
          end,
        },
        refresh = function()
          refreshes = refreshes + 1
          return true, nil
        end,
      },
    })

    assert_equal(restored_file, file)
    assert_equal(refreshes, 1)
  end)

  reset_actions()
end)

it("describes restoring an untracked file as deletion", function()
  reset_actions()
  local restored_file = nil
  package.loaded["vigit.ui"] = { render = function() end }

  with_fake_vim({
    api = {
      nvim_get_current_buf = function() return 5 end,
      nvim_win_get_cursor = function() return { 2, 0 } end,
    },
    ui = {
      select = function(choices, opts, callback)
        assert_equal(choices[2], "Delete file")
        assert_truthy(opts.prompt:match("Delete untracked file"))
        assert_truthy(opts.prompt:match("scratch%.md"))
        callback("Delete file")
      end,
    },
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function() end,
  }, function()
    local file = { path = "scratch.md", section = "unstaged", status = "?" }
    local actions = require("vigit.actions")
    actions.restore_file({
      changes_buf = 5,
      diff_buf = 6,
      state = {
        cwd = "/tmp/repo",
        file_at_line = function()
          return file
        end,
        git = {
          restore_file_to_head = function(actual_file)
            restored_file = actual_file
            return true, nil
          end,
        },
        refresh = function()
          return true, nil
        end,
      },
    })

    assert_equal(restored_file, file)
  end)

  reset_actions()
end)

it("opens a terminal for the active Vigit session", function()
  reset_actions()
  local opened_session = nil
  package.loaded["vigit.ui"] = {
    open_terminal = function(session)
      opened_session = session
      return true
    end,
  }

  with_fake_vim({}, function()
    local actions = require("vigit.actions")
    local session = { root = "/tmp/worktree" }
    local opened = actions.open_terminal(session)

    assert_equal(opened, true)
    assert_equal(opened_session, session)
  end)

  reset_actions()
end)
