local anchor = require("vigit.core.anchor")
local config = require("vigit.config")
local Result = require("vigit.core.result")
local Mutations = require("vigit.application.mutations")
local Changes = require("vigit.application.changes")
local ErrorState = require("vigit.application.error_state")
local confirm = require("vigit.ui.confirm")
local layout = require("vigit.ui.layout")
local renderer = require("vigit.ui.renderer")
local diff_view = require("vigit.ui.views.diff")
local comments_view = require("vigit.ui.views.comments")

local M = {}

local context = {}
local handler_requests = setmetatable({}, { __mode = "k" })
local refresh_requests = setmetatable({}, { __mode = "k" })
local source_target_kinds = {
  add = true,
  context = true,
  delete = true,
  file_placeholder = true,
}
local comment_target_kinds = { add = true, context = true, delete = true }
local open_comments

local supported_intents = {
  toggle_focus = true, focus_left = true, focus_right = true,
  activate = true, select_change = true, next_file = true,
  previous_file = true, next_hunk = true, previous_hunk = true,
  toggle_all_files = true, toggle_changes_mode = true, toggle_file_index = true,
  toggle_hunk_index = true, restore_hunk = true, restore_file = true,
  add_comment = true, open_comments = true, prepare_prompt = true,
  open_file = true, goto_definition = true, open_terminal = true,
  open_worktrees = true, toggle_context = true, refresh = true, resize = true,
  abandon = true, close = true, show_help = true,
}

function M.supports_intent(intent)
  return supported_intents[intent] == true
end

local function record_error(session, error)
  if type(error) ~= "table" then return end
  local diagnostic = {}
  for key, value in pairs(error) do diagnostic[key] = value end
  diagnostic.session_id = session and session.id or diagnostic.session_id
  require("vigit.ui.log").push(diagnostic)
end

function M.configure(opts)
  local previous = context
  local mutations = opts.mutations or Mutations.new({
    on_change = function(session)
      record_error(session, session.error)
      renderer.render(session)
    end,
  })
  context = {
    changes = assert(opts.changes),
    mutations = mutations,
    registry = assert(opts.registry),
    config = opts.config,
    open_file = opts.open_file,
    goto_definition = opts.goto_definition,
    open_terminal = opts.open_terminal,
    reviews = opts.reviews,
    worktrees = opts.worktrees,
  }
  return previous
end

local function review_error(session, error)
  record_error(session, error)
  session.errors = session.errors or {}
  session.errors.comments = error
  ErrorState.resolve(session)
  renderer.render(session)
end

local function review_changed(session)
  session.errors = session.errors or {}
  session.errors.comments = nil
  ErrorState.resolve(session)
  renderer.render(session)
end

local function reviews_for(session)
  return context.reviews or session.review_service
end

local function reload_comments(session)
  local reviews = reviews_for(session)
  if not reviews then return nil end
  local result = reviews:load(session)
  if not result.ok then
    review_error(session, result.error)
    return nil
  end
  review_changed(session)
  return result.value
end

local function comment_anchor(session)
  local window = session.owned.diff_win
  if not window or not vim.api.nvim_win_is_valid(window) then return nil end
  local cursor = vim.api.nvim_win_get_cursor(window)
  local row = renderer.target_at(session.owned.diff_buf, cursor[1])
  if not row or not comment_target_kinds[row.kind] or not row.source_line
      or not row.source_anchor or row.source_anchor.context == nil then return nil end
  return anchor.from_row(row, cursor[2]), row, cursor[1]
end

local function comment_by_id(session, id)
  for _, comment in ipairs(session.data.comments or {}) do
    if comment.id == id then return comment end
  end
end

