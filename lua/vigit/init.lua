-- Public Vigit runtime.
local process = require("vigit.adapters.process")
local Git = require("vigit.adapters.git_cli")
local neovim = require("vigit.adapters.neovim")
local Changes = require("vigit.application.changes")
local Reviews = require("vigit.application.reviews")
local Worktrees = require("vigit.application.worktrees")
local config = require("vigit.config")
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
local reconciled_generation = setmetatable({}, { __mode = "k" })
local pending_refreshes = setmetatable({}, { __mode = "k" })

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

function M.setup_observers()
  local group = vim.api.nvim_create_augroup("VigitRefreshObservers", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      if not config.get().refresh.on_write then return end
      local path = vim.api.nvim_buf_get_name(args.buf)
      if path == "" or path:match("^%a+://") then return end
      for _, session in ipairs(registry:all()) do
        if not session.closed and belongs_to(session.root, path) then request_refresh(session) end
      end
    end,
    desc = "Refresh Vigit sessions after source writes",
  })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      if not config.get().refresh.on_tab_enter then return end
      local tab = vim.api.nvim_get_current_tabpage()
      for _, session in ipairs(registry:all()) do
        if not session.closed and session.owned.tab == tab then request_refresh(session) end
      end
    end,
    desc = "Refresh the entered Vigit tab",
  })
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

local function current_path()
  local buffer_path = vim.api.nvim_buf_get_name(0)
  if buffer_path ~= "" and not buffer_path:match("^%a+://") then
    return buffer_path
  end
  return vim.uv.cwd()
end

local function focus_existing(session)
  if session.closed
      or not session.owned.tab
      or not vim.api.nvim_tabpage_is_valid(session.owned.tab) then
    return false
  end
  vim.api.nvim_set_current_tabpage(session.owned.tab)
  controller.dispatch(session, "resize")
  return true
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
    focus_session = focus_existing,
    loaded_source_buffers = neovim.loaded_source_buffers,
    platform = package.config:sub(1, 1) == "\\" and "win32" or "posix",
  },
  concurrency = 4,
  open_session = function(root)
    return M.open({ cwd = root })
  end,
  close_session = function(session)
    controller.dispatch(session, "close")
  end,
})

function M.open(opts)
  opts = opts or {}
  local root_result = neovim.find_repo_root(opts.cwd or current_path())
  if not root_result.ok then
    log.push(root_result.error)
    return nil, root_result.error
  end

  local root = root_result.value
  local existing = registry:get(root)
  if existing and focus_existing(existing) then
    return existing
  end
  if existing then
    registry:remove(existing.id)
  end

  next_id = next_id + 1
  local session = Session.new({
    id = "vigit-" .. next_id,
    root = root,
  })
  session.review_service = Reviews.new({ relative_path = config.get().review.path })
  session.view.changes_mode = config.get().ui.changes_mode
  registry:put(session)

  local ok, open_error = pcall(layout.open, session)
  if not ok then
    renderer.clear(session)
    pcall(layout.close, session)
    session.closed = true
    registry:remove(session.id)
    log.push({
      session_id = session.id,
      code = "ui_open_failed",
      message = "Unable to open Vigit review UI",
      details = open_error,
    })
    return nil, {
      code = "ui_open_failed",
      message = "Unable to open Vigit review UI",
      details = open_error,
      retryable = false,
    }
  end

  keymaps.apply(session)
  local comments = session.review_service:load(session)
  if not comments.ok then
    session.errors.comments = comments.error
    session.error = comments.error
    log_session_error(session)
  end
  renderer.render(session)
  changes:refresh(session)
  return session
end

function M.active_session()
  local current = vim.api.nvim_get_current_tabpage()
  for _, session in ipairs(registry:all()) do
    if not session.closed and session.owned.tab == current then return session end
  end
end

function M.worktrees(opts)
  opts = opts or {}
  local session = opts.session
  local root
  if session and not session.closed then
    root = session.root
  else
    local root_result = neovim.find_repo_root(opts.cwd or current_path())
    if not root_result.ok then
      log.push(root_result.error)
      return nil, root_result.error
    end
    root = root_result.value
  end
  local origin = session or { root = root, closed = false }
  return worktrees_view.open({
    app = worktrees,
    origin = origin,
    origin_tab = vim.api.nvim_get_current_tabpage(),
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
