local keymaps = require("vigit.ui.keymaps")
local log = require("vigit.ui.log")

local M = {}
local active_picker
local namespace_id = 0

local function record_error(picker, error)
  if type(error) ~= "table" then return end
  if picker and picker.logged_errors[error] then return end
  if picker then picker.logged_errors[error] = true end
  log.push(error)
end

local function record_row_errors(picker, rows)
  for _, row in ipairs(rows or {}) do
    record_error(picker, row.error)
    for _, probe in pairs(row.probes or {}) do
      if probe.state == "error" then record_error(picker, probe.error) end
    end
  end
end

local function width(text)
  return vim.fn.strdisplaywidth(tostring(text or ""))
end

local function shorten(text, maximum)
  text = tostring(text or "")
  if width(text) <= maximum then return text end
  if maximum <= 1 then return "…" end
  local result = ""
  for index = 0, vim.fn.strchars(text) - 1 do
    local character = vim.fn.strcharpart(text, index, 1)
    if width(result .. character .. "…") > maximum then break end
    result = result .. character
  end
  return result .. "…"
end

local function pad(text, maximum)
  local value = shorten(text, maximum)
  return value .. string.rep(" ", math.max(0, maximum - width(value)))
end

local function fetched_text(value)
  local hour_minute = tostring(value or ""):match("T(%d%d:%d%d)")
    or tostring(value or ""):match("(%d%d:%d%d)")
  return hour_minute and ("fetched " .. hour_minute) or ""
end

local function file_counts(row)
  local files = row.files or {}
  return string.format("S:%d M:%d ?:%d", files.staged or 0, files.unstaged or 0, files.untracked or 0)
end

local function probe(row, name)
  return row.probes and row.probes[name] or nil
end

local function error_text(prefix, value)
  return prefix .. " !" .. tostring(value and value.code or "unknown")
end

