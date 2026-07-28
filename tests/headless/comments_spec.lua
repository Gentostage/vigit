local Fixture = require("tests.fixtures.git_repo")
local controller = require("vigit.ui.controller")
local renderer = require("vigit.ui.renderer")
local v2 = require("vigit.v2")
local Changes = require("vigit.application.changes")
local Reviews = require("vigit.application.reviews")
local Result = require("vigit.core.result")

local function close(session)
  if session and not session.closed then controller.dispatch(session, "close") end
end

local function changed_row(session)
  for row = 1, vim.api.nvim_buf_line_count(session.owned.diff_buf) do
    local target = renderer.target_at(session.owned.diff_buf, row)
    if target and target.kind == "add" then return row end
  end
end

local function deleted_row(session)
  for row = 1, vim.api.nvim_buf_line_count(session.owned.diff_buf) do
    local target = renderer.target_at(session.owned.diff_buf, row)
    if target and target.kind == "delete" then return row end
  end
end

local function has_marker(buffer, expected)
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })) do
    local chunks = extmark[4].virt_text
    if chunks and chunks[1] and chunks[1][1]:find(expected, 1, true) then return true end
  end
  return false
end

local function first_change(session)
  for _, section in ipairs({ "staged", "unstaged" }) do
    if session.data.status and session.data.status[section] and session.data.status[section][1] then
      return session.data.status[section][1]
    end
  end
end

local function save_editor(session, lines)
  local buffer = assert(session.owned.comment_editor_buf)
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_set_current_win(session.owned.comment_editor_win)
  vim.api.nvim_feedkeys(vim.keycode("<C-s>"), "x", false)
  assert_truthy(vim.wait(1000, function() return session.owned.comment_editor_win == nil end, 10))
end

