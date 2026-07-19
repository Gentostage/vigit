local function with_fake_vim(vim_api, fn)
  local old_vim = _G.vim
  _G.vim = vim_api
  local ok, err = pcall(fn)
  _G.vim = old_vim
  if not ok then
    error(err, 0)
  end
end

it("setup registers Vigit command that opens the UI", function()
  local command_name = nil
  local command_callback = nil
  local opened = false

  package.loaded["vigit"] = nil
  package.loaded["vigit.ui"] = { open = function()
    opened = true
  end }

  with_fake_vim({
    api = {
      nvim_create_user_command = function(name, callback)
        command_name = name
        command_callback = callback
      end,
    },
  }, function()
    local vigit = require("vigit")
    vigit.setup()
    assert_equal(command_name, "Vigit")
    assert_truthy(command_callback)
    command_callback()
    assert_equal(opened, true)
  end)

  package.loaded["vigit"] = nil
  package.loaded["vigit.ui"] = nil
end)

it("open creates windows, buffers, and renders state lines", function()
  local next_buf = 0
  local current_win = 100
  local lines_by_buf = {}
  local keymaps = 0

  package.loaded["vigit.ui"] = nil
  package.loaded["vigit.state"] = {
    new = function(opts)
      return {
        cwd = opts.cwd,
        changes_lines = { "Unstaged", " M a.txt" },
        diff_lines = { "Unstaged", "@@ a.txt" },
        git = {
          is_repo = function(cwd)
            assert_equal(cwd, "/tmp/repo")
            return true, nil
          end,
        },
        refresh = function()
          return true, nil
        end,
      }
    end,
  }
  package.loaded["vigit.actions"] = {
    close = function() end,
    refresh = function() end,
    toggle_full_context = function() end,
    stage = function() end,
    open_file = function() end,
  }

  with_fake_vim({
    log = { levels = { ERROR = 4, INFO = 2 } },
    fn = { getcwd = function() return "/unused" end },
    notify = function() end,
    bo = setmetatable({}, {
      __index = function(table, key)
        local value = {}
        rawset(table, key, value)
        return value
      end,
    }),
    cmd = function(command)
      if command == "vsplit" then
        current_win = 101
      end
    end,
    keymap = {
      set = function(_, _, rhs)
        assert_equal(type(rhs), "function")
        keymaps = keymaps + 1
      end,
    },
    api = {
      nvim_create_buf = function()
        next_buf = next_buf + 1
        return next_buf
      end,
      nvim_buf_set_lines = function(buf, _, _, _, lines)
        lines_by_buf[buf] = lines
      end,
      nvim_buf_set_name = function() end,
      nvim_win_set_buf = function() end,
      nvim_get_current_win = function()
        return current_win
      end,
      nvim_win_set_width = function(win, width)
        assert_equal(win, 100)
        assert_equal(width, 32)
      end,
    },
  }, function()
    local ui = require("vigit.ui")
    local session, err = ui.open({ cwd = "/tmp/repo" })
    assert_equal(err, nil)
    assert_equal(session.state.cwd, "/tmp/repo")
    assert_equal(session.changes_buf, 1)
    assert_equal(session.diff_buf, 2)
    assert_equal(session.changes_win, 100)
    assert_equal(session.diff_win, 101)
    assert_equal(lines_by_buf[1][2], " M a.txt")
    assert_equal(lines_by_buf[2][2], "@@ a.txt")
    assert_equal(keymaps, 10)
  end)

  package.loaded["vigit.ui"] = nil
  package.loaded["vigit.state"] = nil
  package.loaded["vigit.actions"] = nil
end)

