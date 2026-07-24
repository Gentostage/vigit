local function reset_picker()
  package.loaded["vigit.worktree_picker"] = nil
  package.loaded["vigit.worktrees"] = nil
  package.loaded["vigit.git"] = nil
  package.loaded["vigit.ui"] = nil
end

local function with_fake_vim(vim_api, fn)
  local old_vim = _G.vim
  _G.vim = vim_api
  local ok, err = pcall(fn)
  _G.vim = old_vim
  if not ok then
    error(err, 0)
  end
end

it("shows upstream safety in worktree status", function()
  reset_picker()
  package.loaded["vigit.git"] = {}
  package.loaded["vigit.worktrees"] = {}
  local picker = require("vigit.worktree_picker")

  assert_truthy(picker.status_text({
    changed = 0,
    upstream = "origin/feature",
    ahead = 0,
    behind = 0,
  }):match("PUSHED"))
  assert_truthy(picker.status_text({
    changed = 0,
    upstream = "origin/feature",
    ahead = 2,
    behind = 3,
  }):match("↑2"))
  assert_truthy(picker.status_text({
    changed = 0,
    upstream = nil,
  }):match("NO UPSTREAM"))
  reset_picker()
end)

it("blocks worktree removal before confirmation when safety checks fail", function()
  reset_picker()
  local prompted = false
  local warning = nil
  package.loaded["vigit.git"] = {}
  package.loaded["vigit.worktrees"] = {
    removal_blocker = function()
      return "Branch has 2 unpushed commits"
    end,
  }

  with_fake_vim({
    log = { levels = { INFO = 2, WARN = 3, ERROR = 4 } },
    notify = function(message)
      warning = message
    end,
    ui = {
      input = function()
        prompted = true
      end,
    },
    api = {
      nvim_win_is_valid = function()
        return true
      end,
      nvim_win_get_cursor = function()
        return { 3, 0 }
      end,
    },
  }, function()
    local picker_module = require("vigit.worktree_picker")
    picker_module.remove_selected({
      win = 1,
      entries = {
        { path = "/repo/wt", name = "wt", branch = "feature", changed = 0 },
      },
      session = { root = "/repo/wt" },
    })
  end)

  assert_equal(prompted, false)
  assert_truthy(warning:match("2 unpushed commits"))
  reset_picker()
end)

it("closes and removes an open clean pushed worktree while keeping its branch", function()
  reset_picker()
  local picker_win_valid = true
  local closed_path = nil
  local removed = nil
  local focused_path = nil
  package.loaded["vigit.git"] = {
    remove_worktree = function(cwd, path, force)
      removed = { cwd = cwd, path = path, force = force }
      return true, nil
    end,
  }
  package.loaded["vigit.worktrees"] = {
    removal_blocker = function()
      return nil
    end,
    list = function()
      return {
        {
          path = "/repo/wt",
          name = "wt",
          branch = "feature",
          changed = 0,
          upstream = "origin/feature",
          ahead = 0,
          open = true,
        },
        {
          path = "/repo",
          name = "repo",
          branch = "main",
          primary = true,
        },
      }, nil
    end,
  }
  package.loaded["vigit.ui"] = {
    close_worktree = function(path)
      closed_path = path
      picker_win_valid = false
      return true, nil
    end,
    focus_worktree = function(path)
      focused_path = path
      return {}, nil
    end,
  }

  with_fake_vim({
    log = { levels = { INFO = 2, WARN = 3, ERROR = 4 } },
    notify = function() end,
    ui = {
      input = function(_, callback)
        callback("DELETE")
      end,
    },
    api = {
      nvim_win_is_valid = function()
        return picker_win_valid
      end,
      nvim_win_get_cursor = function()
        return { 3, 0 }
      end,
    },
  }, function()
    local picker_module = require("vigit.worktree_picker")
    picker_module.remove_selected({
      win = 1,
      entries = {
        {
          path = "/repo/wt",
          name = "wt",
          branch = "feature",
          changed = 0,
          upstream = "origin/feature",
          ahead = 0,
          open = true,
        },
        {
          path = "/repo",
          name = "repo",
          branch = "main",
          primary = true,
        },
      },
      session = { root = "/repo/wt" },
    })
  end)

  assert_equal(closed_path, "/repo/wt")
  assert_equal(removed.cwd, "/repo")
  assert_equal(removed.path, "/repo/wt")
  assert_equal(removed.force, false)
  assert_equal(focused_path, "/repo")
  reset_picker()
end)

it("revalidates worktree safety after DELETE confirmation", function()
  reset_picker()
  local removal_attempted = false
  local warning = nil
  package.loaded["vigit.git"] = {
    remove_worktree = function()
      removal_attempted = true
      return true, nil
    end,
  }
  local checks = 0
  package.loaded["vigit.worktrees"] = {
    removal_blocker = function(entry)
      checks = checks + 1
      if entry.ahead and entry.ahead > 0 then
        return "Branch has 1 unpushed commit"
      end
      return nil
    end,
    list = function()
      return {
        {
          path = "/repo/wt",
          name = "wt",
          branch = "feature",
          changed = 0,
          upstream = "origin/feature",
          ahead = 1,
        },
        {
          path = "/repo",
          primary = true,
        },
      }, nil
    end,
  }
  package.loaded["vigit.ui"] = {
    close_worktree = function()
      return true, nil
    end,
    focus_worktree = function() end,
  }

  with_fake_vim({
    log = { levels = { INFO = 2, WARN = 3, ERROR = 4 } },
    notify = function(message)
      warning = message
    end,
    ui = {
      input = function(_, callback)
        callback("DELETE")
      end,
    },
    api = {
      nvim_win_is_valid = function()
        return true
      end,
      nvim_win_get_cursor = function()
        return { 3, 0 }
      end,
    },
  }, function()
    local picker_module = require("vigit.worktree_picker")
    picker_module.remove_selected({
      win = 1,
      entries = {
        {
          path = "/repo/wt",
          name = "wt",
          branch = "feature",
          changed = 0,
          upstream = "origin/feature",
          ahead = 0,
        },
        {
          path = "/repo",
          primary = true,
        },
      },
      session = { root = "/repo/wt" },
    })
  end)

  assert_equal(checks, 2)
  assert_equal(removal_attempted, false)
  assert_truthy(warning:match("changed since confirmation"))
  assert_truthy(warning:match("unpushed commit"))
  reset_picker()
end)
