local M = {}

local groups = {
  add = "DiffAdd",
  delete = "DiffDelete",
  context = "Normal",
  meta = "Comment",
}

local function shorten(text, width)
  if width <= 1 or #text <= width then
    return text
  end
  return text:sub(1, width - 1) .. "…"
end

local function add_line(output, line, group, truncate)
  output.lines[#output.lines + 1] = truncate == false
    and line
    or shorten(line, output.width)
  if group then
    output.highlights[#output.highlights + 1] = {
      row = #output.lines,
      group = group,
    }
  end
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

local function render_file(output, change, diff, loading)
  local section = (change.section or diff and diff.section or ""):upper()
  local path = change.path or diff and diff.path or "unknown"
  add_line(output, string.format("[%s] %s", section, path), "Title")

  if loading and not diff then
    add_line(output, "Loading diff…", "Comment")
    return
  end
  if not diff then
    add_line(output, "Diff not loaded", "Comment")
    return
  end
  if diff.binary then
    add_line(output, "Binary file", "Comment")
    return
  end

  for _, header in ipairs(diff.headers or {}) do
    add_line(output, header, "Comment")
  end
  if #(diff.hunks or {}) == 0 then
    add_line(output, "No textual changes", "Comment")
    return
  end

  for _, hunk in ipairs(diff.hunks) do
    add_line(output, hunk.header, "DiffText")
    for _, line in ipairs(hunk.lines or {}) do
      add_line(output, line.text, groups[line.kind], false)
    end
  end
end

local function find_change(status, change_id)
  for _, change in ipairs(change_list(status)) do
    if change.id == change_id then
      return change
    end
  end
end

function M.render(state, width)
  local output = {
    lines = {},
    highlights = {},
    targets = {},
    width = math.max(1, tonumber(width) or 1),
  }
  local status = state.data and state.data.status

  if not status then
    if state.error then
      add_line(output, "Error: " .. state.error.message, "ErrorMsg")
    else
      add_line(output, "Loading changes…", "Comment")
    end
    output.width = nil
    return output
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
        loading[change.id]
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
        loading[change.id]
      )
      if state.error and not state.data.diffs[change.id] then
        add_line(output, "Error: " .. state.error.message, "ErrorMsg")
      end
    end
  end

  output.width = nil
  return output
end

return M
