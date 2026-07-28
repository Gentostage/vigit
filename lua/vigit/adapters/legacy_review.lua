local Result = require("vigit.core.result")
local SecureRead = require("vigit.adapters.secure_read")

local M = {}
local Legacy = {}
Legacy.__index = Legacy

local function error(code, message, details)
  return Result.err(code, message, details)
end

local function safe_id(value)
  return type(value) == "string" and value:match("^[%w._-]+$") ~= nil
end

local function within(root, candidate)
  root, candidate = root:gsub("/+$", ""), candidate:gsub("/+$", "")
  return candidate == root or candidate:sub(1, #root + 1) == root .. "/"
end

local function normalize_root(root)
  local absolute = vim.fn.fnamemodify(root, ":p"):gsub("/+$", "")
  return vim.uv.fs_realpath(absolute) or absolute
end

local function worktree_id(root)
  local name = root:match("([^/]+)$") or "worktree"
  name = name:gsub("[^%w._-]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  return (name == "" and "worktree" or name) .. "-" .. vim.fn.sha256(root):sub(1, 12)
end

local function safe_relative(relative)
  if type(relative) ~= "string" or relative == "" or relative:sub(1, 1) == "/"
      or relative:find("\\", 1, true) or relative:find("//", 1, true) then return false end
  for part in relative:gmatch("[^/]+") do
    if part == "." or part == ".." then return false end
  end
  return true
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({ common_git_dir = opts.common_git_dir, uv = opts.uv or vim.uv, reader = opts.reader or SecureRead.new(opts) }, Legacy)
end

function Legacy:resolve_common_git_dir(root)
  local value
  if type(self.common_git_dir) == "function" then value = self.common_git_dir(root)
  elseif type(self.common_git_dir) == "string" then value = self.common_git_dir
  else
    local result = vim.system({ "git", "-C", root, "rev-parse", "--git-common-dir" }, { text = true }):wait()
    if result.code ~= 0 then return error("legacy_path_unavailable", "Legacy Git common directory is unavailable", result.stderr) end
    value = vim.trim(result.stdout or "")
    if value:sub(1, 1) ~= "/" then value = root .. "/" .. value end
  end
  if type(value) ~= "string" or value == "" then return error("legacy_path_unavailable", "Legacy Git common directory is unavailable") end
  local canonical = self.uv.fs_realpath(value)
  if not canonical then return error("legacy_path_unavailable", "Legacy Git common directory cannot be resolved") end
  return Result.ok(canonical)
end

function Legacy:read_under(root, relative)
  if not safe_relative(relative) then return error("unsafe_legacy_path", "Legacy path is unsafe", relative) end
  return self.reader:read(root, relative)
end

local function decode(source, label)
  local ok, value = pcall(vim.json.decode, source.bytes)
  if not ok or type(value) ~= "table" then return error("malformed_legacy", "Legacy " .. label .. " is malformed", source.relative_path) end
  return Result.ok(value)
end

function Legacy:preview(root)
  root = normalize_root(root)
  local common = self:resolve_common_git_dir(root)
  if not common.ok then return common end
  local prefix = "vigit/worktrees/" .. worktree_id(root)
  local pointer_source
  for _, name in ipairs({ "draft", "run", "latest" }) do
    local candidate = self:read_under(common.value, prefix .. "/active/" .. name .. ".json")
    if candidate.ok then
      pointer_source = candidate.value
      pointer_source.relative_path = pointer_source.relative_path:sub(#prefix + 2)
      break
    elseif candidate.error.code ~= "legacy_not_found" then
      return candidate
    end
  end
  if not pointer_source then return Result.ok({ importable = 0, comments = {}, sources = {} }) end
  local pointer = decode(pointer_source, "review pointer")
  if not pointer.ok then return pointer end
  if pointer.value.schema_version ~= 2 then return error("unsupported_legacy_schema", "Legacy review pointer schema is unsupported") end
  local review_id = pointer.value.review_id
  if not safe_id(review_id) then return error("unsafe_legacy_path", "Legacy review pointer contains an unsafe review ID") end
  local session_source = self:read_under(common.value, prefix .. "/reviews/" .. review_id .. "/session.json")
  if not session_source.ok then return session_source end
  session_source.value.relative_path = session_source.value.relative_path:sub(#prefix + 2)
  local review_session = decode(session_source.value, "review session")
  if not review_session.ok then return review_session end
  if review_session.value.schema_version ~= 2 then return error("unsupported_legacy_schema", "Legacy review session schema is unsupported") end
  if type(review_session.value.issue_ids) ~= "table" or not vim.islist(review_session.value.issue_ids) then
    return error("malformed_legacy", "Legacy review session has invalid issue IDs")
  end
  local comments, sources = {}, { pointer_source, session_source.value }
  local seen_ids = {}
  for _, issue_id in ipairs(review_session.value.issue_ids) do
    if not safe_id(issue_id) or seen_ids[issue_id] then return error("unsafe_legacy_path", "Legacy review contains an unsafe issue ID") end
    seen_ids[issue_id] = true
    local issue_source = self:read_under(common.value, prefix .. "/reviews/" .. review_id .. "/comments/" .. issue_id .. ".json")
    if not issue_source.ok then return issue_source end
    issue_source.value.relative_path = issue_source.value.relative_path:sub(#prefix + 2)
    sources[#sources + 1] = issue_source.value
    local issue = decode(issue_source.value, "review issue")
    if not issue.ok then return issue end
    local value = issue.value
    if value.schema_version ~= nil and value.schema_version ~= 2 then
      return error("unsupported_legacy_schema", "Legacy review issue schema is unsupported", issue_id)
    end
    if type(value.file) ~= "string" or value.file == "" or not safe_relative(value.file)
        or type(value.comment) ~= "string" then
      return error("malformed_legacy", "Legacy review issue has unsafe comment fields", issue_id)
    end
    local line = tonumber(value.line)
    if not line or line < 1 or line % 1 ~= 0 then return error("malformed_legacy", "Legacy review issue has an invalid source line", issue_id) end
    local response = type(value.result) == "table" and (value.result.summary or value.result.message) or value.result
    comments[#comments + 1] = {
      id = value.id or issue_id, path = value.file, line = line, column = 0,
      side = "new", section = value.section == "staged" and "staged" or "unstaged",
      context = type(value.context) == "string" and value.context or "",
      body = value.comment,
      done = value.status == "resolved" or value.status == "done" or value.status == "closed",
      response = type(response) == "string" and response or "",
    }
  end
  return Result.ok({ importable = #comments, comments = comments, sources = sources })
end

return M
