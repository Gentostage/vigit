local anchor = require("vigit.core.anchor")
local config = require("vigit.config")

local M = {}

local groups = {
  add = "DiffAdd",
  delete = "DiffDelete",
  context = "Normal",
  meta = "Comment",
}

local function escape_control(text)
  text = text:gsub("\\", "\\\\")
  return (text:gsub("[%z\1-\31\127]", function(character)
    if character == "\n" then
      return "\\n"
    elseif character == "\r" then
      return "\\r"
    elseif character == "\t" then
      return "\\t"
    end
    return string.format("\\x%02X", character:byte())
  end))
end

local function shorten(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end

  local ellipsis = "…"
  local available = width - vim.fn.strdisplaywidth(ellipsis)
  if available <= 0 then
    return ellipsis
  end

  local low = 0
  local high = vim.fn.strchars(text)
  while low < high do
    local middle = math.ceil((low + high) / 2)
    local prefix = vim.fn.strcharpart(text, 0, middle)
    if vim.fn.strdisplaywidth(prefix) <= available then
      low = middle
    else
      high = middle - 1
    end
  end
  return vim.fn.strcharpart(text, 0, low) .. ellipsis
end

local function add_line(output, line, group, truncate, metadata)
  local text = truncate == false
    and line
    or shorten(line, output.width)
  output.lines[#output.lines + 1] = text
  if group then
    output.highlights[#output.highlights + 1] = {
      row = #output.lines,
      group = group,
    }
  end

  metadata = metadata or {}
  local rendered_row = {
    text = text,
    kind = metadata.kind or "message",
    change_id = metadata.change_id,
    hunk_id = metadata.hunk_id,
    path = metadata.path,
    section = metadata.section,
    side = metadata.side,
    source_line = metadata.source_line,
    source_anchor = anchor.from_row(metadata, 0),
  }
  output.rows[#output.rows + 1] = rendered_row
  output.targets[#output.targets + 1] = {
    row = #output.lines,
    text = rendered_row.text,
    kind = rendered_row.kind,
    change_id = rendered_row.change_id,
    hunk_id = rendered_row.hunk_id,
    path = rendered_row.path,
    section = rendered_row.section,
    side = rendered_row.side,
    source_line = rendered_row.source_line,
    source_anchor = rendered_row.source_anchor,
  }
end

local function change_list(status)
  local changes = {}
  for _, section in ipairs({ "staged", "unstaged" }) do
    for _, change in ipairs(status[section] or {}) do
      changes[#changes + 1] = change
    end
  end
  return changes
end

local function row_metadata(change, diff, kind, values)
  local metadata = {
    path = change.path or diff and diff.path,
    section = change.section or diff and diff.section,
    change_id = change.id or diff and diff.id,
    kind = kind,
  }
  for key, value in pairs(values or {}) do
    metadata[key] = value
  end
  return metadata
end

local function gap_size(previous_hunk, hunk)
  local next_start = tonumber(hunk.new_start)
  if not next_start then
    return 0
  end
  if not previous_hunk then
    return math.max(0, next_start - 1)
  end

  local previous_start = tonumber(previous_hunk.new_start)
  local previous_count = tonumber(previous_hunk.new_count)
  if not previous_start or not previous_count then
    return 0
  end
  return math.max(0, next_start - (previous_start + previous_count))
end

local function source_for_line(line)
  if line.kind == "delete" and line.old_line ~= nil then
    return {
      side = "old",
      source_line = line.old_line,
      context = line.text,
    }
  end
  if line.new_line ~= nil then
    return {
      side = "new",
      source_line = line.new_line,
      context = line.text,
    }
  end
  if line.old_line ~= nil then
    return {
      side = "old",
      source_line = line.old_line,
      context = line.text,
    }
  end
end

local function neighboring_source(lines, clusters, index, cluster)
  for distance = 1, #lines do
    for _, candidate_index in ipairs({ index - distance, index + distance }) do
      local candidate = lines[candidate_index]
      if candidate
          and anchor.cluster_for_index(clusters, candidate_index) == cluster then
        local source = source_for_line(candidate)
        if source then
          return source
        end
      end
    end
  end
end

local function typed_error(error)
  local message = type(error.message) == "string"
      and error.message
    or "Unable to load diff"
  if type(error.code) == "string" and error.code ~= "" then
    return string.format("Error [%s]: %s", error.code, message)
  end
  return "Error: " .. message
end

local function render_file(output, change, diff, loading, file_error)
  local section = (change.section or diff and diff.section or ""):upper()
  local path = change.path or diff and diff.path or "unknown"
  local file_side = change.status == "D" and "old" or "new"
  add_line(
    output,
    string.format("[%s] %s", section, escape_control(path)),
    "Title",
    nil,
    row_metadata(change, diff, "file_header", { side = file_side })
  )

  if file_error and file_error.code == "diff_too_large" then
    add_line(
      output,
      escape_control(
        "Diff unavailable [diff_too_large]: "
          .. (file_error.message or "configured byte limit exceeded")
          .. " · Press e to open file"
      ),
      "ErrorMsg",
      nil,
      row_metadata(change, diff, "file_placeholder", {
        side = file_side,
        source_line = 1,
      })
    )
    return
  end
  if loading then
    add_line(
      output,
      "Loading diff…",
      "Comment",
      nil,
      row_metadata(change, diff, "loading", { side = file_side })
    )
  end
  if not diff then
    if file_error then
      add_line(
        output,
        escape_control(typed_error(file_error)),
        "ErrorMsg",
        nil,
        row_metadata(change, diff, "error", { side = file_side })
      )
    elseif not loading then
      add_line(
        output,
        "Diff not loaded",
        "Comment",
        nil,
        row_metadata(change, diff, "message", { side = file_side })
      )
    end
    return
  end
  if file_error then
    add_line(
      output,
      escape_control(typed_error(file_error)),
      "ErrorMsg",
      nil,
      row_metadata(change, diff, "error", { side = file_side })
    )
  end
  if diff.binary then
    add_line(
      output,
      "Binary file",
      "Comment",
      nil,
      row_metadata(change, diff, "binary", { side = file_side })
    )
    return
  end

  for _, header in ipairs(diff.headers or {}) do
    add_line(
      output,
      escape_control(header),
      "Comment",
      nil,
      row_metadata(change, diff, "meta", { side = file_side })
    )
  end
  if #(diff.hunks or {}) == 0 then
    add_line(
      output,
      "No textual changes",
      "Comment",
      nil,
      row_metadata(change, diff, "message", { side = file_side })
    )
    return
  end

  local hunk_models = {}
  local context_lines = config.get().ui.context_lines
  for _, hunk in ipairs(diff.hunks) do
    hunk_models[#hunk_models + 1] = {
      hunk = hunk,
      clusters = anchor.logical_clusters(change, hunk, context_lines),
    }
  end

  local previous_hunk
  for _, model in ipairs(hunk_models) do
    local hunk = model.hunk
    local first_cluster = model.clusters[1]
    local hidden_lines = gap_size(previous_hunk, hunk)
    if hidden_lines > 0 then
      add_line(
        output,
        string.format("… %d unchanged lines …", hidden_lines),
        "Comment",
        nil,
        row_metadata(change, diff, "gap", {
          side = "new",
          source_line = hunk.new_start,
          hunk_id = first_cluster.key,
        })
      )
    end

    local hunk_side = hunk.new_count == 0 and "old" or "new"
    local hunk_line = hunk_side == "old" and hunk.old_start or hunk.new_start
    add_line(
      output,
      escape_control(hunk.header),
      "DiffText",
      nil,
      row_metadata(change, diff, "hunk", {
        side = hunk_side,
        source_line = hunk_line,
        hunk_id = first_cluster.key,
      })
    )
    for index, line in ipairs(hunk.lines or {}) do
      local cluster = anchor.cluster_for_index(model.clusters, index)
      local source = source_for_line(line)
      if not source and line.kind == "meta" then
        source = neighboring_source(
          hunk.lines or {},
          model.clusters,
          index,
          cluster
        )
      end
      add_line(
        output,
        line.text,
        groups[line.kind],
        false,
        row_metadata(change, diff, line.kind, {
          text = line.text,
          old_line = line.old_line,
          new_line = line.new_line,
          side = source and source.side,
          source_line = source and source.source_line,
          context = source and source.context,
          hunk_id = cluster.key,
        })
      )
    end
    previous_hunk = hunk
  end
end

local function find_change(status, change_id)
  for _, change in ipairs(change_list(status)) do
    if change.id == change_id then
      return change
    end
  end
end

local function is_diff_error(error, diff_errors)
  if not error then
    return false
  end
  for _, candidate in pairs(diff_errors or {}) do
    if candidate == error then
      return true
    end
  end
  return false
end

local function visible_global_error(state, diff_errors)
  if state.error and not is_diff_error(state.error, diff_errors) then
    return state.error
  end
end

function M.render(state, width)
  local output = {
    lines = {},
    highlights = {},
    targets = {},
    rows = {},
    width = math.max(1, tonumber(width) or 1),
  }
  local status = state.data and state.data.status
  local errors = state.errors or {}
  local diff_errors = errors.diffs or {}

  if not status then
    local initial_error = state.error
    if initial_error then
      add_line(
        output,
        escape_control(typed_error(initial_error)),
        "ErrorMsg"
      )
    else
      add_line(output, "Loading changes…", "Comment")
    end
    output.width = nil
    return output
  end

  local global_error = visible_global_error(state, diff_errors)
  if global_error then
    add_line(
      output,
      escape_control(typed_error(global_error)),
      "ErrorMsg"
    )
  end
  if state.busy and state.busy.status then
    add_line(output, "Refreshing changes…", "Comment")
  end

  local changes = change_list(status)
  if #changes == 0 then
    add_line(output, "No changes", "Comment")
    output.width = nil
    return output
  end

  local view = state.view or {}
  local loading = state.busy and state.busy.diff or {}
  if view.diff_mode == "all_files" then
    for index, change in ipairs(changes) do
      if index > 1 then
        add_line(output, "")
      end
      render_file(
        output,
        change,
        state.data.diffs and state.data.diffs[change.id],
        loading[change.id],
        diff_errors[change.id]
      )
    end
  else
    local change = find_change(status, view.selected_change_id)
    if not change then
      add_line(output, "Select a change", "Comment")
    else
      render_file(
        output,
        change,
        state.data.diffs and state.data.diffs[change.id],
        loading[change.id],
        diff_errors[change.id]
      )
    end
  end

  output.width = nil
  return output
end

return M
