local Fixture = require("tests.fixtures.git_repo")
local config = require("vigit.config")
local controller = require("vigit.ui.controller")
local renderer = require("vigit.ui.renderer")
local v2 = require("vigit.v2")

local function close_session(session)
  if session and not session.closed then
    controller.dispatch(session, "abandon")
  end
end

local function close_tab(tab)
  if not tab or not vim.api.nvim_tabpage_is_valid(tab) then
    return
  end
  if #vim.api.nvim_list_tabpages() == 1 then
    vim.cmd("tabnew")
  end
  vim.api.nvim_set_current_tabpage(tab)
  vim.cmd("tabclose")
end

local function delete_buffer(buffer)
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    pcall(vim.api.nvim_buf_delete, buffer, { force = true })
  end
end

local function find_change(session, path)
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, change in ipairs(session.data.status[section] or {}) do
      if change.path == path then
        return change
      end
    end
  end
end

local function find_source_row(session, source_line, kind)
  local lines = vim.api.nvim_buf_get_lines(
    session.owned.diff_buf,
    0,
    -1,
    false
  )
  for row = 1, #lines do
    local target = renderer.target_at(session.owned.diff_buf, row)
    if target
        and target.kind == kind
        and target.source_line == source_line then
      return row, target
    end
  end
end

local function contains_line(buffer, expected)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    if line == expected then
      return true
    end
  end
  return false
end

