local M = {}

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

local function add_highlight(
    output,
    row,
    group,
    start_col,
    end_col
)
  output.highlights[#output.highlights + 1] = {
    row = row,
    group = group,
    start_col = start_col,
    end_col = end_col,
  }
end

local function add_line(output, line, highlight)
  output.lines[#output.lines + 1] = line
  if highlight then
    add_highlight(output, #output.lines, highlight)
  end
  return #output.lines
end

local function add_styled_line(output, segments, width)
  local text = {}
  for _, segment in ipairs(segments) do
    text[#text + 1] = segment.text
  end
  local line = shorten(table.concat(text), width)
  local row = add_line(output, line)
  local cursor = 0
  for _, segment in ipairs(segments) do
    local start_col = cursor
    cursor = cursor + #segment.text
    if segment.group and start_col < #line then
      add_highlight(
        output,
        row,
        segment.group,
        start_col,
        math.min(cursor, #line)
      )
    end
  end
  return row
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
    local label = string.format("  %s %s", change.status, escape_control(change.path))
    if change.old_path then
      label = string.format(
        "  %s %s → %s",
        change.status,
        escape_control(change.old_path),
        escape_control(change.path)
      )
    end
    local row = add_line(output, shorten(label, width))
    add_target(output, row, {
      kind = "change",
      change_id = change.id,
      change = change,
    })
  end
end

local function build_tree(changes)
  local root = {
    entries = {},
    directories = {},
  }
  for _, change in ipairs(changes) do
    local parts = path_parts(change.path)
    local parent = root
    local path = ""
    for index = 1, #parts - 1 do
      local name = parts[index]
      path = path == "" and name or path .. "/" .. name
      local directory = parent.directories[name]
      if not directory then
        directory = {
          kind = "directory",
          name = name,
          path = path,
          entries = {},
          directories = {},
        }
        parent.directories[name] = directory
        parent.entries[#parent.entries + 1] = directory
      end
      parent = directory
    end
    parent.entries[#parent.entries + 1] = {
      kind = "change",
      name = parts[#parts] or change.path,
      change = change,
    }
  end
  return root
end

local status_groups = {
  A = "VigitChangesAdded",
  C = "VigitChangesAdded",
  D = "VigitChangesDeleted",
  M = "VigitChangesModified",
  R = "VigitChangesModified",
  T = "VigitChangesModified",
  U = "VigitChangesConflict",
  ["?"] = "VigitChangesUntracked",
}

local function directory_key(section, path)
  return section .. "\0" .. path
end

local function render_tree_node(
    output,
    node,
    depth,
    width,
    icons,
    section,
    expanded_dirs
)
  local indent = string.rep(" ", depth)
  for _, entry in ipairs(node.entries) do
    if entry.kind == "directory" then
      local icon, group = icons.directory()
      local key = directory_key(section, entry.path)
      local expanded = expanded_dirs[key] ~= false
      local row = add_styled_line(output, {
        { text = indent },
        {
          text = expanded and "▾ " or "▸ ",
          group = "Comment",
        },
        {
          text = string.format(
            "%s %s/",
            icon,
            escape_control(entry.name)
          ),
          group = group or "VigitChangesDirectory",
        },
      }, width)
      add_target(output, row, {
        kind = "directory",
        path = entry.path,
        section = section,
        key = key,
        expanded = expanded,
      })
      if expanded then
        render_tree_node(
          output,
          entry,
          depth + 1,
          width,
          icons,
          section,
          expanded_dirs
        )
      end
    else
      local change = entry.change
      local icon, group = icons.file(entry.name, change.path)
      local row = add_styled_line(output, {
        { text = indent },
        {
          text = change.status,
          group = status_groups[change.status]
            or "VigitChangesModified",
        },
        { text = " " },
        {
          text = string.format("%s %s", icon, escape_control(entry.name)),
          group = group or "VigitChangesFile",
        },
      }, width)
      add_target(output, row, {
        kind = "change",
        change_id = change.id,
        change = change,
      })
    end
  end
end

local function render_tree(
    output,
    changes,
    width,
    icons,
    section,
    expanded_dirs
)
  render_tree_node(
    output,
    build_tree(changes),
    0,
    width,
    icons,
    section,
    expanded_dirs
  )
end

local function render_section(
    output,
    title,
    changes,
    mode,
    width,
    icons,
    section,
    expanded_dirs
)
  if #changes == 0 then
    return
  end

  if #output.lines > 0 then
    add_line(output, "")
  end
  local header_group = title == "Staged"
      and "VigitChangesStagedHeader"
    or "VigitChangesUnstagedHeader"
  add_line(output, string.format("%s (%d)", title, #changes), header_group)
  if mode == "list" then
    render_list(output, changes, width)
  else
    render_tree(
      output,
      changes,
      width,
      icons,
      section,
      expanded_dirs
    )
  end
end

function M.render(state, width, opts)
  opts = opts or {}
  local icons = opts.icons or require("vigit.ui.icons")
  width = math.max(1, tonumber(width) or 1)
  local output = {
    lines = {},
    highlights = {},
    targets = {},
  }
  local status = state.data and state.data.status

  if not status then
    if state.error then
      add_line(
        output,
        shorten(escape_control("Error: " .. state.error.message), width),
        "ErrorMsg"
      )
    else
      add_line(output, "Loading changes…", "Comment")
    end
    return output
  end

  if state.error then
    add_line(
      output,
      shorten(escape_control("Error: " .. state.error.message), width),
      "ErrorMsg"
    )
  end

  local mode = state.view and state.view.changes_mode or "tree"
  local expanded_dirs = state.view and state.view.expanded_dirs or {}
  render_section(
    output,
    "Staged",
    status.staged or {},
    mode,
    width,
    icons,
    "staged",
    expanded_dirs
  )
  render_section(
    output,
    "Unstaged",
    status.unstaged or {},
    mode,
    width,
    icons,
    "unstaged",
    expanded_dirs
  )

  local selected_change_id = state.view and state.view.selected_change_id
  if selected_change_id then
    for _, target in ipairs(output.targets) do
      if target.kind == "change" and target.change_id == selected_change_id then
        add_highlight(output, target.row, "VigitChangesSelected")
        break
      end
    end
  end

  if #output.targets == 0 then
    add_line(output, "No changes", "Comment")
  end
  return output
end

return M
