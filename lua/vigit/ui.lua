local State = require("vigit.state")
local highlights = require("vigit.highlights")

local M = {}

local active_session = nil
local sessions_by_root = {}
local CHANGES_MIN_WIDTH = 30
local CHANGES_MAX_WIDTH = 50
local CHANGES_WIDTH_RATIO = 0.28
local DIFF_MIN_WIDTH = 40

local function layout_windows_are_valid(session)
  return session
    and session.changes_win
    and vim.api.nvim_win_is_valid(session.changes_win)
    and session.diff_win
    and vim.api.nvim_win_is_valid(session.diff_win)
end

local function target_changes_width()
  local available = math.max(vim.o.columns - 1, 1)
  local proportional = math.floor(available * CHANGES_WIDTH_RATIO)
  local target = math.max(CHANGES_MIN_WIDTH, math.min(CHANGES_MAX_WIDTH, proportional))
  return math.max(1, math.min(target, available - math.min(DIFF_MIN_WIDTH, available - 1)))
end

local function apply_layout(session)
  if not layout_windows_are_valid(session) then
    return false
  end
  vim.api.nvim_set_option_value("winfixwidth", true, { scope = "local", win = session.changes_win })
  vim.api.nvim_set_option_value("winfixwidth", false, { scope = "local", win = session.diff_win })
  vim.api.nvim_win_set_width(session.changes_win, target_changes_width())
  return true
end

local function valid_tab(tab)
  return tab and vim.api.nvim_tabpage_is_valid(tab)
end

local function normalize_root(path)
  return vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
end

local function worktree_name(path)
  return normalize_root(path):match("([^/]+)$") or normalize_root(path)
end

local function session_is_valid(session)
  return session and valid_tab(session.vigit_tab)
end

local function set_active_session(session)
  if session_is_valid(session) then
    active_session = session
  end
end

local function capture_cursor(win)
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_cursor(win)
  end
  return { 1, 0 }
end

