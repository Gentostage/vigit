local keymaps = require("vigit.ui.keymaps")

local M = {}

local function mode_label(modes)
  return #modes == 1 and modes[1] == "n" and "" or ("[" .. table.concat(modes, "/") .. "] ")
end

function M.lines(current, configured)
  local lines = { " VIGIT KEYMAPS", "" }
  local current_ids = {}
  lines[#lines + 1] = " CURRENT · " .. string.upper(current or "ALL")
  for _, entry in ipairs(keymaps.for_context(current, configured)) do
    current_ids[entry.id] = true
    lines[#lines + 1] = string.format("   %-14s %s", mode_label(entry.modes) .. entry.lhs, entry.description)
  end
  for _, group in ipairs({ "navigation", "view", "git", "comments", "worktrees", "lifecycle" }) do
    local found = false
    for _, entry in ipairs(keymaps.active_entries(configured)) do
      if entry.group == group and not current_ids[entry.id] then
        if not found then
          lines[#lines + 1] = ""
          lines[#lines + 1] = " " .. string.upper(group)
          found = true
        end
        lines[#lines + 1] = string.format("   %-14s %s", mode_label(entry.modes) .. entry.lhs, entry.description)
      end
    end
  end
  local footer = keymaps.hints("help", math.huge, configured)
  if footer ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = " " .. footer
  end
  return lines
end

function M.open(context)
  context = context or "diff"
  local lines = M.lines(context, require("vigit.config").get())
  local columns = math.max(vim.o.columns, 40)
  local screen_lines = math.max(vim.o.lines - vim.o.cmdheight, 10)
  local width = 36
  for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line) + 2) end
  width = math.min(width, columns - 4, 100)
  local height = math.max(6, math.min(#lines, screen_lines - 4))
  local buffer = vim.api.nvim_create_buf(false, true)
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor", row = math.max(math.floor((screen_lines - height) / 2), 0),
    col = math.max(math.floor((columns - width) / 2), 0), width = width, height = height,
    style = "minimal", border = "rounded", title = " Vigit Help ", title_pos = "center",
  })
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "vigit-help"
  vim.wo[window].wrap = false
  local function close()
    if vim.api.nvim_win_is_valid(window) then vim.api.nvim_win_close(window, true) end
  end
  keymaps.apply_aux(nil, buffer, "help", { close = close })
  return { buf = buffer, win = window }
end

return M