local function jump_to_comment(session, comment)
  local window = session.owned.diff_win
  if not window or not vim.api.nvim_win_is_valid(window) then return end
  local function jump_rendered()
    if session.closed then return end
    local rendered = diff_view.render(session, vim.api.nvim_win_get_width(window))
    local reviews = reviews_for(session)
    if not reviews then return false end
    local row = reviews:nearest_anchor(rendered.rows, comment)
    if not row then return false end
    vim.api.nvim_set_current_win(window)
    vim.api.nvim_win_set_cursor(window, { row, comment.column or 0 })
    return true
  end
  if jump_rendered() then return end
  local matched
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, change in ipairs(session.data.status and session.data.status[section] or {}) do
      local path = comment.side == "old" and change.old_path or change.path
      if path == comment.path and change.section == comment.section then
        matched = change
        break
      end
    end
    if matched then break end
  end
  if not matched then
    review_error(session, Result.err("comment_anchor_missing", "Comment anchor is no longer in the Git diff").error)
    return
  end
  session.view.diff_mode = "one_file"
  session.view.selected_change_id = matched.id
  context.changes:load_diff(session, matched.id, nil, nil, function(result)
    if not result.ok or not jump_rendered() then
      review_error(session, Result.err("comment_anchor_missing", "Comment anchor is no longer in the rendered diff").error)
    end
  end)
end

local function add_or_edit_comment(session)
  local reviews = reviews_for(session)
  if not reviews then return end
  local source_anchor, _, row = comment_anchor(session)
  if not source_anchor or not source_anchor.path or not source_anchor.source_line then
    review_error(session, Result.err("comment_anchor_required", "Select a source line in the diff before adding a comment").error)
    return
  end
  local ids = renderer.comment_ids_at(session.owned.diff_buf, row)
  if #ids > 1 then
    open_comments(session, ids)
    return
  end
  local existing = ids[1] and comment_by_id(session, ids[1]) or nil
  comments_view.open_editor(session, reviews, {
    comment = existing,
    anchor = source_anchor,
    changed = function() review_changed(session) end,
    failed = function(error) review_error(session, error) end,
  })
end

open_comments = function(session, focus_ids)
  local reviews = reviews_for(session)
  if not reviews then return end
  comments_view.open(session, reviews, {
    changed = function() review_changed(session) end,
    failed = function(error) review_error(session, error) end,
    select = function(comment) jump_to_comment(session, comment) end,
    focus_ids = focus_ids,
  })
end

local function prepare_prompt(session)
  local reviews = reviews_for(session)
  if not reviews then return end
  local prompt = reviews:prompt(session)
  if type(prompt) == "table" and prompt.ok == false then
    review_error(session, prompt.error)
    return
  end
  local copied = vim.fn.has("clipboard") == 1 and pcall(vim.fn.setreg, "+", prompt)
  if not copied then comments_view.open_prompt(session, prompt) end
end

local function change_for(session, change_id)
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, change in ipairs(session.data.status and session.data.status[section] or {}) do
      if change.id == change_id then
        return change
      end
    end
  end
end

local function cursor_target(session)
  local window = session.owned.changes_win
  if not window or not vim.api.nvim_win_is_valid(window) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(window)[1]
  return renderer.target_at(session.owned.changes_buf, row)
end

local function capture_diff_anchor(session)
  local window = session.owned.diff_win
  if not window or not vim.api.nvim_win_is_valid(window) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(window)
  local row = renderer.target_at(session.owned.diff_buf, cursor[1])
  if not row or not row.change_id or not row.hunk_id then
    return nil
  end
  return {
    change_id = row.change_id,
    hunk_id = row.hunk_id,
    source_anchor = anchor.from_row(row, cursor[2]),
  }
end

local function restore_diff_anchor(session, source_anchor, reconcile_context)
  local window = session.owned.diff_win
  if session.closed or not window or not vim.api.nvim_win_is_valid(window) then
    return
  end

  local rendered = diff_view.render(
    session,
    vim.api.nvim_win_get_width(window)
  )
  local row = anchor.match(rendered.rows, source_anchor)
  if reconcile_context and row and source_anchor.context then
    local candidate = anchor.from_row(rendered.rows[row], source_anchor.column)
    if candidate.context ~= source_anchor.context then
      local contextual = {}
      for key, value in pairs(source_anchor) do
        contextual[key] = value
      end
      contextual.source_line = nil
      row = anchor.match(rendered.rows, contextual) or row
    end
  end
  if row then
    vim.api.nvim_win_set_cursor(window, {
      row,
      source_anchor.column or 0,
    })
    return anchor.from_row(rendered.rows[row], source_anchor.column)
  end
