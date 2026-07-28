local Result = require("vigit.core.result")
local Session = require("vigit.ui.session")
local anchor = require("vigit.core.anchor")

local function change(section)
  return {
    id = section .. "\0file.txt",
    section = section,
    status = "M",
    path = "file.txt",
  }
end

local function status(staged, unstaged)
  return {
    branch = {},
    staged = staged or {},
    unstaged = unstaged or {},
  }
end

local function hunk(change_model, suffix, lines)
  return {
    id = change_model.id .. "\0" .. suffix,
    header = "@@ -1,10 +1,10 @@",
    patch = "@@ -1 +1 @@\n-old\n+new",
    old_start = 1,
    new_start = 1,
    lines = lines,
  }
end

local function two_clusters(change_model)
  local lines = {
    { kind = "delete", text = "old first", old_line = 1 },
    { kind = "add", text = "new first", new_line = 1 },
  }
  for line = 2, 8 do
    lines[#lines + 1] = {
      kind = "context",
      text = "context " .. line,
      old_line = line,
      new_line = line,
    }
  end
  lines[#lines + 1] = { kind = "delete", text = "old second", old_line = 9 }
  lines[#lines + 1] = { kind = "add", text = "new second", new_line = 9 }
  return hunk(change_model, "1:1", lines)
end

local function default_hunk(change_model)
  return hunk(change_model, "1:1", {
    { kind = "delete", text = "old first", old_line = 1 },
    { kind = "add", text = "new first", new_line = 1 },
  })
end

local function with_controller(section, body)
  local previous_controller = package.loaded["vigit.ui.controller"]
  local previous_renderer = package.loaded["vigit.ui.renderer"]
  local previous_layout = package.loaded["vigit.ui.layout"]
  local previous_diff_view = package.loaded["vigit.ui.views.diff"]
  local original_api = {
    current_win = vim.api.nvim_get_current_win,
    win_is_valid = vim.api.nvim_win_is_valid,
    win_get_cursor = vim.api.nvim_win_get_cursor,
    win_set_cursor = vim.api.nvim_win_set_cursor,
    win_get_width = vim.api.nvim_win_get_width,
    buf_is_valid = vim.api.nvim_buf_is_valid,
  }
  local current = change(section)
  local other = change(section == "staged" and "unstaged" or "staged")
  local session = Session.new({ id = section, root = "/repo" })
  session.owned.changes_win = section .. "-changes-win"
  session.owned.changes_buf = section .. "-changes-buf"
  session.owned.diff_win = section .. "-diff-win"
  session.owned.diff_buf = section .. "-diff-buf"
  session.data.status = section == "staged"
    and status({ current }, {})
    or status({}, { current })
  local expanded_hunk = two_clusters(current)
  local target_hunk_id = anchor.logical_clusters(current, expanded_hunk, 3)[1].key
  session.data.diffs[current.id] = {
    id = current.id,
    change = current,
    section = current.section,
    status = current.status,
    path = current.path,
    headers = { "diff --git a/file.txt b/file.txt", "--- a/file.txt", "+++ b/file.txt" },
    hunks = { expanded_hunk },
  }
  local targets = {
    [session.owned.diff_buf] = {
      [1] = {
        kind = "add",
        change_id = current.id,
        hunk_id = target_hunk_id,
        path = current.path,
        section = current.section,
        side = "new",
        source_line = 1,
        text = "new first",
      },
    },
  }

  package.loaded["vigit.ui.renderer"] = {
    target_at = function(buffer, row)
      return targets[buffer] and targets[buffer][row]
    end,
    file_targets = function(active_session)
      local result = {}
      for _, candidate_section in ipairs({ "staged", "unstaged" }) do
        for _, item in ipairs(active_session.data.status[candidate_section] or {}) do
          result[#result + 1] = { change_id = item.id, change = item }
        end
      end
      return result
    end,
    render = function() end,
    clear = function() end,
  }
  package.loaded["vigit.ui.layout"] = {
    toggle_changes = function() end,
    resize = function() end,
    abandon = function() end,
    close = function() end,
  }
  package.loaded["vigit.ui.views.diff"] = {
    render = function()
      return { rows = {} }
    end,
  }
  package.loaded["vigit.ui.controller"] = nil
  vim.api.nvim_get_current_win = function()
    return session.owned.diff_win
  end
  vim.api.nvim_win_is_valid = function(window)
    return window ~= nil
  end
  vim.api.nvim_win_get_cursor = function()
    return { 1, 0 }
  end
  vim.api.nvim_win_set_cursor = function() end
  vim.api.nvim_win_get_width = function()
    return 80
  end
  vim.api.nvim_buf_is_valid = function(buffer)
    return buffer ~= nil
  end

  local default = default_hunk(current)
  local default_diff = {
    id = current.id,
    change = current,
    section = current.section,
    status = current.status,
    path = current.path,
    headers = { "diff --git a/file.txt b/file.txt", "--- a/file.txt", "+++ b/file.txt" },
    hunks = { default },
  }
  local diff_contexts = {}
  local mutations = {}
  local git = {
    diff = function(_, _, _, context_lines, _, callback)
      diff_contexts[#diff_contexts + 1] = context_lines
      callback(Result.ok(default_diff))
    end,
  }
  local method = section == "staged" and "unstage_hunk" or "stage_hunk"
  git[method] = function(_, _, file_diff, selected, done)
    mutations[#mutations + 1] = { file_diff = file_diff, hunk = selected }
    session.data.status = section == "staged"
      and status({}, { other })
      or status({ other }, {})
    done(Result.ok(true))
  end
  local changes = {
    git = git,
    refresh = function(_, active_session, callback)
      callback({ phase = "status", result = Result.ok(active_session.data.status) })
    end,
    load_diff = function(_, _, _, _, _, callback)
      callback(Result.ok({}))
    end,
  }
  local ok, message = xpcall(function()
    local controller = require("vigit.ui.controller")
    controller.configure({
      changes = changes,
      registry = { remove = function() end },
    })
    controller.dispatch(session, "toggle_hunk_index")
    body({
      diff_contexts = diff_contexts,
      mutations = mutations,
      default_diff = default_diff,
      default_hunk = default,
    })
  end, debug.traceback)

  vim.api.nvim_get_current_win = original_api.current_win
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

it("toggle_hunk_index stages one default-context hunk from expanded clusters", function()
  with_controller("unstaged", function(harness)
    assert_equal(#harness.diff_contexts, 1)
    assert_equal(harness.diff_contexts[1], 3)
    assert_equal(#harness.mutations, 1)
    assert_equal(harness.mutations[1].file_diff, harness.default_diff)
    assert_equal(harness.mutations[1].hunk, harness.default_hunk)
    assert_equal(#harness.mutations[1].hunk.lines, 2)
  end)
end)

it("toggle_hunk_index unstages one default-context hunk from expanded clusters", function()
  with_controller("staged", function(harness)
    assert_equal(#harness.diff_contexts, 1)
    assert_equal(harness.diff_contexts[1], 3)
    assert_equal(#harness.mutations, 1)
    assert_equal(harness.mutations[1].file_diff, harness.default_diff)
    assert_equal(harness.mutations[1].hunk, harness.default_hunk)
    assert_equal(#harness.mutations[1].hunk.lines, 2)
  end)
end)