local function upstream_text(row, maximum)
  local upstream_probe = probe(row, "upstream")
  if upstream_probe and upstream_probe.state == "error" then
    return error_text("upstream", upstream_probe.error)
  end
  if upstream_probe and upstream_probe.state == "pending" then return "upstream loading" end
  local upstream = row.upstream
  if not upstream then return upstream_probe and "upstream unknown" or "" end
  if upstream and upstream.state == "tracking" then
    local counts = ((upstream.ahead or 0) > 0 and (" ↑" .. upstream.ahead) or "")
      .. ((upstream.behind or 0) > 0 and (" ↓" .. upstream.behind) or "")
    local suffix = "local refs" .. counts
    local fetched = fetched_text(upstream.fetched_at)
    local tail = {}
    for _, value in ipairs({ suffix, fetched }) do
      if value ~= "" then tail[#tail + 1] = value end
    end
    local tail_text = table.concat(tail, " · ")
    local name_width = maximum and math.max(1, maximum - width(tail_text) - (tail_text ~= "" and 3 or 0)) or nil
    local name = name_width and shorten(upstream.name or "upstream", name_width) or (upstream.name or "upstream")
    return name .. (tail_text ~= "" and (" · " .. tail_text) or "")
  end
  if upstream.state == "no_upstream" then return "no upstream" end
  if upstream.state == "detached" then return "detached" end
  return ""
end

local function status(row, maximum)
  local parts = {}
  local status_probe = probe(row, "status")
  if status_probe and status_probe.state == "error" then
    parts[#parts + 1] = error_text("status", status_probe.error)
  elseif (status_probe and status_probe.state == "ok") or row.files then
    parts[#parts + 1] = file_counts(row)
  elseif status_probe and status_probe.state == "pending" then
    parts[#parts + 1] = "status loading"
  else
    parts[#parts + 1] = "status unknown"
  end
  local upstream = upstream_text(row, maximum and math.max(1, maximum - width(parts[1]) - 3) or nil)
  if upstream ~= "" then parts[#parts + 1] = upstream end
  if row.error and not row.probes and not (row.upstream and row.upstream.state == "tracking") then
    parts[#parts + 1] = "!" .. row.error.code
  end
  if row.loading and not row.probes then parts[#parts + 1] = "loading" end
  if row.active then parts[#parts + 1] = "ACTIVE" end
  return maximum and shorten(table.concat(parts, " · "), maximum) or table.concat(parts, " · ")
end

local function branch(row)
  return row.branch or (row.detached and "detached") or "(unknown)"
end

local function narrow_details(row, maximum)
  return "  " .. status(row, math.max(1, maximum - 2))
end

local function has_probe_error(row)
  if row.error then return true end
  for _, value in pairs(row.probes or {}) do
    if value.state == "error" then return true end
  end
  return false
end

local function add_highlight(output, row, group, start_col, end_col)
  output.highlights[#output.highlights + 1] = {
    row = row,
    group = group,
    start_col = start_col,
    end_col = end_col,
  }
end

local function add_match(spans, text, needle, group, init)
  local start_col, end_col = text:find(needle, init or 1, true)
  if not start_col then return init end
  spans[#spans + 1] = {
    group = group,
    start_col = start_col - 1,
    end_col = end_col,
  }
  return end_col + 1
end

local function status_spans(row, text)
  local spans = {}
  if has_probe_error(row) then
    spans[#spans + 1] = {
      group = "VigitWorktreeError",
      start_col = 0,
      end_col = #text,
    }
    return spans
  end

  local files = row.files or {}
  local cursor = 1
  if row.files or (probe(row, "status") or {}).state == "ok" then
    cursor = add_match(
      spans, text, "S:" .. (files.staged or 0),
      "VigitWorktreeStaged", cursor
    )
    cursor = add_match(
      spans, text, "M:" .. (files.unstaged or 0),
      "VigitWorktreeUnstaged", cursor
    )
    cursor = add_match(
      spans, text, "?:" .. (files.untracked or 0),
      "VigitWorktreeUntracked", cursor
    )
  end

  local upstream = row.upstream
  if upstream and upstream.state == "tracking" then
    add_match(
      spans, text, upstream.name or "upstream",
      "VigitWorktreeUpstream"
    )
    if (upstream.ahead or 0) > 0 then
      add_match(
        spans, text, "↑" .. upstream.ahead,
        "VigitWorktreeDivergence"
      )
    end
    if (upstream.behind or 0) > 0 then
      add_match(
        spans, text, "↓" .. upstream.behind,
        "VigitWorktreeDivergence"
      )
    end
  elseif upstream
      and (upstream.state == "detached" or upstream.state == "no_upstream") then
    add_match(
      spans,
      text,
      upstream.state == "detached" and "detached" or "no upstream",
      "VigitWorktreeDetached"
    )
  end
  if row.active then
    add_match(spans, text, "ACTIVE", "VigitWorktreeActive")
  end
  return spans
end

function M.render(rows, maximum, selected_path, error)
  maximum = math.max(1, maximum or 20)
  local output = {
    lines = { "WORKTREES" },
    targets = {},
    highlights = {
      { row = 1, group = "VigitWorktreeHeader" },
    },
  }
  local wide = maximum >= 100
  if wide then
    local status_width = math.max(48, math.floor(maximum * 0.55))
    local remaining = maximum - 4 - status_width - 6
    local name_width = math.max(10, math.floor(remaining * 0.45))
    local branch_width = math.max(10, remaining - name_width)
    output.layout = {
      type = 4, name = name_width, branch = branch_width, status = status_width,
    }
    output.lines[#output.lines + 1] = table.concat({
      pad("TYPE", 4), pad("NAME", name_width), pad("BRANCH", branch_width), pad("STATUS", status_width),
    }, "  ")
    add_highlight(output, #output.lines, "VigitWorktreeColumns", 0, -1)
  end
  if error then
    output.lines[#output.lines + 1] = shorten("Error: " .. error.message, maximum)
    output.highlights[#output.highlights + 1] = { row = #output.lines, group = "ErrorMsg" }
  end
  for _, row in ipairs(rows or {}) do
    local type_label = row.kind == "root" and "ROOT" or "WT"
    local type_group = row.kind == "root"
        and "VigitWorktreeRoot"
      or "VigitWorktreeLinked"
    local first
    local spans
    if wide then
      local layout = output.layout
      local type_text = pad(type_label, layout.type)
      local name_text = pad(row.name, layout.name)
      local branch_text = pad(branch(row), layout.branch)
      local status_value = status(row, layout.status)
      local status_text = pad(status_value, layout.status)
      first = table.concat({
        type_text, name_text, branch_text, status_text,
      }, "  ")
      local name_start = #type_text + 2
      local branch_start = name_start + #name_text + 2
      local status_start = branch_start + #branch_text + 2
      spans = {
        { group = type_group, start_col = 0, end_col = #type_label },
        {
          group = type_group,
          start_col = name_start,
          end_col = name_start + #shorten(row.name, layout.name),
        },
        {
          group = row.detached
              and "VigitWorktreeDetached"
            or "VigitWorktreeBranch",
          start_col = branch_start,
          end_col = branch_start + #shorten(branch(row), layout.branch),
        },
      }
      for _, span in ipairs(status_spans(row, status_value)) do
        spans[#spans + 1] = {
          group = span.group,
          start_col = status_start + span.start_col,
          end_col = status_start + span.end_col,
        }
      end
    else
      first = string.format("%s  %s · %s", type_label, row.name, branch(row))
      local name_start = #type_label + 2
      local branch_start = name_start + #row.name + 3
      spans = {
        { group = type_group, start_col = 0, end_col = #type_label },
        {
          group = type_group,
          start_col = name_start,
          end_col = name_start + #row.name,
        },
        {
          group = row.detached
              and "VigitWorktreeDetached"
            or "VigitWorktreeBranch",
          start_col = branch_start,
          end_col = branch_start + #branch(row),
        },
      }
    end
    first = shorten(first, maximum)
    output.lines[#output.lines + 1] = first
    local target = { row = #output.lines, path = row.path, entry = row }
    output.targets[#output.targets + 1] = target
    for _, span in ipairs(spans) do
      add_highlight(
        output,
        target.row,
        span.group,
        span.start_col,
        span.end_col
      )
    end
    if not wide then
      local details = shorten(narrow_details(row, maximum), maximum)
      output.lines[#output.lines + 1] = details
      local status_text = details:sub(3)
      for _, span in ipairs(status_spans(row, status_text)) do
        add_highlight(
          output,
          #output.lines,
          span.group,
          span.start_col + 2,
          span.end_col + 2
        )
      end
    end
  end
  if #(rows or {}) == 0 then
    output.lines[#output.lines + 1] = "No worktrees"
  end
  output.lines[#output.lines + 1] = ""
  output.lines[#output.lines + 1] = keymaps.hints(
    "worktrees",
    maximum,
    require("vigit.config").get()
  )
  output.highlights[#output.highlights + 1] = { row = #output.lines, group = "Comment" }
  return output
end

local function target_at(picker, row)
  for _, target in ipairs(picker.targets or {}) do
    if target.row == row then return target end
  end
end

local function set_lines(picker, output)
  if picker.closed or not vim.api.nvim_buf_is_valid(picker.buf) then return end
  vim.bo[picker.buf].modifiable = true
  vim.api.nvim_buf_set_lines(picker.buf, 0, -1, false, output.lines)
  vim.bo[picker.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(picker.buf, picker.namespace, 0, -1)
  for _, highlight in ipairs(output.highlights) do
    vim.api.nvim_buf_add_highlight(
      picker.buf,
      picker.namespace,
      highlight.group,
      highlight.row - 1,
      highlight.start_col or 0,
      highlight.end_col or -1
    )
  end
  picker.targets = output.targets
  picker.row_by_path = {}
  for _, target in ipairs(output.targets) do picker.row_by_path[target.path] = target.row end
  if picker.win and vim.api.nvim_win_is_valid(picker.win) then
    local row = picker.row_by_path[picker.selected_path] or output.targets[1] and output.targets[1].row or 1
    vim.api.nvim_win_set_cursor(picker.win, { row, 0 })
  end
end

local function selected(picker)
  if not picker.win or not vim.api.nvim_win_is_valid(picker.win) then return nil end
  return target_at(picker, vim.api.nvim_win_get_cursor(picker.win)[1])
end

local function close(picker, return_origin)
  if picker.closed then return end
  picker.closed = true
  if active_picker == picker then active_picker = nil end
  if picker.pending_open and picker.pending_open.cancel then pcall(picker.pending_open.cancel) end
  if picker.pending_fetch and picker.pending_fetch.cancel then pcall(picker.pending_fetch.cancel) end
  if picker.pending_remove and picker.pending_remove.cancel then pcall(picker.pending_remove.cancel) end
  if picker.pending_list and picker.pending_list.cancel then pcall(picker.pending_list.cancel) end
  picker.pending_open, picker.pending_fetch, picker.pending_remove, picker.pending_list = nil, nil, nil, nil
  if picker.app.dispose then
    picker.app:dispose(picker.origin, picker)
  else
    picker.app:cancel(picker.origin)
    if picker.app.detach then picker.app:detach(picker) end
  end
  if picker.win and vim.api.nvim_win_is_valid(picker.win) then
    vim.api.nvim_win_close(picker.win, true)
  end
  if return_origin and picker.origin_tab and vim.api.nvim_tabpage_is_valid(picker.origin_tab) then
    vim.api.nvim_set_current_tabpage(picker.origin_tab)
  end
end

local function move(picker, delta)
  if #picker.targets == 0 or not picker.win or not vim.api.nvim_win_is_valid(picker.win) then return end
  local current = selected(picker)
  local index = 1
  for candidate, target in ipairs(picker.targets) do
    if current == target then index = candidate break end
  end
  index = ((index - 1 + delta) % #picker.targets) + 1
  vim.api.nvim_win_set_cursor(picker.win, { picker.targets[index].row, 0 })
end

local function refresh(picker)
  picker.error = nil
  if picker.pending_list and picker.pending_list.cancel then pcall(picker.pending_list.cancel) end
  picker.pending_list = picker.app:list(picker.origin, function(result)
    if picker.closed or result.ok then return end
    record_error(picker, result.error)
    picker.error = result.error
    picker:render_now()
  end)
end

local function geometry()
  local columns = math.max(0, math.floor(tonumber(vim.o.columns) or 0))
  local lines = math.max(0, math.floor(tonumber(vim.o.lines) or 0)
    - math.max(0, math.floor(tonumber(vim.o.cmdheight) or 0)))
  local content_width = columns - 2
  local content_height = lines - 2
  if content_width < 1 or content_height < 1 then
    return nil, Result.err(
      "picker_too_small",
      "Editor is too small to open the worktree picker"
    )
  end

  local desired_width = math.max(1, math.floor(columns * 0.82))
  local desired_height = math.max(1, math.min(18, math.floor(lines * 0.75)))
  local window_width = math.min(content_width, desired_width)
  local window_height = math.min(content_height, desired_height)
  return {
    width = window_width,
    height = window_height,
    row = math.max(0, math.floor((lines - window_height - 2) / 2)),
    col = math.max(0, math.floor((columns - window_width - 2) / 2)),
    title = window_width >= width(" Vigit Worktrees ") and " Vigit Worktrees " or nil,
  }
end

function M.open(opts)
  local app = assert(opts.app)
  local origin = assert(opts.origin)
  if active_picker and not active_picker.closed
      and active_picker.win and vim.api.nvim_win_is_valid(active_picker.win) then
    vim.api.nvim_set_current_win(active_picker.win)
    return active_picker
  end
  local window, geometry_error = geometry()
  if not window then
    log.push(geometry_error)
    return nil, geometry_error
  end
  local picker = {
    app = app,
    origin = origin,
    origin_tab = opts.origin_tab or vim.api.nvim_get_current_tabpage(),
    return_mode = opts.return_mode or "review",
    source_root = opts.source_root,
    source_buffer = opts.source_buffer,
    source_kind = opts.source_kind,
    rows = {},
    targets = {},
    row_by_path = {},
    selected_path = opts.selected_path,
    namespace = nil,
    logged_errors = setmetatable({}, { __mode = "k" }),
  }
  namespace_id = namespace_id + 1
  picker.namespace = vim.api.nvim_create_namespace("vigit-v2-worktrees-" .. namespace_id)
  picker.buf = vim.api.nvim_create_buf(false, true)
  local window_options = {
    relative = "editor",
    width = window.width,
    height = window.height,
    row = window.row,
    col = window.col,
    style = "minimal",
    border = "rounded",
  }
  if window.title then
    window_options.title = window.title
    window_options.title_pos = "center"
  end
  picker.win = vim.api.nvim_open_win(picker.buf, true, window_options)
  vim.bo[picker.buf].buftype = "nofile"
  vim.bo[picker.buf].bufhidden = "wipe"
  vim.bo[picker.buf].swapfile = false
  vim.bo[picker.buf].filetype = "vigit-worktrees"
  vim.bo[picker.buf].modifiable = false
  vim.wo[picker.win].cursorline = true
  vim.wo[picker.win].wrap = false

  function picker:render_now()
    if self.closed or not vim.api.nvim_win_is_valid(self.win) then return end
    local selected_target = selected(self)
    if selected_target then self.selected_path = selected_target.path end
    local output = M.render(self.rows, vim.api.nvim_win_get_width(self.win), self.selected_path, self.error)
    set_lines(self, output)
  end
  function picker:refresh() refresh(self) end
  function picker:select()
    local target = selected(self)
    if not target then return end
    self.selected_path = target.path
    if self.pending_open and self.pending_open.cancel then pcall(self.pending_open.cancel) end
    local pending = {}
    self.pending_open = pending
    local handle = self.app:open(target.entry, function(result)
      if self.pending_open ~= pending then return end
      self.pending_open = nil
      if self.closed then return end
      if result.ok then
        close(self, false)
      else
        record_error(self, result.error)
        self.error = result.error
        self:render_now()
      end
    end, {
      mode = self.return_mode,
      source_root = self.source_root,
      source_buffer = self.source_buffer,
      source_kind = self.source_kind,
    })
    pending.cancel = handle and handle.cancel
  end
  function picker:fetch()
    local target = selected(self)
    if not target then return end
    if self.pending_fetch and self.pending_fetch.cancel then pcall(self.pending_fetch.cancel) end
    local pending = {}
    self.pending_fetch = pending
    local handle = self.app:fetch(target.entry, function(result)
      if self.pending_fetch ~= pending then return end
      self.pending_fetch = nil
      if self.closed then return end
      if not result.ok then
        record_error(self, result.error)
        self.error = result.error
        self:render_now()
        return
      end
      self:refresh()
    end)
    pending.cancel = handle and handle.cancel
  end
  function picker:remove()
    local target = selected(self)
    if not target then return end
    if self.pending_remove and self.pending_remove.cancel then pcall(self.pending_remove.cancel) end
    local pending = {}
    self.pending_remove = pending
    local handle = self.app:remove(target.entry, function(result)
      if self.pending_remove ~= pending then return end
      self.pending_remove = nil
      if self.closed then return end
      if result.origin then
        self.origin = result.origin
        self.source_root = self.origin.root
        self.source_buffer = nil
      end
      if not result.ok then
        record_error(self, result.error)
        self.error = result.error
        self:render_now()
        return
      end
      if not result.origin and result.value and result.value.origin then
        self.origin = result.value.origin
        self.source_root = self.origin.root
        self.source_buffer = nil
      end
      self.selected_path = self.origin.root
      self:refresh()
    end, self.origin)
    pending.cancel = handle and handle.cancel
    return handle
  end
  function picker:close() close(self, true) end

  app:set_on_update(function(rows)
    if picker.closed then return end
    record_row_errors(picker, rows)
    picker.rows = rows
    if picker.render_pending then return end
    picker.render_pending = true
    vim.schedule(function()
      picker.render_pending = false
      if not picker.closed then picker:render_now() end
    end)
  end, picker)
  keymaps.apply_aux(nil, picker.buf, "worktrees", {
    close = function() picker:close() end,
    select_worktree = function() picker:select() end,
    refresh_worktrees = function() picker:refresh() end,
    fetch_worktree = function() picker:fetch() end,
    remove_worktree = function() picker:remove() end,
    previous_worktree = function() move(picker, -1) end,
    next_worktree = function() move(picker, 1) end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = picker.buf,
    once = true,
    callback = function()
      if not picker.closed then close(picker, false) end
    end,
  })
  active_picker = picker
  picker:refresh()
  return picker
end

return M