local function controlled_refresh(session, reviews)
  local callbacks = {}
  local changes = Changes.new({
    git = {
      status = function(_, _, callback)
        callbacks[#callbacks + 1] = callback
        return { cancel = function() end }
      end,
    },
    on_change = function(current) renderer.render(current) end,
  })
  local previous = controller.configure({
    changes = changes,
    registry = {},
    reviews = reviews,
  })
  controller.dispatch(session, "refresh")
  return callbacks, previous
end

local function restore_controller(previous)
  controller.configure(previous)
end

local function rendered_text(session)
  return table.concat(vim.api.nvim_buf_get_lines(session.owned.diff_buf, 0, -1, false), "\n")
end

it("keeps comment interaction in owned vigit buffers and updates marker previews", function()
  local repo = Fixture.new()
  local session
  local original_confirm = vim.fn.confirm
  local original_has = vim.fn.has
  local ok, message = xpcall(function()
    repo:write("src/service.lua", { "local value = 1", "return value" })
    repo:git({ "add", "--", "src/service.lua" })
    repo:commit("initial")
    repo:write("src/service.lua", { "local value = 1", "return repository.save(value)" })
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function() return first_change(session) ~= nil end, 10))
    controller.dispatch(session, { name = "select_change", change_id = first_change(session).id })
    assert_truthy(vim.wait(2000, function()
      return changed_row(session) ~= nil
    end, 10))
    vim.api.nvim_set_current_win(session.owned.diff_win)
    vim.api.nvim_win_set_cursor(session.owned.diff_win, { changed_row(session), 0 })

    controller.dispatch(session, "add_comment")
    assert_truthy(session.owned.comment_editor_buf and vim.api.nvim_buf_is_valid(session.owned.comment_editor_buf))
    save_editor(session, { "Handle RepositoryError carefully.", "Preserve the retry context." })
    assert_equal(session.data.comments[1].id, "VIGIT-001")
    assert_equal(session.data.comments[1].body, "Handle RepositoryError carefully.\nPreserve the retry context.")
    assert_truthy(has_marker(session.owned.diff_buf, "VIGIT-001 · Handle RepositoryError"))

    local comment_path = repo.root .. "/.vigit/comments.md"
    local external = table.concat(vim.fn.readfile(comment_path), "\n") .. "\n"
    external = external:gsub("## %[% %] VIGIT%-001", "## [x] VIGIT-001")
    external = external:gsub("### Ответ агента\n\n", "### Ответ агента\n\nExternal response.\n")
    assert_equal(vim.fn.writefile(vim.split(external, "\n", { plain = true }), comment_path), 0)
    controller.dispatch(session, "refresh")
    assert_truthy(vim.wait(2000, function()
      return session.data.comments[1].done and session.data.comments[1].response == "External response."
    end, 10))
    vim.api.nvim_set_current_win(session.owned.diff_win)
    vim.api.nvim_win_set_cursor(session.owned.diff_win, { changed_row(session), 0 })

    controller.dispatch(session, "add_comment")
    save_editor(session, { "Updated preview body.", "Still multiline." })
    assert_equal(session.data.comments[1].body, "Updated preview body.\nStill multiline.")
    assert_truthy(has_marker(session.owned.diff_buf, "VIGIT-001 · Updated preview"))

    controller.dispatch(session, "open_comments")
    assert_truthy(session.owned.comments_buf and vim.api.nvim_buf_is_valid(session.owned.comments_buf))
    assert_equal(vim.bo[session.owned.comments_buf].filetype, "vigit-comments")
    assert_truthy(vim.api.nvim_buf_get_name(session.owned.comments_buf):find("vigit://", 1, true) ~= nil)
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert_truthy(vim.wait(1000, function()
      return session.owned.comments_win == nil
        and vim.api.nvim_get_current_win() == session.owned.diff_win
    end, 10))
    assert_truthy(renderer.target_at(
      session.owned.diff_buf,
      vim.api.nvim_win_get_cursor(session.owned.diff_win)[1]
    ).source_line ~= nil)
    controller.dispatch(session, "open_comments")

    vim.fn.confirm = function() return 2 end
    vim.api.nvim_buf_call(session.owned.comments_buf, function() vim.cmd("normal d") end)
    assert_equal(#session.data.comments, 1)
    vim.fn.confirm = function() return 1 end
    vim.api.nvim_buf_call(session.owned.comments_buf, function() vim.cmd("normal d") end)
    assert_equal(#session.data.comments, 0)

    vim.fn.has = function(feature)
      if feature == "clipboard" then return 0 end
      return original_has(feature)
    end
    controller.dispatch(session, "prepare_prompt")
    assert_truthy(session.owned.prompt_buf and vim.api.nvim_buf_is_valid(session.owned.prompt_buf))
    assert_equal(vim.bo[session.owned.prompt_buf].modifiable, false)
    local prompt_buf, prompt_win = session.owned.prompt_buf, session.owned.prompt_win
    controller.dispatch(session, "prepare_prompt")
    assert_equal(session.owned.prompt_buf, prompt_buf)
    assert_equal(session.owned.prompt_win, prompt_win)
  end, debug.traceback)
  vim.fn.confirm = original_confirm
  vim.fn.has = original_has
  close(session)
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("jumps a comments-list entry to its different changed file in the same vigit tab", function()
  local repo = Fixture.new()
  local session
  local ok, message = xpcall(function()
    for _, path in ipairs({ "src/a.lua", "src/b.lua" }) do
      repo:write(path, { "local value = 1", "return value" })
    end
    repo:git({ "add", "--", "src/a.lua", "src/b.lua" })
    repo:commit("initial")
    repo:write("src/a.lua", { "local value = 1", "return changed_a" })
    repo:write("src/b.lua", { "local value = 1", "return changed_b" })
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function() return first_change(session) ~= nil end, 10))
    local reviews = require("vigit.application.reviews")
    assert_truthy(reviews.add(session, {
      path = "src/b.lua", line = 2, side = "new", section = "unstaged", context = "return changed_b",
    }, "Jump to b.").ok)
    renderer.render(session)

    controller.dispatch(session, "open_comments")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert_truthy(vim.wait(2000, function()
      local selected = session.view.selected_change_id or ""
      return selected:find("src/b.lua", 1, true) ~= nil
        and vim.api.nvim_get_current_tabpage() == session.owned.tab
        and changed_row(session) ~= nil
    end, 10))
    local target = renderer.target_at(session.owned.diff_buf, vim.api.nvim_win_get_cursor(session.owned.diff_win)[1])
    assert_equal(target.path, "src/b.lua")
    assert_equal(target.source_line, 2)
    assert_equal(target.side, "new")
    assert_equal(target.section, "unstaged")
  end, debug.traceback)
  close(session)
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("opens an owned disambiguation list instead of duplicating same-row comments", function()
  local repo = Fixture.new()
  local session
  local ok, message = xpcall(function()
    repo:write("src/service.lua", { "local value = 1", "return value" })
    repo:git({ "add", "--", "src/service.lua" })
    repo:commit("initial")
    repo:write("src/service.lua", { "local value = 1", "return changed" })
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function() return first_change(session) ~= nil end, 10))
    controller.dispatch(session, { name = "select_change", change_id = first_change(session).id })
    assert_truthy(vim.wait(2000, function() return changed_row(session) ~= nil end, 10))
    local reviews = require("vigit.application.reviews")
    local anchor = { path = "src/service.lua", line = 2, side = "new", section = "unstaged", context = "return changed" }
    assert_truthy(reviews.add(session, anchor, "First same-row.").ok)
    assert_truthy(reviews.add(session, anchor, "Second same-row.").ok)
    renderer.render(session)
    vim.api.nvim_set_current_win(session.owned.diff_win)
    vim.api.nvim_win_set_cursor(session.owned.diff_win, { changed_row(session), 0 })
    controller.dispatch(session, "add_comment")
    assert_truthy(session.owned.comments_buf and vim.api.nvim_buf_is_valid(session.owned.comments_buf))
    assert_equal(session.owned.comment_editor_buf, nil)
    assert_equal(#session.data.comments, 2)
  end, debug.traceback)
  close(session)
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("does not render a new-side comment on an old-side-only diff", function()
  local repo = Fixture.new()
  local session
  local ok, message = xpcall(function()
    repo:write("src/deleted.lua", { "return old_value" })
    repo:git({ "add", "--", "src/deleted.lua" })
    repo:commit("initial")
    repo:git({ "rm", "--", "src/deleted.lua" })
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function() return first_change(session) ~= nil end, 10))
    controller.dispatch(session, { name = "select_change", change_id = first_change(session).id })
    assert_truthy(vim.wait(2000, function() return deleted_row(session) ~= nil end, 10))
    local reviews = require("vigit.application.reviews")
    assert_truthy(reviews.add(session, {
      path = "src/deleted.lua", line = 1, side = "new", section = "staged", context = "return replacement",
    }, "Must not jump sides.").ok)
    renderer.render(session)
    assert_equal(has_marker(session.owned.diff_buf, "VIGIT-001"), false)
  end, debug.traceback)
  close(session)
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("keeps an open comment editor bound to its original comment", function()
  local repo = Fixture.new()
  local session
  local ok, message = xpcall(function()
    repo:write("src/service.lua", { "local value = 1", "return value" })
    repo:git({ "add", "--", "src/service.lua" })
    repo:commit("initial")
    repo:write("src/service.lua", { "local value = 1", "return changed" })
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function() return first_change(session) ~= nil end, 10))
    local reviews = require("vigit.application.reviews")
    assert_truthy(reviews.add(session, {
      path = "src/service.lua", line = 2, side = "new", section = "unstaged", context = "return changed",
    }, "First.").ok)
    assert_truthy(reviews.add(session, {
      path = "src/service.lua", line = 1, side = "new", section = "unstaged", context = "local value = 1",
    }, "Second.").ok)
    local comments_view = require("vigit.ui.views.comments")
    assert_truthy(comments_view.open_editor(session, reviews, { comment = session.data.comments[1] }))
    local original_window = session.owned.comment_editor_win
    local failed
    local opened, error = comments_view.open_editor(session, reviews, {
      comment = session.data.comments[2],
      failed = function(value) failed = value end,
    })
    assert_equal(opened, nil)
    assert_equal(error.code, "editor_busy")
    assert_equal(failed.code, "editor_busy")
    assert_equal(session.owned.comment_editor_win, original_window)
    assert_equal(session.owned.comment_editor_id, "VIGIT-001")
  end, debug.traceback)
  close(session)
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("keeps comment documents isolated across two live Vigit roots", function()
  local first_repo, second_repo = Fixture.new(), Fixture.new()
  local first, second
  local ok, message = xpcall(function()
    first = assert(v2.open({ cwd = first_repo.root }))
    second = assert(v2.open({ cwd = second_repo.root }))
    assert_truthy(first.owned.tab ~= second.owned.tab)
    local reviews = require("vigit.application.reviews")
    assert_truthy(reviews.add(first, {
      path = "src/first.lua", line = 1, side = "new", section = "unstaged", context = "first",
    }, "First root.").ok)
    assert_truthy(reviews.add(second, {
      path = "src/second.lua", line = 2, side = "new", section = "unstaged", context = "second",
    }, "Second root.").ok)
    local first_document = table.concat(vim.fn.readfile(first_repo.root .. "/.vigit/comments.md"), "\n")
    local second_document = table.concat(vim.fn.readfile(second_repo.root .. "/.vigit/comments.md"), "\n")
    assert_truthy(first_document:find("First root.", 1, true) ~= nil)
    assert_equal(first_document:find("Second root.", 1, true), nil)
    assert_truthy(second_document:find("Second root.", 1, true) ~= nil)
    assert_equal(second_document:find("First root.", 1, true), nil)
    assert_equal(first.data.comments[1].body, "First root.")
    assert_equal(second.data.comments[1].body, "Second root.")
  end, debug.traceback)
  close(first)
  close(second)
  first_repo:cleanup()
  second_repo:cleanup()
  if not ok then error(message, 0) end
end)

