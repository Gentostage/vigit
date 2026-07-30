local Fixture = require("tests.fixtures.git_repo")
local Result = require("vigit.core.result")
local config = require("vigit.config")
local controller = require("vigit.ui.controller")
local neovim = require("vigit.adapters.neovim")
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

local function prepare_repo(repo, files)
  for path, lines in pairs(files) do
    repo:write(path, lines.before)
  end
  repo:git({ "add", "--", "." })
  repo:commit("initial")
  for path, lines in pairs(files) do
    repo:write(path, lines.after)
  end
end

local function find_change(session, relative_path)
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, change in ipairs(session.data.status[section] or {}) do
      if change.path == relative_path then
        return change
      end
    end
  end
end

local function focus_source_row(session, relative_path, needle, column)
  assert_equal(assert(v2.open({ cwd = session.root })), session)
  assert_truthy(vim.wait(2000, function()
    return session.data.status ~= nil and session.busy.status == nil
  end, 10))
  local change = assert(find_change(session, relative_path))
  controller.dispatch(session, {
    name = "select_change",
    change_id = change.id,
  })
  assert_truthy(vim.wait(2000, function()
    return session.data.diffs[change.id] ~= nil
  end, 10))

  local row
  for index, line in ipairs(vim.api.nvim_buf_get_lines(
    session.owned.diff_buf,
    0,
    -1,
    false
  )) do
    local target = renderer.target_at(session.owned.diff_buf, index)
    if line:find(needle, 1, true) and target and target.source_line then
      row = index
      break
    end
  end
  assert_truthy(row)
  vim.api.nvim_set_current_tabpage(session.owned.tab)
  vim.api.nvim_set_current_win(session.owned.diff_win)
  vim.api.nvim_win_set_cursor(session.owned.diff_win, { row, column or 0 })
  return renderer.target_at(session.owned.diff_buf, row)
end

local function tab_var(tab, name)
  return vim.api.nvim_tabpage_get_var(tab, name)
end

local function tab_cwd(tab)
  local current = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_set_current_tabpage(tab)
  local cwd = vim.fn.getcwd(0, 0)
  vim.api.nvim_set_current_tabpage(current)
  return cwd
end

local function vigit_lsp_attach_count(buffer)
  local count = 0
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({
    event = "LspAttach",
    buffer = buffer,
  })) do
    if (autocmd.desc or ""):find("Vigit", 1, true) then
      count = count + 1
    end
  end
  return count
end

