local M = {}

local fallback_backgrounds = {
  dark = {
    add = 0x183525,
    delete = 0x3b2426,
  },
  light = {
    add = 0xd8efdc,
    delete = 0xf6d6d8,
  },
}

local diff_tint = 0.35

M.priorities = {
  background = 10,
  sign = 20,
  syntax = 100,
  symbol = 120,
  overlay = 160,
}

local function set_link(name, target)
  vim.api.nvim_set_hl(0, name, { default = true, link = target })
end

local function source_background(group, kind)
  local ok, highlight = pcall(vim.api.nvim_get_hl, 0, {
    name = group,
    link = false,
  })
  if ok and type(highlight) == "table" and highlight.bg then
    return highlight.bg
  end

  local background = vim.o.background == "light" and "light" or "dark"
  return fallback_backgrounds[background][kind]
end

local function highlight_background(group)
  local ok, highlight = pcall(vim.api.nvim_get_hl, 0, {
    name = group,
    link = false,
  })
  if ok and type(highlight) == "table" then
    return highlight.bg
  end
end

local function color_channel(color, shift)
  return math.floor(color / 2 ^ shift) % 0x100
end

local function blend_channel(background, foreground)
  return math.floor(
    background + (foreground - background) * diff_tint + 0.5
  )
end

local function blend_background(color)
  local normal = highlight_background("Normal")
  if not normal then
    return color
  end

  local red = blend_channel(
    color_channel(normal, 16),
    color_channel(color, 16)
  )
  local green = blend_channel(
    color_channel(normal, 8),
    color_channel(color, 8)
  )
  local blue = blend_channel(
    color_channel(normal, 0),
    color_channel(color, 0)
  )
  return red * 0x10000 + green * 0x100 + blue
end

local function setup_line_backgrounds()
  vim.api.nvim_set_hl(0, "VigitDiffAddLine", {
    bg = blend_background(source_background("DiffAdd", "add")),
  })
  vim.api.nvim_set_hl(0, "VigitDiffDeleteLine", {
    bg = blend_background(source_background("DiffDelete", "delete")),
  })
end

function M.setup()
  setup_line_backgrounds()
  set_link("VigitDiffAddSign", "Added")
  set_link("VigitDiffDeleteSign", "Removed")
  set_link("VigitSymbolContext", "Function")
  set_link("VigitChangesStagedHeader", "Added")
  set_link("VigitChangesUnstagedHeader", "DiagnosticWarn")
  set_link("VigitChangesDirectory", "Directory")
  set_link("VigitChangesFile", "Normal")
  set_link("VigitChangesAdded", "Added")
  set_link("VigitChangesDeleted", "Removed")
  set_link("VigitChangesModified", "DiagnosticWarn")
  set_link("VigitChangesUntracked", "DiagnosticInfo")
  set_link("VigitChangesConflict", "DiagnosticError")
  set_link("VigitChangesSelected", "Visual")
  set_link("VigitWorktreeRoot", "Title")
  set_link("VigitWorktreeLinked", "Directory")
  set_link("VigitWorktreeHeader", "Title")
  set_link("VigitWorktreeColumns", "Keyword")
  set_link("VigitWorktreeBranch", "String")
  set_link("VigitWorktreeClean", "Comment")
  set_link("VigitWorktreeActive", "Added")
  set_link("VigitWorktreeDirty", "DiagnosticWarn")
  set_link("VigitWorktreeDetached", "DiagnosticWarn")
  set_link("VigitWorktreeError", "DiagnosticError")
  set_link("VigitWorktreeStaged", "Added")
  set_link("VigitWorktreeUnstaged", "DiagnosticWarn")
  set_link("VigitWorktreeUntracked", "DiagnosticInfo")
  set_link("VigitWorktreeUpstream", "Type")
  set_link("VigitWorktreeDivergence", "Special")
end

local function add_line_layer(buffer, namespace, row, kind)
  local added = kind == "add"
  local background = added and "VigitDiffAddLine" or "VigitDiffDeleteLine"
  local sign = added and "VigitDiffAddSign" or "VigitDiffDeleteSign"
  vim.api.nvim_buf_set_extmark(buffer, namespace, row - 1, 0, {
    line_hl_group = background,
    priority = M.priorities.background,
    strict = false,
  })
  vim.api.nvim_buf_set_extmark(buffer, namespace, row - 1, 0, {
    sign_text = "▎",
    sign_hl_group = sign,
    priority = M.priorities.sign,
    strict = false,
  })
end

local function add_view_layers(buffer, rendered, namespace)
  local by_row = {}
  for _, highlight in ipairs(rendered.highlights or {}) do
    by_row[highlight.row] = highlight.group
  end

  for row, rendered_row in ipairs(rendered.rows or {}) do
    if rendered_row.kind == "add" or rendered_row.kind == "delete" then
      add_line_layer(buffer, namespace, row, rendered_row.kind)
    elseif rendered_row.kind ~= "context" and by_row[row] then
      vim.api.nvim_buf_set_extmark(buffer, namespace, row - 1, 0, {
        end_row = row,
        hl_group = by_row[row],
        hl_eol = true,
        priority = M.priorities.background,
        strict = false,
      })
    end
  end
end

local function row_side(rendered_row)
  if rendered_row.kind == "delete" then
    return "old"
  end
  if rendered_row.kind == "add" or rendered_row.kind == "context" then
    return "new"
  end
end

local function capture_intersects(capture, source_row)
  if source_row < capture.start_row or source_row > capture.end_row then
    return false
  end
  if capture.start_row == capture.end_row then
    return source_row == capture.start_row
      and capture.end_col > capture.start_col
  end
  if source_row == capture.end_row then
    return capture.end_col > 0
  end
  return true
end