it("keeps a comments reload error after controller refresh completes Git successfully", function()
  local repo = Fixture.new()
  local session, previous
  local ok, message = xpcall(function()
    repo:write("src/service.lua", { "return changed" })
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function() return session.busy.status == nil end, 10))
    assert_equal(vim.fn.mkdir(repo.root .. "/.vigit", "p"), 1)
    assert_equal(vim.fn.writefile({ "## [ ] VIGIT-001 · src/a.lua:1" }, repo.root .. "/.vigit/comments.md"), 0)
    local callbacks
    callbacks, previous = controlled_refresh(session, Reviews.new())
    assert_equal(session.errors.comments.code, "malformed_metadata")
    callbacks[1](Result.ok({ branch = {}, staged = {}, unstaged = {} }))
    assert_equal(session.errors.status, nil)
    assert_equal(session.errors.comments.code, "malformed_metadata")
    assert_equal(session.error.code, "malformed_metadata")
    assert_truthy(rendered_text(session):find("malformed_metadata", 1, true) ~= nil)
  end, debug.traceback)
  if previous then restore_controller(previous) end
  close(session)
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("keeps a Git refresh error after controller refresh successfully reloads comments", function()
  local repo = Fixture.new()
  local session, previous
  local ok, message = xpcall(function()
    repo:write("src/service.lua", { "return changed" })
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function() return session.busy.status == nil end, 10))
    local reviews = Reviews.new()
    assert_truthy(reviews:add(session, {
      path = "src/service.lua", line = 1, side = "new", section = "unstaged", context = "return changed",
    }, "Reloaded comment.").ok)
    session.data.comments = {}
    session.data.comments_count = 0
    local callbacks
    callbacks, previous = controlled_refresh(session, reviews)
    assert_equal(session.errors.comments, nil)
    assert_equal(session.data.comments[1].body, "Reloaded comment.")
    callbacks[1](Result.err("git_status_failed", "Git refresh failed"))
    assert_equal(session.errors.comments, nil)
    assert_equal(session.errors.status.code, "git_status_failed")
    assert_equal(session.error.code, "git_status_failed")
    assert_equal(session.error.message, "Git refresh failed")
    assert_truthy(rendered_text(session):find("git_status_failed", 1, true) ~= nil)
  end, debug.traceback)
  if previous then restore_controller(previous) end
  close(session)
  repo:cleanup()
  if not ok then error(message, 0) end
