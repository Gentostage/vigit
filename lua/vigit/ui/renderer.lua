local process = require("vigit.adapters.process")
local Git = require("vigit.adapters.git_cli")
local anchor = require("vigit.core.anchor")
local treesitter = require("vigit.adapters.treesitter")
local config = require("vigit.config")
local changes_view = require("vigit.ui.views.changes")
local diff_view = require("vigit.ui.views.diff")
local diff_highlights = require("vigit.ui.highlights")

local M = {}

local default_git = Git.new(process)
local syntax_dependencies = {
  git = default_git,
  inspect = treesitter.inspect,
}
local namespaces = setmetatable({}, { __mode = "k" })
local syntax_states = setmetatable({}, { __mode = "k" })
local targets = {}
local comment_rows = {}

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function window_width(window)
  if window and vim.api.nvim_win_is_valid(window) then
    return vim.api.nvim_win_get_width(window)
  end
  return vim.o.columns
end

local function session_namespaces(session)
  local owned = namespaces[session]
  if owned then
    return owned
  end

  local prefix = "vigit-v2-" .. tostring(session.id)
  owned = {
    changes = vim.api.nvim_create_namespace(prefix .. "-changes"),
    changes_targets = vim.api.nvim_create_namespace(
      prefix .. "-changes-targets"
    ),
    diff = vim.api.nvim_create_namespace(prefix .. "-diff"),
    diff_targets = vim.api.nvim_create_namespace(prefix .. "-diff-targets"),
    diff_status = vim.api.nvim_create_namespace(prefix .. "-diff-status"),
    comments = vim.api.nvim_create_namespace(prefix .. "-comments"),
  }
  namespaces[session] = owned
  return owned
end

local function comment_preview(body)
  local preview = vim.trim(tostring(body or ""):gsub("%s+", " "))
  if preview == "" then preview = "(empty comment)" end
  if vim.fn.strchars(preview) > 52 then
    preview = vim.fn.strcharpart(preview, 0, 51) .. "…"
  end
  return preview
end

local function apply_comment_markers(session, rendered, namespace)
  local buffer = session.owned.diff_buf
  if not valid_buffer(buffer) then return end
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  comment_rows[buffer] = {}
  for _, comment in ipairs(session.data.comments or {}) do
    local row = anchor.match(rendered.rows, {
      path = comment.path,
      section = comment.section,
      side = comment.side,
      source_line = comment.line,
      column = comment.column or 0,
      context = comment.context,
    }, { strict_side = true })
    if row then
      local ids = comment_rows[buffer][row] or {}
      ids[#ids + 1] = comment.id
      comment_rows[buffer][row] = ids
      vim.api.nvim_buf_set_extmark(buffer, namespace, row - 1, 0, {
        virt_text = { { " ● " .. comment.id .. " · " .. comment_preview(comment.body), "Comment" } },
        virt_text_pos = "eol",
        priority = diff_highlights.priorities.overlay + 1,
        strict = false,
      })
    end
  end
end

local function add_view_highlights(buffer, namespace, output)
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  for _, highlight in ipairs(output.highlights or {}) do
    local options = {
      hl_group = highlight.group,
      strict = false,
    }
    local column = highlight.start_col or 0
    if highlight.start_col ~= nil and highlight.end_col ~= nil then
      options.end_row = highlight.row - 1
      options.end_col = highlight.end_col
    else
      options.end_row = highlight.row
      options.hl_eol = true
    end
    vim.api.nvim_buf_set_extmark(
      buffer,
      namespace,
      highlight.row - 1,
      column,
      options
    )
  end
end

local function add_targets(buffer, namespace, output)
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  for _, target in ipairs(output.targets or {}) do
    vim.api.nvim_buf_set_extmark(buffer, namespace, target.row - 1, 0, {
      strict = false,
    })
  end
end

local function apply(
    buffer,
    namespace,
    target_namespace,
    output,
    inspections
)
  if not valid_buffer(buffer) then
    return
  end

  targets[buffer] = nil
  vim.bo[buffer].modifiable = true
  local ok, message = xpcall(function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, output.lines)
    if output.rows then
      diff_highlights.apply_diff(
        buffer,
        output,
        inspections or {},
        namespace
      )
    else
      add_view_highlights(buffer, namespace, output)
    end
    add_targets(buffer, target_namespace, output)
    targets[buffer] = output.targets or {}
  end, debug.traceback)
  if valid_buffer(buffer) then
    vim.bo[buffer].modifiable = false
  end
  if not ok then
    error(message, 0)
  end
