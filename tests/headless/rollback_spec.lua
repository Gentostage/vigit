local Result = require("vigit.core.result")
local Session = require("vigit.ui.session")

local function change(section, status, path)
  return { id = section .. "\0" .. path, section = section, status = status, path = path }
end

local function with_controller(body)
  local previous = {
    controller = package.loaded["vigit.ui.controller"],
    renderer = package.loaded["vigit.ui.renderer"],
    layout = package.loaded["vigit.ui.layout"],
    diff = package.loaded["vigit.ui.views.diff"],
    confirm = package.loaded["vigit.ui.confirm"],
  }
  local original = {
    current = vim.api.nvim_get_current_win,
    valid_win = vim.api.nvim_win_is_valid,
    cursor = vim.api.nvim_win_get_cursor,
    valid_buf = vim.api.nvim_buf_is_valid,
    width = vim.api.nvim_win_get_width,
  }
  local target
  local confirmation
  local confirmation_answer = false
  local confirmation_hook
  package.loaded["vigit.ui.renderer"] = {
    target_at = function() return target end,
    file_targets = function() return {} end,
    render = function() end,
    clear = function() end,
  }
  package.loaded["vigit.ui.layout"] = { toggle_changes = function() end, resize = function() end, abandon = function() end, close = function() end }
  package.loaded["vigit.ui.views.diff"] = { render = function() return { rows = {} } end }
  package.loaded["vigit.ui.confirm"] = {
    ask = function(message, callback)
      confirmation = message
      if confirmation_hook then confirmation_hook() end
      callback(confirmation_answer)
      return confirmation_answer
    end,
  }
  package.loaded["vigit.ui.controller"] = nil
  vim.api.nvim_get_current_win = function() return "diff" end
  vim.api.nvim_win_is_valid = function() return true end
  vim.api.nvim_win_get_cursor = function() return { 1, 0 } end
  vim.api.nvim_buf_is_valid = function() return true end
  vim.api.nvim_win_get_width = function() return 80 end

  local ok, err = xpcall(function()
    body({
      controller = require("vigit.ui.controller"),
      set_target = function(value) target = value end,
      confirmation = function() return confirmation end,
      set_confirmation = function(answer, hook)
        confirmation_answer = answer
        confirmation_hook = hook
      end,
    })
  end, debug.traceback)
  vim.api.nvim_get_current_win = original.current
  vim.api.nvim_win_is_valid = original.valid_win
  vim.api.nvim_win_get_cursor = original.cursor
  vim.api.nvim_buf_is_valid = original.valid_buf
  vim.api.nvim_win_get_width = original.width
  package.loaded["vigit.ui.controller"] = previous.controller
  package.loaded["vigit.ui.renderer"] = previous.renderer
  package.loaded["vigit.ui.layout"] = previous.layout
  package.loaded["vigit.ui.views.diff"] = previous.diff
  package.loaded["vigit.ui.confirm"] = previous.confirm
  if not ok then error(err, 0) end
end

it("restore_hunk returns unstage_first for a staged rendered hunk without calling Git", function()
  with_controller(function(harness)
    local staged = change("staged", "M", "file.txt")
    local session = Session.new({ id = "staged", root = "/repo" })
    session.owned.diff_win, session.owned.diff_buf = "diff", "diffbuf"
    session.owned.changes_win, session.owned.changes_buf = "changes", "changesbuf"
    session.data.status = { staged = { staged }, unstaged = {} }
    local calls = 0
    harness.controller.configure({
      changes = { git = { restore_hunk = function() calls = calls + 1 end } },
      registry = { remove = function() end },
    })
    harness.set_target({ change_id = staged.id, hunk_id = "hunk", path = staged.path, section = staged.section })
    harness.controller.dispatch(session, "restore_hunk")
    assert_equal(calls, 0)
    assert_equal(session.error.code, "unstage_first")
  end)
end)

it("restore_file rejects a changed Change after Yes before invoking the adapter", function()
  with_controller(function(harness)
    local original = change("unstaged", "M", "file.txt")
    local session = Session.new({ id = "stale-confirm", root = "/repo" })
    session.owned.diff_win, session.owned.diff_buf = "diff", "diffbuf"
    session.owned.changes_win, session.owned.changes_buf = "changes", "changesbuf"
    session.data.status = { staged = {}, unstaged = { original } }
    local calls = 0
    harness.controller.configure({
      changes = { git = { restore_file = function() calls = calls + 1 end } },
      registry = { remove = function() end },
    })
    harness.set_target({ change_id = original.id, path = original.path, section = original.section })
    harness.set_confirmation(true, function()
      session.data.status.unstaged[1] = {
        id = original.id,
        section = "unstaged",
        status = "D",
        path = original.path,
        old_path = "previous.txt",
      }
    end)
    harness.controller.dispatch(session, "restore_file")
    assert_equal(calls, 0)
    assert_equal(session.error.code, "stale_change")
  end)
end)

