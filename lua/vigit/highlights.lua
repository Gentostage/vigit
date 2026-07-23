local M = {}

local namespace = vim.api.nvim_create_namespace("vigit-highlights")
local syntax = require("vigit.syntax")

local lua_keywords = {
  ["and"] = true,
  ["break"] = true,
  ["do"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["end"] = true,
  ["for"] = true,
  ["function"] = true,
  ["goto"] = true,
  ["if"] = true,
  ["in"] = true,
  ["local"] = true,
  ["not"] = true,
  ["or"] = true,
  ["repeat"] = true,
  ["return"] = true,
  ["then"] = true,
  ["until"] = true,
  ["while"] = true,
}

local lua_constants = {
  ["false"] = true,
  ["nil"] = true,
  ["true"] = true,
}

local function set_link(name, target)
  vim.api.nvim_set_hl(0, name, { default = true, link = target })
end

local function highlight_color(name, property)
  local highlight = vim.api.nvim_get_hl(0, { name = name, link = false })
  return highlight[property]
end

local function blend_color(background, foreground, opacity)
  local function channel(color, shift)
    return math.floor(color / (2 ^ shift)) % 256
  end

  local function blend(background_channel, foreground_channel)
    return math.floor(background_channel + (foreground_channel - background_channel) * opacity + 0.5)
  end

  local red = blend(channel(background, 16), channel(foreground, 16))
  local green = blend(channel(background, 8), channel(foreground, 8))
  local blue = blend(channel(background, 0), channel(foreground, 0))
  return red * 0x10000 + green * 0x100 + blue
end

local function setup_diff_backgrounds()
  local normal_background = highlight_color("Normal", "bg") or 0x000000
  local add_color = highlight_color("DiffAdd", "bg")
    or highlight_color("Added", "fg")
    or highlight_color("DiagnosticOk", "fg")
    or 0x00aa00
  local delete_color = highlight_color("DiffDelete", "bg")
    or highlight_color("Removed", "fg")
    or highlight_color("DiagnosticError", "fg")
    or 0xaa0000

  -- Neovim cannot blend a single line with its window background. Mixing the
  -- colors ourselves gives the diff a translucent look without changing text.
  vim.api.nvim_set_hl(0, "VigitDiffAddLine", {
    bg = blend_color(normal_background, add_color, 0.28),
  })
  vim.api.nvim_set_hl(0, "VigitDiffDeleteLine", {
    bg = blend_color(normal_background, delete_color, 0.28),
  })
end

function M.setup()
  set_link("VigitChangesNormal", "NormalFloat")
  set_link("VigitDiffNormal", "Normal")
  set_link("VigitPanelBorder", "DiagnosticInfo")
  set_link("VigitPanelTitle", "Title")
  set_link("VigitPanelHint", "Comment")
  set_link("VigitCursorLine", "Visual")
  set_link("VigitSectionUnstaged", "DiagnosticWarn")
  set_link("VigitSectionStaged", "DiagnosticOk")
  set_link("VigitFilePath", "Directory")
  set_link("VigitTreeDirectory", "Directory")
  set_link("VigitFileAdded", "Added")
  set_link("VigitFileModified", "Changed")
  set_link("VigitFileDeleted", "Removed")
  set_link("VigitDiffAddSign", "Added")
  set_link("VigitDiffDeleteSign", "Removed")
  set_link("VigitFileHeader", "Function")
  set_link("VigitFileHeaderLine", "CursorLine")
  set_link("VigitFileBorder", "WinSeparator")
  set_link("VigitCardIndex", "Comment")
  set_link("VigitCardStaged", "DiagnosticOk")
  set_link("VigitCardUnstaged", "DiagnosticWarn")
  set_link("VigitHunkHeader", "Special")
  set_link("VigitGap", "Comment")
  set_link("VigitGapContext", "Function")
  set_link("VigitEmpty", "Comment")
  set_link("VigitLuaKeyword", "Keyword")
  set_link("VigitLuaConstant", "Boolean")
  set_link("VigitLuaString", "String")
  set_link("VigitLuaNumber", "Number")
  set_link("VigitLuaComment", "Comment")
  set_link("VigitLuaFunction", "Function")
  set_link("VigitCommentMarker", "DiagnosticInfo")
  setup_diff_backgrounds()
end

local function add_highlight(buf, group, row, start_col, end_col)
  vim.api.nvim_buf_add_highlight(buf, namespace, group, row - 1, start_col or 0, end_col or -1)
end

local function add_line_highlight(buf, group, row)
  vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
    line_hl_group = group,
    priority = 10,
  })
end

local function add_change_sign(buf, row, change_kind)
  local group = change_kind == "added" and "VigitDiffAddSign" or "VigitDiffDeleteSign"
  vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
    sign_text = "▎",
    sign_hl_group = group,
    priority = 20,
  })
end

