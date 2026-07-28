local Result = require("vigit.core.result")
local Changes = require("vigit.application.changes")
local Diff = require("vigit.core.diff")
local Session = require("vigit.ui.session")
local anchor = require("vigit.core.anchor")
local config = require("vigit.config")
local diff_view = require("vigit.ui.views.diff")

local change = {
  id = "unstaged\0src/a.lua",
  section = "unstaged",
  status = "M",
  path = "src/a.lua",
}

local other_change = {
  id = "unstaged\0src/b.lua",
  section = "unstaged",
  status = "M",
  path = "src/b.lua",
}

local function with_vim(fn)
  local previous = _G.vim
  _G.vim = {
    fn = {
      strdisplaywidth = function(text)
        return #text
      end,
      strchars = function(text)
        return #text
      end,
      strcharpart = function(text, start, length)
        return text:sub(start + 1, start + length)
      end,
    },
  }
  local ok, message = xpcall(fn, debug.traceback)
  _G.vim = previous
  if not ok then
    error(message, 0)
  end
end

local function state_with(diff)
  return {
    view = {
      diff_mode = "one_file",
      selected_change_id = change.id,
      expanded_context = {},
      all_files = { loaded = {}, loading = {} },
    },
    data = {
      status = {
        branch = {},
        staged = {},
        unstaged = { change },
      },
      diffs = {
        [change.id] = diff,
      },
    },
    busy = { diff = {} },
  }
end

local function parse_patch(lines, target_change)
  local parsed = Diff.parse(
    table.concat(lines, "\n"),
    target_change or change
  )
  assert_truthy(parsed.ok)
  return parsed.value
end

local function collapsed_diff()
  return parse_patch({
    "diff --git a/src/a.lua b/src/a.lua",
    "--- a/src/a.lua",
    "+++ b/src/a.lua",
    "@@ -1,3 +1,3 @@",
    " line 1",
    "-old 2",
    "+new 2",
    " line 3",
    "@@ -132 +132 @@",
    "-old 132",
    "\\ No newline at end of file",
    "+new 132",
    "",
  })
end