it("preserves a real line-90 byte anchor through f and native e handoff", function()
  local repo = Fixture.new()
  local session
  local source_tab
  local source_buffer
  local ok, message = xpcall(function()
    local before = {}
    local after = {}
    for line = 1, 120 do
      before[line] = string.format("value_%03d = %d", line, line)
      after[line] = before[line]
    end
    before[90] = "target_value = \"old\""
    after[90] = "target_value = \"new\""
    repo:write("src/long_service.py", before)
    repo:git({ "add", "--", "src/long_service.py" })
    repo:commit("initial")
    repo:write("src/long_service.py", after)

    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function()
      return session.data.status ~= nil and session.busy.status == nil
    end, 10))
    local change = assert(find_change(session, "src/long_service.py"))
    controller.dispatch(session, {
      name = "select_change",
      change_id = change.id,
    })
    assert_truthy(vim.wait(2000, function()
      return session.data.diffs[change.id] ~= nil
        and find_source_row(session, 90, "add") ~= nil
    end, 10))

    local row = assert(find_source_row(session, 90, "add"))
    local original_column = 9
    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.api.nvim_set_current_win(session.owned.diff_win)
    vim.api.nvim_win_set_cursor(
      session.owned.diff_win,
      { row, original_column }
    )

    controller.dispatch(session, "f")
    assert_truthy(contains_line(session.owned.diff_buf, "Loading diff…"))
    assert_truthy(contains_line(
      session.owned.diff_buf,
      "target_value = \"new\""
    ))
    assert_truthy(vim.wait(2000, function()
      return not session.busy.diff[change.id]
        and not contains_line(session.owned.diff_buf, "Loading diff…")
    end, 10))
    local expanded_cursor = vim.api.nvim_win_get_cursor(session.owned.diff_win)
    local expanded_target = assert(renderer.target_at(
      session.owned.diff_buf,
      expanded_cursor[1]
    ))
    assert_equal(expanded_target.source_line, 90)
    assert_equal(expanded_cursor[2], original_column)

    controller.dispatch(session, "open_file")
    source_tab = vim.api.nvim_get_current_tabpage()
    source_buffer = vim.api.nvim_get_current_buf()
    assert_equal(source_tab, session.owned.tab)
    assert_equal(
      vim.api.nvim_buf_get_name(source_buffer),
      assert(vim.uv.fs_realpath(repo.root .. "/src/long_service.py"))
    )
    assert_truthy(vim.deep_equal(
      vim.api.nvim_win_get_cursor(0),
      { 90, original_column }
    ))

    assert_equal(assert(v2.open({ cwd = repo.root })), session)
    vim.api.nvim_set_current_win(session.owned.diff_win)
    local returned_cursor = vim.api.nvim_win_get_cursor(session.owned.diff_win)
    local returned_target = assert(renderer.target_at(
      session.owned.diff_buf,
      returned_cursor[1]
    ))
    assert_equal(returned_target.source_line, 90)
    assert_equal(returned_cursor[2], original_column)

    local shifted = {}
    for line = 1, 89 do
      shifted[#shifted + 1] = after[line]
    end
    for line = 1, 10 do
      shifted[#shifted + 1] = string.format("inserted_%03d = true", line)
    end
    for line = 90, #after do
      shifted[#shifted + 1] = after[line]
    end
    repo:write("src/long_service.py", shifted)
    local previous_generation = session.reads.generation
    controller.dispatch(session, "refresh")
    assert_truthy(contains_line(
      session.owned.diff_buf,
      "target_value = \"new\""
    ))
    assert_truthy(contains_line(
      session.owned.diff_buf,
      "Refreshing changes…"
    ))
    assert_truthy(vim.wait(3000, function()
      return session.reads.generation > previous_generation
        and session.busy.status == nil
        and not session.busy.diff[change.id]
        and find_source_row(session, 100, "add") ~= nil
    end, 10))

    local refreshed_cursor = vim.api.nvim_win_get_cursor(
      session.owned.diff_win
    )
    local refreshed_target = assert(renderer.target_at(
      session.owned.diff_buf,
      refreshed_cursor[1]
    ))
    local refreshed_text = vim.api.nvim_buf_get_lines(
      session.owned.diff_buf,
      refreshed_cursor[1] - 1,
      refreshed_cursor[1],
      false
    )[1]
    assert_equal(refreshed_text, "target_value = \"new\"")
    assert_equal(refreshed_target.path, change.path)
    assert_equal(refreshed_target.source_line, 100)
    assert_equal(refreshed_cursor[2], original_column)
  end, debug.traceback)

  close_session(session)
  delete_buffer(source_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("opens a diff_too_large file placeholder with e at line one", function()
  local repo = Fixture.new()
  local session
  local source_tab
  local source_buffer
  local previous_config = config.get()
  local ok, message = xpcall(function()
    config.setup({
      ui = {
        max_diff_bytes = 32,
      },
    })
    repo:write("src/oversized.py", { "value = \"old\"" })
    repo:git({ "add", "--", "src/oversized.py" })
    repo:commit("initial")
    repo:write("src/oversized.py", {
      "value = \"" .. string.rep("new", 100) .. "\"",
    })

    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function()
      return session.data.status ~= nil and session.busy.status == nil
    end, 10))
    local change = assert(find_change(session, "src/oversized.py"))
    controller.dispatch(session, {
      name = "select_change",
      change_id = change.id,
    })
    assert_truthy(vim.wait(2000, function()
      return session.errors.diffs[change.id]
        and session.errors.diffs[change.id].code == "diff_too_large"
    end, 10))

    local placeholder_row
    for row = 1, vim.api.nvim_buf_line_count(session.owned.diff_buf) do
      local target = renderer.target_at(session.owned.diff_buf, row)
      if target and target.kind == "file_placeholder" then
        placeholder_row = row
        break
      end
    end
    assert_truthy(placeholder_row)
    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.api.nvim_set_current_win(session.owned.diff_win)
    vim.api.nvim_win_set_cursor(session.owned.diff_win, { placeholder_row, 0 })
    controller.dispatch(session, "open_file")

    source_tab = vim.api.nvim_get_current_tabpage()
    source_buffer = vim.api.nvim_get_current_buf()
    assert_truthy(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 0 }))
    assert_equal(
      vim.api.nvim_buf_get_name(source_buffer),
      assert(vim.uv.fs_realpath(repo.root .. "/src/oversized.py"))
    )
  end, debug.traceback)

  config.setup(previous_config)
  close_session(session)
  delete_buffer(source_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)
