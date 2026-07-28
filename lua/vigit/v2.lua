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

local M = {}

local next_id = 0
local registry = registry_module.new(function(path)
  return path
end)
local git = Git.new(process)
local changes
local worktrees
local reconciled_generation = setmetatable({}, { __mode = "k" })

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
    platform = (vim.uv.os_uname().sysname == "Windows_NT") and "win32" or "posix",
  },
  concurrency = 4,
  open_session = function(root)
    return M.open({ cwd = root })
  end,
})

function M.open(opts)
  opts = opts or {}
  local root_result = neovim.find_repo_root(opts.cwd or current_path())
  if not root_result.ok then
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

return M
