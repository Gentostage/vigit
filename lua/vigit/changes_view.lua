local M = {}

local function split_path(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function path_suffix(parts, depth)
  return table.concat(parts, "/", math.max(#parts - depth + 1, 1), #parts)
end

local function ends_with_path(path, suffix)
  return path == suffix or path:sub(-#suffix - 1) == "/" .. suffix
end

local function shortest_unique_suffix(file, files)
  local parts = split_path(file.path)
  for depth = 1, #parts do
    local suffix = path_suffix(parts, depth)
    local matches = 0
    for _, candidate in ipairs(files) do
      if ends_with_path(candidate.path, suffix) then
        matches = matches + 1
      end
    end
    if matches == 1 then
      return suffix
    end
  end
  return file.path
end

local function add_line(result, line, meta)
  local row = #result.lines + 1
  result.lines[row] = line
  result.meta_map[row] = meta
  if meta and meta.kind == "file" then
    result.file_map[row] = meta.file
  elseif meta and meta.kind == "directory" then
    result.node_map[row] = meta
  end
end

local function render_list_section(result, section, title, files)
  add_line(result, title, { kind = "section", section = section })
  for _, file in ipairs(files) do
    local display_path = shortest_unique_suffix(file, files)
    add_line(result, " " .. file.status .. " " .. display_path, {
      kind = "file",
      section = section,
      file = file,
      status_start = 1,
      path_start = 3,
    })
  end
end

local function new_directory(name, path)
  return {
    name = name,
    path = path,
    directories = {},
    files = {},
  }
end

local function build_tree(files)
  local root = new_directory("", "")
  for _, file in ipairs(files) do
    local parts = split_path(file.path)
    local node = root
    local directory_path = ""
    for index = 1, #parts - 1 do
      local name = parts[index]
      directory_path = directory_path == "" and name or (directory_path .. "/" .. name)
      if not node.directories[name] then
        node.directories[name] = new_directory(name, directory_path)
      end
      node = node.directories[name]
    end
    node.files[#node.files + 1] = file
  end
  return root
end

local function sorted_directories(node)
  local directories = {}
  for _, directory in pairs(node.directories) do
    directories[#directories + 1] = directory
  end
  table.sort(directories, function(left, right)
    return left.name:lower() < right.name:lower()
  end)
  return directories
end

local function sorted_files(node)
  local files = {}
  for _, file in ipairs(node.files) do
    files[#files + 1] = file
  end
  table.sort(files, function(left, right)
    return left.path:lower() < right.path:lower()
  end)
  return files
end

local function only_directory(node)
  local child = nil
  for _, candidate in pairs(node.directories) do
    if child then
      return nil
    end
    child = candidate
  end
  return child
end

local function directory_key(section, path)
  return section .. ":" .. path
end

local function render_tree_directory(result, section, node, depth, collapsed)
  local compact_node = node
  local label = node.name
  while #compact_node.files == 0 do
    local child = only_directory(compact_node)
    if not child then
      break
    end
    compact_node = child
    label = label .. "/" .. child.name
  end

  local key = directory_key(section, compact_node.path)
  local is_collapsed = collapsed[key] == true
  local indent = string.rep("  ", depth)
  local marker = is_collapsed and "▸" or "▾"
  add_line(result, indent .. marker .. label .. "/", {
    kind = "directory",
    section = section,
    path = compact_node.path,
    key = key,
    collapsed = is_collapsed,
  })

  if is_collapsed then
    return
  end

  for _, directory in ipairs(sorted_directories(compact_node)) do
    render_tree_directory(result, section, directory, depth + 1, collapsed)
  end
  for _, file in ipairs(sorted_files(compact_node)) do
    local indent_file = string.rep("  ", depth + 1)
    local name = split_path(file.path)
    add_line(result, indent_file .. " " .. file.status .. " " .. name[#name], {
      kind = "file",
      section = section,
      file = file,
      status_start = #indent_file + 1,
      path_start = #indent_file + 3,
    })
  end
end

local function render_tree_section(result, section, title, files, collapsed)
  add_line(result, title, { kind = "section", section = section })
  local root = build_tree(files)
  for _, directory in ipairs(sorted_directories(root)) do
    render_tree_directory(result, section, directory, 0, collapsed)
  end
  for _, file in ipairs(sorted_files(root)) do
    local name = split_path(file.path)
    add_line(result, " " .. file.status .. " " .. name[#name], {
      kind = "file",
      section = section,
      file = file,
      status_start = 1,
      path_start = 3,
    })
  end
end

function M.render(status, mode, collapsed)
  status = status or { staged = {}, unstaged = {} }
  mode = mode == "tree" and "tree" or "list"
  collapsed = collapsed or {}

  local result = {
    lines = {},
    file_map = {},
    node_map = {},
    meta_map = {},
  }

  local render_section = mode == "tree" and render_tree_section or render_list_section
  render_section(result, "staged", "Staged", status.staged or {}, collapsed)
  add_line(result, "", nil)
  render_section(result, "unstaged", "Unstaged", status.unstaged or {}, collapsed)

  return result.lines, result.file_map, result.node_map, result.meta_map
end

return M
