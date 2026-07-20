local default_git = require("vigit.git")

local M = {}

local function basename(path)
  return tostring(path or ""):gsub("/+$", ""):match("([^/]+)$") or tostring(path or "")
end

local function normalize(path)
  return tostring(path or ""):gsub("/+$", "")
end

local function review_count(cwd)
  local ok, review = pcall(require, "vigit.review")
  if not ok then
    return 0
  end
  local count = review.open_count(cwd)
  return tonumber(count) or 0
end

function M.list(cwd, opts)
  opts = opts or {}
  local git = opts.git or default_git
  local entries, err = git.worktree_list(cwd)
  if err then
    return nil, err
  end
  local current_root = git.root(cwd)
  current_root = normalize(current_root)
  local primary_root = entries[1] and normalize(entries[1].path) or ""

  for _, entry in ipairs(entries) do
    entry.path = normalize(entry.path)
    entry.name = basename(entry.path)
    entry.branch = entry.branch or (entry.detached and ("detached@" .. tostring(entry.head or ""):sub(1, 8)) or "(unknown)")
    entry.primary = entry.path == primary_root
    entry.current = entry.path == current_root
    entry.open = opts.is_open and opts.is_open(entry.path) or false
    entry.review_count = review_count(entry.path)
    local summary, summary_err = git.worktree_summary(entry.path)
    if summary then
      entry.changed = summary.changed
      entry.staged = summary.staged
      entry.unstaged = summary.unstaged
      entry.untracked = summary.untracked
    else
      entry.changed = 0
      entry.staged = 0
      entry.unstaged = 0
      entry.untracked = 0
      entry.error = summary_err
    end
  end

  table.sort(entries, function(left, right)
    if left.current ~= right.current then
      return left.current
    end
    return left.name:lower() < right.name:lower()
  end)
  return entries, nil
end

return M
