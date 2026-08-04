local Fixture = require("tests.fixtures.git_repo")
local v2 = require("vigit.v2")
local controller = require("vigit.ui.controller")
local layout = require("vigit.ui.layout")

local function close_session(session)
  if session and not session.closed then
    controller.dispatch(session, "abandon")
  end
end

local function select_worktree(picker, path)
  local canonical = assert(vim.uv.fs_realpath(path))
  assert_truthy(vim.wait(2000, function()
    return picker.row_by_path[canonical] ~= nil
  end, 10))
  vim.api.nvim_win_set_cursor(picker.win, {
    picker.row_by_path[canonical],
    0,
  })
  picker:select()
  assert_truthy(vim.wait(2000, function()
    local session = v2.active_session()
    return picker.closed and session and session.root == canonical
  end, 10))
  return v2.active_session()
end

it("открывает picker worktree, различает ROOT и WT и фокусирует существующую сессию", function()
  local repo = Fixture.new()
  local linked = vim.fn.tempname()
  local root_session
  local linked_session
  local ok, message = xpcall(function()
    repo:write("README.md", { "fixture" })
    repo:git({ "add", "README.md" })
    repo:commit("initial")
    repo:git({ "worktree", "add", "-q", "-b", "linked", linked })

    root_session = assert(v2.open({ cwd = repo.root }))
    local picker = assert(v2.worktrees({ cwd = repo.root }))
    assert_truthy(picker.buf and vim.api.nvim_buf_is_valid(picker.buf))
    assert_truthy(vim.wait(2000, function()
      return #picker.rows == 2 and picker.row_by_path[vim.uv.fs_realpath(linked)] ~= nil
    end, 10))
    assert_equal(picker.rows[1].kind, "root")
    assert_equal(picker.rows[2].kind, "linked")
    assert_equal(picker.rows[1].active, true)
    assert_equal(picker.rows[2].active, false)
    for _, lhs in ipairs({ "[w", "]w", "r", "F", "d", "q" }) do
      assert_equal(vim.fn.maparg(lhs, "n", false, true).buffer, 1)
    end
    local linked_row = picker.row_by_path[vim.uv.fs_realpath(linked)]
    vim.api.nvim_win_set_cursor(picker.win, { linked_row, 0 })
    picker:select()
    assert_truthy(vim.wait(2000, function()
      linked_session = v2.active_session()
      return linked_session and linked_session.root == vim.uv.fs_realpath(linked)
    end, 10))

    local again = assert(v2.worktrees({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function()
      return again.row_by_path[vim.uv.fs_realpath(linked)] ~= nil
    end, 10))
    local active_rows = 0
    local linked_active = false
    for _, row in ipairs(again.rows) do
      if row.active then
        active_rows = active_rows + 1
        linked_active = row.path == vim.uv.fs_realpath(linked)
      end
    end
    assert_equal(active_rows, 1)
    assert_equal(linked_active, true)
    local reopened_row = again.row_by_path[vim.uv.fs_realpath(linked)]
    vim.api.nvim_win_set_cursor(again.win, { reopened_row, 0 })
    again:select()
    assert_truthy(vim.wait(2000, function()
      return again.closed and v2.active_session() == linked_session
    end, 10))
  end, debug.traceback)

  close_session(linked_session)
  close_session(root_session)
  vim.fn.delete(linked, "rf")
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("сохраняет editor mode и последний buffer при выборе worktree через W", function()
  local repo = Fixture.new()
  local linked = vim.fn.tempname()
  local root_session
  local linked_session
  local buffers = {}
  local ok, message = xpcall(function()
    repo:write("README.md", { "fixture" })
    repo:git({ "add", "README.md" })
    repo:commit("initial")
    repo:git({ "worktree", "add", "-q", "-b", "linked-code", linked })

    root_session = assert(v2.open({ cwd = repo.root }))
    controller.dispatch(root_session, "close")
    vim.cmd("edit " .. vim.fn.fnameescape(repo.root .. "/README.md"))
    local root_buffer = vim.api.nvim_get_current_buf()
    buffers[#buffers + 1] = root_buffer

    linked_session = select_worktree(
      assert(v2.worktrees({ session = root_session })),
      linked
    )
    assert_equal(linked_session.workspace:mode_name(), "code")
    assert_equal(layout.is_visible(linked_session), false)
    assert_equal(vim.fn.getcwd(0, 0), assert(vim.uv.fs_realpath(linked)))
    assert_equal(vim.api.nvim_buf_get_name(0), "")
    buffers[#buffers + 1] = vim.api.nvim_get_current_buf()

    vim.cmd("edit " .. vim.fn.fnameescape(linked .. "/README.md"))
    local linked_buffer = vim.api.nvim_get_current_buf()
    buffers[#buffers + 1] = linked_buffer

    root_session = select_worktree(
      assert(v2.worktrees({ session = linked_session })),
      repo.root
    )
    assert_equal(root_session.workspace:mode_name(), "code")
    assert_equal(vim.api.nvim_get_current_buf(), root_buffer)

    linked_session = select_worktree(
      assert(v2.worktrees({ session = root_session })),
      linked
    )
    assert_equal(linked_session.workspace:mode_name(), "code")
    assert_equal(vim.api.nvim_get_current_buf(), linked_buffer)
  end, debug.traceback)

  close_session(linked_session)
  close_session(root_session)
  for _, buffer in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
  vim.fn.delete(linked, "rf")
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("в code mode открывает W на worktree текущего source buffer", function()
  local repo = Fixture.new()
  local linked = vim.fn.tempname()
  local root_session
  local linked_session
  local source_buffer
  local picker
  local ok, message = xpcall(function()
    repo:write("README.md", { "fixture" })
    repo:git({ "add", "README.md" })
    repo:commit("initial")
    repo:git({ "worktree", "add", "-q", "-b", "linked-picker-root", linked })

    root_session = assert(v2.open({ cwd = repo.root }))
    controller.dispatch(root_session, "close")
    vim.cmd("edit " .. vim.fn.fnameescape(linked .. "/README.md"))
    source_buffer = vim.api.nvim_get_current_buf()

    picker = assert(v2.worktrees({ session = root_session }))
    local linked_root = assert(vim.uv.fs_realpath(linked))
    assert_truthy(vim.wait(2000, function()
      return picker.row_by_path[linked_root] ~= nil
    end, 10))
    assert_equal(picker.selected_path, linked_root)
    assert_equal(
      vim.api.nvim_win_get_cursor(picker.win)[1],
      picker.row_by_path[linked_root]
    )
    linked_session = select_worktree(picker, linked)
    assert_equal(linked_session.workspace:mode_name(), "code")
    assert_equal(vim.api.nvim_get_current_buf(), source_buffer)
  end, debug.traceback)

  if picker and not picker.closed then picker:close() end
  close_session(linked_session)
  close_session(root_session)
  if source_buffer and vim.api.nvim_buf_is_valid(source_buffer) then
    pcall(vim.api.nvim_buf_delete, source_buffer, { force = true })
  end
  vim.fn.delete(linked, "rf")
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("public worktrees открывает picker без существующей Vigit-сессии и q возвращает origin tab", function()
  local repo = Fixture.new()
  local origin = vim.api.nvim_get_current_tabpage()
  local ok, message = xpcall(function()
    repo:write("README.md", { "fixture" })
    repo:git({ "add", "README.md" })
    repo:commit("initial")
    local picker = assert(v2.worktrees({ cwd = repo.root }))
    assert_equal(v2.active_session(), nil)
    assert_truthy(vim.wait(2000, function()
      return picker.row_by_path[vim.uv.fs_realpath(repo.root)] ~= nil
    end, 10))
    picker:close()
    assert_equal(vim.api.nvim_get_current_tabpage(), origin)
  end, debug.traceback)

  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("не открывает главный worktree вместо исчезнувшего linked path и оставляет picker usable", function()
  local repo = Fixture.new()
  local ok, message = xpcall(function()
    repo:write("README.md", { "fixture" })
    repo:git({ "add", "README.md" })
    repo:commit("initial")
    vim.fn.mkdir(repo.root .. "/nested", "p")
    local picker = assert(v2.worktrees({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function()
      return picker.row_by_path[vim.uv.fs_realpath(repo.root)] ~= nil
    end, 10))
    local result
    picker.app:open({ path = repo.root .. "/nested" }, function(value) result = value end)
    assert_truthy(vim.wait(1000, function() return result ~= nil end, 10))
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "worktree_missing")
    assert_truthy(vim.api.nvim_win_is_valid(picker.win))
    picker:close()
  end, debug.traceback)

  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("повторный вызов worktrees фокусирует единственный picker и после close создаёт новый", function()
  local repo = Fixture.new()
  local ok, message = xpcall(function()
    repo:write("README.md", { "fixture" })
    repo:git({ "add", "README.md" })
    repo:commit("initial")
    local first = assert(v2.worktrees({ cwd = repo.root }))
    local second = assert(v2.worktrees({ cwd = repo.root }))
    assert_equal(second, first)
    assert_equal(second.buf, first.buf)
    first:close()
    local third = assert(v2.worktrees({ cwd = repo.root }))
    assert_truthy(third ~= first)
    third:close()
  end, debug.traceback)

  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("открывает и закрывает picker в границах реального редактора 20x6", function()
  local view = require("vigit.ui.views.worktrees")
  local previous = {
    columns = vim.o.columns,
    lines = vim.o.lines,
    cmdheight = vim.o.cmdheight,
  }
  local app = {}
  function app:set_on_update(callback, owner)
    self.on_update, self.owner = callback, owner
  end
  function app:detach(owner)
    if self.owner == owner then self.on_update, self.owner = nil, nil end
  end
  function app:cancel() end
  function app:list()
    return { cancel = function() end }
  end

  local picker
  local ok, message = xpcall(function()
    vim.o.columns = 20
    vim.o.lines = 6
    vim.o.cmdheight = 1
    picker = view.open({ app = app, origin = { root = "/repo", closed = false } })
    local config = vim.api.nvim_win_get_config(picker.win)
    local usable_lines = vim.o.lines - vim.o.cmdheight

    assert_truthy(config.width + 2 <= vim.o.columns)
    assert_truthy(config.height + 2 <= usable_lines)
    assert_truthy(config.col >= 0 and config.col + config.width + 2 <= vim.o.columns)
    assert_truthy(config.row >= 0 and config.row + config.height + 2 <= usable_lines)

    picker:close()
    assert_equal(vim.api.nvim_win_is_valid(picker.win), false)
  end, debug.traceback)

  if picker and not picker.closed then picker:close() end
  vim.o.columns = previous.columns
  vim.o.lines = previous.lines
  vim.o.cmdheight = previous.cmdheight
  if not ok then error(message, 0) end
end)

it("рендерит completed probes во время loading и не переполняет wide/narrow строки", function()
  local view = require("vigit.ui.views.worktrees")
  local rows = {
    {
      kind = "linked",
      path = "/repo/very-long-worktree-name",
      name = "very-long-worktree-name-for-a-narrow-screen",
      branch = "feature/very-long-branch-name-for-a-small-terminal",
      files = { staged = 1, unstaged = 2, untracked = 3 },
      upstream = {
        state = "tracking", name = "origin/feature/very-long-branch-name",
        source = "local_refs", ahead = 1, behind = 2, fetched_at = "2026-07-28T12:00:00Z",
      },
      probes = {
        status = { state = "ok" },
        upstream = { state = "ok" },
      },
    },
  }
  for _, maximum in ipairs({ 70, 90 }) do
    local rendered = view.render(rows, maximum)
    for _, line in ipairs(rendered.lines) do
      assert_truthy(vim.fn.strdisplaywidth(line) <= maximum)
    end
    local text = table.concat(rendered.lines, "\n")
    assert_truthy(text:match("S:1 M:2 %?:3"))
    assert_truthy(text:match("fetched 12:00"))
    if maximum == 90 then
      assert_truthy(text:match("origin/"))
      assert_truthy(text:match("local refs"))
    end
  end
end)

it("рендерит literal upstream safety matrix из local refs", function()
  local view = require("vigit.ui.views.worktrees")
  local upstreams = {
    {
      name = "wt-equal",
      value = {
        state = "tracking",
        name = "origin/main",
        source = "local_refs",
        ahead = 0,
        behind = 0,
      },
    },
    {
      name = "wt-ahead",
      value = {
        state = "tracking",
        name = "origin/ahead",
        source = "local_refs",
        ahead = 1,
        behind = 0,
      },
    },
    {
      name = "wt-behind",
      value = {
        state = "tracking",
        name = "origin/behind",
        source = "local_refs",
        ahead = 0,
        behind = 2,
      },
    },
    {
      name = "wt-no-upstream",
      value = { state = "no_upstream" },
    },
  }
  local rows = {}
  for index, item in ipairs(upstreams) do
    rows[index] = {
      kind = "linked",
      path = "/repo/" .. item.name,
      name = item.name,
      branch = "feature/" .. index,
      files = { staged = 0, unstaged = 0, untracked = 0 },
      upstream = item.value,
      probes = {
        status = { state = "ok" },
        upstream = { state = "ok" },
      },
    }
  end

  local lines = view.render(rows, 120).lines
  local function row(name)
    for _, line in ipairs(lines) do
      if line:find(name, 1, true) then return vim.trim(line) end
    end
  end

  local equal = assert(row("wt-equal"))
  assert_truthy(equal:find("origin/main · local refs", 1, true) ~= nil)
  assert_equal(equal:find("↑", 1, true), nil)
  assert_equal(equal:find("↓", 1, true), nil)
  assert_truthy(assert(row("wt-ahead")):find(
    "origin/ahead · local refs ↑1",
    1,
    true
  ) ~= nil)
  assert_truthy(assert(row("wt-behind")):find(
    "origin/behind · local refs ↓2",
    1,
    true
  ) ~= nil)
  assert_truthy(assert(row("wt-no-upstream")):find(
    "no upstream",
    1,
    true
  ) ~= nil)
end)

it("derives the worktree footer from enabled mappings without overflow", function()
  local config = require("vigit.config")
  local view = require("vigit.ui.views.worktrees")
  local keymaps = require("vigit.ui.keymaps")
  local ok, message = xpcall(function()
    assert_truthy(config.setup({ keymaps = { ["worktrees.fetch"] = false } }).ok)
    local rendered = view.render({}, 20)
    local footer = rendered.lines[#rendered.lines]
    assert_equal(footer:find("fetch", 1, true), nil)
    assert_truthy(keymaps.display_width(footer) <= 20)
  end, debug.traceback)
  config.setup()
  if not ok then error(message, 0) end
end)

it("показывает раздельные status/upstream probe errors без ложного clean", function()
  local Result = require("vigit.core.result")
  local Worktrees = require("vigit.application.worktrees")
  local view = require("vigit.ui.views.worktrees")
  local function rendered(status_result, upstream_result)
    local git = {}
    function git:worktrees(_, callback)
      self.worktrees_callback = callback
      return { cancel = function() end }
    end
    function git:worktree_status(_, callback)
      self.status_callback = callback
      return { cancel = function() end }
    end
    function git:upstream(_, callback)
      self.upstream_callback = callback
      return { cancel = function() end }
    end
    local app = Worktrees.new({ git = git })
    app:list({ root = "/repo", closed = false })
    git.worktrees_callback(Result.ok({ {
      kind = "root", path = "/repo", name = "repo", branch = "main",
    } }))
    git.status_callback(status_result)
    git.upstream_callback(upstream_result)
    return table.concat(view.render(app.rows, 90).lines, "\n")
  end

  local status_failed = rendered(
    Result.err("status_failed", "status unavailable"),
    Result.ok({ state = "tracking", name = "origin/main", source = "local_refs", ahead = 1, behind = 0 })
  )
  assert_truthy(status_failed:find("status !status_failed", 1, true) ~= nil)
  assert_truthy(status_failed:find("origin/main", 1, true) ~= nil)
  assert_truthy(status_failed:find("S:0 M:0 ?:0", 1, true) == nil)

  local upstream_failed = rendered(
    Result.ok({ staged = 1, unstaged = 2, untracked = 3 }),
    Result.err("upstream_failed", "upstream unavailable")
  )
  assert_truthy(upstream_failed:find("S:1 M:2 ?:3", 1, true) ~= nil)
  assert_truthy(upstream_failed:find("upstream !upstream_failed", 1, true) ~= nil)

  local both_failed = rendered(
    Result.err("status_failed", "status unavailable"),
    Result.err("upstream_failed", "upstream unavailable")
  )
  assert_truthy(both_failed:find("status !status_failed", 1, true) ~= nil)
  assert_truthy(both_failed:find("upstream !upstream_failed", 1, true) ~= nil)
  assert_truthy(both_failed:find("clean", 1, true) == nil)
end)

it("writes picker and root-resolution failures to diagnostics before rendering", function()
  local Result = require("vigit.core.result")
  local log = require("vigit.ui.log")
  local view = require("vigit.ui.views.worktrees")
  local app = {}
  function app:set_on_update(callback, owner)
    self.on_update, self.owner = callback, owner
  end
  function app:detach(owner)
    if self.owner == owner then self.on_update, self.owner = nil, nil end
  end
  function app:cancel() end
  function app:list(_, callback)
    self.on_update({ {
      kind = "root", path = "/repo", name = "repo", branch = "main",
      probes = { status = { state = "error", error = { code = "probe_failed", message = "probe failed" } } },
    } })
    callback(Result.err("list_failed", "list failed"))
    return { cancel = function() end }
  end
  function app:open(_, callback)
    callback(Result.err("open_failed", "open failed"))
    return { cancel = function() end }
  end
  function app:fetch(_, callback)
    callback(Result.err("fetch_failed", "fetch failed"))
    return { cancel = function() end }
  end
  function app:remove(_, callback)
    callback(Result.err("remove_failed", "remove failed"))
    return { cancel = function() end }
  end

  local picker = assert(view.open({ app = app, origin = { root = "/repo", closed = false } }))
  assert_truthy(vim.wait(500, function() return #picker.targets == 1 end, 10))
  picker:select()
  picker:fetch()
  picker:remove()
  local codes = {}
  for _, entry in ipairs(log.entries()) do codes[entry.code] = true end
  for _, code in ipairs({ "list_failed", "probe_failed", "open_failed", "fetch_failed", "remove_failed" }) do
    assert_truthy(codes[code])
  end
  picker:close()

  local _, root_error = require("vigit.v2").worktrees({ cwd = vim.fn.tempname() })
  assert_equal(root_error.code, "not_repository")
  assert_truthy(log.entries()[#log.entries()].code == "not_repository")
end)

it("stale dispose старого picker не отменяет новый picker и его рендер", function()
  local Result = require("vigit.core.result")
  local Worktrees = require("vigit.application.worktrees")
  local view = require("vigit.ui.views.worktrees")
  local git = {}
  function git:worktrees(_, callback)
    self.worktrees_callback = callback
    return { cancel = function() end }
  end
  function git:worktree_status(_, callback)
    self.status_callback = callback
    return { cancel = function() end }
  end
  function git:upstream(_, callback)
    self.upstream_callback = callback
    return { cancel = function() end }
  end
  local app = Worktrees.new({ git = git })
  local origin = { root = "/repo", closed = false }
  local old_picker = view.open({ app = app, origin = origin })
  old_picker:close()
  local new_picker = view.open({ app = app, origin = origin })
  local new_request = app.request

  assert_equal(app:dispose(origin, old_picker), false)
  assert_equal(app.request, new_request)
  git.worktrees_callback(Result.ok({ {
    kind = "root", path = "/repo", name = "repo", branch = "main",
  } }))
  git.status_callback(Result.ok({ staged = 1, unstaged = 0, untracked = 0 }))
  git.upstream_callback(Result.ok({ state = "tracking", name = "origin/main" }))
  assert_truthy(vim.wait(500, function()
    return #new_picker.targets == 1 and new_picker.rows[1].probes.status.state == "ok"
  end, 10))
  new_picker:close()
end)

it("закрытие через q и BufWipeout отменяет picker request и late select", function()
  local view = require("vigit.ui.views.worktrees")
  local function app_for_picker()
    local app = { request = { active = true }, open_callbacks = {} }
    function app:set_on_update(callback, owner)
      self.on_update, self.owner = callback, owner
    end
    function app:detach(owner)
      if self.owner == owner then self.owner, self.on_update = nil, nil end
    end
    function app:list(_, callback)
      self.list_callback = callback
      self.on_update({ {
        kind = "root", path = "/repo/a", name = "a", branch = "main",
        files = { staged = 0, unstaged = 0, untracked = 0 }, loading = false,
      }, {
        kind = "linked", path = "/repo/b", name = "b", branch = "feature",
        files = { staged = 1, unstaged = 0, untracked = 0 }, loading = false,
      } })
      return { cancel = function() self.list_cancelled = true end }
    end
    function app:cancel()
      self.request = nil
      self.cancelled = true
    end
    function app:open(_, callback)
      local pending = { callback = callback, cancelled = false }
      self.open_callbacks[#self.open_callbacks + 1] = pending
      return { cancel = function() pending.cancelled = true end }
    end
    return app
  end
  local origin = { root = "/repo", closed = false }
  local app = app_for_picker()
  local picker = view.open({ app = app, origin = origin })
  assert_truthy(vim.wait(500, function() return #picker.targets == 2 end, 10))
  picker:select()
  vim.api.nvim_win_set_cursor(picker.win, { picker.targets[2].row, 0 })
  picker:select()
  assert_equal(app.open_callbacks[1].cancelled, true)

  vim.api.nvim_feedkeys("q", "x", false)
  assert_truthy(vim.wait(500, function() return picker.closed end, 10))
  assert_equal(app.request, nil)
  assert_equal(app.on_update, nil)
  assert_equal(app.open_callbacks[2].cancelled, true)
  app.open_callbacks[2].callback({ ok = true })
  assert_equal(picker.closed, true)

  local second = view.open({ app = app_for_picker(), origin = origin })
  assert_truthy(vim.wait(500, function() return #second.targets == 2 end, 10))
  local second_app = second.app
  vim.api.nvim_buf_delete(second.buf, { force = true })
  assert_truthy(vim.wait(500, function() return second.closed end, 10))
  assert_equal(second_app.request, nil)
  assert_equal(second_app.on_update, nil)
end)

it("возвращает Tab только diff/changes и даёт W всем owned Vigit contexts", function()
  local keymaps = require("vigit.ui.keymaps")
  local by_id = {}
  for _, entry in ipairs(keymaps.entries) do by_id[entry.id] = entry end
  assert_equal(table.concat(by_id["view.toggle_focus"].contexts, ","), "diff,changes")
  assert_equal(table.concat(by_id["worktrees.open"].contexts, ","),
    "diff,changes,comments,prompt,comment_editor")

  for _, context in ipairs({ "comments", "prompt", "comment_editor" }) do
    local buffer = vim.api.nvim_create_buf(false, true)
    keymaps.apply_aux(nil, buffer, context, { open_worktrees = function() end })
    vim.api.nvim_set_current_buf(buffer)
    local mapping = vim.fn.maparg("W", "n", false, true)
    assert_equal(mapping.buffer, 1)
    assert_truthy(mapping.desc:find("Open worktree picker", 1, true) ~= nil)
    assert_equal(next(vim.fn.maparg("<Tab>", "n", false, true)), nil)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end
end)
