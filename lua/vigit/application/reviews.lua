local anchor = require("vigit.core.anchor")
local review = require("vigit.core.review")
local filesystem_module = require("vigit.adapters.filesystem")
local Result = require("vigit.core.result")

local M = {}
local Reviews = {}
Reviews.__index = Reviews

local default_relative_path = ".vigit/comments.md"
local empty_document = "# Vigit Review\n\n<!-- vigit-format: 1 -->\n"

local function valid_relative_path(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true)
      or path:sub(1, 1) == "/" or path:match("^%a:[/\\]")
      or path:find("\\", 1, true) or path:find("//", 1, true)
      or path:sub(-1) == "/" then
    return false
  end
  for component in path:gmatch("[^/]+") do
    if component == "." or component == ".." then return false end
  end
  return true
end

local function invalid_relative_path()
  return Result.err("invalid_config", "review.path must be a safe repository-relative file path")
end

local function comments_data(session)
  session.data = session.data or {}
  return session.data
end

local function install(session, document)
  local data = comments_data(session)
  data.comments_document = document
  data.comments = document.comments or {}
  data.comments_count = #data.comments
end

local function missing_file(result)
  return result and not result.ok
    and (result.error.code == "not_found"
      or (result.error.code == "read_failed" and (
        result.error.details == 2
        or tostring(result.error.details):lower():find("enoent", 1, true) ~= nil
        or tostring(result.error.details):lower():find("no such file", 1, true) ~= nil
      )))
end

local function require_document(session)
  local document = comments_data(session).comments_document
  if not document then
    return Result.err("comments_not_loaded", "Comments must be loaded before they can be changed")
  end
  return Result.ok(document)
end

function M.new(opts)
  opts = opts or {}
  local configured_path = opts.relative_path or default_relative_path
  local path_ok = valid_relative_path(configured_path)
  local path_error
  if not path_ok then path_error = invalid_relative_path() end
  return setmetatable({
    filesystem = opts.filesystem or filesystem_module.new(),
    review = opts.review or review,
    backup_id = opts.backup_id,
    relative_path = path_ok and configured_path or nil,
    path_error = path_error,
  }, Reviews)
end

function Reviews:load(session)
  if type(session) ~= "table" or type(session.root) ~= "string" or session.root == "" then
    return Result.err("invalid_session", "Comment session must have a worktree root")
  end
  local parsed = self:read_document(session)
  if not parsed.ok then return parsed end
  install(session, parsed.value)
  return parsed
end

function Reviews:read_document(session)
  if self.path_error then return self.path_error end
  if type(session) ~= "table" or type(session.root) ~= "string" or session.root == "" then
    return Result.err("invalid_session", "Comment session must have a worktree root")
  end
  local resolved = self.filesystem:resolve_under(session.root, self.relative_path)
  if not resolved.ok then return resolved end
  local source = self.filesystem:read(resolved.value)
  if missing_file(source) then
    source = Result.ok(empty_document)
  end
  if not source.ok then return source end
  return self.review.parse(source.value)
end

function Reviews:write(session, document)
  if self.path_error then return self.path_error end
  local serialized = self.review.serialize(document)
  local persisted = self.filesystem:atomic_write(session.root, self.relative_path, serialized)
  if not persisted.ok then return persisted end
  install(session, document)
  return Result.ok(document)
end

function Reviews:add(session, source_anchor, body)
  local current = self:read_document(session)
  if not current.ok then return current end
  source_anchor = source_anchor or {}
  local added = self.review.add(current.value, {
    path = source_anchor.path,
    line = source_anchor.line or source_anchor.source_line,
    column = source_anchor.column,
    side = source_anchor.side,
    section = source_anchor.section,
    context = source_anchor.context or "",
    body = body,
  })
  if not added.ok then return added end
  local saved = self:write(session, added.value)
  if not saved.ok then return saved end
  return Result.ok(added.value.last_added)
end

function Reviews:update(session, id, body, changes)
  local current = self:read_document(session)
  if not current.ok then return current end
  changes = changes or {}
  if body ~= nil then changes.body = body end
  local updated = self.review.update(current.value, id, changes)
  if not updated.ok then return updated end
  return self:write(session, updated.value)
end

function Reviews:delete(session, id)
  local current = self:read_document(session)
  if not current.ok then return current end
  local deleted = self.review.delete(current.value, id)
  if not deleted.ok then return deleted end
  return self:write(session, deleted.value)
