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
  local ok, existing = pcall(vim.api.nvim_get_hl, 0, {
    name = name,
    link = true,
  })
  if ok and type(existing) == "table" and next(existing) ~= nil then return end
  vim.api.nvim_set_hl(0, name, { link = target })
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
  local groups = {}
  local group_order = {}
  for buffer_row, rendered_row in ipairs(rendered.rows or {}) do
    local side = row_side(rendered_row)
    local source_anchor = rendered_row.source_anchor
    local source_line = source_anchor and source_anchor.source_line
    local file = inspections[rendered_row.change_id]
    local inspection = file and side and file[side]
    if inspection and type(source_line) == "number" then
      local key = rendered_row.change_id .. "\0" .. side
      local group = groups[key]
      if not group then
        group = { inspection = inspection, rows = {} }
        groups[key] = group
        group_order[#group_order + 1] = key
      end
      group.rows[#group.rows + 1] = {
        buffer_row = buffer_row,
        source_row = source_line - 1,
        text = rendered_row.text or "",
      }
    end
  end

  for _, key in ipairs(group_order) do
    local group = groups[key]
    table.sort(group.rows, function(left, right)
      if left.source_row == right.source_row then
        return left.buffer_row < right.buffer_row
      end
      return left.source_row < right.source_row
    end)
    local captures = {}
    for order, capture in ipairs(group.inspection.captures or {}) do
      captures[#captures + 1] = {
        capture = capture,
        start_row = tonumber(capture.start_row) or math.huge,
        end_row = tonumber(capture.end_row) or -math.huge,
        order = order,
      }
    end
    table.sort(captures, function(left, right)
      if left.start_row ~= right.start_row then
        return left.start_row < right.start_row
      end
      if left.end_row ~= right.end_row then
        return left.end_row < right.end_row
      end
      return left.order < right.order
    end)

    local next_capture = 1
    local active = {}
    for _, row in ipairs(group.rows) do
      while captures[next_capture]
          and captures[next_capture].start_row <= row.source_row do
        active[#active + 1] = captures[next_capture]
        next_capture = next_capture + 1
      end
      local retained = {}
      for _, indexed in ipairs(active) do
        if indexed.end_row >= row.source_row then
          retained[#retained + 1] = indexed
          local capture = indexed.capture
          add_capture(
            buffer,
            namespace,
            row.buffer_row,
            row.text,
            row.source_row,
            capture,
            group.inspection.language,
            group_cache
          )
        end
      end
      active = retained
    end
  end
end

local function visible_source_rows(rendered)
  local visible = {}
  local texts = {}
  for _, rendered_row in ipairs(rendered.rows or {}) do
    if (rendered_row.kind == "add" or rendered_row.kind == "context")
        or rendered_row.kind == "delete" then
      local rows = visible[rendered_row.change_id] or { old = {}, new = {} }
      for _, side in ipairs({ "old", "new" }) do
        local source_line = rendered_row[side .. "_line"]
        local source_anchor = rendered_row.source_anchor
        if source_line == nil and source_anchor and source_anchor.side == side then
          source_line = source_anchor.source_line
        end
        if type(source_line) == "number" then
          rows[side][source_line - 1] = true
        end
      end
      visible[rendered_row.change_id] = rows
      local file_texts = texts[rendered_row.change_id] or {}
      file_texts[#file_texts + 1] = vim.trim(rendered_row.text or "")
      texts[rendered_row.change_id] = file_texts
    end
  end
  return visible, texts
end

local function matching_symbol(symbols, source_row, wanted)
  local best
  local best_span
  for _, symbol in ipairs(symbols or {}) do
    if type(source_row) == "number"
        and source_row >= symbol.start_row and source_row <= symbol.end_row
        and (not wanted or symbol.kind == wanted.kind and symbol.label == wanted.label) then
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

local function hidden_symbol(inspection, source_row, visible, opposite, opposite_row)
  local hidden = {}
  for _, symbol in ipairs(inspection.symbols or {}) do
    if source_row >= symbol.start_row and source_row <= symbol.end_row
        and not (visible.current or {})[symbol.declaration_row] then
      local counterpart = opposite and matching_symbol(opposite.symbols, opposite_row, symbol)
      if not (counterpart and (visible.opposite or {})[counterpart.declaration_row]) then
        hidden[#hidden + 1] = symbol
      end
    end
  end
  local symbol = matching_symbol(hidden, source_row)
  local counterpart = symbol and opposite and matching_symbol(opposite.symbols, opposite_row, symbol)
  return symbol, counterpart
end

local function symbol_key(side, symbol, counterpart)
  -- Pair old/new scope through the hunk's two source coordinates, not its name alone.
  if side == "old" and counterpart then
    side, symbol = "new", counterpart
  end
  return side .. ":" .. tostring(symbol.declaration_row) .. ":" .. tostring(symbol.label)
end

local function add_symbol_context(buffer, namespace, row, label)
  vim.api.nvim_buf_set_extmark(buffer, namespace, row - 1, 0, {
    virt_text = { { " · " .. label, "VigitSymbolContext" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
    priority = M.priorities.symbol,
    strict = false,
  })
end

local function declaration_text_visible(context, texts)
  context = vim.trim(context)
  for _, text in ipairs(texts or {}) do
    if text:sub(1, #context) == context then return true end
  end
  return false
end

local function add_symbol_layers(buffer, rendered, inspections, namespace)
  local visible, texts = visible_source_rows(rendered)
  local seen = {}
  for buffer_row, rendered_row in ipairs(rendered.rows or {}) do
    local source_anchor = rendered_row.source_anchor
    local file = inspections[rendered_row.change_id]
    if rendered_row.kind == "gap"
        and source_anchor
        and type(source_anchor.source_line) == "number" then
      local side = source_anchor.side
      local opposite_side = side == "old" and "new" or "old"
      local inspection = file and file[side]
      local opposite = file and file[opposite_side]
      local opposite_line = rendered_row[opposite_side .. "_line"]
      local opposite_row = opposite_line and opposite_line - 1
      local source_row = source_anchor.source_line - 1
      local visible_rows = visible[rendered_row.change_id] or {}
      local file_seen = seen[rendered_row.change_id] or {}
      seen[rendered_row.change_id] = file_seen
      if inspection and (#(inspection.symbols or {}) > 0
          or opposite and #(opposite.symbols or {}) > 0) then
        local symbol, counterpart = hidden_symbol(
          inspection, source_row,
          { current = visible_rows[side], opposite = visible_rows[opposite_side] },
          opposite, opposite_row
        )
        if not symbol and opposite and opposite_row then
          symbol, counterpart = hidden_symbol(
            opposite, opposite_row,
            { current = visible_rows[opposite_side], opposite = visible_rows[side] },
            inspection, source_row
          )
          if symbol then
            side, inspection, opposite = opposite_side, opposite, inspection
            source_row, opposite_row = opposite_row, source_row
          end
        end
        if symbol and symbol.label then
          local key = symbol_key(side, symbol, counterpart)
          if not file_seen[key] then
            add_symbol_context(buffer, namespace, buffer_row, symbol.label)
            file_seen[key] = true
            for _, owner in ipairs(inspection.symbols or {}) do
              if owner.kind == "class" and owner.name
                  and source_row >= owner.start_row and source_row <= owner.end_row
                  and symbol.label:sub(1, #owner.name + 1) == owner.name .. "." then
                local other_owner = opposite and matching_symbol(opposite.symbols, opposite_row, owner)
                file_seen[symbol_key(side, owner, other_owner)] = true
              end
            end
          end
        end
      elseif rendered_row.scope_context then
        local context = rendered_row.scope_context
        local key = "git:" .. context
        if not file_seen[key]
            and not declaration_text_visible(context, texts[rendered_row.change_id]) then
          add_symbol_context(buffer, namespace, buffer_row, context)
          file_seen[key] = true
        end
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

function M.apply_structure(buffer, rendered, namespace)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then return end
  M.setup()
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  add_view_layers(buffer, rendered, namespace)
end

function M.apply_syntax(buffer, rendered, inspections, namespace)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then return end
  M.setup()
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  add_syntax_layers(buffer, rendered, inspections or {}, namespace)
end

function M.apply_symbols(buffer, rendered, inspections, namespace)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then return end
  M.setup()
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  add_symbol_layers(buffer, rendered, inspections or {}, namespace)
end

return M