end

local function same_source_position(first, second)
  return first
    and second
    and first.path == second.path
    and first.section == second.section
    and first.side == second.side
    and first.source_line == second.source_line
end

local function active_target(session)
  local current_window = vim.api.nvim_get_current_win()
  local window
  local buffer
  if current_window == session.owned.changes_win then
    window = session.owned.changes_win
    buffer = session.owned.changes_buf
  else
    window = session.owned.diff_win
    buffer = session.owned.diff_buf
  end
  if not window
      or not vim.api.nvim_win_is_valid(window)
      or not buffer
      or not vim.api.nvim_buf_is_valid(buffer) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(window)
  return renderer.target_at(buffer, cursor[1]), cursor
end

local function active_change(session)
  local target = active_target(session)
  if not target then
    return nil
  end
  return change_for(session, target.change_id)
end

local function file_target_position(session, change_id)
  for index, target in ipairs(renderer.file_targets(session)) do
    if target.change_id == change_id then
      return index
    end
  end
end

local function file_anchor(session, change)
  local captured = capture_diff_anchor(session)
  if captured and captured.change_id == change.id then
    return captured.source_anchor
  end
  return {
    path = change.path,
    section = change.section,
    column = 0,
  }
end

local function mutation_error(session, error)
  record_error(session, error)
  session.errors = session.errors or {}
  session.errors.mutation = error
  ErrorState.resolve(session)
  renderer.render(session)
end