local function add_card_border(buf, row, width, corner)
  vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
    virt_lines = { { { corner .. string.rep("─", math.max(width - 1, 1)), "VigitFileBorder" } } },
    virt_lines_above = true,
    priority = 20,
  })
end

local function add_card_badge(buf, row, section)
  local group = section == "staged" and "VigitCardStaged" or "VigitCardUnstaged"
  vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
    virt_text = { { " " .. string.upper(section) .. " ", group } },
    virt_text_pos = "right_align",
    hl_mode = "combine",
    priority = 30,
  })
end

local function set_window_option(win, name, value)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
end

local function decorate_window(win, title, normal_group, hint, detail)
  local display_title = tostring(title):gsub("%%", "%%%%")
  local display_detail = detail and tostring(detail):gsub("%%", "%%%%") or nil
  local winbar = {
    "%#VigitPanelTitle#  VIGIT · ",
    display_title,
  }
  if display_detail then
    winbar[#winbar + 1] = " · "
    winbar[#winbar + 1] = "%<"
    winbar[#winbar + 1] = display_detail
  end
  vim.list_extend(winbar, {
    "%=",
    "%#VigitPanelHint# ",
    hint or "s index · r refresh · f context · q close",
    " ",
  })
  set_window_option(win, "cursorline", true)
  set_window_option(win, "number", false)
  set_window_option(win, "relativenumber", false)
  set_window_option(win, "signcolumn", "no")
  set_window_option(win, "foldcolumn", "0")
  set_window_option(win, "wrap", false)
  set_window_option(win, "list", false)
  set_window_option(win, "winbar", table.concat(winbar))
  set_window_option(win, "winhighlight", table.concat({
    "Normal:", normal_group,
    ",NormalNC:", normal_group,
    ",CursorLine:VigitCursorLine",
    ",WinSeparator:VigitPanelBorder",
  }))
end

local function status_group(status)
  if status == "A" or status == "?" then
    return "VigitFileAdded"
  end
  if status == "D" then
    return "VigitFileDeleted"
  end
  return "VigitFileModified"
end

local function decorate_changes(session)
  local buf = session.changes_buf
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  for row, line in ipairs(session.state.changes_lines) do
    local meta = session.state.changes_meta[row]
    if meta and meta.kind == "section" then
      local group = meta.section == "staged" and "VigitSectionStaged" or "VigitSectionUnstaged"
      add_highlight(buf, group, row)
    elseif meta and meta.kind == "directory" then
      add_highlight(buf, "VigitTreeDirectory", row)
    elseif meta and meta.kind == "file" then
      add_highlight(buf, status_group(meta.file.status), row, meta.status_start, meta.status_start + 1)
      add_highlight(buf, "VigitFilePath", row, meta.path_start, -1)
    end
  end
end

local function add_token(buf, row, offset, start_col, end_col, group)
  vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, offset + start_col - 1, {
    end_row = row - 1,
    end_col = offset + end_col,
    hl_group = group,
    hl_mode = "combine",
    priority = 200,
    strict = false,
  })
end

local function highlight_lua_line(buf, row, line)
  local offset = 0
  local source = line
  local index = 1

  while index <= #source do
    local rest = source:sub(index)
    if rest:sub(1, 2) == "--" then
      add_token(buf, row, offset, index, #source, "VigitLuaComment")
      break
    end

    local quote = rest:sub(1, 1)
    if quote == "\"" or quote == "'" then
      local finish = index + 1
      while finish <= #source do
        local char = source:sub(finish, finish)
        if char == "\\" then
          finish = finish + 2
        elseif char == quote then
          break
        else
          finish = finish + 1
        end
      end
      finish = math.min(finish, #source)
      add_token(buf, row, offset, index, finish, "VigitLuaString")
      index = finish + 1
    else
      local number = rest:match("^0[xX][%da-fA-F]+") or rest:match("^%d+%.?%d*")
      local identifier = rest:match("^[%a_][%w_]*")
      if number then
        add_token(buf, row, offset, index, index + #number - 1, "VigitLuaNumber")
        index = index + #number
      elseif identifier then
        local group = nil
        if lua_keywords[identifier] then
          group = "VigitLuaKeyword"
        elseif lua_constants[identifier] then
          group = "VigitLuaConstant"
        elseif rest:sub(#identifier + 1):match("^%s*%(") then
          group = "VigitLuaFunction"
        end
        if group then
          add_token(buf, row, offset, index, index + #identifier - 1, group)
        end
        index = index + #identifier
      else
        index = index + 1
      end
    end
  end
end

local function add_gap_context(buf, row, context)
  vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
    virt_text = { { " · " .. context, "VigitGapContext" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
    priority = 25,
  })
end

local function decorate_diff_buffer(buf, win, lines, diff_map, root)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  set_window_option(win, "signcolumn", "yes:1")
  local width = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or 80
  local ok, treesitter_rows = pcall(syntax.decorate, {
    buf = buf,
    root = root,
    lines = lines,
    diff_map = diff_map,
    add_token = add_token,
    add_gap_context = add_gap_context,
  })
  treesitter_rows = ok and treesitter_rows or {}

  for row, line in ipairs(lines) do
    local meta = diff_map and diff_map[row] or nil
    if line == "Unstaged" then
      add_highlight(buf, "VigitSectionUnstaged", row)
    elseif line == "Staged" then
      add_highlight(buf, "VigitSectionStaged", row)
    elseif line == "No Git changes" or line == "  No changes" then
      add_highlight(buf, "VigitEmpty", row)
    elseif meta and meta.kind == "file_header" then
      add_card_border(buf, row, width, "╭")
      add_card_badge(buf, row, meta.section)
      add_line_highlight(buf, "VigitFileHeaderLine", row)
      add_highlight(buf, "VigitFileHeader", row)
      local index_start, index_end = line:find("%d+/%d+")
      if index_start then
        add_highlight(buf, "VigitCardIndex", row, index_start - 1, index_end)
      end
      local status_start = line:find("[", 1, true)
      if status_start then
        add_highlight(buf, status_group(meta.status), row, status_start - 1, status_start + #meta.status + 1)
      end
    elseif meta and meta.kind == "file_end" then
      add_card_border(buf, row, width, "╰")
    elseif meta and meta.kind == "gap" then
      add_highlight(buf, "VigitGap", row)
    elseif meta and meta.change_kind == "added" then
      add_line_highlight(buf, "VigitDiffAddLine", row)
      add_change_sign(buf, row, "added")
    elseif meta and meta.change_kind == "removed" then
      add_line_highlight(buf, "VigitDiffDeleteLine", row)
      add_change_sign(buf, row, "removed")
    end

    if meta
      and meta.file
      and not meta.kind
      and meta.file.path
      and meta.file.path:match("%.lua$")
      and not treesitter_rows[row]
    then
      highlight_lua_line(buf, row, line)
    end
  end
end

local function decorate_comment_markers(session)
  local width = vim.api.nvim_win_is_valid(session.diff_win) and vim.api.nvim_win_get_width(session.diff_win) or 80
  local max_label_width = math.max(24, math.min(64, math.floor(width * 0.48)))
  local rows = {}
  for _, comment in ipairs(session.review_comments or {}) do
    local row = session.state:diff_line_for_anchor(comment)
    if row then
      rows[row] = rows[row] or {}
      rows[row][#rows[row] + 1] = comment
    end
  end
  for row, comments in pairs(rows) do
    local prefix = #comments == 1 and ("● " .. comments[1].id) or ("● " .. #comments .. " comments")
    local preview = vim.trim(tostring(comments[1].comment or ""):gsub("%s+", " "))
    local available = math.max(max_label_width - vim.fn.strdisplaywidth(prefix .. " · ") - 1, 0)
    if vim.fn.strdisplaywidth(preview) > available then
      preview = vim.fn.strcharpart(preview, 0, available)
      while preview ~= "" and vim.fn.strdisplaywidth(preview) > available do
        preview = vim.fn.strcharpart(preview, 0, vim.fn.strchars(preview) - 1)
      end
      preview = preview .. "…"
    end
    local label = preview ~= "" and (prefix .. " · " .. preview) or prefix
    vim.api.nvim_buf_set_extmark(session.diff_buf, namespace, row - 1, 0, {
      virt_text = { { "  " .. label, "VigitCommentMarker" } },
      virt_text_pos = "eol",
      hl_mode = "combine",
      priority = 40,
    })
  end
end

function M.decorate(session)
  local selected = session.state:selected_file()
  local diff_title = "DIFF · ALL FILES"
  local diff_detail = nil
  local diff_hint = "↵ file · e edit · gd definition · c comment · C comments · P prompt · s index · q close"
  if selected then
    diff_title = "DIFF · ONE FILE"
    diff_detail = selected.path
    diff_hint = "e edit · gd definition · a all · c comment · C comments · P prompt · s index · q close"
  end

  decorate_window(
    session.changes_win,
    "CHANGES · " .. string.upper(session.state.changes_mode),
    "VigitChangesNormal",
    "w worktrees · c comment · C comments · P prompt · t tree · ↵ file · q close",
    session.worktree_name .. " · " .. session.branch .. " · " .. tostring(session.review_count or 0) .. " comments"
  )
  local worktree_detail =
    session.worktree_name .. " · " .. session.branch .. " · " .. tostring(session.review_count or 0) .. " comments"
  if diff_detail then
    worktree_detail = worktree_detail .. " · " .. diff_detail
  end
  decorate_window(session.diff_win, diff_title, "VigitDiffNormal", diff_hint, worktree_detail)
  decorate_changes(session)
  decorate_diff_buffer(session.diff_buf, session.diff_win, session.state.diff_lines, session.state.diff_map, session.root)
  decorate_comment_markers(session)
end

return M