end

function Reviews:prompt(session)
  local current = require_document(session)
  if not current.ok then return current end
  return self.review.prompt(current.value, session.root, self.relative_path)
end

function Reviews:nearest_anchor(rows, comment)
  return anchor.match(rows, {
    path = comment.path,
    section = comment.section,
    side = comment.side,
    source_line = comment.line,
    column = comment.column or 0,
    context = comment.context,
  }, { strict_side = true })
end

function Reviews:migrate_legacy(session, legacy, confirmed)
  if not legacy or type(legacy.preview) ~= "function" then
    return Result.err("legacy_unavailable", "Legacy review importer is unavailable")
  end
  local current = confirmed and self:read_document(session) or require_document(session)
  if not current.ok then return current end
  local preview = legacy:preview(session.root)
  if not preview.ok then return preview end
  if not confirmed then
    return Result.ok({ migrated = false, preview = preview.value })
  end

  local existing = {}
  for _, comment in ipairs(current.value.comments or {}) do existing[comment.id] = true end
  local merged = current.value
  local imported, skipped = 0, 0
  for _, comment in ipairs(preview.value.comments or {}) do
    if existing[comment.id] then
      skipped = skipped + 1
    else
      local added = self.review.add(merged, comment)
      if not added.ok then return added end
      merged = added.value
      existing[comment.id] = true
      imported = imported + 1
    end
  end
  if imported == 0 then
    return Result.ok({ migrated = false, preview = preview.value, imported = 0, skipped = skipped })
  end
  local sources = preview.value.sources or {}
  local backup_relative
  for attempt = 1, 16 do
    local nonce = self.backup_id and self.backup_id(attempt) or string.format("%d-%d", vim.fn.getpid(), attempt)
    if type(nonce) ~= "string" and type(nonce) ~= "number" then
      return Result.err("backup_id_invalid", "Legacy backup ID generator returned an invalid value")
    end
    nonce = tostring(nonce)
    if not nonce:match("^[%w._-]+$") then
      return Result.err("backup_id_invalid", "Legacy backup ID generator returned an unsafe value")
    end
    local candidate = ".vigit/backups/" .. os.date("!%Y%m%dT%H%M%SZ") .. "-" .. nonce .. "-legacy-review"
    local directory = self.filesystem:resolve_under(session.root, candidate)
    if not directory.ok then return directory end
    if not vim.uv.fs_lstat(directory.value) then
      local first = sources[1] and (candidate .. "/" .. sources[1].relative_path) or candidate
      local resolved = self.filesystem:resolve_under(session.root, first)
      if not resolved.ok then return resolved end
      local existing = self.filesystem:read(resolved.value)
      if missing_file(existing) then
        backup_relative = candidate
        break
      elseif not existing.ok then
        return existing
      end
    end
  end
  if not backup_relative then return Result.err("backup_collision", "Unable to allocate a unique legacy review backup") end
  for _, source in ipairs(sources) do
    if type(source.relative_path) ~= "string" or type(source.bytes) ~= "string" then
      return Result.err("malformed_legacy", "Legacy backup source is malformed")
    end
    local backup = self.filesystem:atomic_write(
      session.root,
      backup_relative .. "/" .. source.relative_path,
      source.bytes
    )
    if not backup.ok then return backup end
  end
  local saved = self:write(session, merged)
  if not saved.ok then return saved end
  return Result.ok({
    migrated = true, preview = preview.value, imported = imported, skipped = skipped,
    backup_relative = backup_relative,
  })
end

M.relative_path = default_relative_path
M.empty_document = empty_document

local default
local function instance()
  default = default or M.new()
  return default
end

local function service_for(session)
  return type(session) == "table" and session.review_service or instance()
end

function M.for_session(session) return service_for(session) end
function M.load(session) return service_for(session):load(session) end
function M.add(session, source_anchor, body) return service_for(session):add(session, source_anchor, body) end
function M.update(session, id, body, changes) return service_for(session):update(session, id, body, changes) end
function M.delete(session, id) return service_for(session):delete(session, id) end
function M.prompt(session) return service_for(session):prompt(session) end
function M.nearest_anchor(rows, comment) return instance():nearest_anchor(rows, comment) end
function M.migrate_legacy(session, legacy, confirmed) return service_for(session):migrate_legacy(session, legacy, confirmed) end

return M
