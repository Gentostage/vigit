local default_git = require("vigit.git")
local changes_view = require("vigit.changes_view")

local State = {}
State.__index = State

local function find_diff_file(state, file)
  if not file or not file.section or not file.path then
    return nil
  end
  for _, candidate in ipairs(state.diffs[file.section] or {}) do
    if candidate.path == file.path then
      return candidate
    end
  end
  return nil
end

local function add_diff_line(state, line, meta)
  state.diff_lines[#state.diff_lines + 1] = line
  if meta then
    state.diff_map[#state.diff_lines] = meta
  end
end

local function render_changes(state)
  state.changes_lines, state.changes_map, state.changes_nodes, state.changes_meta =
    changes_view.render(state.status, state.changes_mode, state.collapsed_dirs)
end

local function status_for_file(state, file)
  for _, status_file in ipairs(state.status[file.section] or {}) do
    if status_file.path == file.path then
      return status_file.status
    end
  end
  return "M"
end

local function render_diff_section(state, title, files, file_index, total_files)
  add_diff_line(state, title)
  if #files == 0 then
    add_diff_line(state, "  No changes")
    return file_index
  end
  for _, file in ipairs(files) do
    local previous_hunk = nil
    local status = status_for_file(state, file)
    add_diff_line(state, string.format("  %d/%d  [%s]  %s", file_index, total_files, status, file.path), {
      file = file,
      kind = "file_header",
      index = file_index,
      total = total_files,
      status = status,
      section = file.section,
      target_line = file.target_line or 1,
    })
    for _, line in ipairs(file.lines or {}) do
      if line.kind == "hunk" then
        local hunk = line.hunk
        local hidden = 0
        if previous_hunk then
          local previous_end = previous_hunk.new_start + math.max(previous_hunk.new_count, 1) - 1
          hidden = math.max(hunk.new_start - previous_end - 1, 0)
        else
          hidden = math.max(hunk.new_start - 1, 0)
        end
        if hidden > 0 then
          add_diff_line(state, "        ⋯ " .. hidden .. " unchanged lines ⋯", {
            file = file,
            hunk = hunk,
            kind = "gap",
            target_line = math.max(hunk.new_start, 1),
          })
        end
        previous_hunk = hunk
      else
        local text = line.text
        if line.kind == "added" or line.kind == "removed" or line.kind == "context" then
          text = text:sub(2)
        end
        add_diff_line(state, text, {
          file = file,
          hunk = line.hunk,
          change_kind = line.kind,
          old_line = line.old_line,
          new_line = line.new_line,
          target_line = line.target_line or file.target_line or 1,
        })
      end
    end
    add_diff_line(state, "", {
      file = file,
      kind = "file_end",
      target_line = file.target_line or 1,
    })
    file_index = file_index + 1
  end
  return file_index
end

local function render_diff(state)
  state.diff_lines = {}
  state.diff_map = {}

  local selected = find_diff_file(state, state.selection)
  if state.selection and not selected then
    state.selection = nil
  end

  if selected then
    local title = selected.section == "staged" and "Staged" or "Unstaged"
    render_diff_section(state, title, { selected }, 1, 1)
  else
    local total_files = #state.diffs.unstaged + #state.diffs.staged
    local next_file_index = render_diff_section(state, "Unstaged", state.diffs.unstaged, 1, total_files)
    render_diff_section(state, "Staged", state.diffs.staged, next_file_index, total_files)
  end

  if #state.status.unstaged == 0 and #state.status.staged == 0 then
    state.diff_lines = { "No Git changes" }
    state.diff_map = {}
  end
end

function State.new(opts)
  opts = opts or {}
  return setmetatable({
    git = opts.git or default_git,
    cwd = opts.cwd,
    full_context = false,
    status = { staged = {}, unstaged = {} },
    diffs = { staged = {}, unstaged = {} },
    changes_lines = {},
    diff_lines = {},
    changes_map = {},
    changes_nodes = {},
    changes_meta = {},
    diff_map = {},
    changes_mode = "list",
    collapsed_dirs = {},
    selection = nil,
  }, State)
end

function State:refresh()
  local status, status_err = self.git.status(self.cwd)
  if status_err then
    return false, status_err
  end

  local context = self.full_context and 9999 or 3
  local unstaged, unstaged_err = self.git.diff("unstaged", self.cwd, context, status.unstaged)
  if unstaged_err then
    return false, unstaged_err
  end
  local staged, staged_err = self.git.diff("staged", self.cwd, context, status.staged)
  if staged_err then
    return false, staged_err
  end

  self.status = status
  self.diffs = { unstaged = unstaged or {}, staged = staged or {} }
  render_changes(self)
  render_diff(self)

  return true, nil
end

function State:toggle_full_context()
  self.full_context = not self.full_context
  return self:refresh()
end

function State:file_at_line(buffer_name, line)
  if buffer_name == "changes" then
    return self.changes_map[line]
  end
  local meta = self.diff_map[line]
  return meta and meta.file or nil
end

function State:changes_node_at_line(line)
  return self.changes_nodes[line]
end

function State:toggle_changes_mode()
  self.changes_mode = self.changes_mode == "list" and "tree" or "list"
  render_changes(self)
  return self.changes_mode
end

function State:set_directory_collapsed(node, collapsed)
  if not node or node.kind ~= "directory" or not node.key then
    return false
  end
  if collapsed == nil then
    collapsed = not self.collapsed_dirs[node.key]
  end
  self.collapsed_dirs[node.key] = collapsed and true or nil
  render_changes(self)
  return true
end

function State:changes_line_for_file(file)
  if not file then
    return nil
  end
  for line = 1, #self.changes_lines do
    local candidate = self.changes_map[line]
    if candidate and candidate.path == file.path and candidate.section == file.section then
      return line
    end
  end
  return nil
end

function State:changes_line_for_directory(section, path)
  for line = 1, #self.changes_lines do
    local node = self.changes_nodes[line]
    if node and node.section == section and node.path == path then
      return line
    end
  end
  return nil
end

function State:first_changes_file_line()
  for line = 1, #self.changes_lines do
    if self.changes_map[line] then
      return line
    end
  end
  return 1
end

function State:select_file(file)
  local selected = find_diff_file(self, file)
  if not selected then
    return false, file and ("No diff available for " .. file.path) or "No file under cursor"
  end
  self.selection = { section = selected.section, path = selected.path }
  render_diff(self)
  return true, nil
end

function State:show_all_files()
  self.selection = nil
  render_diff(self)
end

function State:selected_file()
  return find_diff_file(self, self.selection)
end

function State:is_single_file()
  return self:selected_file() ~= nil
end

function State:edit_target(buffer_name, line)
  local file = self:file_at_line(buffer_name, line) or self:selected_file()
  local selected = find_diff_file(self, file)
  if not selected then
    return nil, nil
  end

  local target_line = selected.target_line or 1
  if buffer_name == "diff" then
    local meta = self.diff_map[line]
    target_line = (meta and meta.target_line) or target_line
  end
  return selected, math.max(target_line, 1)
end

function State:diff_line_for_file(file)
  if not file then
    return nil
  end
  for line = 1, #self.diff_lines do
    local meta = self.diff_map[line]
    if meta and meta.file and meta.file.path == file.path and meta.file.section == file.section then
      return line
    end
  end
  return nil
end

function State:diff_line_for_anchor(comment)
  if not comment or not comment.file then
    return nil
  end
  local target = tonumber(comment.line) or 1
  local best_line = nil
  local best_score = nil
  for line = 1, #self.diff_lines do
    local meta = self.diff_map[line]
    if meta
      and meta.file
      and meta.file.path == comment.file
    then
      local distance = math.abs((tonumber(meta.target_line) or target) - target)
      local section_penalty = comment.section and meta.file.section ~= comment.section and 10000 or 0
      local structural_penalty = meta.kind and 100000 or 0
      local score = structural_penalty + section_penalty + distance
      if best_score == nil or score < best_score then
        best_line = line
        best_score = score
      end
    end
  end
  return best_line
end

function State:hunk_at_line(line)
  local meta = self.diff_map[line]
  if not meta or not meta.hunk then
    return nil
  end
  return { file = meta.file, hunk = meta.hunk }
end

return State