local function resolve_capture_group(group, language, cache)
  if cache[group] ~= nil then
    return cache[group] or nil
  end

  local candidate = tostring(group or "")
  local language_suffix = "." .. tostring(language or "")
  if language_suffix ~= "."
      and candidate:sub(-#language_suffix) == language_suffix then
    candidate = candidate:sub(1, -#language_suffix - 1)
  end
  if candidate == "@none" then
    cache[group] = false
    return nil
  end
  while candidate:sub(1, 1) == "@" do
    local ok, definition = pcall(vim.api.nvim_get_hl, 0, {
      name = candidate,
      link = true,
    })
    if ok and type(definition) == "table" and next(definition) ~= nil then
      cache[group] = candidate
      return candidate
    end
    local shorter = candidate:gsub("%.[^.]+$", "")
    if shorter == candidate then
      break
    end
    candidate = shorter
  end

  cache[group] = false
  return nil
end

local function add_capture(
    buffer,
    namespace,
    buffer_row,
    text,
    source_row,
    capture,
    language,
    group_cache
)
  if not capture_intersects(capture, source_row) then
    return
  end

  local start_col = source_row == capture.start_row
    and capture.start_col
    or 0
  local end_col = source_row == capture.end_row
    and capture.end_col
    or #text
  start_col = math.max(0, math.min(tonumber(start_col) or 0, #text))
  end_col = math.max(start_col, math.min(tonumber(end_col) or #text, #text))
  if end_col <= start_col then
    return
  end

  local group = resolve_capture_group(capture.group, language, group_cache)
  if not group then
    return
  end
  local priority = tonumber(capture.priority)
  if not priority or priority % 1 ~= 0 then
    priority = M.priorities.syntax
  end
  vim.api.nvim_buf_set_extmark(buffer, namespace, buffer_row - 1, start_col, {
    end_row = buffer_row - 1,
    end_col = end_col,
    hl_group = group,
    hl_mode = "combine",
    priority = priority,
    strict = false,
  })
end

local function add_syntax_layers(buffer, rendered, inspections, namespace)
  local group_cache = {}
  for buffer_row, rendered_row in ipairs(rendered.rows or {}) do
    local side = row_side(rendered_row)
    local source_anchor = rendered_row.source_anchor
    local source_line = source_anchor and source_anchor.source_line
    local file = inspections[rendered_row.change_id]
    local inspection = file and side and file[side]
    if inspection and type(source_line) == "number" then
      local source_row = source_line - 1
      for _, capture in ipairs(inspection.captures or {}) do
        add_capture(
          buffer,
          namespace,
          buffer_row,
          rendered_row.text or "",
          source_row,
          capture,
          inspection.language,
          group_cache
        )
      end
    end
  end
end

local function visible_source_rows(rendered)
  local visible = {}
  for _, rendered_row in ipairs(rendered.rows or {}) do
    local source_anchor = rendered_row.source_anchor
    if (rendered_row.kind == "add" or rendered_row.kind == "context")
        and source_anchor
        and source_anchor.side == "new"
        and type(source_anchor.source_line) == "number" then
      local rows = visible[rendered_row.change_id] or {}
      rows[source_anchor.source_line - 1] = true
      visible[rendered_row.change_id] = rows
    end
  end
  return visible
end

local function symbol_at(symbols, source_row)
  local best
  local best_span
  for _, symbol in ipairs(symbols or {}) do
    if source_row >= symbol.start_row and source_row <= symbol.end_row then
      local span = symbol.end_row - symbol.start_row
      if best == nil
          or span < best_span
          or (span == best_span and symbol.start_row > best.start_row) then
        best = symbol
        best_span = span
      end
    end
  end
  return best
end

local function hunk_describes_symbol(rendered, gap_row, symbol)
  local hunk = rendered.rows and rendered.rows[gap_row + 1]
  if not hunk
      or hunk.kind ~= "hunk"
      or hunk.change_id ~= rendered.rows[gap_row].change_id then
    return false
  end

  local text = hunk.text or ""
  if symbol.name and text:find(symbol.name, 1, true) then
    return true
  end

  local owner = symbol.label
      and symbol.label:match("^(.+)%.[^.]+%(%)$")
    or nil
  return owner ~= nil and text:find(owner, 1, true) ~= nil
end

local function add_symbol_layers(buffer, rendered, inspections, namespace)
  local visible = visible_source_rows(rendered)
  for buffer_row, rendered_row in ipairs(rendered.rows or {}) do
    local source_anchor = rendered_row.source_anchor
    local file = inspections[rendered_row.change_id]
    local inspection = file and file.new
    if rendered_row.kind == "gap"
        and source_anchor
        and source_anchor.side == "new"
        and type(source_anchor.source_line) == "number"
        and inspection then
      local symbol = symbol_at(
        inspection.symbols,
        source_anchor.source_line - 1
      )
      local visible_rows = visible[rendered_row.change_id] or {}
      if symbol
          and symbol.label
          and not visible_rows[symbol.declaration_row]
          and not hunk_describes_symbol(rendered, buffer_row, symbol) then
        vim.api.nvim_buf_set_extmark(
          buffer,
          namespace,
          buffer_row - 1,
          0,
          {
            virt_text = {
              { " · " .. symbol.label, "VigitSymbolContext" },
            },
            virt_text_pos = "eol",
            hl_mode = "combine",
            priority = M.priorities.symbol,
            strict = false,
          }
        )
      end
    end
  end
end

function M.apply_diff(buffer, rendered, inspections, namespace)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return
  end
  M.setup()
  inspections = inspections or {}
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  add_view_layers(buffer, rendered, namespace)
  add_syntax_layers(buffer, rendered, inspections, namespace)
  add_symbol_layers(buffer, rendered, inspections, namespace)
end

return M