local function restore_cursor(win, position)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local row = math.min(math.max(position[1] or 1, 1), line_count)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local col = math.min(math.max(position[2] or 0, 0), #line)
  vim.api.nvim_win_set_cursor(win, { row, col })
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Vigit" })
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function make_buffer(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

function M.render(session)
  local review = require("vigit.review")
  local comments, err = review.comments(session.root)
  session.review_comments = comments or {}
  session.review_error = err
  session.review_count = #session.review_comments
  set_lines(session.changes_buf, session.state.changes_lines)
  set_lines(session.diff_buf, session.state.diff_lines)
  highlights.decorate(session)
end

function M.render_diff(session)
  local review = require("vigit.review")
  local comments, err = review.comments(session.root)
  session.review_comments = comments or {}
  session.review_error = err
  session.review_count = #session.review_comments
  set_lines(session.diff_buf, session.state.diff_lines)
  highlights.decorate(session)
end

function M.resize(session)
  session = session or active_session
  if not apply_layout(session) then
    return false
  end
  highlights.decorate(session)
  return true
end

local function local_normal_mapping(buf, lhs)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local mapping = nil
  vim.api.nvim_buf_call(buf, function()
    local found = vim.fn.maparg(lhs, "n", false, true)
    if type(found) == "table" and found.buffer == 1 and next(found) ~= nil then
      mapping = found
    end
  end)
  return mapping
end

local function buffer_display_path(session, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return "[No Name]"
  end
  local root = vim.fn.fnamemodify(session.state.cwd, ":p")
  local absolute = vim.fn.fnamemodify(name, ":p")
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end
  if absolute:sub(1, #root) == root then
    return absolute:sub(#root + 1)
  end
  return vim.fn.fnamemodify(absolute, ":~")
end

local function decorate_editor_window(session, buf, win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local display_path = buffer_display_path(session, buf):gsub("%%", "%%%%")
  vim.api.nvim_set_option_value("winbar", table.concat({
    "%#VigitPanelTitle#  VIGIT · EDIT · ",
    "%<",
    display_path,
    "%=",
    "%#VigitPanelHint# :w save · Q back ",
  }), { scope = "local", win = win })
end

local function remove_editor_mappings(editor)
  if not editor then
    return
  end
  if editor.bufenter_autocmd then
    pcall(vim.api.nvim_del_autocmd, editor.bufenter_autocmd)
  end
  for buf, tracked in pairs(editor.buffers or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.keymap.del, "n", "Q", { buffer = buf })
      if tracked.previous_q_mapping then
        vim.api.nvim_buf_call(buf, function()
          vim.fn.mapset("n", false, tracked.previous_q_mapping)
        end)
      end
    end
  end
end

local function attach_editor_buffer(session, buf, win)
  local editor = session and session.editor or nil
  if not editor or not valid_tab(editor.tab) or vim.api.nvim_get_current_tabpage() ~= editor.tab then
    return false
  end
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == "" then
    return false
  end

  if not editor.buffers[buf] then
    editor.buffers[buf] = {
      previous_q_mapping = local_normal_mapping(buf, "Q"),
    }
    vim.keymap.set("n", "Q", function()
      M.return_from_editor(session)
    end, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "Return to Vigit",
    })
  end
  decorate_editor_window(session, buf, win)
  return true
end

local function modified_editor_buffers(session, editor)
  local modified = {}
  for buf in pairs(editor.buffers or {}) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      modified[#modified + 1] = buffer_display_path(session, buf)
    end
  end
  table.sort(modified)
  return modified
end

local function finish_editor(session, opts)
  opts = opts or {}
  local editor = session and session.editor or nil
  if not editor then
    return
  end
  session.editor = nil
  remove_editor_mappings(editor)

  if (opts.focus or active_session == session) and valid_tab(session.vigit_tab) then
    vim.api.nvim_set_current_tabpage(session.vigit_tab)
  end

  local ok, err = session.state:refresh()
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return
  end
  M.render(session)
  restore_cursor(session.changes_win, editor.positions.changes)
  restore_cursor(session.diff_win, editor.positions.diff)
end

local function forget_session(session)
  if not session then
    return
  end
  if sessions_by_root[session.root] == session then
    sessions_by_root[session.root] = nil
  end
  if active_session == session then
    active_session = nil
  end
  remove_editor_mappings(session.editor)
  session.editor = nil
  if session.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
    session.augroup = nil
  end
end

function M.close(session)
  session = session or active_session
  if not session then
    return false
  end
  local modified = session.editor and modified_editor_buffers(session, session.editor) or {}
  if #modified > 0 then
    notify("Unsaved files: " .. table.concat(modified, ", ") .. ". Use :w before closing", vim.log.levels.WARN)
    return false
  end
  if valid_tab(session.vigit_tab) then
    vim.api.nvim_set_current_tabpage(session.vigit_tab)
    local ok, err = pcall(vim.cmd, "tabclose")
    if not ok then
      notify(tostring(err), vim.log.levels.ERROR)
      return false
    end
  end
  forget_session(session)
  return true
end

local function map(session, buf, lhs, fn)
  vim.keymap.set("n", lhs, function()
    fn(session)
  end, { buffer = buf, silent = true, nowait = true })
end

local function attach_keymaps(session)
  local actions = require("vigit.actions")
  for _, buf in ipairs({ session.changes_buf, session.diff_buf }) do
    map(session, buf, "q", actions.close)
    map(session, buf, "r", actions.refresh)
    map(session, buf, "f", actions.toggle_full_context)
    map(session, buf, "s", actions.stage)
    map(session, buf, "a", actions.show_all_files)
    map(session, buf, "e", actions.edit_file)
    map(session, buf, "c", actions.add_review_comment)
    map(session, buf, "C", actions.open_reviews)
    map(session, buf, "P", actions.prepare_review)
    map(session, buf, "w", actions.open_worktrees)
    map(session, buf, "]w", actions.next_worktree)
    map(session, buf, "[w", actions.previous_worktree)
    map(session, buf, "<CR>", actions.select_file)
  end
  vim.keymap.set("x", "c", function()
    actions.add_review_comment(session, { visual = true })
  end, { buffer = session.diff_buf, silent = true, nowait = true })
  map(session, session.diff_buf, "gd", actions.goto_definition)
  map(session, session.changes_buf, "t", actions.toggle_changes_view)
  map(session, session.changes_buf, "h", actions.collapse_directory)
  map(session, session.changes_buf, "l", actions.expand_directory)
end

function M.open(opts)
  opts = opts or {}
  highlights.setup()

  local requested_cwd = opts.cwd or vim.fn.getcwd()
  local root, root_err = require("vigit.git").root(requested_cwd)
  if not root then
    local message = root_err or "Not inside a Git repository"
    notify(message, vim.log.levels.ERROR)
    return nil, message
  end
  root = normalize_root(root)

  local existing = sessions_by_root[root]
  if session_is_valid(existing) then
    vim.api.nvim_set_current_tabpage(existing.vigit_tab)
    set_active_session(existing)
    local ok, refresh_err = existing.state:refresh()
    if not ok then
      notify(refresh_err, vim.log.levels.ERROR)
      return nil, refresh_err
    end
    M.render(existing)
    return existing, nil
  elseif existing then
    forget_session(existing)
  end

  local state = State.new({ cwd = root })
  local is_repo, repo_err = state.git.is_repo(root)
  if not is_repo then
    local message = repo_err or "Not inside a Git repository"
    notify(message, vim.log.levels.ERROR)
    return nil, message
  end

  local ok, refresh_err = state:refresh()
  if not ok then
    notify(refresh_err, vim.log.levels.ERROR)
    return nil, refresh_err
  end

  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(root))
  local vigit_tab = vim.api.nvim_get_current_tabpage()
  local changes_buf = make_buffer("Vigit Changes · " .. root, "vigit")
  local diff_buf = make_buffer("Vigit Diff · " .. root, "diff")
  -- Built-in diff syntax paints whole added/removed lines and would cover the
  -- language-aware highlights added by Vigit.
  vim.bo[diff_buf].syntax = ""
  vim.api.nvim_win_set_buf(0, diff_buf)
  local diff_win = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit")
  local changes_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(changes_win, changes_buf)
  vim.api.nvim_set_current_win(diff_win)

  local session = {
    state = state,
    root = root,
    worktree_name = worktree_name(root),
    branch = state.git.branch(root) or "(unknown)",
    changes_buf = changes_buf,
    diff_buf = diff_buf,
    changes_win = changes_win,
    diff_win = diff_win,
    vigit_tab = vigit_tab,
    editor = nil,
    review_comments = {},
    review_error = nil,
    review_count = 0,
  }
  sessions_by_root[root] = session
  set_active_session(session)
  apply_layout(session)

  session.augroup = vim.api.nvim_create_augroup("VigitSession" .. changes_buf, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = session.augroup,
    callback = function()
      vim.schedule(function()
        if active_session == session then
          M.resize(session)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = session.augroup,
    callback = function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      if current_tab == session.vigit_tab or (session.editor and current_tab == session.editor.tab) then
        set_active_session(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = session.augroup,
    buffer = changes_buf,
    callback = function()
      if active_session == session and session.state:is_single_file() then
        require("vigit.actions").preview_file(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = session.augroup,
    callback = function()
      vim.schedule(function()
        if not valid_tab(session.vigit_tab) then
          forget_session(session)
        elseif session.editor and not valid_tab(session.editor.tab) then
          finish_editor(session)
        end
      end)
    end,
  })
  M.render(session)
  attach_keymaps(session)
  return session, nil
end

function M.active_session()
  return active_session
end

function M.sessions()
  local result = {}
  for root, session in pairs(sessions_by_root) do
    if session_is_valid(session) then
      result[#result + 1] = session
    else
      sessions_by_root[root] = nil
    end
  end
  table.sort(result, function(left, right)
    return vim.api.nvim_tabpage_get_number(left.vigit_tab) < vim.api.nvim_tabpage_get_number(right.vigit_tab)
  end)
  return result
end

function M.session_for(path)
  local root = require("vigit.git").root(path)
  if not root then
    return nil
  end
  local session = sessions_by_root[normalize_root(root)]
  return session_is_valid(session) and session or nil
end

function M.focus_worktree(path)
  local session = M.session_for(path)
  if session then
    vim.api.nvim_set_current_tabpage(session.vigit_tab)
    set_active_session(session)
    local ok, err = session.state:refresh()
    if not ok then
      notify(err, vim.log.levels.ERROR)
      return nil, err
    end
    M.render(session)
    return session, nil
  end
  return M.open({ cwd = path })
end

function M.cycle_worktree(direction)
  local sessions = M.sessions()
  if #sessions == 0 then
    return false
  end
  local current_index = 1
  for index, session in ipairs(sessions) do
    if session == active_session then
      current_index = index
      break
    end
  end
  local offset = direction and direction < 0 and -1 or 1
  local target_index = ((current_index - 1 + offset) % #sessions) + 1
  local target = sessions[target_index]
  vim.api.nvim_set_current_tabpage(target.vigit_tab)
  set_active_session(target)
  return true
end

function M.focus_file(session, file)
  if not file then
    notify("No file under cursor", vim.log.levels.WARN)
    return false
  end

  local line = session.state:diff_line_for_file(file)
  if not line then
    notify("No diff available for " .. file.path, vim.log.levels.WARN)
    return false
  end

  vim.api.nvim_set_current_win(session.diff_win)
  vim.api.nvim_win_set_cursor(session.diff_win, { line, 0 })
  vim.api.nvim_win_call(session.diff_win, function()
    vim.cmd("normal! zz")
  end)
  return true
end

function M.focus_overview(session)
  if not session.diff_win or not vim.api.nvim_win_is_valid(session.diff_win) then
    return false
  end
  local target_line = 1
  for row = 1, #session.state.diff_lines do
    local meta = session.state.diff_map[row]
    if meta and meta.kind == "file_header" then
      target_line = row
      break
    end
  end
  vim.api.nvim_set_current_win(session.diff_win)
  vim.api.nvim_win_set_cursor(session.diff_win, { target_line, 0 })
  return true
end

function M.return_from_editor(session)
  local editor = session and session.editor or nil
  if not editor then
    return false
  end
  local modified = modified_editor_buffers(session, editor)
  if #modified > 0 then
    notify("Unsaved files: " .. table.concat(modified, ", ") .. ". Use :w before Q", vim.log.levels.WARN)
    return false
  end

  if valid_tab(editor.tab) then
    vim.api.nvim_set_current_tabpage(editor.tab)
    local ok, err = pcall(vim.cmd, "tabclose")
    if not ok then
      notify(tostring(err), vim.log.levels.ERROR)
      return false
    end
  end
  finish_editor(session, { focus = true })
  return true
end

function M.open_editor(session, file, target_line, opts)
  opts = opts or {}
  if session.editor and valid_tab(session.editor.tab) then
    vim.api.nvim_set_current_tabpage(session.editor.tab)
    notify("An edit tab is already open", vim.log.levels.INFO)
    return true
  end
  if session.editor then
    finish_editor(session)
  end

  local path = vim.fn.fnamemodify(vim.fs.joinpath(session.state.cwd, file.path), ":p")
  if vim.fn.filereadable(path) == 0 then
    notify("File does not exist: " .. file.path, vim.log.levels.WARN)
    return false
  end

  local positions = {
    changes = capture_cursor(session.changes_win),
    diff = capture_cursor(session.diff_win),
  }

  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(session.root))
  local editor_tab = vim.api.nvim_get_current_tabpage()
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    pcall(vim.cmd, "tabclose")
    notify(tostring(err), vim.log.levels.ERROR)
    return false
  end

  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local line_count = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local row = math.min(math.max(tonumber(target_line) or 1, 1), line_count)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local column = math.min(math.max(tonumber(opts.column) or 0, 0), #line)
  vim.api.nvim_win_set_cursor(win, { row, column })

  session.editor = {
    tab = editor_tab,
    positions = positions,
    buffers = {},
  }
  session.editor.bufenter_autocmd = vim.api.nvim_create_autocmd("BufEnter", {
    group = session.augroup,
    callback = function(args)
      if session.editor and session.editor.tab == editor_tab then
        attach_editor_buffer(session, args.buf, vim.api.nvim_get_current_win())
      end
    end,
  })
  attach_editor_buffer(session, buf, win)
  if opts.after_open then
    opts.after_open(buf, win)
  end
  return true
end

return M