local function refresh_file_mutation(session, path, section, source_anchor, target_position)
  context.changes:refresh(session, function(event)
    if session.closed or not event.result.ok or event.phase ~= "status" then
      return
    end

    local updated
    for _, change in ipairs(session.data.status[section] or {}) do
      if change.path == path then
        updated = change
        break
      end
    end
    if not updated then
      local targets = renderer.file_targets(session)
      local target = targets[math.min(target_position or 1, #targets)]
      updated = target and change_for(session, target.change_id) or nil
    end
    if not updated then
      session.view.selected_change_id = nil
      session.view.anchor = nil
      renderer.render(session)
      return
    end

    session.view.selected_change_id = updated.id
    local restored_anchor = {}
    for key, value in pairs(source_anchor) do
      restored_anchor[key] = value
    end
    restored_anchor.path = updated.path
    restored_anchor.section = updated.section
    session.view.anchor = restored_anchor
    context.changes:load_diff(session, updated.id, nil, nil, function()
      if session.view.anchor == restored_anchor then
        session.view.anchor = restore_diff_anchor(
          session,
          restored_anchor,
          true
        ) or restored_anchor
      end
    end)
  end)
end

local function toggle_file_index(session)
  if session.busy.mutation then
    return
  end

  local change = active_change(session)
  if not change or (change.section ~= "staged" and change.section ~= "unstaged") then
    mutation_error(session, Result.err(
      "stale_change",
      "File change is missing or stale"
    ).error)
    return
  end

  local method = change.section == "staged" and "unstage_file" or "stage_file"
  if type(context.changes.git[method]) ~= "function" then
    mutation_error(session, Result.err(
      "mutation_unavailable",
      "File index mutation is unavailable"
    ).error)
    return
  end

  session.mutations = session.mutations or {}
  session.mutations.toggle_serial = (session.mutations.toggle_serial or 0) + 1
  local source_anchor = file_anchor(session, change)
  local target_position = file_target_position(session, change.id)
  local destination_section = change.section == "staged" and "unstaged" or "staged"
  context.mutations:enqueue(session, {
    id = "toggle_file_index:" .. session.mutations.toggle_serial,
    run = function(done)
      context.changes.git[method](context.changes.git, session.root, change, done)
    end,
    after_success = function()
      refresh_file_mutation(
        session,
        change.path,
        destination_section,
        source_anchor,
        target_position
      )
    end,
  })
end

local function hunk_for(change, file_diff, hunk_id)
  if not file_diff or type(hunk_id) ~= "string" then
    return nil
  end
  for _, hunk in ipairs(file_diff.hunks or {}) do
    if hunk.id == hunk_id then
      return hunk
    end
    for _, cluster in ipairs(anchor.logical_clusters(
      change,
      hunk,
      config.get().ui.context_lines
    )) do
      if cluster.key == hunk_id then
        return hunk
      end
    end
  end
end

local function change_identity(change)
  if not change then
    return nil
  end
  return table.concat({
    change.id or "",
    change.section or "",
    change.status or "",
    change.path or "",
    change.old_path or "",
    change.unmerged and "1" or "0",
  }, "\0")
end

local function toggle_hunk_index(session)
  if session.busy.mutation then
    return
  end

  local target = active_target(session)
  local change = target and change_for(session, target.change_id)
  if not change or not target.hunk_id
      or (change.section ~= "staged" and change.section ~= "unstaged") then
    mutation_error(session, Result.err(
      "stale_hunk",
      "Selected hunk is missing or stale"
    ).error)
    return
  end

  session.mutations = session.mutations or {}
  session.mutations.toggle_hunk_serial = (session.mutations.toggle_hunk_serial or 0) + 1
  local source_anchor = file_anchor(session, change)
  local target_position = file_target_position(session, change.id)
  local mutation_path = change.path
  local destination_section
  context.mutations:enqueue(session, {
    id = "toggle_hunk_index:" .. session.mutations.toggle_hunk_serial,
    run = function(done)
      local latest_change = change_for(session, target.change_id)
      if session.closed or not latest_change
          or (latest_change.section ~= "staged" and latest_change.section ~= "unstaged") then
        done(Result.err("stale_hunk", "Selected hunk is missing or stale"))
        return
      end

      local method = latest_change.section == "staged" and "unstage_hunk" or "stage_hunk"
      if type(context.changes.git[method]) ~= "function" then
        done(Result.err("mutation_unavailable", "Hunk index mutation is unavailable"))
        return
      end

      local ui = config.get().ui
      context.changes.git:diff(
        session.root,
        latest_change,
        ui.context_lines,
        ui.max_diff_bytes,
        function(diff_result)
          if session.closed then
            done(Result.err("stale_hunk", "Selected hunk is missing or stale"))
            return
          end
          if not diff_result.ok then
            done(diff_result)
            return
          end
          local hunk = hunk_for(latest_change, diff_result.value, target.hunk_id)
          if not hunk then
            done(Result.err("stale_hunk", "Selected hunk is missing or stale"))
            return
          end
          destination_section = latest_change.section == "staged" and "unstaged" or "staged"
          mutation_path = latest_change.path
          context.changes.git[method](
            context.changes.git,
            session.root,
            diff_result.value,
            hunk,
            done
          )
        end
      )
    end,
    after_success = function()
      refresh_file_mutation(
        session,
        mutation_path,
        destination_section,
        source_anchor,
        target_position
      )
    end,
  })
end

local function restore_hunk(session)
  if session.busy.mutation then
    return
  end

  local target = active_target(session)
  local change = target and change_for(session, target.change_id)
  if not change or not target.hunk_id then
    mutation_error(session, Result.err(
      "hunk_required",
      "Select an unstaged hunk before discarding it"
    ).error)
    return
  end
  if change.section == "staged" then
    mutation_error(session, Result.err(
      "unstage_first",
      "Unstage this hunk before discarding it"
    ).error)
    return
  end
  if change.section ~= "unstaged" then
    mutation_error(session, Result.err("stale_hunk", "Selected hunk is missing or stale").error)
    return
  end
  if type(context.changes.git.restore_hunk) ~= "function" then
    mutation_error(session, Result.err("mutation_unavailable", "Hunk rollback is unavailable").error)
    return
  end

  local rendered_hunk = hunk_for(
    change,
    session.data.diffs and session.data.diffs[change.id],
    target.hunk_id
  )
  if not rendered_hunk or type(rendered_hunk.patch) ~= "string" then
    mutation_error(session, Result.err("stale_hunk", "Selected hunk is missing or stale").error)
    return
  end
  local rendered_patch = rendered_hunk.patch

  confirm.ask("Discard selected hunk in " .. change.path .. "?", function(accepted)
    if not accepted or session.closed or session.busy.mutation then
      return
    end
    session.mutations = session.mutations or {}
    session.mutations.restore_hunk_serial = (session.mutations.restore_hunk_serial or 0) + 1
    local source_anchor = file_anchor(session, change)
    local target_position = file_target_position(session, change.id)
    local mutation_path = change.path
    context.mutations:enqueue(session, {
      id = "restore_hunk:" .. session.mutations.restore_hunk_serial,
      run = function(done)
        local latest_change = change_for(session, target.change_id)
        if session.closed or not latest_change or latest_change.section ~= "unstaged" then
          done(Result.err("stale_hunk", "Selected hunk is missing or stale"))
          return
        end
        local ui = config.get().ui
        context.changes.git:diff(
          session.root,
          latest_change,
          ui.context_lines,
          ui.max_diff_bytes,
          function(diff_result)
            if session.closed then
              done(Result.err("stale_hunk", "Selected hunk is missing or stale"))
              return
            end
            if not diff_result.ok then
              done(diff_result)
              return
            end
            local hunk = hunk_for(latest_change, diff_result.value, target.hunk_id)
            if not hunk or hunk.patch ~= rendered_patch then
              done(Result.err("stale_hunk", "Selected hunk is missing or stale"))
              return
            end
            mutation_path = latest_change.path
            context.changes.git:restore_hunk(
              session.root,
              diff_result.value,
              hunk,
              done
            )
          end
        )
      end,
      after_success = function()
        refresh_file_mutation(
          session,
          mutation_path,
          "unstaged",
          source_anchor,
          target_position
        )
      end,
    })
  end)
end

local function restore_file(session)
  if session.busy.mutation then
    return
  end

  local change = active_change(session)
  if not change or (change.section ~= "staged" and change.section ~= "unstaged") then
    mutation_error(session, Result.err("stale_change", "File change is missing or stale").error)
    return
  end
  if type(context.changes.git.restore_file) ~= "function" then
    mutation_error(session, Result.err("mutation_unavailable", "File rollback is unavailable").error)
    return
  end

  local prompt = change.status == "?"
    and ("Delete untracked file " .. change.path .. "?")
    or ("Restore " .. change.path .. " to HEAD? Staged and unstaged changes will be lost.")
  local confirmed_identity = change_identity(change)
  confirm.ask(prompt, function(accepted)
    if not accepted or session.closed or session.busy.mutation then
      return
    end
    session.mutations = session.mutations or {}
    session.mutations.restore_file_serial = (session.mutations.restore_file_serial or 0) + 1
    local source_anchor = file_anchor(session, change)
    local target_position = file_target_position(session, change.id)
    context.mutations:enqueue(session, {
      id = "restore_file:" .. session.mutations.restore_file_serial,
      run = function(done)
        local latest_change = change_for(session, change.id)
        if session.closed or not latest_change
            or change_identity(latest_change) ~= confirmed_identity then
          done(Result.err("stale_change", "File change is missing or stale"))
          return
        end
        context.changes.git:restore_file(session.root, latest_change, done)
      end,
      after_success = function()
        refresh_file_mutation(
          session,
          change.path,
          change.section,
          source_anchor,
          target_position
        )
      end,
    })
  end)
end

local function readonly(values)
  return setmetatable({}, {
    __index = values,
    __newindex = function()
      error("HandlerContext is read-only", 2)
    end,
    __pairs = function()
      return next, values, nil
    end,
    __metatable = "HandlerContext",
  })
end

local function handler_context(session)
  local target, cursor = active_target(session)
  if not target then
    return nil
  end

  local relative_path
  local source_line
  if target.kind == "change" and target.change then
    relative_path = target.change.path
  elseif source_target_kinds[target.kind] and target.source_line then
    relative_path = target.path
    source_line = target.source_line
  end
  if not relative_path then
    return nil
  end

  local candidate = vim.fs.joinpath(session.root, relative_path)
  local path = vim.uv.fs_realpath(candidate) or vim.fs.normalize(candidate)
  return readonly({
    session_id = session.id,
    root = session.root,
    branch = session.branch,
    path = path,
    relative_path = relative_path,
    line = source_line or 1,
    column = source_line and cursor[2] or 0,
    workspace = session.workspace,
    resources = session.resources,
  })
end

local function valid_handler_result(result)
  if not Result.is(result) then
    return false
  end
  if result.ok then
    return true
  end
  return type(result.error) == "table"
    and type(result.error.code) == "string"
    and result.error.code ~= ""
    and type(result.error.message) == "string"
    and result.error.message ~= ""
end

local function cancel_request(request)
  if not request or type(request.cancel) ~= "function" then
    return
  end
  local cancel = request.cancel
  request.cancel = nil
  pcall(cancel)
end

local function cancel_handler_request(session, action)
  local requests = handler_requests[session]
  if not requests then
    return
  end
  local request = requests[action]
  requests[action] = nil
  cancel_request(request)
end

local function cancel_handler_requests(session)
  local requests = handler_requests[session]
  handler_requests[session] = nil
  if not requests then
    return
  end
  for _, request in pairs(requests) do
    cancel_request(request)
  end
end

local function complete_handler(session, action, request, result)
  local requests = handler_requests[session]
  if session.closed or not requests or requests[action] ~= request then
    return
  end
  requests[action] = nil
  request.cancel = nil

  if not valid_handler_result(result) then
    result = Result.err(
      "invalid_handler_result",
      "Handler completion must receive a Result",
      result
    )
  end

  session.errors = session.errors or {}
  if result.ok then
    session.errors.handler = nil
  else
    record_error(session, result.error)
    session.errors.handler = result.error
  end
  ErrorState.resolve(session)
  renderer.render(session)
end

local function invoke_handler(
  session,
  action,
  unavailable_message,
  failure_message
)
  local values = handler_context(session)
  if not values then
    return
  end
  if session.workspace
      and type(session.workspace.show_code) == "function" then
    local code_mode = session.workspace:show_code()
    if not code_mode.ok then
      record_error(session, code_mode.error)
      renderer.render(session)
      return
    end
  end
  local configured = context.config
    and context.config.get().handlers[action]
  local handler = configured or context[action]
  local requests = handler_requests[session]
  if not requests then
    requests = {}
    handler_requests[session] = requests
  end
  cancel_handler_request(session, action)
  if type(handler) ~= "function" then
    local request = {}
    requests[action] = request
    complete_handler(session, action, request, Result.err(
      "handler_unavailable",
      unavailable_message
    ))
    return
  end

  local request = {}
  requests[action] = request
  local completed = false
  local function done(result)
    if completed then
      return
    end
    completed = true
    complete_handler(session, action, request, result)
  end
  local returned_cancel
  local ok, message = xpcall(function()
    returned_cancel = handler(values, done)
  end, debug.traceback)
  if not ok then
    done(Result.err(
      "handler_failed",
      failure_message,
      message
    ))
  end
  if type(returned_cancel) == "function" and not completed then
    local current = handler_requests[session]
    if session.closed or not current or current[action] ~= request then
      pcall(returned_cancel)
    else
      request.cancel = returned_cancel
    end
  end
end

local function select_change(session, intent)
  local target
  if type(intent) == "table" and intent.change_id then
    target = {
      kind = "change",
      change_id = intent.change_id,
    }
  else
    target = cursor_target(session)
  end
  if not target or target.kind ~= "change" then
    return target
  end
  if target.change_id ~= session.view.selected_change_id then
    refresh_requests[session] = nil
    context.changes:select(session, target.change_id)
  end
  return target
end

local function activate(session, intent)
  local target = cursor_target(session)
  if type(intent) == "table" and intent.change_id then
    target = {
      kind = "change",
      change_id = intent.change_id,
    }
  end
  if not target then
    return
  end

  if target.kind == "directory" then
    session.view.expanded_dirs = session.view.expanded_dirs or {}
    local key = target.key
      or string.format("%s\0%s", target.section or "", target.path)
    session.view.expanded_dirs[key] = target.expanded == false
    renderer.render(session)
    return
  end

  if target.kind == "change" then
    select_change(session, target)
    if session.owned.diff_win
        and vim.api.nvim_win_is_valid(session.owned.diff_win) then
      vim.api.nvim_set_current_win(session.owned.diff_win)
    end
  end
end

local function move_file(session, delta)
  local targets = renderer.file_targets(session)
  if #targets == 0 then
    return
  end

  local index = 0
  for candidate, target in ipairs(targets) do
    if target.change_id == session.view.selected_change_id then
      index = candidate
      break
    end
  end
  if index == 0 then
    index = delta > 0 and 0 or 1
  end
  index = ((index - 1 + delta) % #targets) + 1

  if session.owned.changes_win
      and vim.api.nvim_win_is_valid(session.owned.changes_win) then
    vim.api.nvim_win_set_cursor(session.owned.changes_win, { targets[index].row, 0 })
  end
  select_change(session, targets[index])
end

local function move_hunk(session, delta)
  local window = session.owned.diff_win
  if not window or not vim.api.nvim_win_is_valid(window) then return end
  local rendered = diff_view.render(session, vim.api.nvim_win_get_width(window))
  local rows, seen = {}, {}
  for row, target in ipairs(rendered.rows or {}) do
    if target.hunk_id and not seen[target.hunk_id] then
      seen[target.hunk_id] = true
      rows[#rows + 1] = row
    end
  end
  if #rows == 0 then return end
  local current = vim.api.nvim_win_get_cursor(window)[1]
  local index = delta > 0 and 1 or #rows
  for candidate, row in ipairs(rows) do
    if row == current then index = candidate; break end
    if delta > 0 and row > current then index = candidate; break end
    if delta < 0 and row >= current then index = math.max(1, candidate - 1); break end
  end
  if (delta > 0 and rows[index] <= current) or (delta < 0 and rows[index] >= current) then
    index = ((index - 1 + delta) % #rows) + 1
  end
  vim.api.nvim_win_set_cursor(window, { rows[index], 0 })
end

local function all_change_ids(session)
  local ids = {}
  local status = session.data.status or {}
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, change in ipairs(status[section] or {}) do
      if not session.view.all_files.loaded[change.id]
          and not session.view.all_files.loading[change.id] then
        ids[#ids + 1] = change.id
      end
    end
  end
  return ids
end

function M.dispatch(session, intent)
  if not session or session.closed then
    return
  end
  local name = type(intent) == "table" and (intent.name or intent.intent) or intent

  if name == "toggle_focus" then
    layout.toggle_changes(session)
    renderer.render(session)
  elseif name == "focus_left" or name == "focus_right" then
    layout.focus_direction(session, name == "focus_left" and "left" or "right")
  elseif name == "activate" then
    activate(session, intent)
  elseif name == "select_change" then
    select_change(session, intent)
  elseif name == "next_file" then
    move_file(session, 1)
  elseif name == "previous_file" then
    move_file(session, -1)
  elseif name == "next_hunk" then
    move_hunk(session, 1)
  elseif name == "previous_hunk" then
    move_hunk(session, -1)
  elseif name == "toggle_all_files" then
    refresh_requests[session] = nil
    session.view.diff_mode = session.view.diff_mode == "one_file"
      and "all_files"
      or "one_file"
    renderer.render(session)
    if session.view.diff_mode == "all_files" then
      context.changes:load_all_visible(session, all_change_ids(session))
    end
  elseif name == "toggle_changes_mode" then
    session.view.changes_mode = session.view.changes_mode == "tree" and "list" or "tree"
    renderer.render(session)
  elseif name == "toggle_file_index" then
    toggle_file_index(session)
  elseif name == "toggle_hunk_index" then
    toggle_hunk_index(session)
  elseif name == "restore_hunk" then
    restore_hunk(session)
  elseif name == "restore_file" then
    restore_file(session)
  elseif name == "add_comment" then
    add_or_edit_comment(session)
  elseif name == "open_comments" then
    open_comments(session)
  elseif name == "prepare_prompt" then
    prepare_prompt(session)
  elseif name == "open_file" then
    invoke_handler(
      session,
      "open_file",
      "Open-file handler is unavailable",
      "Open-file handler failed"
    )
  elseif name == "goto_definition" then
    invoke_handler(
      session,
      "goto_definition",
      "Go-to-definition handler is unavailable",
      "Go-to-definition handler failed"
    )
  elseif name == "open_terminal" then
    invoke_handler(
      session,
      "open_terminal",
      "Terminal handler is unavailable",
      "Terminal handler failed"
    )
  elseif name == "open_worktrees" then
    if context.worktrees and type(context.worktrees.open) == "function" then
      context.worktrees.open(session)
    end
  elseif name == "show_help" then
    local current = vim.api.nvim_get_current_win()
    local name_for_window = current == session.owned.changes_win and "changes" or "diff"
    require("vigit.ui.views.help").open(name_for_window)
  elseif name == "toggle_context" or name == "f" then
    refresh_requests[session] = nil
    local captured = capture_diff_anchor(session)
    if captured then
      local previous = session.view.anchor
      if previous
          and previous.hunk_id
          and session.view.expanded_context[previous.hunk_id]
          and same_source_position(previous, captured.source_anchor) then
        captured.hunk_id = previous.hunk_id
        captured.source_anchor.hunk_id = previous.hunk_id
      end
      session.view.anchor = captured.source_anchor
      context.changes:toggle_context(
        session,
        captured.change_id,
        captured.hunk_id,
        function()
          if session.view.anchor == captured.source_anchor then
            session.view.anchor = restore_diff_anchor(
              session,
              captured.source_anchor
            ) or captured.source_anchor
          end
        end
      )
    end
  elseif name == "refresh" then
    reload_comments(session)
    local captured = capture_diff_anchor(session)
    if not captured then
      refresh_requests[session] = nil
      context.changes:refresh(session)
    else
      local request = {
        change_id = captured.change_id,
        source_anchor = captured.source_anchor,
      }
      refresh_requests[session] = request
      session.view.anchor = request.source_anchor
      context.changes:refresh(session, function(event)
        if session.closed
            or refresh_requests[session] ~= request
            or session.view.anchor ~= request.source_anchor then
          return
        end

        local ready = event.phase == "diff"
            and event.change_id == request.change_id
          or event.phase == "status"
            and (not event.result.ok
              or not event.load_ids[request.change_id])
        if not ready then
          return
        end

        refresh_requests[session] = nil
        local window = session.owned.diff_win
        if not window or not vim.api.nvim_win_is_valid(window) then
          return
        end
        local current = renderer.target_at(
          session.owned.diff_buf,
          vim.api.nvim_win_get_cursor(window)[1]
        )
        if current and current.change_id ~= request.change_id then
          return
        end
        session.view.anchor = restore_diff_anchor(
          session,
          request.source_anchor,
          true
        ) or request.source_anchor
      end)
    end
  elseif name == "resize" then
    layout.resize(session)
    renderer.render(session)
  elseif name == "abandon" then
    refresh_requests[session] = nil
    cancel_handler_requests(session)
    if session.workspace
        and type(session.workspace.active_session) == "function"
        and session.workspace:active_session() == session
        and type(session.workspace.close) == "function" then
      session.workspace:close()
    else
      renderer.clear(session)
      layout.abandon(session)
      context.registry:remove(session.id)
    end
  elseif name == "close" then
    refresh_requests[session] = nil
    cancel_handler_requests(session)
    if session.workspace
        and type(session.workspace.show_code) == "function" then
      session.workspace:show_code()
    else
      layout.close(session)
    end
  end
end

return M
