-- Public Vigit runtime.
local process = require("vigit.adapters.process")
local Git = require("vigit.adapters.git_cli")
local neovim = require("vigit.adapters.neovim")
local Changes = require("vigit.application.changes")
local Reviews = require("vigit.application.reviews")
local Workspace = require("vigit.application.workspace")
local Worktrees = require("vigit.application.worktrees")
local config = require("vigit.config")
local Result = require("vigit.core.result")
local controller = require("vigit.ui.controller")
local keymaps = require("vigit.ui.keymaps")
local layout = require("vigit.ui.layout")
local registry_module = require("vigit.ui.registry")
local renderer = require("vigit.ui.renderer")
local Session = require("vigit.ui.session")
local worktrees_view = require("vigit.ui.views.worktrees")
local log = require("vigit.ui.log")

local M = {}

local next_id = 0
local commands_registered = false
local registry = registry_module.new(function(path)
  return path
end)
local git = Git.new(process)
local changes
local worktrees
local workspace
local reconciled_generation = setmetatable({}, { __mode = "k" })
local pending_refreshes = setmetatable({}, { __mode = "k" })
local refresh_timer

local function log_session_error(session)
  if not session or not session.error then
    if session then session.logged_error = nil end
    return
  end
  if session.logged_error == session.error then return end
  session.logged_error = session.error
  local error = {}
  for key, value in pairs(session.error) do error[key] = value end
  error.session_id = session.id
  log.push(error)
end

local function normalized_path(path)
  if type(path) ~= "string" or path == "" then return nil end
  path = vim.fs.normalize(path):gsub("\\", "/")
  if package.config:sub(1, 1) == "\\" then return path:lower() end
  return path
end

local function belongs_to(root, path)
  root, path = normalized_path(root), normalized_path(path)
  if not root or not path then return false end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function request_refresh(session)
  if not session or session.closed then return end
  local previous = pending_refreshes[session]
  if previous and previous.timer and not previous.timer:is_closing() then
    previous.timer:stop()
    previous.timer:close()
  end
  local request = { generation = session.reads.generation }
  pending_refreshes[session] = request
  request.timer = vim.defer_fn(function()
    if pending_refreshes[session] ~= request then return end
    pending_refreshes[session] = nil
    if session.closed or session.reads.generation ~= request.generation then return end
    controller.dispatch(session, "refresh")
  end, config.get().refresh.debounce_ms)
end

local function request_idle_refresh(session)
  if session and not session.busy.status then
    request_refresh(session)
  end
end

local function stop_refresh_timer()
  local timer = refresh_timer
  refresh_timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function polling_session()
  local session = workspace and workspace:active_session()
  if not session
      or session.closed
      or session.busy.status
      or session.reads.jobs.poll
      or not session.owned.tab
      or not vim.api.nvim_tabpage_is_valid(session.owned.tab)
      or vim.api.nvim_get_current_tabpage() ~= session.owned.tab
      or not layout.is_visible(session) then
    return nil
  end
  return session
end

local function start_refresh_timer()
  local interval = config.get().refresh.poll_interval_ms
  if interval <= 0 then return end

  local timer = assert(vim.uv.new_timer())
  refresh_timer = timer
  timer:start(interval, interval, vim.schedule_wrap(function()
    if refresh_timer ~= timer then return end
    local session = polling_session()
    if not session then return end

    changes:probe(session, function(event)
      if not event.result.ok or not event.changed then return end
      if polling_session() == session then request_refresh(session) end
    end)
  end))
end