it("open propagates actions module load errors", function()
  local next_buf = 0
  local current_win = 100

  package.loaded["vigit.ui"] = nil
  local old_preload = package.preload["vigit.actions"]
  package.loaded["vigit.actions"] = nil
  package.preload["vigit.actions"] = function()
    error("actions load failed")
  end
  package.loaded["vigit.state"] = {
    new = function(opts)
      return {
        cwd = opts.cwd,
        changes_lines = { "Unstaged" },
        diff_lines = { "No Git changes" },
        git = {
          is_repo = function()
            return true, nil
          end,
        },
        refresh = function()
          return true, nil
        end,
      }
    end,
  }

  with_fake_vim({
    log = { levels = { ERROR = 4, INFO = 2 } },
    fn = { getcwd = function() return "/tmp/repo" end },
    notify = function() end,
    bo = setmetatable({}, {
      __index = function(table, key)
        local value = {}
        rawset(table, key, value)
        return value
      end,
    }),
    cmd = function(command)
      if command == "vsplit" then
        current_win = 101
      end
    end,
    keymap = { set = function() end },
    api = {
      nvim_create_buf = function()
        next_buf = next_buf + 1
        return next_buf
      end,
      nvim_buf_set_lines = function() end,
      nvim_buf_set_name = function() end,
      nvim_win_set_buf = function() end,
      nvim_get_current_win = function()
        return current_win
      end,
      nvim_win_set_width = function() end,
    },
  }, function()
    local ui = require("vigit.ui")
    local ok, err = pcall(function()
      ui.open({ cwd = "/tmp/repo" })
    end)
    assert_equal(ok, false)
    assert_truthy(tostring(err):match("actions load failed"))
  end)

  package.loaded["vigit.ui"] = nil
  package.loaded["vigit.state"] = nil
  package.preload["vigit.actions"] = old_preload
end)

it("opens a focused file diff window", function()
  local next_buf = 0
  local current_win = 100
  local lines_by_buf = {}

  package.loaded["vigit.ui"] = nil
  package.loaded["vigit.state"] = { new = function() end }

  with_fake_vim({
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function() end,
    bo = setmetatable({}, {
      __index = function(table, key)
        local value = {}
        rawset(table, key, value)
        return value
      end,
    }),
    cmd = function(command)
      assert_equal(command, "botright split")
      current_win = 101
    end,
    api = {
      nvim_create_buf = function()
        next_buf = next_buf + 1
        return next_buf
      end,
      nvim_buf_set_lines = function(buf, _, _, _, lines)
        lines_by_buf[buf] = lines
      end,
      nvim_buf_set_name = function() end,
      nvim_get_current_win = function()
        return current_win
      end,
      nvim_win_set_buf = function(win, buf)
        assert_equal(win, 101)
        assert_equal(buf, 1)
      end,
    },
  }, function()
    local ui = require("vigit.ui")
    local session = {
      state = {
        cwd = "/tmp/repo",
        full_context = true,
        git = {
          diff_file = function(file, cwd, context)
            assert_equal(file.path, "a.txt")
            assert_equal(cwd, "/tmp/repo")
            assert_equal(context, 9999)
            return { { lines = { { text = "@@ -1 +1 @@" }, { text = "+one" } } } }, nil
          end,
        },
      },
    }

    ui.open_file_window(session, { path = "a.txt", section = "unstaged" })

    assert_equal(session.file_win, 101)
    assert_equal(lines_by_buf[1][1], "@@ a.txt")
    assert_equal(lines_by_buf[1][2], "@@ -1 +1 @@")
    assert_equal(lines_by_buf[1][3], "+one")
  end)

  package.loaded["vigit.ui"] = nil
  package.loaded["vigit.state"] = nil
end)

it("reuses an existing focused file diff window", function()
  local next_buf = 0
  local current_win = 100
  local split_count = 0
  local buffers_by_win = {}

  package.loaded["vigit.ui"] = nil
  package.loaded["vigit.state"] = { new = function() end }

  with_fake_vim({
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    notify = function() end,
    bo = setmetatable({}, {
      __index = function(table, key)
        local value = {}
        rawset(table, key, value)
        return value
      end,
    }),
    cmd = function(command)
      assert_equal(command, "botright split")
      split_count = split_count + 1
      current_win = 101
    end,
    api = {
      nvim_create_buf = function()
        next_buf = next_buf + 1
        return next_buf
      end,
      nvim_buf_set_lines = function() end,
      nvim_buf_set_name = function() end,
      nvim_get_current_win = function()
        return current_win
      end,
      nvim_win_set_buf = function(win, buf)
        buffers_by_win[win] = buf
      end,
      nvim_win_is_valid = function(win)
        return win == 101
      end,
    },
  }, function()
    local ui = require("vigit.ui")
    local session = {
      state = {
        cwd = "/tmp/repo",
        git = {
          diff_file = function(file)
            return { { lines = { { text = "@@ -1 +1 @@" }, { text = "+" .. file.path } } } }, nil
          end,
        },
      },
    }

    ui.open_file_window(session, { path = "a.txt", section = "unstaged" })
    ui.open_file_window(session, { path = "b.txt", section = "unstaged" })

    assert_equal(split_count, 1)
    assert_equal(session.file_win, 101)
    assert_equal(buffers_by_win[101], 2)
  end)

  package.loaded["vigit.ui"] = nil
  package.loaded["vigit.state"] = nil
end)