it("restore_file asks y/N and does not mutate after No", function()
  with_controller(function(harness)
    local unstaged = change("unstaged", "M", "file.txt")
    local session = Session.new({ id = "unstaged", root = "/repo" })
    session.owned.diff_win, session.owned.diff_buf = "diff", "diffbuf"
    session.owned.changes_win, session.owned.changes_buf = "changes", "changesbuf"
    session.data.status = { staged = {}, unstaged = { unstaged } }
    local calls = 0
    harness.controller.configure({
      changes = { git = { restore_file = function() calls = calls + 1 end } },
      registry = { remove = function() end },
    })
    harness.set_target({ change_id = unstaged.id, path = unstaged.path, section = unstaged.section })
    harness.controller.dispatch(session, "restore_file")
    assert_truthy(harness.confirmation())
    assert_equal(calls, 0)
  end)
end)

it("restore_hunk does not fall back to whole-file rollback from a file header", function()
  with_controller(function(harness)
    local unstaged = change("unstaged", "M", "file.txt")
    local session = Session.new({ id = "header", root = "/repo" })
    session.owned.diff_win, session.owned.diff_buf = "diff", "diffbuf"
    session.owned.changes_win, session.owned.changes_buf = "changes", "changesbuf"
    session.data.status = { staged = {}, unstaged = { unstaged } }
    local calls = 0
    harness.controller.configure({
      changes = { git = { restore_hunk = function() calls = calls + 1 end } },
      registry = { remove = function() end },
    })
    harness.set_target({ change_id = unstaged.id, path = unstaged.path, section = unstaged.section })
    harness.controller.dispatch(session, "restore_hunk")
    assert_equal(calls, 0)
    assert_equal(session.error.code, "hunk_required")
  end)
end)

it("restore_hunk rejects fresh content at the same rendered hunk coordinates", function()
  with_controller(function(harness)
    local unstaged = change("unstaged", "M", "file.txt")
    local session = Session.new({ id = "stale-hunk", root = "/repo" })
    session.owned.diff_win, session.owned.diff_buf = "diff", "diffbuf"
    session.owned.changes_win, session.owned.changes_buf = "changes", "changesbuf"
    session.data.status = { staged = {}, unstaged = { unstaged } }
    local hunk_id = unstaged.id .. "\0" .. "1:1"
    local rendered_hunk = { id = hunk_id, patch = "@@ -1 +1 @@\n-old\n+rendered" }
    session.data.diffs[unstaged.id] = {
      id = unstaged.id, change = unstaged, section = unstaged.section,
      path = unstaged.path, headers = { "diff --git a/file.txt b/file.txt", "--- a/file.txt", "+++ b/file.txt" },
      hunks = { rendered_hunk },
    }
    local calls = 0
    harness.controller.configure({
      changes = {
        git = {
          diff = function(_, _, _, _, _, callback)
            callback(Result.ok({
              id = unstaged.id, change = unstaged, section = unstaged.section,
              path = unstaged.path,
              headers = { "diff --git a/file.txt b/file.txt", "--- a/file.txt", "+++ b/file.txt" },
              hunks = { { id = hunk_id, patch = "@@ -1 +1 @@\n-old\nfresh" } },
            }))
          end,
          restore_hunk = function() calls = calls + 1 end,
        },
      },
      registry = { remove = function() end },
    })
    harness.set_target({ change_id = unstaged.id, hunk_id = hunk_id, path = unstaged.path, section = unstaged.section })
    harness.controller.dispatch(session, "restore_hunk")
    assert_equal(calls, 0)
    assert_equal(session.error.code, "stale_hunk")
  end)
end)

it("registers x for hunk rollback and X for confirmed file rollback", function()
  local keymaps = require("vigit.ui.keymaps")
  local intents = {}
  for _, entry in ipairs(keymaps.entries) do
    intents[entry.lhs] = entry.intent
  end
  assert_equal(intents.x, "restore_hunk")
  assert_equal(intents.X, "restore_file")
end)
