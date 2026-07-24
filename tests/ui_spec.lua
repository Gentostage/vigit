local function with_fake_vim(vim_api, fn)
  local old_vim = _G.vim
  _G.vim = vim_api
  local ok, err = pcall(fn)
  _G.vim = old_vim
  if not ok then
    error(err, 0)
  end
end

local function reset_ui_modules()
  package.loaded["vigit.ui"] = nil
  package.loaded["vigit.state"] = nil
  package.loaded["vigit.highlights"] = nil
  package.loaded["vigit.git"] = nil
  package.loaded["vigit.review"] = nil
  package.loaded["vigit.actions"] = nil
end

local function stub_ui_modules(state_module)
  reset_ui_modules()
  package.loaded["vigit.state"] = state_module
  package.loaded["vigit.highlights"] = {
    setup = function() end,
    decorate = function() end,
  }
  package.loaded["vigit.git"] = {
    root = function(path)
      return path, nil
    end,
  }
  package.loaded["vigit.review"] = {
    comments = function()
      return {}, nil
    end,
  }
end

local function open_vim_fixture()
  local fixture = {
    next_buf = 0,
    current_win = 100,
    lines_by_buf = {},
    keymaps = 0,
    mappings = {},
    mapping_options = {},
    width = nil,
  }
  local buffer_options = setmetatable({}, {
    __index = function(table, key)
      local value = {}
      rawset(table, key, value)
      return value
    end,
  })
  local buffer_vars = setmetatable({}, {
    __index = function(table, key)
      local value = {}
      rawset(table, key, value)
      return value
    end,
  })

  fixture.vim = {
    o = { columns = 120 },
    log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
    fn = {
      getcwd = function() return "/unused" end,
      fnamemodify = function(path) return path end,
      fnameescape = function(path) return path end,
    },
    notify = function() end,
    schedule = function() end,
    bo = buffer_options,
    b = buffer_vars,
    cmd = function(command)
      if command == "rightbelow vsplit" then
        fixture.current_win = 101
      end
    end,
    keymap = {
      set = function(mode, lhs, rhs, opts)
        assert_equal(type(rhs), "function")
        fixture.keymaps = fixture.keymaps + 1
        fixture.mappings[mode .. ":" .. lhs] = true
        fixture.mapping_options[mode .. ":" .. lhs] = opts
      end,
    },
    api = {
      nvim_create_buf = function()
        fixture.next_buf = fixture.next_buf + 1
        return fixture.next_buf
      end,
      nvim_buf_set_lines = function(buf, _, _, _, lines)
        fixture.lines_by_buf[buf] = lines
      end,
      nvim_buf_set_name = function() end,
      nvim_win_set_buf = function() end,
      nvim_get_current_win = function()
        return fixture.current_win
      end,
      nvim_set_current_win = function(win)
        fixture.current_win = win
      end,
      nvim_win_is_valid = function(win)
        return win == 100 or win == 101
      end,
      nvim_win_set_width = function(win, width)
        assert_equal(win, 101)
        fixture.width = width
      end,
      nvim_set_option_value = function() end,
      nvim_get_current_tabpage = function()
        return 10
      end,
      nvim_tabpage_is_valid = function(tab)
        return tab == 10
      end,
      nvim_create_augroup = function()
        return 7
      end,
      nvim_create_autocmd = function()
        return 1
      end,
    },
  }
  return fixture
end

it("setup registers Vigit command that opens the UI", function()
  local commands = {}
  local opened = false

  package.loaded["vigit"] = nil
  package.loaded["vigit.ui"] = { open = function()
    opened = true
  end }

  with_fake_vim({
    api = {
      nvim_create_user_command = function(name, callback)
        commands[name] = callback
      end,
    },
  }, function()
    local vigit = require("vigit")
    vigit.setup()
    assert_truthy(commands.Vigit)
    assert_truthy(commands.VigitWorktrees)
    assert_truthy(commands.VigitComments)
    assert_truthy(commands.VigitReviews)
    assert_truthy(commands.VigitInstallCodexSkill)
    assert_truthy(commands.VigitHelp)
    commands.Vigit()
    assert_equal(opened, true)
  end)

  package.loaded["vigit"] = nil
  package.loaded["vigit.ui"] = nil
end)