local function expanded_diff()
  local lines = {
    "diff --git a/src/a.lua b/src/a.lua",
    "--- a/src/a.lua",
    "+++ b/src/a.lua",
    "@@ -1,132 +1,132 @@",
  }
  for line = 1, 132 do
    if line == 2 then
      lines[#lines + 1] = "-old 2"
      lines[#lines + 1] = "+new 2"
    elseif line == 132 then
      lines[#lines + 1] = "-old 132"
      lines[#lines + 1] = "\\ No newline at end of file"
      lines[#lines + 1] = "+new 132"
    else
      lines[#lines + 1] = " line " .. line
    end
  end
  lines[#lines + 1] = ""
  return parse_patch(lines)
end

local function single_hunk_diff(line, old_text, new_text, target_change)
  target_change = target_change or change
  old_text = old_text or "old " .. line
  new_text = new_text or "new " .. line
  local path = target_change.path
  return parse_patch({
    string.format("diff --git a/%s b/%s", path, path),
    "--- a/" .. path,
    "+++ b/" .. path,
    string.format("@@ -%d +%d @@", line, line),
    "-" .. old_text,
    "+" .. new_text,
    "",
  }, target_change)
end

local function empty_diff()
  return parse_patch({
    "diff --git a/src/a.lua b/src/a.lua",
    "--- a/src/a.lua",
    "+++ b/src/a.lua",
    "",
  })
end

local function find_row(rendered, kind)
  for index, row in ipairs(rendered.rows or {}) do
    if row.kind == kind then
      return index, row
    end
  end
end

local function find_source_row(rendered, source_line)
  for index, row in ipairs(rendered.rows or {}) do
    if row.source_anchor.source_line == source_line
        and row.kind == "context" then
      return index, row
    end
  end
end

it("renders the already-resolved comments error ahead of a handler error", function()
  with_vim(function()
    local state = state_with(empty_diff())
    state.errors = {
      comments = { code = "comments_failed", message = "Comments failed" },
      handler = { code = "handler_failed", message = "Handler failed" },
      diffs = {},
    }
    state.error = state.errors.comments

    local rendered = diff_view.render(state, 80)

    assert_truthy(rendered.lines[1]:find("comments_failed", 1, true) ~= nil)
    assert_equal(rendered.lines[1]:find("handler_failed", 1, true), nil)
  end)
end)

it("renders status and selected diff errors only through resolved state.error", function()
  with_vim(function()
    local state = state_with(empty_diff())
    state.errors = {
      status = { code = "status_failed", message = "Status failed" },
      comments = { code = "comments_failed", message = "Comments failed" },
      handler = { code = "handler_failed", message = "Handler failed" },
      diffs = { [change.id] = { code = "diff_failed", message = "Diff failed" } },
    }
    state.error = state.errors.status
    local rendered = diff_view.render(state, 80)
    assert_truthy(rendered.lines[1]:find("status_failed", 1, true) ~= nil)

    state.errors.status = nil
    state.error = state.errors.diffs[change.id]
    rendered = diff_view.render(state, 80)
    assert_truthy(table.concat(rendered.lines, "\n"):find("diff_failed", 1, true) ~= nil)
  end)
end)

local function refresh_git()
  local fake = {
    status_callbacks = {},
    status_handles = {},
    diff_calls = {},
  }
  function fake:status(_, callback)
    self.status_callbacks[#self.status_callbacks + 1] = callback
    local handle = { cancelled = 0 }
    handle.cancel = function()
      handle.cancelled = handle.cancelled + 1
    end
    self.status_handles[#self.status_handles + 1] = handle
    return handle
  end
  function fake:diff(_, requested_change, context_lines, _, callback)
    local handle = { cancelled = 0 }
    handle.cancel = function()
      handle.cancelled = handle.cancelled + 1
    end
    self.diff_calls[#self.diff_calls + 1] = {
      change = requested_change,
      context = context_lines,
      callback = callback,
      handle = handle,
    }
    return handle
  end
  return fake
end

it("создаёт row contract и old-side anchor для deletion", function()
  with_vim(function()
    local diff = {
      id = change.id,
      path = change.path,
      section = change.section,
      headers = { "--- a/src/a.lua", "+++ b/src/a.lua" },
      hunks = {
        {
          id = "h1",
          header = "@@ -9 +9 @@",
          old_start = 9,
          old_count = 1,
          new_start = 9,
          new_count = 1,
          lines = {
            { kind = "delete", text = "return false", old_line = 9 },
            { kind = "add", text = "return true", new_line = 9 },
          },
        },
      },
    }

    local rendered = diff_view.render(state_with(diff), 100)
    assert_equal(#rendered.rows, #rendered.lines)
    for index, row in ipairs(rendered.rows) do
      assert_equal(row.text, rendered.lines[index])
      assert_equal(row.change_id, change.id)
      assert_truthy(type(row.kind) == "string")
      assert_truthy(type(row.source_anchor) == "table")
    end

    local _, deletion = find_row(rendered, "delete")
    assert_equal(deletion.source_anchor.side, "old")
    assert_equal(deletion.source_anchor.source_line, 9)
    assert_equal(deletion.source_anchor.context, "return false")
  end)
end)

it("привязывает no-newline meta к marker-free deletion coordinate", function()
  with_vim(function()
    local diff = parse_patch({
      "diff --git a/src/a.lua b/src/a.lua",
      "--- a/src/a.lua",
      "+++ b/src/a.lua",
      "@@ -9 +9,0 @@",
      "--value",
      "\\ No newline at end of file",
      "",
    })
    local rendered = diff_view.render(state_with(diff), 100)
    local deletion_row
    local meta_row
    for index, row in ipairs(rendered.rows) do
      if row.kind == "delete" then
        deletion_row = index
      elseif row.text == "\\ No newline at end of file" then
        meta_row = index
      end
    end

    assert_truthy(deletion_row)
    assert_truthy(meta_row)
    assert_equal(rendered.rows[deletion_row].source_anchor.context, "-value")
    assert_equal(rendered.rows[meta_row].source_anchor.side, "old")
    assert_equal(rendered.rows[meta_row].source_anchor.source_line, 9)
    assert_equal(
      rendered.rows[meta_row].hunk_id,
      rendered.rows[deletion_row].hunk_id
    )
    local restored = anchor.match(
      rendered.rows,
      anchor.from_row(rendered.rows[meta_row], 3)
    )
    assert_truthy(restored and restored > 1)
    assert_equal(rendered.rows[restored].source_anchor.source_line, 9)
  end)
end)

it("рендерит стабильный gap anchor для скрытого контекста", function()
  with_vim(function()
    local rendered = diff_view.render(state_with(collapsed_diff()), 100)
    local gap_index, gap = find_row(rendered, "gap")

    assert_truthy(gap_index)
    assert_equal(gap.text, "… 128 unchanged lines …")
    assert_equal(gap.hunk_id, change.id .. "\0logical:132:132")
    assert_equal(gap.source_anchor.source_line, 132)
    assert_equal(gap.source_anchor.side, "new")
  end)
end)

it("после expanded_context находит ту же source line среди раскрытых строк", function()
  with_vim(function()
    local collapsed_state = state_with(collapsed_diff())
    local collapsed = diff_view.render(collapsed_state, 100)
    local _, gap = find_row(collapsed, "gap")
    local captured = anchor.from_row(gap, 7)

    local expanded_state = state_with(expanded_diff())
    expanded_state.view.expanded_context[gap.hunk_id] = true
    local expanded = diff_view.render(expanded_state, 100)
    local restored = anchor.match(expanded.rows, captured)

    assert_truthy(restored)
    assert_truthy(find_source_row(expanded, 131))
    assert_equal(expanded.rows[restored].text, "new 132")
    assert_equal(expanded.rows[restored].source_anchor.source_line, 132)
  end)
end)

it("переключает только текущий context и отменяет устаревший per-file read", function()
  local previous_config = config.get()
  local fake = {
    calls = {},
    callbacks = {},
    handles = {},
  }
  function fake:diff(_, _, context_lines, _, callback)
    self.calls[#self.calls + 1] = context_lines
    self.callbacks[#self.callbacks + 1] = callback
    local handle = { cancelled = 0 }
    handle.cancel = function()
      handle.cancelled = handle.cancelled + 1
    end
    self.handles[#self.handles + 1] = handle
    return handle
  end

  local ok, message = xpcall(function()
    assert_truthy(config.setup({ ui = { context_lines = 4 } }).ok)
    local changes = Changes.new({ git = fake })
    local session = Session.new({ id = "a", root = "/repo" })
    session.data.status = {
      branch = {},
      staged = {},
      unstaged = { change },
    }
    local completed = 0
    local h1 = change.id .. "\0logical:2:2"
    local h2 = change.id .. "\0logical:132:132"

    changes:toggle_context(session, change.id, h1, function()
      completed = completed + 1
    end)
    changes:toggle_context(session, change.id, h2, function()
      completed = completed + 1
    end)
    assert_equal(session.view.expanded_context[h1], true)
    assert_equal(session.view.expanded_context[h2], true)
    assert_equal(fake.calls[1], 9999)
    assert_equal(fake.calls[2], 9999)

    changes:toggle_context(session, change.id, h2, function()
      completed = completed + 1
    end)
    assert_equal(session.view.expanded_context[h1], true)
    assert_equal(session.view.expanded_context[h2], nil)
    assert_equal(fake.calls[3], 9999)
    assert_equal(fake.handles[1].cancelled, 1)

    changes:toggle_context(session, change.id, h1, function()
      completed = completed + 1
    end)
    assert_equal(session.view.expanded_context[h1], nil)
    assert_equal(fake.calls[4], 4)

    fake.callbacks[1](Result.ok(collapsed_diff()))
    fake.callbacks[2](Result.ok(collapsed_diff()))
    fake.callbacks[3](Result.err(
      "diff_too_large",
      "Diff exceeds configured byte limit"
    ))
    assert_equal(completed, 0)
    assert_equal(session.error, nil)
    assert_equal(next(session.view.expanded_context), nil)
    fake.callbacks[4](Result.ok(collapsed_diff()))
    assert_equal(completed, 1)
  end, debug.traceback)

  config.setup(previous_config)
  if not ok then
    error(message, 0)
  end
end)

it("refresh сохраняет expanded context для выбранного файла", function()
  local fake = {
    status_callbacks = {},
    diff_calls = {},
  }
  function fake:status(_, callback)
    self.status_callbacks[#self.status_callbacks + 1] = callback
    return { cancel = function() end }
  end
  function fake:diff(_, _, context_lines, _, callback)
    self.diff_calls[#self.diff_calls + 1] = {
      context = context_lines,
      callback = callback,
    }
    return { cancel = function() end }
  end

  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local status = {
    branch = {},
    staged = {},
    unstaged = { change },
  }
  local context_key = change.id .. "\0logical:132:132"
  session.data.status = status
  session.view.selected_change_id = change.id
  session.view.expanded_context[context_key] = true
  session.view.applied_expanded_context[context_key] = true

  changes:refresh(session)
  fake.status_callbacks[1](Result.ok(status))

  assert_equal(fake.diff_calls[1].context, 9999)
  assert_equal(session.view.expanded_context[context_key], true)
end)

it("refresh мигрирует active logical key к ближайшему returned hunk", function()
  local fake = {
    status_callbacks = {},
    diff_calls = {},
  }
  function fake:status(_, callback)
    self.status_callbacks[#self.status_callbacks + 1] = callback
    return { cancel = function() end }
  end
  function fake:diff(_, _, context_lines, _, callback)
    self.diff_calls[#self.diff_calls + 1] = {
      context = context_lines,
      callback = callback,
    }
    return { cancel = function() end }
  end

  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local status = {
    branch = {},
    staged = {},
    unstaged = { change },
  }
  local old_key = change.id .. "\0logical:10:10"
  local new_key = change.id .. "\0logical:11:11"
  session.data.status = status
  session.data.diffs[change.id] =
    single_hunk_diff(10, "before", "after")
  session.view.selected_change_id = change.id
  session.view.expanded_context[old_key] = true
  session.view.applied_expanded_context[old_key] = true

  changes:refresh(session)
  fake.status_callbacks[1](Result.ok(status))
  assert_equal(fake.diff_calls[1].context, 9999)
  fake.diff_calls[1].callback(Result.ok(
    single_hunk_diff(11, "before", "after")
  ))

  assert_equal(session.view.expanded_context[old_key], nil)
  assert_equal(session.view.expanded_context[new_key], true)
  assert_equal(session.view.applied_expanded_context[old_key], nil)
  assert_equal(session.view.applied_expanded_context[new_key], true)
  with_vim(function()
    local rendered = diff_view.render(session, 100)
    local _, added = find_row(rendered, "add")
    assert_equal(added.hunk_id, new_key)
    changes:toggle_context(session, change.id, added.hunk_id)
  end)
  assert_equal(next(session.view.expanded_context), nil)
  assert_equal(fake.diff_calls[2].context, config.get().ui.context_lines)
end)

it("refresh не мигрирует removed hunk к несвязанному соседнему hunk", function()
  local fake = {
    status_callbacks = {},
    diff_calls = {},
  }
  function fake:status(_, callback)
    self.status_callbacks[#self.status_callbacks + 1] = callback
    return { cancel = function() end }
  end
  function fake:diff(_, _, context_lines, _, callback)
    self.diff_calls[#self.diff_calls + 1] = {
      context = context_lines,
      callback = callback,
    }
    return { cancel = function() end }
  end

  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local status = {
    branch = {},
    staged = {},
    unstaged = { change },
  }
  local removed_key = change.id .. "\0logical:10:10"
  local unrelated_key = change.id .. "\0logical:11:11"
  session.data.status = status
  session.data.diffs[change.id] =
    single_hunk_diff(10, "removed before", "removed after")
  session.view.selected_change_id = change.id
  session.view.expanded_context[removed_key] = true
  session.view.applied_expanded_context[removed_key] = true

  changes:refresh(session)
  fake.status_callbacks[1](Result.ok(status))
  fake.diff_calls[1].callback(Result.ok(
    single_hunk_diff(11, "unrelated before", "unrelated after")
  ))

  assert_equal(session.view.expanded_context[removed_key], nil)
  assert_equal(session.view.expanded_context[unrelated_key], nil)
  assert_equal(next(session.view.applied_expanded_context), nil)
end)

it("refresh удаляет active key для исчезнувшего hunk без replacement", function()
  local fake = {
    status_callbacks = {},
    diff_calls = {},
  }
  function fake:status(_, callback)
    self.status_callbacks[#self.status_callbacks + 1] = callback
    return { cancel = function() end }
  end
  function fake:diff(_, _, context_lines, _, callback)
    self.diff_calls[#self.diff_calls + 1] = {
      context = context_lines,
      callback = callback,
    }
    return { cancel = function() end }
  end

  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local status = {
    branch = {},
    staged = {},
    unstaged = { change },
  }
  local removed_key = change.id .. "\0logical:10:10"
  session.data.status = status
  session.view.selected_change_id = change.id
  session.view.expanded_context[removed_key] = true
  session.view.applied_expanded_context[removed_key] = true

  changes:refresh(session)
  fake.status_callbacks[1](Result.ok(status))
  fake.diff_calls[1].callback(Result.ok(empty_diff()))

  assert_equal(next(session.view.expanded_context), nil)
  assert_equal(next(session.view.applied_expanded_context), nil)
  changes:load_diff(session, change.id)
  assert_equal(fake.diff_calls[2].context, config.get().ui.context_lines)
end)

it("refresh удаляет context state исчезнувшего Change", function()
  local fake = refresh_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local removed_key = change.id .. "\0logical:10:10"
  session.data.status = {
    branch = {},
    staged = {},
    unstaged = { change },
  }
  session.data.diffs[change.id] = single_hunk_diff(10)
  session.view.diff_mode = "all_files"
  session.view.selected_change_id = change.id
  session.view.expanded_context[removed_key] = true
  session.view.applied_expanded_context[removed_key] = true

  changes:refresh(session)
  fake.status_callbacks[1](Result.ok({
    branch = {},
    staged = {},
    unstaged = {},
  }))

  assert_equal(session.view.selected_change_id, nil)
  assert_equal(next(session.view.expanded_context), nil)
  assert_equal(next(session.view.applied_expanded_context), nil)
  assert_equal(next(session.data.diffs), nil)
  assert_equal(#fake.diff_calls, 0)
end)

it("all-files refresh мигрирует только hunk своего Change", function()
  local fake = refresh_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local current_status = {
    branch = {},
    staged = {},
    unstaged = { change, other_change },
  }
  local first_old_key = change.id .. "\0logical:10:10"
  local first_new_key = change.id .. "\0logical:11:11"
  local second_old_key = other_change.id .. "\0logical:10:10"
  local second_new_key = other_change.id .. "\0logical:11:11"
  local first_old_diff = single_hunk_diff(
    10,
    "removed before",
    "removed after",
    change
  )
  local second_old_diff = single_hunk_diff(
    10,
    "kept before",
    "kept after",
    other_change
  )
  session.data.status = current_status
  session.data.diffs[change.id] = first_old_diff
  session.data.diffs[other_change.id] = second_old_diff
  session.view.diff_mode = "all_files"
  session.view.selected_change_id = change.id
  session.view.expanded_context[first_old_key] = true
  session.view.expanded_context[second_old_key] = true
  session.view.applied_expanded_context[first_old_key] = true
  session.view.applied_expanded_context[second_old_key] = true

  changes:refresh(session)
  fake.status_callbacks[1](Result.ok(current_status))

  assert_equal(#fake.diff_calls, 2)
  assert_equal(fake.diff_calls[1].change, change)
  assert_equal(fake.diff_calls[2].change, other_change)
  assert_equal(session.data.diffs[change.id], first_old_diff)
  assert_equal(session.data.diffs[other_change.id], second_old_diff)

  fake.diff_calls[1].callback(Result.ok(single_hunk_diff(
    11,
    "unrelated before",
    "unrelated after",
    change
  )))
  fake.diff_calls[2].callback(Result.ok(single_hunk_diff(
    11,
    "kept before",
    "kept after",
    other_change
  )))

  assert_equal(session.view.expanded_context[first_old_key], nil)
  assert_equal(session.view.expanded_context[first_new_key], nil)
  assert_equal(session.view.expanded_context[second_old_key], nil)
  assert_equal(session.view.expanded_context[second_new_key], true)
  assert_equal(session.view.applied_expanded_context[first_new_key], nil)
  assert_equal(
    session.view.applied_expanded_context[second_new_key],
    true
  )
end)

it("selected refresh failure откатывает superseded optimistic intent", function()
  local fake = refresh_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local current_status = {
    branch = {},
    staged = {},
    unstaged = { change },
  }
  local context_key = change.id .. "\0logical:10:10"
  local applied_diff = single_hunk_diff(10)
  session.data.status = current_status
  session.data.diffs[change.id] = applied_diff
  session.view.selected_change_id = change.id

  changes:toggle_context(session, change.id, context_key)
  assert_equal(session.view.expanded_context[context_key], true)
  changes:refresh(session)

  assert_equal(session.view.expanded_context[context_key], nil)
  assert_equal(next(session.view.applied_expanded_context), nil)
  assert_equal(fake.diff_calls[1].handle.cancelled, 1)

  fake.status_callbacks[1](Result.ok(current_status))
  assert_equal(#fake.diff_calls, 2)
  assert_equal(fake.diff_calls[2].context, config.get().ui.context_lines)
  assert_equal(session.data.diffs[change.id], applied_diff)

  fake.diff_calls[1].callback(Result.err(
    "git_diff_failed",
    "Stale optimistic failure"
  ))
  assert_equal(session.error, nil)
  assert_equal(session.data.diffs[change.id], applied_diff)

  fake.diff_calls[2].callback(Result.err(
    "git_diff_failed",
    "Current refresh failure"
  ))
  assert_equal(session.view.expanded_context[context_key], nil)
  assert_equal(next(session.view.applied_expanded_context), nil)
  assert_equal(session.data.diffs[change.id], applied_diff)
  assert_equal(session.error.message, "Current refresh failure")
end)

it("all-files refresh failure откатывает только свой superseded intent", function()
  local fake = refresh_git()
  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  local current_status = {
    branch = {},
    staged = {},
    unstaged = { change, other_change },
  }
  local first_diff = single_hunk_diff(10, nil, nil, change)
  local second_diff = single_hunk_diff(20, nil, nil, other_change)
  local first_key = change.id .. "\0logical:10:10"
  session.data.status = current_status
  session.data.diffs[change.id] = first_diff
  session.data.diffs[other_change.id] = second_diff
  session.view.diff_mode = "all_files"
  session.view.selected_change_id = change.id

  changes:toggle_context(session, change.id, first_key)
  changes:refresh(session)
  assert_equal(session.view.expanded_context[first_key], nil)

  fake.status_callbacks[1](Result.ok(current_status))
  assert_equal(#fake.diff_calls, 3)
  assert_equal(fake.diff_calls[2].change, change)
  assert_equal(fake.diff_calls[3].change, other_change)
  assert_equal(fake.diff_calls[2].context, config.get().ui.context_lines)

  fake.diff_calls[2].callback(Result.err(
    "git_diff_failed",
    "Current all-files failure"
  ))
  local second_updated = single_hunk_diff(
    20,
    "updated before",
    "updated after",
    other_change
  )
  fake.diff_calls[3].callback(Result.ok(second_updated))

  assert_equal(session.data.diffs[change.id], first_diff)
  assert_equal(session.data.diffs[other_change.id], second_updated)
  assert_equal(session.view.expanded_context[first_key], nil)
  assert_equal(session.view.applied_expanded_context[first_key], nil)
  assert_equal(session.error.message, "Current all-files failure")

  fake.diff_calls[1].callback(Result.err(
    "git_diff_failed",
    "Stale all-files failure"
  ))
  assert_equal(session.data.diffs[change.id], first_diff)
  assert_equal(session.data.diffs[other_change.id], second_updated)
  assert_equal(session.error.message, "Current all-files failure")
end)

it("откатывает optimistic expand после diff_too_large", function()
  local callbacks = {}
  local fake = {}
  function fake:diff(_, _, _, _, callback)
    callbacks[#callbacks + 1] = callback
    return { cancel = function() end }
  end

  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  session.data.status = {
    branch = {},
    staged = {},
    unstaged = { change },
  }
  local previous_diff = collapsed_diff()
  session.data.diffs[change.id] = previous_diff
  local context_key = change.id .. "\0logical:132:132"

  changes:toggle_context(session, change.id, context_key)
  assert_equal(session.view.expanded_context[context_key], true)
  callbacks[1](Result.err(
    "diff_too_large",
    "Diff exceeds configured byte limit"
  ))

  assert_equal(session.view.expanded_context[context_key], nil)
  assert_equal(next(session.view.applied_expanded_context), nil)
  assert_equal(session.data.diffs[change.id], previous_diff)
  assert_equal(session.error.code, "diff_too_large")
end)

it("откатывает optimistic collapse после diff failure", function()
  local callbacks = {}
  local fake = {}
  function fake:diff(_, _, _, _, callback)
    callbacks[#callbacks + 1] = callback
    return { cancel = function() end }
  end

  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  session.data.status = {
    branch = {},
    staged = {},
    unstaged = { change },
  }
  local previous_diff = expanded_diff()
  session.data.diffs[change.id] = previous_diff
  local context_key = change.id .. "\0logical:132:132"
  session.view.expanded_context[context_key] = true
  session.view.applied_expanded_context[context_key] = true

  changes:toggle_context(session, change.id, context_key)
  assert_equal(session.view.expanded_context[context_key], nil)
  callbacks[1](Result.err("git_diff_failed", "Git diff failed"))

  assert_equal(session.view.expanded_context[context_key], true)
  assert_equal(session.view.applied_expanded_context[context_key], true)
  assert_equal(session.data.diffs[change.id], previous_diff)
  assert_equal(session.error.code, "git_diff_failed")
end)

it("failed collapse после superseded expand откатывается к applied collapsed", function()
  local callbacks = {}
  local fake = {}
  function fake:diff(_, _, _, _, callback)
    callbacks[#callbacks + 1] = callback
    return { cancel = function() end }
  end

  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  session.data.status = {
    branch = {},
    staged = {},
    unstaged = { change },
  }
  local previous_diff = collapsed_diff()
  session.data.diffs[change.id] = previous_diff
  local context_key = change.id .. "\0logical:132:132"

  changes:toggle_context(session, change.id, context_key)
  changes:toggle_context(session, change.id, context_key)
  assert_equal(session.view.expanded_context[context_key], nil)
  callbacks[2](Result.err("git_diff_failed", "Git diff failed"))

  assert_equal(session.view.expanded_context[context_key], nil)
  assert_equal(session.view.applied_expanded_context[context_key], nil)
  callbacks[1](Result.ok(expanded_diff()))
  assert_equal(session.view.expanded_context[context_key], nil)
  assert_equal(session.view.applied_expanded_context[context_key], nil)
  assert_equal(session.data.diffs[change.id], previous_diff)
end)

it("failed expand после superseded collapse откатывается к applied expanded", function()
  local callbacks = {}
  local fake = {}
  function fake:diff(_, _, _, _, callback)
    callbacks[#callbacks + 1] = callback
    return { cancel = function() end }
  end

  local changes = Changes.new({ git = fake })
  local session = Session.new({ id = "a", root = "/repo" })
  session.data.status = {
    branch = {},
    staged = {},
    unstaged = { change },
  }
  local previous_diff = expanded_diff()
  session.data.diffs[change.id] = previous_diff
  local context_key = change.id .. "\0logical:132:132"
  session.view.expanded_context[context_key] = true
  session.view.applied_expanded_context[context_key] = true

  changes:toggle_context(session, change.id, context_key)
  changes:toggle_context(session, change.id, context_key)
  assert_equal(session.view.expanded_context[context_key], true)
  callbacks[2](Result.err("git_diff_failed", "Git diff failed"))

  assert_equal(session.view.expanded_context[context_key], true)
  assert_equal(session.view.applied_expanded_context[context_key], true)
  callbacks[1](Result.ok(collapsed_diff()))
  assert_equal(session.view.expanded_context[context_key], true)
  assert_equal(session.view.applied_expanded_context[context_key], true)
  assert_equal(session.data.diffs[change.id], previous_diff)
end)

it("intent f восстанавливает cursor по SourceAnchor после async render", function()
  local previous_vim = _G.vim
  local previous_layout = package.loaded["vigit.ui.layout"]
  local previous_renderer = package.loaded["vigit.ui.renderer"]
  local previous_controller = package.loaded["vigit.ui.controller"]
  local callbacks = {}
  local contexts = {}
  local restored_cursor
  local current_cursor

  local ok, message = xpcall(function()
    local session = Session.new({ id = "a", root = "/repo" })
    session.owned.diff_buf = 11
    session.owned.diff_win = 12
    session.data.status = {
      branch = {},
      staged = {},
      unstaged = { change },
    }
    session.data.diffs[change.id] = collapsed_diff()
    session.view.selected_change_id = change.id

    _G.vim = {
      fn = {
        strdisplaywidth = function(text)
          return #text
        end,
        strchars = function(text)
          return #text
        end,
        strcharpart = function(text, start, length)
          return text:sub(start + 1, start + length)
        end,
      },
      api = {
        nvim_win_is_valid = function(window)
          return window == session.owned.diff_win
        end,
        nvim_win_get_cursor = function()
          return current_cursor
        end,
        nvim_win_get_width = function()
          return 100
        end,
        nvim_win_set_cursor = function(_, cursor)
          restored_cursor = cursor
          current_cursor = cursor
        end,
      },
    }

    local collapsed = diff_view.render(session, 100)
    session.gap_row = assert(find_row(collapsed, "gap"))
    local context_key = collapsed.rows[session.gap_row].hunk_id
    current_cursor = { session.gap_row, 5 }
    local fake_renderer = {
      target_at = function(buffer, row)
        assert_equal(buffer, session.owned.diff_buf)
        local current = diff_view.render(session, 100)
        for _, target in ipairs(current.targets) do
          if target.row == row then
            return target
          end
        end
      end,
      render = function() end,
      file_targets = function()
        return {}
      end,
      clear = function() end,
    }
    package.loaded["vigit.ui.layout"] = {
      toggle_changes = function() end,
      resize = function() end,
      abandon = function() end,
      close = function() end,
    }
    package.loaded["vigit.ui.renderer"] = fake_renderer
    package.loaded["vigit.ui.controller"] = nil

    local fake_git = {}
    function fake_git:diff(_, _, context_lines, _, callback)
      contexts[#contexts + 1] = context_lines
      callbacks[#callbacks + 1] = callback
      return { cancel = function() end }
    end
    local changes = Changes.new({ git = fake_git })
    local controller = require("vigit.ui.controller")
    controller.configure({
      changes = changes,
      registry = { remove = function() end },
    })

    controller.dispatch(session, "f")
    assert_equal(restored_cursor, nil)
    assert_equal(contexts[1], 9999)

    callbacks[1](Result.ok(expanded_diff()))
    assert_equal(session.view.applied_expanded_context[context_key], true)
    assert_truthy(restored_cursor)
    assert_truthy(restored_cursor[1] > 1)
    assert_equal(restored_cursor[2], 5)
    local rendered = diff_view.render(session, 100)
    assert_equal(
      rendered.rows[restored_cursor[1]].source_anchor.source_line,
      132
    )

    local moved_row, moved = find_source_row(rendered, 120)
    assert_truthy(moved_row)
    assert_equal(moved.hunk_id, context_key)
    current_cursor = { moved_row, 2 }
    controller.dispatch(session, "f")
    assert_equal(contexts[2], config.get().ui.context_lines)
    assert_equal(next(session.view.expanded_context), nil)
    callbacks[2](Result.ok(collapsed_diff()))
    assert_equal(next(session.view.applied_expanded_context), nil)
    rendered = diff_view.render(session, 100)
    assert_truthy(restored_cursor[1] > 1)
    assert_equal(
      rendered.rows[restored_cursor[1]].hunk_id,
      context_key
    )
  end, debug.traceback)

  _G.vim = previous_vim
  package.loaded["vigit.ui.layout"] = previous_layout
  package.loaded["vigit.ui.renderer"] = previous_renderer
  package.loaded["vigit.ui.controller"] = previous_controller
  if not ok then
    error(message, 0)
  end
end)