it("hands identical relative paths to distinct buffers in one workspace tab", function()
  local repo_a = Fixture.new()
  local repo_b = Fixture.new()
  local sessions = {}
  local source_tabs = {}
  local source_buffers = {}
  local extra_buffers = {}
  local original_cwd = vim.fn.getcwd(-1, -1)
  local ok, message = xpcall(function()
    prepare_repo(repo_a, {
      ["src/service.py"] = {
        before = { "def service():", "  return \"old-a\"" },
        after = { "def service():", "  return \"new-a\"" },
      },
      ["src/other.py"] = {
        before = { "def other():", "  return \"old-other\"" },
        after = { "def other():", "  return \"new-other\"" },
      },
    })
    prepare_repo(repo_b, {
      ["src/service.py"] = {
        before = { "def service():", "  return \"old-b\"" },
        after = { "def service():", "  return \"new-b\"" },
      },
    })

    local session_a = assert(v2.open({ cwd = repo_a.root }))
    local session_b = assert(v2.open({ cwd = repo_b.root }))
    sessions = { session_a, session_b }

    local target_a = focus_source_row(
      session_a,
      "src/service.py",
      "return \"new-a\"",
      4
    )
    controller.dispatch(session_a, "open_file")
    local tab_a = vim.api.nvim_get_current_tabpage()
    local buf_a = vim.api.nvim_get_current_buf()
    source_tabs[#source_tabs + 1] = tab_a
    source_buffers[#source_buffers + 1] = buf_a
    local cursor_a_initial = vim.api.nvim_win_get_cursor(
      vim.api.nvim_get_current_win()
    )
    assert_equal(cursor_a_initial[1], target_a.source_line)
    assert_equal(cursor_a_initial[2], 4)

    local target_b = focus_source_row(
      session_b,
      "src/service.py",
      "return \"new-b\"",
      3
    )
    controller.dispatch(session_b, "open_file")
    local tab_b = vim.api.nvim_get_current_tabpage()
    local buf_b = vim.api.nvim_get_current_buf()
    source_tabs[#source_tabs + 1] = tab_b
    source_buffers[#source_buffers + 1] = buf_b

    assert_equal(tab_a, tab_b)
    assert_truthy(buf_a ~= buf_b)
    assert_equal(vim.bo[buf_a].buflisted, true)
    assert_equal(vim.bo[buf_b].buflisted, true)
    assert_equal(
      vim.api.nvim_buf_get_name(buf_a),
      assert(vim.uv.fs_realpath(repo_a.root .. "/src/service.py"))
    )
    assert_equal(
      vim.api.nvim_buf_get_name(buf_b),
      assert(vim.uv.fs_realpath(repo_b.root .. "/src/service.py"))
    )
    local cursor_b = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
    assert_equal(cursor_b[1], target_b.source_line)
    assert_equal(cursor_b[2], 3)
    assert_equal(tab_var(tab_a, "vigit_root"), session_b.root)
    assert_equal(tab_var(tab_b, "vigit_branch"), session_b.branch)
    assert_equal(tab_var(tab_a, "vigit_role"), "workspace")
    assert_equal(tab_var(tab_b, "vigit_role"), "workspace")
    assert_equal(tab_cwd(tab_b), session_b.root)
    assert_equal(vim.fn.getcwd(-1, -1), original_cwd)
    assert_truthy(tab_var(tab_b, "vigit_label"):find("service.py", 1, true))
    assert_equal(session_a.owned.tab, tab_a)
    assert_equal(session_b.owned.tab, tab_b)
    assert_equal(session_a.owned.source_tab, nil)
    assert_equal(session_b.owned.source_tab, nil)
    assert_equal(session_a.resources.source_buffers[buf_a], (
      assert(vim.uv.fs_realpath(repo_a.root .. "/src/service.py"))
    ))
    assert_equal(session_b.resources.source_buffers[buf_b], (
      assert(vim.uv.fs_realpath(repo_b.root .. "/src/service.py"))
    ))

    local target_other = focus_source_row(
      session_a,
      "src/other.py",
      "return \"new-other\"",
      2
    )
    controller.dispatch(session_a, "open_file")
    local reused_tab = vim.api.nvim_get_current_tabpage()
    local other_buf = vim.api.nvim_get_current_buf()
    source_buffers[#source_buffers + 1] = other_buf
    assert_equal(reused_tab, tab_a)
    assert_equal(vim.bo[other_buf].buflisted, true)
    assert_equal(
      vim.api.nvim_buf_get_name(other_buf),
      assert(vim.uv.fs_realpath(repo_a.root .. "/src/other.py"))
    )
    assert_equal(tab_var(tab_a, "vigit_root"), session_a.root)
    assert_equal(tab_var(tab_a, "vigit_role"), "workspace")
    assert_equal(tab_cwd(tab_a), session_a.root)
    assert_truthy(tab_var(tab_a, "vigit_label"):find("other.py", 1, true))
    local previous_source = vim.api.nvim_buf_get_mark(buf_a, "'")
    assert_equal(previous_source[1], target_a.source_line)
    assert_equal(previous_source[2], 3)

    local unloaded = vim.fn.bufadd(repo_a.root .. "/src/unloaded.py")
    local nofile = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(nofile, repo_a.root .. "/src/not-source.py")
    vim.bo[nofile].buftype = "nofile"
    extra_buffers = { unloaded, nofile }
    local loaded = neovim.loaded_source_buffers(session_a.root)
    assert_truthy(loaded.ok)
    assert_equal(#loaded.value, 2)
    assert_equal(loaded.value[1].path, assert(vim.uv.fs_realpath(
      repo_a.root .. "/src/other.py"
    )))
    assert_equal(loaded.value[2].path, assert(vim.uv.fs_realpath(
      repo_a.root .. "/src/service.py"
    )))

    controller.dispatch(session_a, "close")
    assert_equal(session_a.closed, false)
    assert_equal(vim.api.nvim_tabpage_is_valid(tab_a), true)
    assert_equal(vim.api.nvim_tabpage_is_valid(tab_b), true)
    assert_equal(vim.api.nvim_buf_is_valid(buf_a), true)
    assert_equal(vim.api.nvim_buf_is_valid(buf_b), true)
    assert_equal(vim.fn.getcwd(-1, -1), original_cwd)
    local cursor_a = vim.api.nvim_win_get_cursor(vim.fn.bufwinid(other_buf))
    assert_equal(cursor_a[1], target_other.source_line)
    assert_equal(cursor_a[2], 2)
  end, debug.traceback)

  for _, session in ipairs(sessions) do
    close_session(session)
  end
  for _, buffer in ipairs(source_buffers) do
    delete_buffer(buffer)
  end
  for _, buffer in ipairs(extra_buffers) do
    delete_buffer(buffer)
  end
  repo_a:cleanup()
  repo_b:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("does not inject Vigit lifecycle into a handed-off source buffer", function()
  local repo = Fixture.new()
  local session
  local source_tab
  local source_buffer
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "value = \"old\"" },
        after = { "value = \"new\"" },
      },
    })
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "value = \"new\"", 1)
    local source_path = assert(vim.uv.fs_realpath(
      repo.root .. "/src/service.py"
    ))
    source_buffer = vim.fn.bufadd(source_path)
    vim.fn.bufload(source_buffer)
    local mappings_before = vim.api.nvim_buf_get_keymap(source_buffer, "n")
    local autocmds_before = vim.api.nvim_get_autocmds({
      buffer = source_buffer,
    })
    vim.wo[session.owned.diff_win].winbar = "Vigit owned winbar"
    controller.dispatch(session, "open_file")
    source_tab = vim.api.nvim_get_current_tabpage()
    assert_equal(vim.api.nvim_get_current_buf(), source_buffer)
    local source_window = vim.api.nvim_get_current_win()

    assert_equal(vim.bo[source_buffer].buftype, "")
    assert_equal(vim.wo[source_window].winbar, vim.go.winbar)
    assert_truthy(vim.deep_equal(
      vim.api.nvim_buf_get_keymap(source_buffer, "n"),
      mappings_before
    ))
    assert_truthy(vim.deep_equal(
      vim.api.nvim_get_autocmds({ buffer = source_buffer }),
      autocmds_before
    ))
  end, debug.traceback)

  close_session(session)
  close_tab(source_tab)
  delete_buffer(source_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("filters loaded source buffers by canonical path components", function()
  local repo = Fixture.new()
  local sibling = repo.root .. "-sibling"
  local outside = vim.fn.tempname()
  local buffers = {}
  local ok, message = xpcall(function()
    local control_path = repo.root .. "/inside\ncontrol.lua"
    local aliased_path = repo.root .. "/inside-via-external-alias.lua"
    vim.fn.writefile({ "inside" }, control_path)
    vim.fn.writefile({ "aliased" }, aliased_path)
    vim.fn.mkdir(sibling, "p")
    vim.fn.writefile({ "sibling" }, sibling .. "/file.lua")
    vim.fn.mkdir(outside, "p")
    vim.fn.writefile({ "outside" }, outside .. "/file.lua")
    repo:symlink(outside .. "/file.lua", "outside-link.lua")
    vim.fn.system({ "ln", "-s", "--", aliased_path, outside .. "/inside-alias.lua" })
    assert_equal(vim.v.shell_error, 0)

    for _, path in ipairs({
      control_path,
      sibling .. "/file.lua",
      repo.root .. "/outside-link.lua",
      outside .. "/inside-alias.lua",
    }) do
      local buffer = vim.fn.bufadd(path)
      vim.fn.bufload(buffer)
      buffers[#buffers + 1] = buffer
    end

    local loaded = neovim.loaded_source_buffers(repo.root)
    assert_truthy(loaded.ok)
    assert_equal(#loaded.value, 2)
    assert_equal(loaded.value[1].buf, buffers[1])
    assert_equal(loaded.value[1].path, assert(vim.uv.fs_realpath(control_path)))
    assert_equal(loaded.value[2].buf, buffers[4])
    assert_equal(loaded.value[2].path, assert(vim.uv.fs_realpath(aliased_path)))
  end, debug.traceback)

  for _, buffer in ipairs(buffers) do
    delete_buffer(buffer)
  end
  vim.fn.delete(sibling, "rf")
  vim.fn.delete(outside, "rf")
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("ignores missing external Windows UNC source buffers but fails closed inside target", function()
  local original_package_config = package.config
  local original_adapter = package.loaded["vigit.adapters.neovim"]
  local original_realpath = vim.uv.fs_realpath
  local original_lstat = vim.uv.fs_lstat
  local original_buf_get_name = vim.api.nvim_buf_get_name
  local buffers = {}
  local ok, message = xpcall(function()
    local root = "\\\\server\\share\\repo"
    local external_backslash = "\\\\server\\share\\outside\\missing.py"
    local external_slash = "//server/share/outside/missing.py"
    local inside = "\\\\server\\share\\repo\\missing.py"
    local inside_slash = "//server/share/repo/missing.py"
    local missing = {
      [external_backslash] = true,
      [external_slash] = true,
      [inside] = true,
      [inside_slash] = true,
    }
    local names = {}

    package.config = "\\\\\n;\n?\n!\n-\n"
    package.loaded["vigit.adapters.neovim"] = nil
    local windows_neovim = require("vigit.adapters.neovim")
    vim.uv.fs_realpath = function(path)
      if path == root then
        return root
      end
      if missing[path] then
        return nil
      end
      return original_realpath(path)
    end
    vim.uv.fs_lstat = function(path)
      if missing[path] then
        return nil, nil, "ENOENT"
      end
      return original_lstat(path)
    end
    vim.api.nvim_buf_get_name = function(buffer)
      return names[buffer] or original_buf_get_name(buffer)
    end

    for _, path in ipairs({
      external_backslash,
      external_slash,
      inside,
      inside_slash,
    }) do
      local buffer = vim.api.nvim_create_buf(true, false)
      names[buffer] = path
      buffers[#buffers + 1] = buffer
    end

    local blocked = windows_neovim.loaded_source_buffers(root)
    assert_equal(blocked.ok, false)
    assert_equal(blocked.error.code, "source_buffer_unavailable")

    delete_buffer(buffers[3])
    buffers[3] = nil
    local still_blocked = windows_neovim.loaded_source_buffers(root)
    assert_equal(still_blocked.ok, false)
    assert_equal(still_blocked.error.code, "source_buffer_unavailable")

    delete_buffer(buffers[4])
    buffers[4] = nil
    local ignored = windows_neovim.loaded_source_buffers(root)
    assert_truthy(ignored.ok)
    assert_equal(#ignored.value, 0)
  end, debug.traceback)

  vim.uv.fs_realpath = original_realpath
  vim.uv.fs_lstat = original_lstat
  vim.api.nvim_buf_get_name = original_buf_get_name
  package.config = original_package_config
  package.loaded["vigit.adapters.neovim"] = original_adapter
  for _, buffer in ipairs(buffers) do
    delete_buffer(buffer)
  end
  if not ok then
    error(message, 0)
  end
end)

it("passes a read-only HandlerContext to custom handlers and stores typed errors", function()
  local repo = Fixture.new()
  local session
  local received
  local mutable
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "first", "old" },
        after = { "first", "new" },
      },
    })
    assert_truthy(config.setup({
      handlers = {
        open_file = function(handler_context, done)
          received = handler_context
          mutable = pcall(function()
            handler_context.root = "/mutated"
          end)
          done(Result.err(
            "custom_open_failed",
            "Custom handler refused the handoff",
            "fixture"
          ))
        end,
      },
    }).ok)

    session = assert(v2.open({ cwd = repo.root }))
    local target = focus_source_row(
      session,
      "src/service.py",
      "new",
      2
    )
    controller.dispatch(session, "open_file")

    assert_truthy(received)
    assert_equal(received.session_id, session.id)
    assert_equal(received.root, session.root)
    assert_equal(received.branch, session.branch)
    assert_equal(received.path, assert(vim.uv.fs_realpath(
      repo.root .. "/src/service.py"
    )))
    assert_equal(received.relative_path, "src/service.py")
    assert_equal(received.line, target.source_line)
    assert_equal(received.column, 2)
    assert_equal(received.owned, nil)
    assert_equal(received.data, nil)
    assert_equal(mutable, false)
    assert_equal(session.error.code, "custom_open_failed")
    assert_equal(session.error.message, "Custom handler refused the handoff")
    assert_equal(session.error.details, "fixture")
  end, debug.traceback)

  config.setup(nil)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("ignores open-file completion after the session closes", function()
  local repo = Fixture.new()
  local session
  local callback
  local renders = 0
  local original_render = renderer.render
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "old" },
        after = { "new" },
      },
    })
    assert_truthy(config.setup({
      handlers = {
        open_file = function(_, done)
          callback = done
        end,
      },
    }).ok)
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "new", 0)

    controller.dispatch(session, "open_file")
    assert_truthy(callback)
    local previous_error = session.error
    local previous_handler_error = session.errors.handler
    controller.dispatch(session, "abandon")
    renderer.render = function(...)
      renders = renders + 1
      return original_render(...)
    end

    callback(Result.err("late_open_failed", "Late completion"))
    assert_equal(session.error, previous_error)
    assert_equal(session.errors.handler, previous_handler_error)
    assert_equal(renders, 0)
  end, debug.traceback)

  renderer.render = original_render
  config.setup(nil)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("accepts only the latest open-file completion exactly once", function()
  local repo = Fixture.new()
  local session
  local callbacks = {}
  local renders = 0
  local original_render = renderer.render
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "old" },
        after = { "new" },
      },
    })
    assert_truthy(config.setup({
      handlers = {
        open_file = function(_, done)
          callbacks[#callbacks + 1] = done
        end,
      },
    }).ok)
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "new", 0)
    controller.dispatch(session, "open_file")
    focus_source_row(session, "src/service.py", "new", 0)
    controller.dispatch(session, "open_file")
    assert_equal(#callbacks, 2)

    renderer.render = function(...)
      renders = renders + 1
      return original_render(...)
    end
    callbacks[2](Result.err("current_open_failed", "Current completion"))
    assert_equal(session.error.code, "current_open_failed")
    assert_equal(renders, 1)

    callbacks[1](Result.err("stale_open_failed", "Stale completion"))
    callbacks[2](Result.err("duplicate_open_failed", "Duplicate completion"))
    assert_equal(session.error.code, "current_open_failed")
    assert_equal(renders, 1)
  end, debug.traceback)

  renderer.render = original_render
  config.setup(nil)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("invokes open-file for changes but not directory header or empty rows", function()
  local repo = Fixture.new()
  local session
  local calls = 0
  local received
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/staged.py"] = {
        before = { "old staged" },
        after = { "new staged" },
      },
      ["src/unstaged.py"] = {
        before = { "old unstaged" },
        after = { "new unstaged" },
      },
    })
    repo:git({ "add", "--", "src/staged.py" })
    assert_truthy(config.setup({
      handlers = {
        open_file = function(handler_context, done)
          calls = calls + 1
          received = handler_context
          done(Result.ok())
        end,
      },
    }).ok)
    session = assert(v2.open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function()
      return session.data.status ~= nil and session.busy.status == nil
    end, 10))

    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.api.nvim_set_current_win(session.owned.changes_win)
    local directory_row
    local empty_row
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      session.owned.changes_buf,
      0,
      -1,
      false
    )) do
      local target = renderer.target_at(session.owned.changes_buf, row)
      if target and target.kind == "directory" then
        directory_row = directory_row or row
      elseif line == "" and not target then
        empty_row = row
      end
    end
    assert_truthy(directory_row)
    assert_truthy(empty_row)
    vim.api.nvim_win_set_cursor(session.owned.changes_win, { directory_row, 0 })
    controller.dispatch(session, "open_file")
    vim.api.nvim_win_set_cursor(session.owned.changes_win, { empty_row, 0 })
    controller.dispatch(session, "open_file")

    focus_source_row(session, "src/unstaged.py", "new unstaged", 0)
    local file_header_row
    for row = 1, vim.api.nvim_buf_line_count(session.owned.diff_buf) do
      local target = renderer.target_at(session.owned.diff_buf, row)
      if target and target.kind == "file_header" then
        file_header_row = row
        break
      end
    end
    assert_truthy(file_header_row)
    vim.api.nvim_win_set_cursor(session.owned.diff_win, { file_header_row, 0 })
    controller.dispatch(session, "open_file")

    assert_equal(calls, 0)

    vim.api.nvim_set_current_win(session.owned.changes_win)
    local change_row
    for row = 1, vim.api.nvim_buf_line_count(session.owned.changes_buf) do
      local target = renderer.target_at(session.owned.changes_buf, row)
      if target
          and target.kind == "change"
          and target.change.path == "src/unstaged.py" then
        change_row = row
        break
      end
    end
    assert_truthy(change_row)
    vim.api.nvim_win_set_cursor(session.owned.changes_win, { change_row, 0 })
    controller.dispatch(session, "open_file")

    assert_equal(calls, 1)
    assert_truthy(received)
    assert_equal(received.session_id, session.id)
    assert_equal(received.root, session.root)
    assert_equal(received.branch, session.branch)
    assert_equal(received.relative_path, "src/unstaged.py")
    assert_equal(received.path, assert(vim.uv.fs_realpath(
      repo.root .. "/src/unstaged.py"
    )))
    assert_equal(received.line, 1)
    assert_equal(received.column, 0)
  end, debug.traceback)

  config.setup(nil)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("turns a malformed failed handler Result into a typed error", function()
  local repo = Fixture.new()
  local session
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "old" },
        after = { "new" },
      },
    })
    assert_truthy(config.setup({
      handlers = {
        open_file = function(_, done)
          done({ ok = false })
        end,
      },
    }).ok)
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "new", 0)
    local previous = {
      code = "previous_handler_error",
      message = "Previous handler error",
      retryable = false,
    }
    session.errors.handler = previous
    session.error = previous

    controller.dispatch(session, "open_file")
    assert_equal(session.error.code, "invalid_handler_result")
    assert_equal(session.error.message, "Handler completion must receive a Result")
    assert_equal(session.errors.handler, session.error)
  end, debug.traceback)

  config.setup(nil)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("hands gd to the source buffer user mapping without injecting Vigit mappings", function()
  local repo = Fixture.new()
  local session
  local source_tab
  local source_buffer
  local definition_buffer
  local definition_cursor
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = {
          "def target():",
          "  return 1",
          "",
          "result = target()",
        },
        after = {
          "def target():",
          "  return 1",
          "",
          "result = target() + 1",
        },
      },
    })
    session = assert(v2.open({ cwd = repo.root }))
    local target = focus_source_row(
      session,
      "src/service.py",
      "result = target() + 1",
      9
    )
    local source_path = assert(vim.uv.fs_realpath(
      repo.root .. "/src/service.py"
    ))
    source_buffer = vim.fn.bufadd(source_path)
    vim.fn.bufload(source_buffer)
    vim.keymap.set("n", "gd", function()
      definition_buffer = vim.api.nvim_get_current_buf()
      definition_cursor = vim.api.nvim_win_get_cursor(0)
    end, {
      buffer = source_buffer,
      desc = "Fixture source definition",
    })

    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.api.nvim_set_current_win(session.owned.diff_win)
    assert_equal(vim.fn.maparg("gd", "n", false, true).buffer, 1)
    assert_truthy(
      vim.fn.maparg("gd", "n", false, true).desc:find("Vigit", 1, true)
    )
    controller.dispatch(session, "goto_definition")
    vim.api.nvim_feedkeys("", "x", false)

    assert_truthy(vim.wait(1000, function()
      return definition_buffer ~= nil
    end, 10))
    source_tab = vim.api.nvim_get_current_tabpage()
    assert_equal(definition_buffer, source_buffer)
    assert_equal(definition_cursor[1], target.source_line)
    assert_equal(definition_cursor[2], 9)
    local source_mapping = vim.fn.maparg("gd", "n", false, true)
    assert_equal(source_mapping.buffer, 1)
    assert_equal(source_mapping.desc, "Fixture source definition")
  end, debug.traceback)

  close_session(session)
  close_tab(source_tab)
  delete_buffer(source_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("uses the attached source LSP client for gd exactly once", function()
  local repo = Fixture.new()
  local session
  local source_tab
  local source_buffer
  local definition_calls = 0
  local definition_buffer
  local definition_cursor
  local original_get_clients = vim.lsp.get_clients
  local original_definition = vim.lsp.buf.definition
  local original_search = vim.fn.getreg("/")
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "value = old_value" },
        after = { "value = new_value" },
      },
    })
    session = assert(v2.open({ cwd = repo.root }))
    local target = focus_source_row(
      session,
      "src/service.py",
      "value = new_value",
      8
    )
    source_buffer = vim.fn.bufadd(assert(vim.uv.fs_realpath(
      repo.root .. "/src/service.py"
    )))
    vim.fn.bufload(source_buffer)
    vim.fn.setreg("/", "vigit-lsp-sentinel")
    vim.lsp.get_clients = function(opts)
      assert_equal(opts.bufnr, source_buffer)
      return {
        {
          id = 41,
          name = "fixture-lsp",
          attached_buffers = { [source_buffer] = true },
        },
      }
    end
    vim.lsp.buf.definition = function()
      definition_calls = definition_calls + 1
      definition_buffer = vim.api.nvim_get_current_buf()
      definition_cursor = vim.api.nvim_win_get_cursor(0)
    end

    controller.dispatch(session, "goto_definition")
    source_tab = vim.api.nvim_get_current_tabpage()

    assert_equal(definition_calls, 1)
    assert_equal(definition_buffer, source_buffer)
    assert_equal(definition_cursor[1], target.source_line)
    assert_equal(definition_cursor[2], 8)
    assert_equal(vim.fn.getreg("/"), "vigit-lsp-sentinel")
    assert_equal(session.error, nil)
  end, debug.traceback)

  vim.lsp.get_clients = original_get_clients
  vim.lsp.buf.definition = original_definition
  vim.fn.setreg("/", original_search)
  close_session(session)
  close_tab(source_tab)
  delete_buffer(source_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("continues gd once when LspAttach wins the bounded wait", function()
  local repo = Fixture.new()
  local session
  local source_tab
  local source_buffer
  local definition_calls = 0
  local original_get_clients = vim.lsp.get_clients
  local original_definition = vim.lsp.buf.definition
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "value = old_value" },
        after = { "value = new_value" },
      },
    })
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "value = new_value", 5)
    source_buffer = vim.fn.bufadd(assert(vim.uv.fs_realpath(
      repo.root .. "/src/service.py"
    )))
    vim.fn.bufload(source_buffer)
    vim.lsp.get_clients = function(opts)
      assert_equal(opts.bufnr, source_buffer)
      return {}
    end
    vim.lsp.buf.definition = function()
      definition_calls = definition_calls + 1
      assert_equal(vim.api.nvim_get_current_buf(), source_buffer)
    end

    controller.dispatch(session, "goto_definition")
    source_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_exec_autocmds("LspAttach", {
      buffer = source_buffer,
      data = { client_id = 42 },
    })
    vim.api.nvim_exec_autocmds("LspAttach", {
      buffer = source_buffer,
      data = { client_id = 42 },
    })

    assert_truthy(vim.wait(1000, function()
      return definition_calls == 1
    end, 10))
    assert_equal(definition_calls, 1)
    assert_equal(session.error, nil)
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({
      event = "LspAttach",
      buffer = source_buffer,
    })) do
      assert_truthy(not (autocmd.desc or ""):find("Vigit", 1, true))
    end
  end, debug.traceback)

  vim.lsp.get_clients = original_get_clients
  vim.lsp.buf.definition = original_definition
  close_session(session)
  close_tab(source_tab)
  delete_buffer(source_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("returns lsp_unavailable without moving off the source anchor", function()
  local repo = Fixture.new()
  local session
  local source_tab
  local source_buffer
  local definition_calls = 0
  local original_get_clients = vim.lsp.get_clients
  local original_definition = vim.lsp.buf.definition
  local original_search = vim.fn.getreg("/")
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = {
          "def old_value():",
          "  return 1",
          "result = old_value()",
        },
        after = {
          "def new_value():",
          "  return 1",
          "result = new_value()",
        },
      },
    })
    session = assert(v2.open({ cwd = repo.root }))
    local target = focus_source_row(
      session,
      "src/service.py",
      "result = new_value()",
      11
    )
    source_buffer = vim.fn.bufadd(assert(vim.uv.fs_realpath(
      repo.root .. "/src/service.py"
    )))
    vim.fn.bufload(source_buffer)
    vim.fn.setreg("/", "vigit-timeout-sentinel")
    vim.lsp.get_clients = function(opts)
      assert_equal(opts.bufnr, source_buffer)
      return {}
    end
    vim.lsp.buf.definition = function()
      definition_calls = definition_calls + 1
    end

    controller.dispatch(session, "goto_definition")
    source_tab = vim.api.nvim_get_current_tabpage()

    assert_truthy(vim.wait(1500, function()
      return session.error and session.error.code == "lsp_unavailable"
    end, 10))
    assert_equal(definition_calls, 0)
    assert_equal(vim.api.nvim_get_current_buf(), source_buffer)
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert_equal(cursor[1], target.source_line)
    assert_equal(cursor[2], 11)
    assert_equal(vim.fn.getreg("/"), "vigit-timeout-sentinel")
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({
      event = "LspAttach",
      buffer = source_buffer,
    })) do
      assert_truthy(not (autocmd.desc or ""):find("Vigit", 1, true))
    end
  end, debug.traceback)

  vim.lsp.get_clients = original_get_clients
  vim.lsp.buf.definition = original_definition
  vim.fn.setreg("/", original_search)
  close_session(session)
  close_tab(source_tab)
  delete_buffer(source_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("opens a user-owned terminal split rooted at the current worktree", function()
  local repo = Fixture.new()
  local session
  local terminal_tab
  local terminal_buffer
  local original_global_cwd = vim.fn.getcwd(-1, -1)
  local original_tab_cwd = vim.fn.getcwd(0, 0)
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "value = old_value" },
        after = { "value = new_value" },
      },
    })
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "value = new_value", 0)
    vim.api.nvim_set_current_tabpage(session.owned.tab)
    vim.api.nvim_set_current_win(session.owned.diff_win)
    assert_equal(vim.fn.maparg("T", "n", false, true).buffer, 1)

    controller.dispatch(session, "open_terminal")
    terminal_tab = vim.api.nvim_get_current_tabpage()
    terminal_buffer = vim.api.nvim_get_current_buf()

    assert_equal(vim.bo[terminal_buffer].buftype, "terminal")
    assert_equal(tab_var(terminal_tab, "vigit_root"), session.root)
    assert_equal(tab_var(terminal_tab, "vigit_branch"), session.branch)
    assert_equal(terminal_tab, session.owned.tab)
    assert_equal(tab_var(terminal_tab, "vigit_role"), "workspace")
    assert_truthy(tab_var(terminal_tab, "vigit_label"):find("TERM", 1, true))
    assert_equal(vim.fn.getcwd(-1, -1), original_global_cwd)
    assert_equal(vim.fn.getcwd(0, 0), session.root)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(
      terminal_buffer,
      "n"
    )) do
      assert_truthy(not (mapping.desc or ""):find("Vigit", 1, true))
    end
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({
      buffer = terminal_buffer,
    })) do
      assert_truthy(not (autocmd.desc or ""):find("Vigit", 1, true))
    end
    assert_equal(session.owned.terminal_tab, nil)
    assert_equal(session.owned.terminal_buf, nil)
    assert_equal(session.resources.terminal.buf, terminal_buffer)

    controller.dispatch(session, "close")
    assert_equal(session.closed, false)
    assert_equal(vim.api.nvim_tabpage_is_valid(terminal_tab), true)
    assert_equal(vim.api.nvim_buf_is_valid(terminal_buffer), true)
  end, debug.traceback)

  close_session(session)
  close_tab(terminal_tab)
  delete_buffer(terminal_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("reports an action-specific typed failure from a custom definition handler", function()
  local repo = Fixture.new()
  local session
  local received
  local mutable
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "value = old_value" },
        after = { "value = new_value" },
      },
    })
    assert_truthy(config.setup({
      handlers = {
        goto_definition = function(handler_context)
          received = handler_context
          mutable = pcall(function()
            handler_context.line = 99
          end)
          error("fixture definition handler exploded")
        end,
      },
    }).ok)
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "value = new_value", 6)

    controller.dispatch(session, "goto_definition")

    assert_truthy(received)
    assert_equal(received.session_id, session.id)
    assert_equal(received.root, session.root)
    assert_equal(received.relative_path, "src/service.py")
    assert_equal(received.owned, nil)
    assert_equal(mutable, false)
    assert_equal(session.error.code, "handler_failed")
    assert_equal(session.error.message, "Go-to-definition handler failed")
    assert_truthy(
      session.error.details:find(
        "fixture definition handler exploded",
        1,
        true
      )
    )
  end, debug.traceback)

  config.setup(nil)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("cancels a superseded pending gd before the current LspAttach", function()
  local repo = Fixture.new()
  local session
  local source_tab
  local source_buffer
  local definition_calls = 0
  local original_get_clients = vim.lsp.get_clients
  local original_definition = vim.lsp.buf.definition
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "value = old_value" },
        after = { "value = new_value" },
      },
    })
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "value = new_value", 5)
    source_buffer = vim.fn.bufadd(assert(vim.uv.fs_realpath(
      repo.root .. "/src/service.py"
    )))
    vim.fn.bufload(source_buffer)
    vim.lsp.get_clients = function()
      return {}
    end
    vim.lsp.buf.definition = function()
      definition_calls = definition_calls + 1
      assert_equal(vim.api.nvim_get_current_buf(), source_buffer)
    end

    controller.dispatch(session, "goto_definition")
    source_tab = vim.api.nvim_get_current_tabpage()
    assert_equal(vigit_lsp_attach_count(source_buffer), 1)

    focus_source_row(session, "src/service.py", "value = new_value", 5)
    controller.dispatch(session, "goto_definition")
    assert_equal(vigit_lsp_attach_count(source_buffer), 1)

    vim.api.nvim_exec_autocmds("LspAttach", {
      buffer = source_buffer,
      data = { client_id = 51 },
    })
    assert_truthy(vim.wait(1000, function()
      return definition_calls == 1
    end, 10))
    assert_equal(vigit_lsp_attach_count(source_buffer), 0)
    local stale_changed_state = vim.wait(500, function()
      return definition_calls > 1 or session.error ~= nil
    end, 10)
    assert_equal(stale_changed_state, false)
    assert_equal(definition_calls, 1)
  end, debug.traceback)

  vim.lsp.get_clients = original_get_clients
  vim.lsp.buf.definition = original_definition
  close_session(session)
  close_tab(source_tab)
  delete_buffer(source_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

local function assert_disposal_cancels_pending_definition(intent)
  local repo = Fixture.new()
  local session
  local source_tab
  local source_buffer
  local review_tab
  local definition_calls = 0
  local original_get_clients = vim.lsp.get_clients
  local original_definition = vim.lsp.buf.definition
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "value = old_value" },
        after = { "value = new_value" },
      },
    })
    session = assert(v2.open({ cwd = repo.root }))
    review_tab = session.owned.tab
    focus_source_row(session, "src/service.py", "value = new_value", 4)
    source_buffer = vim.fn.bufadd(assert(vim.uv.fs_realpath(
      repo.root .. "/src/service.py"
    )))
    vim.fn.bufload(source_buffer)
    vim.lsp.get_clients = function()
      return {}
    end
    vim.lsp.buf.definition = function()
      definition_calls = definition_calls + 1
    end

    controller.dispatch(session, "goto_definition")
    source_tab = vim.api.nvim_get_current_tabpage()
    assert_equal(vigit_lsp_attach_count(source_buffer), 1)
    controller.dispatch(session, intent)

    local abandoned = intent == "abandon"
    assert_equal(session.closed, abandoned)
    assert_equal(vigit_lsp_attach_count(source_buffer), 0)
    vim.api.nvim_exec_autocmds("LspAttach", {
      buffer = source_buffer,
      data = { client_id = 52 },
    })
    local stale_side_effect = vim.wait(500, function()
      return definition_calls > 0 or session.error ~= nil
    end, 10)
    assert_equal(stale_side_effect, false)
    assert_equal(definition_calls, 0)
  end, debug.traceback)

  vim.lsp.get_clients = original_get_clients
  vim.lsp.buf.definition = original_definition
  close_session(session)
  close_tab(source_tab)
  close_tab(review_tab)
  delete_buffer(source_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end

it("cancels a pending gd when review is hidden", function()
  assert_disposal_cancels_pending_definition("close")
end)

it("cancels a pending gd before abandoning the review session", function()
  assert_disposal_cancels_pending_definition("abandon")
end)

it("refuses LSP side effects after the source window changes buffer", function()
  local repo = Fixture.new()
  local session
  local source_tab
  local source_buffer
  local other_buffer
  local definition_calls = 0
  local original_get_clients = vim.lsp.get_clients
  local original_definition = vim.lsp.buf.definition
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "value = old_value" },
        after = { "value = new_value" },
      },
    })
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "value = new_value", 3)
    source_buffer = vim.fn.bufadd(assert(vim.uv.fs_realpath(
      repo.root .. "/src/service.py"
    )))
    vim.fn.bufload(source_buffer)
    vim.lsp.get_clients = function()
      return {}
    end
    vim.lsp.buf.definition = function()
      definition_calls = definition_calls + 1
    end

    controller.dispatch(session, "goto_definition")
    source_tab = vim.api.nvim_get_current_tabpage()
    local source_window = vim.api.nvim_get_current_win()
    other_buffer = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(other_buffer, repo.root .. "/src/other.py")
    vim.api.nvim_win_set_buf(source_window, other_buffer)

    vim.api.nvim_exec_autocmds("LspAttach", {
      buffer = source_buffer,
      data = { client_id = 53 },
    })
    assert_truthy(vim.wait(1000, function()
      return session.error and session.error.code == "source_unavailable"
    end, 10))
    assert_equal(definition_calls, 0)
    assert_equal(vim.api.nvim_win_get_buf(source_window), other_buffer)
    assert_equal(vigit_lsp_attach_count(source_buffer), 0)
  end, debug.traceback)

  vim.lsp.get_clients = original_get_clients
  vim.lsp.buf.definition = original_definition
  close_session(session)
  close_tab(source_tab)
  delete_buffer(source_buffer)
  delete_buffer(other_buffer)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("calls custom cancellation once on supersede and once on abandon", function()
  local repo = Fixture.new()
  local session
  local cancel_calls = 0
  local callbacks = {}
  local cancel_handles = {}
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "value = old_value" },
        after = { "value = new_value" },
      },
    })
    assert_truthy(config.setup({
      handlers = {
        goto_definition = function(_, done)
          callbacks[#callbacks + 1] = done
          local cancelled = false
          local function cancel()
            if cancelled then
              return
            end
            cancelled = true
            cancel_calls = cancel_calls + 1
          end
          cancel_handles[#cancel_handles + 1] = cancel
          return cancel
        end,
      },
    }).ok)
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "value = new_value", 0)

    controller.dispatch(session, "goto_definition")
    focus_source_row(session, "src/service.py", "value = new_value", 0)
    controller.dispatch(session, "goto_definition")
    assert_equal(cancel_calls, 1)
    controller.dispatch(session, "abandon")
    assert_equal(cancel_calls, 2)

    for _, cancel in ipairs(cancel_handles) do
      cancel()
      cancel()
    end
    callbacks[1](Result.err("stale", "Stale completion"))
    callbacks[2](Result.err("late", "Late completion"))
    assert_equal(cancel_calls, 2)
  end, debug.traceback)

  config.setup(nil)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)

it("does not retain a cancel handle returned after synchronous completion", function()
  local repo = Fixture.new()
  local session
  local cancel_calls = 0
  local ok, message = xpcall(function()
    prepare_repo(repo, {
      ["src/service.py"] = {
        before = { "value = old_value" },
        after = { "value = new_value" },
      },
    })
    assert_truthy(config.setup({
      handlers = {
        goto_definition = function(_, done)
          done(Result.ok())
          return function()
            cancel_calls = cancel_calls + 1
          end
        end,
      },
    }).ok)
    session = assert(v2.open({ cwd = repo.root }))
    focus_source_row(session, "src/service.py", "value = new_value", 0)

    controller.dispatch(session, "goto_definition")
    controller.dispatch(session, "close")
    assert_equal(cancel_calls, 0)
  end, debug.traceback)

  config.setup(nil)
  close_session(session)
  repo:cleanup()
  if not ok then
    error(message, 0)
  end
end)