it("open creates windows, buffers, and renders state lines", function()
  stub_ui_modules({
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
          branch = function(cwd)
            assert_equal(cwd, "/tmp/repo")
            return "main"
          end,
        },
        refresh = function()
          return true, nil
        end,
      }
    end,
  })
  package.loaded["vigit.actions"] = {
    close = function() end,
    refresh = function() end,
    toggle_full_context = function() end,
    stage = function() end,
    open_file = function() end,
  }

  local fixture = open_vim_fixture()
  with_fake_vim(fixture.vim, function()
    local ui = require("vigit.ui")
    local session, err = ui.open({ cwd = "/tmp/repo" })
    assert_equal(err, nil)
    assert_equal(session.state.cwd, "/tmp/repo")
    assert_equal(session.changes_buf, 1)
    assert_equal(session.diff_buf, 2)
    assert_equal(session.changes_win, 101)
    assert_equal(session.diff_win, 100)
    assert_equal(session.branch, "main")
    assert_equal(fixture.lines_by_buf[1][2], " M a.txt")
    assert_equal(fixture.lines_by_buf[2][2], "@@ a.txt")
    assert_equal(fixture.width, 33)
    assert_equal(fixture.keymaps, 39)
    assert_equal(fixture.mappings["n:x"], true)
    assert_equal(fixture.mappings["n:X"], true)
    assert_equal(fixture.mappings["n:T"], true)
    assert_equal(fixture.mappings["n:?"], true)
    assert_truthy(fixture.mapping_options["n:?"].desc:match("help"))
  end)

  reset_ui_modules()
end)

it("open propagates actions module load errors", function()
  local old_preload = package.preload["vigit.actions"]
  stub_ui_modules({
    new = function(opts)
      return {
        cwd = opts.cwd,
        changes_lines = { "Unstaged" },
        diff_lines = { "No Git changes" },
        git = {
          is_repo = function()
            return true, nil
          end,
          branch = function()
            return "main"
          end,
        },
        refresh = function()
          return true, nil
        end,
      }
    end,
  })
  package.loaded["vigit.actions"] = nil
  package.preload["vigit.actions"] = function()
    error("actions load failed")
  end

  local fixture = open_vim_fixture()
  with_fake_vim(fixture.vim, function()
    local ui = require("vigit.ui")
    local ok, err = pcall(function()
      ui.open({ cwd = "/tmp/repo" })
    end)
    assert_equal(ok, false)
    assert_truthy(tostring(err):match("actions load failed"))
  end)

  reset_ui_modules()
  package.preload["vigit.actions"] = old_preload
end)

it("focuses a selected file in the existing diff window", function()
  stub_ui_modules({ new = function() end })
  local focused_win = nil
  local focused_cursor = nil
  local centered = false

  with_fake_vim({
    log = { levels = { WARN = 3 } },
    notify = function() end,
    cmd = function(command)
      assert_equal(command, "normal! zz")
      centered = true
    end,
    api = {
      nvim_set_current_win = function(win)
        focused_win = win
      end,
      nvim_win_set_cursor = function(win, cursor)
        assert_equal(win, 22)
        focused_cursor = cursor
      end,
      nvim_win_call = function(win, callback)
        assert_equal(win, 22)
        callback()
      end,
    },
  }, function()
    local ui = require("vigit.ui")
    local file = { path = "a.txt", section = "unstaged" }
    local focused = ui.focus_file({
      diff_win = 22,
      state = {
        diff_line_for_file = function(_, actual)
          assert_equal(actual, file)
          return 14
        end,
      },
    }, file)

    assert_equal(focused, true)
    assert_equal(focused_win, 22)
    assert_equal(focused_cursor[1], 14)
    assert_equal(focused_cursor[2], 0)
    assert_equal(centered, true)
  end)

  reset_ui_modules()
end)

it("focuses the first file header when returning to the overview", function()
  stub_ui_modules({ new = function() end })
  local focused_cursor = nil

  with_fake_vim({
    api = {
      nvim_win_is_valid = function(win)
        return win == 22
      end,
      nvim_set_current_win = function() end,
      nvim_win_set_cursor = function(win, cursor)
        assert_equal(win, 22)
        focused_cursor = cursor
      end,
    },
  }, function()
    local ui = require("vigit.ui")
    local focused = ui.focus_overview({
      diff_win = 22,
      state = {
        diff_lines = { "Unstaged", "  No changes", "Staged", "  1/1 [M] README.md" },
        diff_map = {
          [4] = { kind = "file_header" },
        },
      },
    })

    assert_equal(focused, true)
    assert_equal(focused_cursor[1], 4)
    assert_equal(focused_cursor[2], 0)
  end)

  reset_ui_modules()
end)