function M.setup_observers()
  stop_refresh_timer()
  local group = vim.api.nvim_create_augroup("VigitRefreshObservers", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      if not config.get().refresh.on_write then return end
      local path = vim.api.nvim_buf_get_name(args.buf)
      if path == "" or path:match("^%a+://") then return end
      local session = workspace and workspace:active_session()
      if session and not session.closed and belongs_to(session.root, path) then
        request_refresh(session)
      end
    end,
    desc = "Refresh Vigit sessions after source writes",
  })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      if not config.get().refresh.on_tab_enter then return end
      local tab = vim.api.nvim_get_current_tabpage()
      local session = workspace and workspace:active_session()
      if session and not session.closed and session.owned.tab == tab then
        request_refresh(session)
      end
    end,
    desc = "Refresh the entered Vigit tab",
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if not config.get().refresh.on_focus then return end
      local session = polling_session()
      if session then request_refresh(session) end
    end,
    desc = "Refresh the visible Vigit review after focus returns",
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = stop_refresh_timer,
    desc = "Stop Vigit automatic refresh",
  })
  start_refresh_timer()
end

local function all_missing_ids(session)
  local ids = {}
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, change in ipairs(session.data.status[section] or {}) do
      if not session.data.diffs[change.id]
          and not session.view.all_files.loading[change.id] then
        ids[#ids + 1] = change.id
      end
    end
  end
  return ids
end

local function reconcile_all_files(session)
  if session.closed
      or session.view.diff_mode ~= "all_files"
      or not session.data.status
      or session.busy.status
      or session.error
      or reconciled_generation[session] == session.reads.generation then
    return
  end

  local generation = session.reads.generation
  reconciled_generation[session] = generation
  vim.schedule(function()
    if session.closed
        or session.reads.generation ~= generation
        or session.view.diff_mode ~= "all_files" then
      return
    end
    changes:load_all_visible(session, all_missing_ids(session))
  end)
end

changes = Changes.new({
  git = git,
  on_change = function(session)
    local status = session.data.status
    if status and not session.busy.status then
      session.branch = status.branch and status.branch.head or nil
    end
    log_session_error(session)
    renderer.render(session)
    reconcile_all_files(session)
  end,
})

controller.configure({
  changes = changes,
  registry = registry,
  config = config,
  open_file = neovim.open_file,
  goto_definition = neovim.goto_definition,
  open_terminal = neovim.open_terminal,
  worktrees = {
    open = function(session)
      return M.worktrees({ session = session })
    end,
  },
})

local function current_workspace()
  if not workspace
      or not workspace.tab
      or not vim.api.nvim_tabpage_is_valid(workspace.tab)
      or vim.api.nvim_get_current_tabpage() ~= workspace.tab then
    return nil
  end
  return workspace
end

local function current_path()
  local buffer = vim.api.nvim_get_current_buf()
  local buffer_path = vim.api.nvim_buf_get_name(buffer)
  if vim.bo[buffer].buftype == ""
      and buffer_path ~= ""
      and not buffer_path:match("^%a+://") then
    return buffer_path, "code_buffer"
  end
  local active = current_workspace()
  if active and active.root then
    local source_buffer = neovim.editor_source(active, active.root, buffer)
    if source_buffer then
      return vim.api.nvim_buf_get_name(source_buffer), "workspace_source"
    end
    return active.root, "workspace_root"
  end
  return vim.fn.getcwd(0, 0), "effective_cwd"
end

local function invocation_mode()
  local active = current_workspace()
  if active and active:mode_name() == "review" then return "review" end
  return "code"
end

local function record_root_resolution(source, path, root, mode)
  local active_root = workspace and workspace.root or nil
  local details = {
    source = source,
    path = path,
    root = root,
    active_root = active_root,
    mode = mode,
  }
  log.event("root_resolved", details)
  if active_root and active_root ~= root then
    log.event("root_mismatch", details)
  end
end

local function resolve_invocation_root(opts)
  opts = opts or {}
  local mode = opts.mode or invocation_mode()
  local active = current_workspace()
  local active_session = active and active:active_session() or nil
  if opts.cwd ~= nil then
    local resolved = neovim.find_repo_root(opts.cwd)
    if resolved.ok then
      record_root_resolution(opts.source or "explicit", opts.cwd, resolved.value, mode)
    end
    return resolved
  end
  if mode == "review" and active_session then
    record_root_resolution("review_session", active_session.root, active_session.root, mode)
    return Result.ok(active_session.root)
  end

  local path, source = current_path()
  local resolved = neovim.find_repo_root(path)
  if resolved.ok then
    record_root_resolution(source, path, resolved.value, mode)
    return resolved
  end
  if active_session then
    record_root_resolution("session_fallback", path, active_session.root, mode)
    return Result.ok(active_session.root)
  end
  return resolved
end

local function worktree_root(path, callback)
  vim.schedule(function()
    callback(neovim.find_repo_root(path))
  end)
  return { cancel = function() end }
end

worktrees = Worktrees.new({
  git = git,
  registry = registry,
  neovim = {
    canonical_root = worktree_root,
    loaded_source_buffers = neovim.loaded_source_buffers,
    platform = package.config:sub(1, 1) == "\\" and "win32" or "posix",
  },
  concurrency = 4,
  switch_session = function(root, opts)
    local previous_root = workspace and workspace.root or nil
    local session, open_error = M.open({
      cwd = root,
      source = "worktree_picker",
      skip_switch_event = true,
    })
    if session then
      if opts and opts.mode == "code" then
        local restored = neovim.show_editor(session, workspace, {
          source_root = opts.source_root,
          source_buffer = opts.source_buffer,
          source_kind = opts.source_kind,
        })
        if not restored.ok then return restored end
        if restored.value then
          local code_mode = workspace:show_code()
          if not code_mode.ok then return code_mode end
        end
      end
      if previous_root ~= session.root then
        log.event("session_switch", {
          source = "worktree_picker",
          from_root = previous_root,
          to_root = session.root,
          mode = opts and opts.mode or "review",
          session_id = session.id,
        })
      end
      return Result.ok(session)
    end
    return Result.err(
      (open_error and open_error.code) or "worktree_missing",
      (open_error and open_error.message) or "Worktree no longer exists",
      open_error
    )
  end,
  stop_terminal = function()
    if not workspace then
      return Result.err(
        "workspace_unavailable",
        "Vigit workspace is unavailable"
      )
    end
    return neovim.stop_workspace_terminal(workspace)
  end,
  active_root = function()
    return workspace and workspace.root or nil
  end,
  close_session = function(session)
    if workspace then
      workspace:remove_session(session.root)
    end
  end,
})

local function normal_window(tab)
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(window).relative == "" then
      return window
    end
  end
  return vim.api.nvim_tabpage_get_win(tab)
end

local function set_workspace_root(active, root)
  local result = neovim.bind_workspace_root(active, root)
  if result.ok then
    log.event("workspace_root_bound", {
      root = result.value,
      global_cwd = vim.fn.getcwd(-1, -1),
      tab_cwd = vim.fn.getcwd(0, 0),
      process_cwd = vim.uv.cwd(),
    })
  else
    log.push(result.error)
  end
  return result
end

local function create_session(root, snapshot)
  next_id = next_id + 1
  local session = Session.new({
    id = "vigit-" .. next_id,
    root = root,
  })
  session.review_service = Reviews.new({
    relative_path = config.get().review.path,
  })
  session.view.changes_mode = config.get().ui.changes_mode
  for key, value in pairs(snapshot or {}) do
    session.view[key] = value
  end

  local comments = session.review_service:load(session)
  if not comments.ok then
    session.errors.comments = comments.error
    session.error = comments.error
    log_session_error(session)
  end
  return Result.ok(session)
end

local function dispose_session(session)
  renderer.clear(session)
  layout.dispose(session)
  registry:remove(session.id)
end

local function mount_session(session, active)
  session.workspace = active
  registry:put(session)
  local ok, open_error = xpcall(function()
    layout.show(session, active)
    keymaps.apply(session)
    renderer.render(session)
    changes:refresh(session)
  end, debug.traceback)
  if not ok then
    return Result.err(
      "ui_open_failed",
      "Unable to open Vigit review UI",
      open_error
    )
  end
  return Result.ok(session)
end

local function ensure_workspace()
  if workspace
      and workspace.tab
      and vim.api.nvim_tabpage_is_valid(workspace.tab) then
    return workspace
  end
  if workspace then
    workspace:close()
  end

  local tab = vim.api.nvim_get_current_tabpage()
  workspace = Workspace.new({
    canonicalize = function(path)
      return path
    end,
    inspect = neovim.inspect_workspace,
    set_root = set_workspace_root,
    create_session = create_session,
    mount = mount_session,
    show = function(session, active)
      local ok, message = xpcall(function()
        vim.api.nvim_set_current_tabpage(active.tab)
        layout.show(session, active)
        renderer.render(session)
      end, debug.traceback)
      if not ok then
        return Result.err(
          "ui_open_failed",
          "Unable to show Vigit review UI",
          message
        )
      end
      return Result.ok(session)
    end,
    hide = layout.hide,
    dispose = dispose_session,
    tab = tab,
    code_win = normal_window(tab),
  })
  return workspace
end

function M.open(opts)
  opts = opts or {}
  local previous_root = workspace and workspace.root or nil
  local root_result = resolve_invocation_root(opts)
  if not root_result.ok then
    log.push(root_result.error)
    return nil, root_result.error
  end

  local active = ensure_workspace()
  local existing = active.sessions[root_result.value]
  local opened = active:open(root_result.value)
  if not opened.ok then
    log.push(opened.error)
    return nil, opened.error
  end
  if opened.value == existing then
    request_idle_refresh(opened.value)
  end
  if not opts.skip_switch_event and previous_root ~= opened.value.root then
    log.event("session_switch", {
      source = opts.source or (opts.cwd and "explicit" or "command"),
      from_root = previous_root,
      to_root = opened.value.root,
      mode = "review",
      session_id = opened.value.id,
    })
  end
  return opened.value
end

function M.active_session()
  if not workspace
      or not workspace.tab
      or not vim.api.nvim_tabpage_is_valid(workspace.tab)
      or vim.api.nvim_get_current_tabpage() ~= workspace.tab then
    return nil
  end
  return workspace:active_session()
end

function M.worktrees(opts)
  opts = opts or {}
  local session = opts.session
  local active = workspace and workspace:active_session() or nil
  local return_mode = invocation_mode()
  local root_result = resolve_invocation_root({
    cwd = opts.cwd,
    mode = return_mode,
    source = "worktree_picker",
  })
  if not root_result.ok then
    log.push(root_result.error)
    return nil, root_result.error
  end
  local root = root_result.value
  local context_session = workspace and workspace.sessions[root] or nil
  if not context_session and session and not session.closed and session.root == root then
    context_session = session
  elseif not context_session and active and active.root == root then
    context_session = active
  end
  local source_buffer
  local source_kind
  if return_mode == "code" then
    source_buffer, source_kind = neovim.editor_source(
      workspace,
      root,
      vim.api.nvim_get_current_buf()
    )
  end
  if return_mode == "code" and context_session and not context_session.closed then
    neovim.remember_source_buffer(
      context_session.resources,
      context_session.root,
      source_buffer
    )
  end
  local origin = context_session or { root = root, closed = false }
  return worktrees_view.open({
    app = worktrees,
    origin = origin,
    origin_tab = vim.api.nvim_get_current_tabpage(),
    return_mode = return_mode,
    source_root = root,
    source_buffer = source_buffer,
    source_kind = source_kind,
    selected_path = root,
  })
end

function M.help(context)
  return require("vigit.ui.views.help").open(context)
end

local function notify_error(error)
  vim.notify(
    string.format("[%s] %s", error.code, error.message),
    vim.log.levels.ERROR,
    { title = "Vigit" }
  )
end

local function open_command(opts)
  local _, open_error = M.open({
    cwd = opts.args ~= "" and opts.args or nil,
  })
  if open_error then notify_error(open_error) end
end

local function open_comments()
  local session = M.active_session()
  if session then
    controller.dispatch(session, "open_comments")
  else
    vim.notify("Open Vigit first", vim.log.levels.WARN, { title = "Vigit" })
  end
end

local function migrate_reviews()
  local session = M.active_session()
  if not session then
    vim.notify("Open a Vigit session first", vim.log.levels.WARN, { title = "Vigit" })
    return
  end
  local reviews = Reviews.for_session(session)
  local legacy = require("vigit.adapters.legacy_review").new()
  local preview = reviews:migrate_legacy(session, legacy, false)
  if not preview.ok then
    notify_error(preview.error)
    return
  end
  local count = preview.value.preview.importable or 0
  if count == 0 then
    vim.notify("No legacy review comments to import", vim.log.levels.INFO, { title = "Vigit" })
    return
  end
  require("vigit.ui.confirm").ask(
    string.format("Import %d legacy review comment(s)?", count),
    function(accepted)
      if not accepted then return end
      local migrated = reviews:migrate_legacy(session, legacy, true)
      if not migrated.ok then
        notify_error(migrated.error)
        return
      end
      controller.dispatch(session, "refresh")
      vim.notify(
        string.format("Imported %d legacy review comment(s)", migrated.value.imported or 0),
        vim.log.levels.INFO,
        { title = "Vigit" }
      )
    end
  )
end

local function install_codex_skill(opts)
  local function install(force)
    local ok, result = require("vigit.skill").install({ force = force })
    vim.notify(result, ok and vim.log.levels.INFO or vim.log.levels.ERROR, { title = "Vigit" })
  end
  if not opts.bang then
    install(false)
    return
  end
  vim.ui.select({ "Cancel", "Replace installed skill" }, {
    prompt = "Replace the installed vigit-review skill?",
  }, function(choice)
    if choice == "Replace installed skill" then install(true) end
  end)
end

function M.setup(opts)
  local configured = config.setup(opts)
  if not configured.ok then return nil, configured.error end
  M.setup_observers()
  if commands_registered then return true end

  vim.api.nvim_create_user_command("Vigit", open_command, {
    nargs = "?",
    complete = "dir",
    force = true,
    desc = "Open Vigit for the current worktree",
  })
  vim.api.nvim_create_user_command("VigitV2", open_command, {
    nargs = "?",
    complete = "dir",
    force = true,
    desc = "Compatibility alias for :Vigit",
  })
  vim.api.nvim_create_user_command("VigitWorktrees", function()
    local _, worktree_error = M.worktrees({ session = M.active_session() })
    if worktree_error then notify_error(worktree_error) end
  end, {
    force = true,
    desc = "Open the Vigit worktree picker",
  })
  vim.api.nvim_create_user_command("VigitComments", open_comments, {
    force = true,
    desc = "Open comments for the active Vigit worktree",
  })
  vim.api.nvim_create_user_command("VigitHelp", function()
    M.help()
  end, {
    force = true,
    desc = "Show Vigit key mappings",
  })
  vim.api.nvim_create_user_command("VigitLog", function()
    log.open()
  end, {
    force = true,
    desc = "Show Vigit diagnostics",
  })
  vim.api.nvim_create_user_command("VigitMigrateReviews", migrate_reviews, {
    force = true,
    desc = "Preview and explicitly import legacy review comments into Vigit",
  })
  vim.api.nvim_create_user_command("VigitInstallCodexSkill", install_codex_skill, {
    bang = true,
    force = true,
    desc = "Install or update the bundled vigit-review Codex skill",
  })
  commands_registered = true
  return true
end

return M
