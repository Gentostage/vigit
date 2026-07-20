local review_store = require("vigit.review")

local M = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Vigit" })
end

local function trim_blank_edges(lines)
  local first = 1
  local last = #lines
  while first <= last and vim.trim(lines[first]) == "" do
    first = first + 1
  end
  while last >= first and vim.trim(lines[last]) == "" do
    last = last - 1
  end
  local result = {}
  for index = first, last do
    result[#result + 1] = lines[index]
  end
  return result
end

local function parse_buffer(lines)
  return vim.trim(table.concat(trim_blank_edges(lines), "\n"))
end

local function confirm_discard(callback)
  vim.ui.select({ "Keep editing", "Discard" }, {
    prompt = "Discard unsaved review comment?",
  }, function(choice)
    callback(choice == "Discard")
  end)
end

function M.open(session, target, opts)
  opts = opts or {}
  local editing = opts.issue ~= nil
  local columns = math.max(vim.o.columns, 50)
  local screen_lines = math.max(vim.o.lines - vim.o.cmdheight, 12)
  local width = math.max(46, math.min(90, columns - 6))
  local height = math.max(10, math.min(22, screen_lines - 6))
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(math.floor((screen_lines - height) / 2), 0),
    col = math.max(math.floor((columns - width) / 2), 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Vigit Comment ",
    title_pos = "center",
  })

  local saved = false

  local function update_title()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    vim.api.nvim_set_option_value("winbar", table.concat({
      "%#VigitPanelTitle# ",
      editing and ("EDIT " .. opts.issue.id) or "NEW COMMENT",
      " · ",
      target.file,
      ":",
      tostring(target.line),
      target.line_end ~= target.line and ("-" .. tostring(target.line_end)) or "",
      "%=",
      "%#VigitPanelHint# :w/Ctrl-S save · q close ",
    }), { scope = "local", win = win })
  end

  local function close(force)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if not force and vim.bo[buf].modified and not saved then
      confirm_discard(function(discard)
        if discard and vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end)
      return
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function save()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local comment = parse_buffer(lines)
    if comment == "" then
      notify("Write a review comment before saving", vim.log.levels.WARN)
      return
    end
    local issue, err
    if editing then
      issue, err = review_store.update(session.root, opts.issue.id, { comment = comment })
    else
      local issue_data = vim.deepcopy(target)
      issue_data.type = "COMMENT"
      issue_data.comment = comment
      issue, err = review_store.add(session.root, issue_data)
    end
    if not issue then
      notify(err, vim.log.levels.ERROR)
      return
    end
    saved = true
    vim.bo[buf].modified = false
    session.review_count = review_store.open_count(session.root)
    require("vigit.ui").render(session)
    notify(issue.id .. (editing and " updated" or " added"))
    close(true)
  end

  vim.api.nvim_buf_set_name(buf, "Vigit Comment · " .. target.file)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  local initial_comment = editing and opts.issue.comment or opts.initial_comment
  local initial_lines = initial_comment and vim.split(initial_comment, "\n", { plain = true }) or { "" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
  vim.bo[buf].modified = false
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:VigitPanelBorder"
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = save,
  })
  vim.keymap.set("n", "q", function()
    close(false)
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    close(false)
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
      vim.cmd("stopinsert")
    end
    save()
  end, { buffer = buf, silent = true, nowait = true })
  update_title()
  vim.cmd("startinsert")

  return { buf = buf, win = win }
end

return M