it("opens a terminal tab in the current worktree and returns with Q", function()
  stub_ui_modules({ new = function() end })
  local current_tab = 10
  local terminal_tab_valid = true
  local commands = {}
  local normal_q = nil
  local terminal_ctrl_q = nil
  local terminal_close_registered = false

  with_fake_vim({
    b = setmetatable({}, {
      __index = function(items, key)
        local value = {}
        rawset(items, key, value)
        return value
      end,
    }),
    log = { levels = { ERROR = 4 } },
    notify = function() end,
    schedule = function(callback)
      callback()
    end,
    fn = {
      fnameescape = function(path) return path end,
    },
    cmd = function(command)
      commands[#commands + 1] = command
      if command == "tabnew" then
        current_tab = 20
      elseif command == "tabclose" then
        terminal_tab_valid = false
        current_tab = 10
      end
    end,
    keymap = {
      set = function(mode, lhs, callback)
        if mode == "n" and lhs == "Q" then
          normal_q = callback
        elseif mode == "t" and lhs == "<C-q>" then
          terminal_ctrl_q = callback
        end
      end,
    },
    api = {
      nvim_get_current_tabpage = function()
        return current_tab
      end,
      nvim_get_current_buf = function()
        return 3
      end,
      nvim_get_current_win = function()
        return 30
      end,
      nvim_tabpage_is_valid = function(tab)
        return tab == 10 or (tab == 20 and terminal_tab_valid)
      end,
      nvim_set_current_tabpage = function(tab)
        current_tab = tab
      end,
      nvim_set_option_value = function(name, value, opts)
        assert_equal(name, "winbar")
        assert_truthy(value:match("VIGIT · TERMINAL"))
        assert_equal(opts.win, 30)
      end,
      nvim_create_autocmd = function(event, opts)
        assert_equal(event, "TermClose")
        assert_equal(opts.buffer, 3)
        terminal_close_registered = true
        return 9
      end,
    },
  }, function()
    local ui = require("vigit.ui")
    local opened = ui.open_terminal({
      root = "/tmp/worktree",
      worktree_name = "worktree",
      vigit_tab = 10,
      augroup = 7,
    })

    assert_equal(opened, true)
    assert_equal(commands[1], "tabnew")
    assert_equal(commands[2], "tcd /tmp/worktree")
    assert_equal(commands[3], "terminal")
    assert_equal(commands[4], "startinsert")
    assert_truthy(normal_q)
    assert_truthy(terminal_ctrl_q)
    assert_equal(terminal_close_registered, true)

    normal_q()
    assert_equal(current_tab, 10)
    assert_equal(commands[#commands], "tabclose")
  end)

  reset_ui_modules()
end)

it("closes the Vigit session registered for a worktree", function()
  stub_ui_modules({ new = function() end })
  local closed_session = nil

  with_fake_vim({
    fn = {
      fnamemodify = function(path) return path end,
    },
  }, function()
    local ui = require("vigit.ui")
    local target = { root = "/repo/wt" }
    local original_session_for = ui.session_for
    local original_close = ui.close
    ui.session_for = function(path)
      assert_equal(path, "/repo/wt")
      return target
    end
    ui.close = function(session)
      closed_session = session
      return true
    end

    local ok, err = ui.close_worktree("/repo/wt")
    assert_equal(ok, true)
    assert_equal(err, nil)
    assert_equal(closed_session, target)

    ui.session_for = original_session_for
    ui.close = original_close
  end)

  reset_ui_modules()
end)

it("returns an exact blocker when a worktree editor has unsaved files", function()
  stub_ui_modules({ new = function() end })
  local buffer_options = {
    [3] = { modified = true },
  }

  with_fake_vim({
    bo = buffer_options,
    log = { levels = { WARN = 3 } },
    notify = function() end,
    fn = {
      fnamemodify = function(path)
        return path
      end,
    },
    api = {
      nvim_buf_is_valid = function(buf)
        return buf == 3
      end,
      nvim_buf_get_name = function()
        return "/repo/wt/file.txt"
      end,
    },
  }, function()
    local ui = require("vigit.ui")
    local ok, err = ui.close({
      root = "/repo/wt",
      state = { cwd = "/repo/wt" },
      editor = {
        buffers = {
          [3] = {},
        },
      },
    })

    assert_equal(ok, false)
    assert_truthy(err:match("Unsaved files: file%.txt"))
  end)

  reset_ui_modules()
end)
