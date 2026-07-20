local default_git = require("vigit.git")

local M = {}

local SCHEMA_VERSION = 2
local POINTER_NAMES = { "draft", "run", "latest" }

local function timestamp()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function normalize_path(path)
  local absolute = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
  return (vim.uv and vim.uv.fs_realpath(absolute)) or absolute
end

local function read_file(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function write_file(path, content)
  local temporary = string.format("%s.tmp.%d", path, vim.fn.getpid())
  local handle, err = io.open(temporary, "w")
  if not handle then
    return false, err
  end
  handle:write(content)
  handle:close()
  local ok, rename_err = os.rename(temporary, path)
  if not ok then
    os.remove(temporary)
    return false, rename_err
  end
  return true, nil
end

local function read_json(path)
  local content = read_file(path)
  if not content or content == "" then
    return nil, nil
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil, "Invalid Vigit JSON file: " .. path
  end
  return decoded, nil
end

local function write_json(path, value)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return false, tostring(encoded)
  end
  return write_file(path, encoded .. "\n")
end

local function remove_file(path)
  if vim.fn.filereadable(path) == 0 then
    return true, nil
  end
  local ok, err = os.remove(path)
  return ok ~= nil, err
end

local function sanitize(value)
  local result = tostring(value or ""):gsub("[^%w._-]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  return result ~= "" and result or "worktree"
end

local function make_worktree_id(root)
  local name = root:match("([^/]+)$") or "worktree"
  return sanitize(name) .. "-" .. vim.fn.sha256(root):sub(1, 12)
end

local function make_review_id(root)
  local compact_time = os.date("!%Y%m%dT%H%M%SZ")
  local entropy = table.concat({
    root,
    tostring(vim.uv and vim.uv.hrtime() or os.clock()),
    tostring(vim.fn.getpid()),
  }, ":")
  return "review-" .. compact_time .. "-" .. vim.fn.sha256(entropy):sub(1, 8)
end

local function workspace_paths(cwd)
  local root, root_err = default_git.root(cwd)
  if not root then
    return nil, root_err
  end
  root = normalize_path(root)
  local git_dir, git_err = default_git.git_dir(root)
  if not git_dir then
    return nil, git_err
  end
  local common_git_dir, common_err = default_git.common_git_dir(root)
  if not common_git_dir then
    return nil, common_err
  end
  common_git_dir = normalize_path(common_git_dir)
  git_dir = normalize_path(git_dir)
  local worktree_id = make_worktree_id(root)
  local directory = common_git_dir .. "/vigit/worktrees/" .. worktree_id
  return {
    root = root,
    git_dir = git_dir,
    common_git_dir = common_git_dir,
    worktree_id = worktree_id,
    directory = directory,
    worktree = directory .. "/worktree.json",
    comments_markdown = directory .. "/comments.md",
    active = directory .. "/active",
    reviews = directory .. "/reviews",
    legacy_json = git_dir .. "/vigit/review.json",
    legacy_markdown = git_dir .. "/vigit/review.md",
  }, nil
end

local function pointer_path(paths, name)
  return paths.active .. "/" .. name .. ".json"
end

local function session_paths(paths, review_id)
  local directory = paths.reviews .. "/" .. review_id
  return {
    directory = directory,
    session = directory .. "/session.json",
    prompt = directory .. "/prompt.md",
    summary = directory .. "/summary.md",
    comments = directory .. "/comments",
  }
end

local function ensure_directories(paths)
  vim.fn.mkdir(paths.active, "p")
  vim.fn.mkdir(paths.reviews, "p")
end

local function read_worktree(paths)
  local metadata, err = read_json(paths.worktree)
  if err then
    return nil, err
  end
  return metadata or {
    schema_version = SCHEMA_VERSION,
    worktree_id = paths.worktree_id,
    root = paths.root,
    created_at = timestamp(),
    next_issue_number = 1,
  }, nil
end

local function write_worktree(paths, metadata)
  metadata.schema_version = SCHEMA_VERSION
  metadata.worktree_id = paths.worktree_id
  metadata.root = paths.root
  metadata.updated_at = timestamp()
  metadata.next_issue_number = tonumber(metadata.next_issue_number) or 1
  return write_json(paths.worktree, metadata)
end

local function read_pointer(paths, name)
  local pointer, err = read_json(pointer_path(paths, name))
  if err then
    return nil, err
  end
  if not pointer then
    return nil, nil
  end
  if pointer.schema_version ~= SCHEMA_VERSION or type(pointer.review_id) ~= "string" then
    return nil, "Invalid Vigit " .. name .. " pointer"
  end
  return pointer.review_id, nil
end

local function write_pointer(paths, name, review_id)
  return write_json(pointer_path(paths, name), {
    schema_version = SCHEMA_VERSION,
    review_id = review_id,
    updated_at = timestamp(),
  })
end

local function load_issue(path)
  local issue, err = read_json(path)
  if not issue then
    return nil, err
  end
  issue.schema_version = issue.schema_version or SCHEMA_VERSION
  issue.acceptance = type(issue.acceptance) == "table" and issue.acceptance or {}
  issue.result = type(issue.result) == "table" and issue.result or {}
  return issue, nil
end

local function load_session(paths, review_id)
  if not review_id or review_id == "" then
    return nil, nil
  end
  local locations = session_paths(paths, review_id)
  local session, err = read_json(locations.session)
  if not session then
    return nil, err or ("Missing Vigit review session: " .. review_id)
  end
  if session.schema_version ~= SCHEMA_VERSION then
    return nil, "Unsupported Vigit review schema: " .. tostring(session.schema_version)
  end
  local issues = {}
  for _, issue_id in ipairs(session.issue_ids or {}) do
    local issue, issue_err = load_issue(locations.comments .. "/" .. issue_id .. ".json")
    if not issue then
      return nil, issue_err or ("Missing Vigit review issue: " .. issue_id)
    end
    issues[#issues + 1] = issue
  end
  session.id = session.id or review_id
  session.issues = issues
  session.paths = locations
  return session, nil
end

local function save_session(paths, session)
  local locations = session_paths(paths, session.id)
  vim.fn.mkdir(locations.comments, "p")
  local stored = vim.deepcopy(session)
  stored.issues = nil
  stored.paths = nil
  stored.schema_version = SCHEMA_VERSION
  stored.updated_at = timestamp()
  session.updated_at = stored.updated_at
  return write_json(locations.session, stored)
end

local function save_issue(paths, review_id, issue)
  local locations = session_paths(paths, review_id)
  vim.fn.mkdir(locations.comments, "p")
  issue.schema_version = SCHEMA_VERSION
  issue.updated_at = timestamp()
  return write_json(locations.comments .. "/" .. issue.id .. ".json", issue)
end

local function create_session(paths, status)
  local branch = default_git.branch(paths.root) or "(unknown)"
  local head = default_git.head(paths.root) or ""
  local now = timestamp()
  local session = {
    schema_version = SCHEMA_VERSION,
    id = make_review_id(paths.root),
    worktree_id = paths.worktree_id,
    worktree = paths.root,
    branch = branch,
    head = head,
    status = status or "draft",
    created_at = now,
    updated_at = now,
    issue_ids = {},
    issues = {},
  }
  local ok, err = save_session(paths, session)
  if not ok then
    return nil, err
  end
  return session, nil
end

local function import_legacy(paths, metadata)
  if metadata.legacy_imported_at or vim.fn.filereadable(paths.legacy_json) == 0 then
    return true, nil
  end
  local legacy, legacy_err = read_json(paths.legacy_json)
  if not legacy then
    return false, legacy_err
  end
  local session, session_err = create_session(paths, "draft")
  if not session then
    return false, session_err
  end
  for _, old in ipairs(legacy.issues or {}) do
    local issue = vim.deepcopy(old)
    issue.schema_version = SCHEMA_VERSION
    issue.id = issue.id or string.format("VIGIT-%03d", metadata.next_issue_number)
    local number = tonumber(issue.id:match("VIGIT%-(%d+)")) or metadata.next_issue_number
    metadata.next_issue_number = math.max(metadata.next_issue_number, number + 1)
    issue.type = issue.type or "FIX"
    issue.status = issue.status or "open"
    issue.acceptance = type(issue.acceptance) == "table" and issue.acceptance or {}
    issue.result = type(issue.result) == "table" and issue.result or {}
    local ok, err = save_issue(paths, session.id, issue)
    if not ok then
      return false, err
    end
    session.issue_ids[#session.issue_ids + 1] = issue.id
    session.issues[#session.issues + 1] = issue
  end
  local saved, save_err = save_session(paths, session)
  if not saved then
    return false, save_err
  end
  local pointed, pointer_err = write_pointer(paths, "draft", session.id)
  if not pointed then
    return false, pointer_err
  end
  metadata.legacy_imported_at = timestamp()
  metadata.legacy_source = paths.legacy_json
  return write_worktree(paths, metadata)
end

local function ensure_workspace(cwd)
  local paths, path_err = workspace_paths(cwd)
  if not paths then
    return nil, path_err
  end
  ensure_directories(paths)
  local metadata_exists = vim.fn.filereadable(paths.worktree) == 1
  local metadata, metadata_err = read_worktree(paths)
  if not metadata then
    return nil, metadata_err
  end
  metadata.next_issue_number = tonumber(metadata.next_issue_number) or 1
  if not metadata_exists or metadata.root ~= paths.root or metadata.worktree_id ~= paths.worktree_id then
    local ok, write_err = write_worktree(paths, metadata)
    if not ok then
      return nil, write_err
    end
  end
  local imported, import_err = import_legacy(paths, metadata)
  if not imported then
    return nil, import_err
  end
  return paths, nil
end

local function ensure_draft(paths)
  local draft_id, pointer_err = read_pointer(paths, "draft")
  if pointer_err then
    return nil, pointer_err
  end
  if draft_id then
    return load_session(paths, draft_id)
  end
  local session, err = create_session(paths, "draft")
  if not session then
    return nil, err
  end
  local ok, write_err = write_pointer(paths, "draft", session.id)
  if not ok then
    return nil, write_err
  end
  return session, nil
end

local function markdown_escape(value)
  return tostring(value or ""):gsub("```", "`` `")
end

local function render_checklist(lines, title, items)
  if type(items) ~= "table" or #items == 0 then
    return
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "### " .. title
  lines[#lines + 1] = ""
  for _, item in ipairs(items) do
    local state = item.done == true or item.status == "passed" or item.status == "done"
    local text = type(item) == "table" and (item.text or item.label or item.command or "") or tostring(item)
    lines[#lines + 1] = string.format("- [%s] %s", state and "x" or " ", markdown_escape(text))
    if type(item) == "table" and item.evidence and item.evidence ~= "" then
      lines[#lines + 1] = "  - " .. markdown_escape(item.evidence)
    end
  end
end

local function render_markdown(session)
  local lines = {
    "# Vigit Review " .. session.id,
    "",
    "- Worktree: `" .. markdown_escape(session.worktree) .. "`",
    "- Branch: `" .. markdown_escape(session.branch) .. "`",
    "- Status: `" .. markdown_escape(session.status) .. "`",
    "- Updated: " .. markdown_escape(session.updated_at),
    "",
  }
  if #(session.issues or {}) == 0 then
    lines[#lines + 1] = "No review issues."
  end
  for _, issue in ipairs(session.issues or {}) do
    lines[#lines + 1] = string.format("## %s · %s · %s", issue.id, issue.type or "FIX", issue.status or "open")
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("- File: `%s`", markdown_escape(issue.file))
    lines[#lines + 1] = string.format("- Lines: %s-%s", tostring(issue.line or 1), tostring(issue.line_end or issue.line or 1))
    lines[#lines + 1] = string.format("- Section: `%s`", markdown_escape(issue.section or "unstaged"))
    lines[#lines + 1] = ""
    lines[#lines + 1] = "### Comment"
    lines[#lines + 1] = ""
    lines[#lines + 1] = markdown_escape(issue.comment)
    render_checklist(lines, "Acceptance", issue.acceptance)
    if issue.context and issue.context ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "### Context"
      lines[#lines + 1] = ""
      lines[#lines + 1] = "```diff"
      lines[#lines + 1] = markdown_escape(issue.context)
      lines[#lines + 1] = "```"
    end
    if issue.result and issue.result.summary and issue.result.summary ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "### Result"
      lines[#lines + 1] = ""
      lines[#lines + 1] = markdown_escape(issue.result.summary)
      render_checklist(lines, "Verification", issue.result.checklist)
    elseif issue.resolution and issue.resolution ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "### Result"
      lines[#lines + 1] = ""
      lines[#lines + 1] = markdown_escape(issue.resolution)
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function active_session(paths)
  for _, name in ipairs({ "draft", "run", "latest" }) do
    local review_id, err = read_pointer(paths, name)
    if err then
      return nil, err
    end
    if review_id then
      local session, session_err = load_session(paths, review_id)
      if not session then
        return nil, session_err
      end
      session.pointer = name
      return session, nil
    end
  end
  return nil, nil
end

function M.workspace(cwd)
  return ensure_workspace(cwd)
end

function M.paths(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local session = active_session(paths)
  local locations = session and session_paths(paths, session.id) or nil
  return {
    directory = paths.directory,
    active = paths.active,
    reviews = paths.reviews,
    worktree = paths.worktree,
    comments = paths.comments_markdown,
    json = locations and locations.session or nil,
    markdown = locations and locations.summary or nil,
  }, nil
end

function M.load(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local session, load_err = active_session(paths)
  if load_err then
    return nil, load_err
  end
  if session then
    return session, nil
  end
  return {
    schema_version = SCHEMA_VERSION,
    id = nil,
    worktree_id = paths.worktree_id,
    worktree = paths.root,
    status = "empty",
    issues = {},
    issue_ids = {},
  }, nil
end

function M.load_session(cwd, review_id)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  return load_session(paths, review_id)
end

function M.write_issue(cwd, review_id, issue)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return false, err
  end
  return save_issue(paths, review_id, issue)
end

function M.add(cwd, issue)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local draft, draft_err = ensure_draft(paths)
  if not draft then
    return nil, draft_err
  end
  local metadata, metadata_err = read_worktree(paths)
  if not metadata then
    return nil, metadata_err
  end
  issue = vim.deepcopy(issue)
  issue.id = string.format("VIGIT-%03d", metadata.next_issue_number)
  metadata.next_issue_number = metadata.next_issue_number + 1
  issue.schema_version = SCHEMA_VERSION
  issue.type = "COMMENT"
  issue.status = "open"
  issue.created_at = timestamp()
  issue.updated_at = issue.created_at
  issue.line = math.max(tonumber(issue.line) or 1, 1)
  issue.line_end = math.max(tonumber(issue.line_end) or issue.line, issue.line)
  issue.acceptance = type(issue.acceptance) == "table" and issue.acceptance or {}
  issue.result = type(issue.result) == "table" and issue.result or {}
  local issue_ok, issue_err = save_issue(paths, draft.id, issue)
  if not issue_ok then
    return nil, issue_err
  end
  draft.issue_ids[#draft.issue_ids + 1] = issue.id
  draft.issues[#draft.issues + 1] = issue
  local session_ok, session_err = save_session(paths, draft)
  if not session_ok then
    return nil, session_err
  end
  local metadata_ok, metadata_write_err = write_worktree(paths, metadata)
  if not metadata_ok then
    return nil, metadata_write_err
  end
  M.sync_markdown(cwd)
  M.sync_comments(cwd)
  return issue, nil
end

function M.open_count(cwd)
  local draft = M.draft(cwd)
  return draft and #(draft.issues or {}) or 0
end

function M.sync_markdown(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return false, err
  end
  local session, load_err = active_session(paths)
  if not session then
    return load_err == nil, load_err
  end
  local locations = session_paths(paths, session.id)
  return write_file(locations.summary, render_markdown(session))
end

function M.active(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local result = {}
  for _, name in ipairs(POINTER_NAMES) do
    local review_id, pointer_err = read_pointer(paths, name)
    if pointer_err then
      return nil, pointer_err
    end
    result[name] = review_id
  end
  return result, nil
end

function M.list_sessions(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local sessions = {}
  for name, kind in vim.fs.dir(paths.reviews) do
    if kind == "directory" then
      local session = load_session(paths, name)
      if session then
        sessions[#sessions + 1] = session
      end
    end
  end
  table.sort(sessions, function(left, right)
    return tostring(left.created_at or "") > tostring(right.created_at or "")
  end)
  return sessions, nil
end

function M.remove_pointer(cwd, name)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return false, err
  end
  return remove_file(pointer_path(paths, name))
end

function M.set_pointer(cwd, name, review_id)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return false, err
  end
  return write_pointer(paths, name, review_id)
end

function M.save_session(cwd, session)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return false, err
  end
  return save_session(paths, session)
end

function M.session_paths(cwd, review_id)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  return session_paths(paths, review_id), nil
end

local function empty_draft(paths)
  return {
    schema_version = SCHEMA_VERSION,
    id = nil,
    worktree_id = paths.worktree_id,
    worktree = paths.root,
    status = "draft",
    issue_ids = {},
    issues = {},
  }
end

function M.draft(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local draft_id, pointer_err = read_pointer(paths, "draft")
  if pointer_err then
    return nil, pointer_err
  end
  if not draft_id then
    return empty_draft(paths), nil
  end
  return load_session(paths, draft_id)
end

local function render_comments_markdown(session)
  local lines = {
    "# Vigit Comments",
    "",
    "Worktree: `" .. markdown_escape(session.worktree) .. "`",
    "",
  }
  if #(session.issues or {}) == 0 then
    lines[#lines + 1] = "No comments."
  end
  for _, issue in ipairs(session.issues or {}) do
    lines[#lines + 1] = "## " .. issue.id
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
      "- Source: `%s:%d-%d`",
      markdown_escape(issue.file),
      tonumber(issue.line) or 1,
      tonumber(issue.line_end) or tonumber(issue.line) or 1
    )
    lines[#lines + 1] = "- Section: `" .. markdown_escape(issue.section or "unstaged") .. "`"
    lines[#lines + 1] = ""
    lines[#lines + 1] = markdown_escape(issue.comment)
    if issue.context and issue.context ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "```diff"
      lines[#lines + 1] = markdown_escape(issue.context)
      lines[#lines + 1] = "```"
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.sync_comments(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return false, err
  end
  local session, draft_err = M.draft(cwd)
  if not session then
    return false, draft_err
  end
  return write_file(paths.comments_markdown, render_comments_markdown(session))
end

function M.comments(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local session, draft_err = M.draft(cwd)
  if not session then
    return nil, draft_err
  end
  if vim.fn.filereadable(paths.comments_markdown) == 0 then
    local ok, write_err = write_file(paths.comments_markdown, render_comments_markdown(session))
    if not ok then
      return nil, write_err
    end
  end
  return session.issues or {}, nil
end

function M.update(cwd, issue_id, changes)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local draft_id, pointer_err = read_pointer(paths, "draft")
  if pointer_err then
    return nil, pointer_err
  end
  if not draft_id then
    return nil, "Comment is not in the active draft: " .. tostring(issue_id)
  end
  local session, session_err = load_session(paths, draft_id)
  if not session then
    return nil, session_err
  end
  local comment = vim.trim(changes and changes.comment or "")
  if comment == "" then
    return nil, "Comment cannot be empty"
  end
  for _, issue in ipairs(session.issues or {}) do
    if issue.id == issue_id then
      issue.comment = comment
      issue.type = "COMMENT"
      local saved, save_err = save_issue(paths, session.id, issue)
      if not saved then
        return nil, save_err
      end
      local session_saved, session_save_err = save_session(paths, session)
      if not session_saved then
        return nil, session_save_err
      end
      M.sync_comments(cwd)
      return issue, nil
    end
  end
  return nil, "Comment is not in the active draft: " .. tostring(issue_id)
end

function M.delete(cwd, issue_id)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return false, err
  end
  local draft_id, pointer_err = read_pointer(paths, "draft")
  if pointer_err then
    return false, pointer_err
  end
  if not draft_id then
    return false, "Comment is not in the active draft: " .. tostring(issue_id)
  end
  local session, session_err = load_session(paths, draft_id)
  if not session then
    return false, session_err
  end
  local found = false
  local issue_ids = {}
  local issues = {}
  for _, issue in ipairs(session.issues or {}) do
    if issue.id == issue_id then
      found = true
    else
      issue_ids[#issue_ids + 1] = issue.id
      issues[#issues + 1] = issue
    end
  end
  if not found then
    return false, "Comment is not in the active draft: " .. tostring(issue_id)
  end
  local removed, remove_err = remove_file(session_paths(paths, session.id).comments .. "/" .. issue_id .. ".json")
  if not removed then
    return false, remove_err
  end
  session.issue_ids = issue_ids
  session.issues = issues
  local saved, save_err = save_session(paths, session)
  if not saved then
    return false, save_err
  end
  M.sync_comments(cwd)
  return true, nil
end

function M.simple_prompt(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local comments, comments_err = M.comments(cwd)
  if not comments then
    return nil, comments_err
  end
  if #comments == 0 then
    return nil, "No comments to send"
  end
  local synced, sync_err = M.sync_comments(cwd)
  if not synced then
    return nil, sync_err
  end
  local prompt = table.concat({
    "Resolve every review comment from this file:",
    paths.comments_markdown,
    "",
    "Work only in this exact Git worktree:",
    paths.root,
    "",
    "For each comment, inspect its saved source and context, then make the smallest safe code change.",
    "Do not edit the comments file. Do not stage, commit, push, or switch branches/worktrees.",
    "When finished, summarize which comment IDs were resolved and which remain blocked.",
  }, "\n")
  return {
    prompt = prompt .. "\n",
    comments_path = paths.comments_markdown,
  }, nil
end

local function render_prompt(session)
  local lines = {
    "$vigit-review",
    "",
    "Process the frozen Vigit review session `" .. session.id .. "`.",
    "",
    "- Worktree: `" .. session.worktree .. "`",
    "- Worktree ID: `" .. session.worktree_id .. "`",
    "- Branch at freeze: `" .. tostring(session.branch or "") .. "`",
    "- HEAD at freeze: `" .. tostring(session.head or "") .. "`",
    "- Issues: " .. tostring(#(session.issues or {})),
    "",
    "Work only in this exact worktree. Read the bundled Vigit review state,",
    "claim this session, process its frozen issue order, update every result,",
    "and complete the session. Do not stage, commit, push, switch branches, or",
    "inspect another worktree.",
    "",
    "Issue summary:",
  }
  for _, issue in ipairs(session.issues or {}) do
    lines[#lines + 1] = string.format(
      "- `%s` `%s` `%s:%d-%d`: %s",
      issue.id,
      issue.type or "FIX",
      issue.file,
      issue.line or 1,
      issue.line_end or issue.line or 1,
      tostring(issue.comment or ""):gsub("\n", " ")
    )
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.prepare(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local run_id, run_err = read_pointer(paths, "run")
  if run_err then
    return nil, run_err
  end
  if run_id then
    return nil, "Review already running: " .. run_id
  end
  local draft_id, draft_err = read_pointer(paths, "draft")
  if draft_err then
    return nil, draft_err
  end
  if not draft_id then
    return nil, "No draft review comments"
  end
  local session, session_err = load_session(paths, draft_id)
  if not session then
    return nil, session_err
  end
  if #(session.issue_ids or {}) == 0 then
    return nil, "No draft review comments"
  end
  session.status = "ready"
  session.frozen_at = timestamp()
  session.head = default_git.head(paths.root) or session.head
  session.branch = default_git.branch(paths.root) or session.branch
  local saved, save_err = save_session(paths, session)
  if not saved then
    return nil, save_err
  end
  local prompt = render_prompt(session)
  local prompt_ok, prompt_err = write_file(session_paths(paths, session.id).prompt, prompt)
  if not prompt_ok then
    return nil, prompt_err
  end
  local pointed, pointer_err = write_pointer(paths, "run", session.id)
  if not pointed then
    return nil, pointer_err
  end
  local removed, remove_err = remove_file(pointer_path(paths, "draft"))
  if not removed then
    return nil, remove_err
  end
  M.sync_markdown(cwd)
  return {
    session = session,
    prompt = prompt,
    prompt_path = session_paths(paths, session.id).prompt,
  }, nil
end

function M.prompt(cwd, review_id)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local content = read_file(session_paths(paths, review_id).prompt)
  if not content then
    return nil, "Missing prompt for review: " .. review_id
  end
  return content, nil
end

function M.retry(cwd)
  local paths, err = ensure_workspace(cwd)
  if not paths then
    return nil, err
  end
  local run_id, run_err = read_pointer(paths, "run")
  if run_err then
    return nil, run_err
  end
  if not run_id then
    return nil, "No interrupted review run"
  end
  local session, session_err = load_session(paths, run_id)
  if not session then
    return nil, session_err
  end
  local reset = 0
  for _, issue in ipairs(session.issues or {}) do
    if issue.status == "processing" then
      issue.status = "open"
      issue.started_at = nil
      issue.result = {}
      local ok, issue_err = save_issue(paths, session.id, issue)
      if not ok then
        return nil, issue_err
      end
      reset = reset + 1
    end
  end
  if reset == 0 then
    return nil, "No processing issues to retry"
  end
  session.status = "ready"
  session.retry_count = (tonumber(session.retry_count) or 0) + 1
  session.retry_requested_at = timestamp()
  local saved, save_err = save_session(paths, session)
  if not saved then
    return nil, save_err
  end
  local prompt = "RETRY\n\n" .. render_prompt(session)
  local prompt_ok, prompt_err = write_file(session_paths(paths, session.id).prompt, prompt)
  if not prompt_ok then
    return nil, prompt_err
  end
  M.sync_markdown(cwd)
  return {
    session = session,
    reset = reset,
    prompt = prompt,
    prompt_path = session_paths(paths, session.id).prompt,
  }, nil
end

return M
