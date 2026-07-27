local M = {}

local function shorten(text, width)
  if width <= 1 or #text <= width then
    return text
  end
  return text:sub(1, width - 1) .. "…"
end

local function add_line(output, line, highlight)
  output.lines[#output.lines + 1] = line
  if highlight then
    output.highlights[#output.highlights + 1] = {
      row = #output.lines,
      group = highlight,
    }
  end
  return #output.lines
end

local function add_target(output, row, target)
  target.row = row
  output.targets[#output.targets + 1] = target
end

local function path_parts(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function render_list(output, changes, width)
  for _, change in ipairs(changes) do
    local label = string.format("  %s %s", change.status, change.path)
    if change.old_path then
      label = string.format("  %s %s → %s", change.status, change.old_path, change.path)
    end
    local row = add_line(output, shorten(label, width))
    add_target(output, row, {
      kind = "change",
      change_id = change.id,
      change = change,
    })
  end
end

local function render_tree(output, changes, width)
  local emitted = {}

  for _, change in ipairs(changes) do
    local parts = path_parts(change.path)
    local parent = ""
    for index = 1, #parts - 1 do
      parent = parent == "" and parts[index] or parent .. "/" .. parts[index]
      if not emitted[parent] then
        emitted[parent] = true
        local indent = string.rep("  ", index)
        local row = add_line(output, shorten(indent .. "▾ " .. parts[index] .. "/", width))
        add_target(output, row, {
          kind = "directory",
          path = parent,
        })
      end
    end

    local indent = string.rep("  ", math.max(1, #parts))
    local name = parts[#parts] or change.path
    local row = add_line(
      output,
      shorten(string.format("%s%s %s", indent, change.status, name), width)
    )
    add_target(output, row, {
      kind = "change",
      change_id = change.id,
      change = change,
    })
  end
end

local function render_section(output, title, changes, mode, width)
  if #changes == 0 then
    return
  end

  if #output.lines > 0 then
    add_line(output, "")
  end
  add_line(output, string.format("%s (%d)", title, #changes), "Title")
  if mode == "list" then
    render_list(output, changes, width)
  else
    render_tree(output, changes, width)
  end
end

function M.render(state, width)
  width = math.max(1, tonumber(width) or 1)
  local output = {
    lines = {},
    highlights = {},
    targets = {},
  }
  local status = state.data and state.data.status

  if not status then
    if state.error then
      add_line(output, shorten("Error: " .. state.error.message, width), "ErrorMsg")
    else
      add_line(output, "Loading changes…", "Comment")
    end
    return output
  end

  if state.error then
    add_line(output, shorten("Error: " .. state.error.message, width), "ErrorMsg")
  end

  local mode = state.view and state.view.changes_mode or "tree"
  render_section(output, "Staged", status.staged or {}, mode, width)
  render_section(output, "Unstaged", status.unstaged or {}, mode, width)

  if #output.targets == 0 then
    add_line(output, "No changes", "Comment")
  end
  return output
end

return M
