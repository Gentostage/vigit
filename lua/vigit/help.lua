local keymaps = require("vigit.keymaps")

local M = {}

local function mode_label(mode)
  if type(mode) == "table" then
    return "[" .. table.concat(mode, "/"):upper() .. "] "
  end
  if mode and mode ~= "n" then
    return "[" .. tostring(mode):upper() .. "] "
  end
  return ""
end

local function context_lines(context, current)
  local heading = string.upper(context.title)
  if current then
    heading = "CURRENT · " .. heading
  end
  local lines = { " " .. heading }
  for _, entry in ipairs(keymaps.entries(context.id)) do
    local key = mode_label(entry.mode) .. entry.key
    lines[#lines + 1] = string.format("   %-14s %s", key, entry.desc)
  end
  return lines
end

function M.lines(current)
  local lines = { " VIGIT KEYMAPS", "" }
  local selected = keymaps.context(current)
  if selected then
    for _, line in ipairs(context_lines(selected, true)) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = ""
  end
  for _, context in ipairs(keymaps.contexts()) do
    if context.id ~= current then
      for _, line in ipairs(context_lines(context, false)) do
        lines[#lines + 1] = line
      end
      lines[#lines + 1] = ""
    end
  end
  lines[#lines + 1] = " q / Esc close"
  return lines
end

function M.open(context)
  context = context or keymaps.context_for_buffer()
  local lines = M.lines(context)
  local columns = math.max(vim.o.columns, 40)
  local screen_lines = math.max(vim.o.lines - vim.o.cmdheight, 10)
  local natural_width = 40
  for _, line in ipairs(lines) do
    natural_width = math.max(natural_width, vim.fn.strdisplaywidth(line))
  end
  local width = math.max(36, math.min(natural_width + 2, columns - 4, 100))
  local height = math.max(6, math.min(#lines, screen_lines - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(math.floor((screen_lines - height) / 2), 0),
    col = math.max(math.floor((columns - width) / 2), 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Vigit Help ",
    title_pos = "center",
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "vigit-help"
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:VigitPanelBorder"

  local namespace = vim.api.nvim_create_namespace("vigit-help-" .. buf)
  for index, line in ipairs(lines) do
    if line:match("^ VIGIT KEYMAPS") or line:match("^ CURRENT ·") then
      vim.api.nvim_buf_add_highlight(buf, namespace, "VigitPanelTitle", index - 1, 0, -1)
    elseif line:match("^ [A-Z]") then
      vim.api.nvim_buf_add_highlight(buf, namespace, "Title", index - 1, 0, -1)
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  keymaps.bind(buf, "help", { close = close })
  return { buf = buf, win = win }
end

return M