end)

it("uses review.path for V2 comments, prompt, and session service after lazy V2 load", function()
  local repo = Fixture.new()
  local session
  local config = require("vigit.config")
  local ok, message = xpcall(function()
    assert_truthy(config.setup({ review = { path = ".custom/review.md" } }).ok)
    repo:write("src/service.lua", { "return base" })
    repo:git({ "add", "--", "src/service.lua" })
    repo:commit("initial")
    repo:write("src/service.lua", { "return changed" })
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function() return first_change(session) ~= nil end, 10))
    local reviews = require("vigit.application.reviews")
    assert_truthy(reviews.add(session, {
      path = "src/service.lua", line = 1, side = "new", section = "unstaged", context = "return changed",
    }, "Custom location.").ok)
    assert_truthy(vim.uv.fs_stat(repo.root .. "/.custom/review.md"))
    assert_equal(vim.uv.fs_stat(repo.root .. "/.vigit/comments.md"), nil)
    local prompt = reviews.prompt(session)
    assert_truthy(prompt:find(repo.root .. "/.custom/review.md", 1, true) ~= nil)
    assert_equal(vim.fn.mkdir(repo.root .. "/.vigit/backups", "p"), 1)
    local migrated = reviews.migrate_legacy(session, {
      preview = function()
        return Result.ok({
          importable = 1,
          comments = {
            {
              id = "VIGIT-002", path = "src/service.lua", line = 1, column = 0,
              side = "new", section = "unstaged", context = "return changed",
              body = "Imported custom migration.", response = "", done = false,
            },
          },
          sources = {},
        })
      end,
    }, true)
    assert_truthy(migrated.ok)
    local custom = table.concat(vim.fn.readfile(repo.root .. "/.custom/review.md"), "\n")
    assert_truthy(custom:find("Imported custom migration.", 1, true) ~= nil)
    assert_equal(vim.uv.fs_stat(repo.root .. "/.vigit/comments.md"), nil)
  end, debug.traceback)
  config.setup({})
  close(session)
  repo:cleanup()
  if not ok then error(message, 0) end
end)