end

local function cancel_job(job)
  local handle = job and (job.handle or job)
  if type(handle) == "table" and type(handle.cancel) == "function" then
    pcall(handle.cancel)
  end
end

local function cancel_syntax_jobs(session)
  for key, job in pairs(session.reads.jobs or {}) do
    if type(key) == "string" and key:sub(1, 7) == "syntax:" then
      cancel_job(job)
      session.reads.jobs[key] = nil
    end
  end
end

local function syntax_state(session)
  local state = syntax_states[session]
  if state and state.generation == session.reads.generation then
    return state
  end

  cancel_syntax_jobs(session)
  state = {
    generation = session.reads.generation,
    token = 0,
    files = {},
  }
  syntax_states[session] = state
  return state
end

local function changes_by_id(session)
  local changes = {}
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, change in ipairs(
        session.data.status and session.data.status[section] or {}
    ) do
      changes[change.id] = change
    end
  end
  return changes
end

local function visible_changes(session, rendered)
  local by_id = changes_by_id(session)
  local result = {}
  local seen = {}
  for _, row in ipairs(rendered.rows or {}) do
    if row.change_id
        and not seen[row.change_id]
        and (row.kind == "add"
          or row.kind == "delete"
          or row.kind == "context"
          or row.kind == "gap") then
      local change = by_id[row.change_id]
      if change then
        seen[row.change_id] = true
        result[#result + 1] = change
      end
    end
  end
  return result
end

local function visible_inspections(state, rendered)
  local result = {}
  for _, row in ipairs(rendered.rows or {}) do
    local file = row.change_id and state.files[row.change_id] or nil
    if file and file.complete then
      result[row.change_id] = file.inspections
    end
  end
  return result
end

local function state_is_current(session, state)
  return syntax_states[session] == state
    and not session.closed
    and session.reads.generation == state.generation
end

local function apply_current_inspections(session, state)
  if not state_is_current(session, state)
      or not state.rendered
      or not valid_buffer(session.owned.diff_buf) then
    return
  end
  diff_highlights.apply_diff(
    session.owned.diff_buf,
    state.rendered,
    visible_inspections(state, state.rendered),
    state.namespace
  )
  local owned = namespaces[session]
  if owned then
    M.apply_syntax_statuses(session, state, owned.diff_status)
  end
end

local function inspection_path(change, side)
  if side == "old" then
    return change.old_path or change.path
  end
  return change.path
end

local function inspect_snapshot(change, side, result)
  if not result.ok then
    return result
  end
  local ok, inspected = pcall(syntax_dependencies.inspect, {
    path = inspection_path(change, side),
    source = result.value,
    max_bytes = config.get().ui.max_highlight_bytes,
  })
  if not ok then
    return {
      ok = false,
      error = {
        code = "parser_unavailable",
        message = "Tree-sitter inspection failed",
        details = inspected,
        retryable = false,
      },
    }
  end
  return inspected
end

local function start_snapshot_side(session, state, change, file, side)
  local job_key = "syntax:" .. change.id .. ":" .. side
  local request = {}
  session.reads.jobs[job_key] = request
  local handle = syntax_dependencies.git:snapshot(
    session.root,
    change,
    side,
    function(result)
      if session.reads.jobs[job_key] == request then
        session.reads.jobs[job_key] = nil
      end
      if not state_is_current(session, state)
          or state.files[change.id] ~= file then
        return
      end

      local inspected = inspect_snapshot(change, side, result)
      if inspected and inspected.ok then
        file.inspections[side] = inspected.value
      elseif inspected and inspected.error then
        file.errors[side] = inspected.error
      end
      file.pending = file.pending - 1
      if file.pending == 0 then
        file.complete = true
        apply_current_inspections(session, state)
      end
    end
  )
  if session.reads.jobs[job_key] == request then
    request.handle = handle
  end
end

local function schedule_inspection(session, state, rendered, namespace)
  state.token = state.token + 1
  local token = state.token
  state.rendered = rendered
  state.namespace = namespace

  vim.schedule(function()
    if not state_is_current(session, state) or state.token ~= token then
      return
    end
    for _, change in ipairs(visible_changes(session, rendered)) do
      if not state.files[change.id] then
        local file = {
          pending = 2,
          inspections = {},
          errors = {},
          complete = false,
        }
        state.files[change.id] = file
        start_snapshot_side(session, state, change, file, "old")
        start_snapshot_side(session, state, change, file, "new")
      end
    end
  end)
end

local function status_row(rendered, change_id)
  for row, rendered_row in ipairs(rendered.rows or {}) do
    if rendered_row.kind == "file_header"
        and rendered_row.change_id == change_id then
      return row
    end
  end
end

local function syntax_status(file)
  if not file or not file.complete then
    return "syntax: loading", "Comment"
  end
  local failure = file.errors.old or file.errors.new
  if failure then
    local code = type(failure.code) == "string"
        and failure.code
      or "unknown_error"
    return "syntax: " .. code, "ErrorMsg"
  end
end

function M.apply_syntax_statuses(session, state, namespace)
  local buffer = session.owned.diff_buf
  if not valid_buffer(buffer) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  if not state_is_current(session, state) or not state.rendered then
    return
  end

  for _, change in ipairs(visible_changes(session, state.rendered)) do
    local text, group = syntax_status(state.files[change.id])
    local row = status_row(state.rendered, change.id)
    if text and row then
      vim.api.nvim_buf_set_extmark(buffer, namespace, row - 1, 0, {
        virt_text = { { " [" .. text .. "]", group } },
        virt_text_pos = "right_align",
        priority = diff_highlights.priorities.overlay,
        strict = false,
      })
    end
  end
end

function M.configure(opts)
  opts = opts or {}
  syntax_dependencies = {
    git = opts.git or default_git,
    inspect = opts.inspect or treesitter.inspect,
  }
end

function M.render(session)
  if session.closed
      or not session.owned.tab
      or not vim.api.nvim_tabpage_is_valid(session.owned.tab) then
    return
  end

  diff_highlights.setup()
  local changes = changes_view.render(
    session,
    window_width(session.owned.changes_win)
  )
  local diff = diff_view.render(
    session,
    window_width(session.owned.diff_win)
  )
  local owned_namespaces = session_namespaces(session)
  local state = syntax_state(session)
  state.rendered = diff
  state.namespace = owned_namespaces.diff
  apply(
    session.owned.changes_buf,
    owned_namespaces.changes,
    owned_namespaces.changes_targets,
    changes
  )
  apply(
    session.owned.diff_buf,
    owned_namespaces.diff,
    owned_namespaces.diff_targets,
    diff,
    visible_inspections(state, diff)
  )
  M.apply_syntax_statuses(
    session,
    state,
    owned_namespaces.diff_status
  )
  apply_comment_markers(session, diff, owned_namespaces.comments)
  if session.owned.diff_win
      and vim.api.nvim_win_is_valid(session.owned.diff_win) then
    vim.wo[session.owned.diff_win].signcolumn = "yes:1"
  end
  schedule_inspection(session, state, diff, owned_namespaces.diff)
end

function M.target_at(buffer, row)
  for _, target in ipairs(targets[buffer] or {}) do
    if target.row == row then
      return target
    end
  end
end

function M.file_targets(session)
  local result = {}
  for _, target in ipairs(targets[session.owned.changes_buf] or {}) do
    if target.kind == "change" then
      result[#result + 1] = target
    end
  end
  return result
end

function M.comment_ids_at(buffer, row)
  local source = comment_rows[buffer] and comment_rows[buffer][row] or {}
  local result = {}
  for index, id in ipairs(source) do result[index] = id end
  return result
end

function M.clear(session)
  cancel_syntax_jobs(session)
  syntax_states[session] = nil
  if session.owned.diff_buf then
    targets[session.owned.diff_buf] = nil
    comment_rows[session.owned.diff_buf] = nil
  end
  if session.owned.changes_buf then
    targets[session.owned.changes_buf] = nil
  end
  local owned_namespaces = namespaces[session]
  if owned_namespaces then
    for kind, namespace in pairs(owned_namespaces) do
      local buffer = kind:sub(1, 4) == "diff"
        and session.owned.diff_buf
        or session.owned.changes_buf
      if valid_buffer(buffer) then
        pcall(vim.api.nvim_buf_clear_namespace, buffer, namespace, 0, -1)
      end
    end
  end
  namespaces[session] = nil
end

return M
