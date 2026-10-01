local Result = require("vigit.core.result")

local M = {}
local is_windows = package.config:sub(1, 1) == "\\"
local lsp_attach_timeout_ms = 300

local function normalize(path)
  if is_windows then
    path = path:gsub("\\", "/"):lower()
  end
  path = path:gsub("/+$", "")
  return path == "" and "/" or path
end

local function is_within(root, path)
  root = normalize(root)
  path = normalize(path)
  if root == "/" then
    return path:sub(1, 1) == "/"
  end
  return path:sub(1, #root + 1) == root .. "/"
end

local function canonical_path(path)
  return vim.uv.fs_realpath(path)
end

local function source_label(context)
  local branch = context.branch
  if type(branch) ~= "string" or branch == "" then
    branch = "detached"
  end
  return string.format(
    "CODE %s · %s",
    branch,
    vim.fs.basename(context.relative_path)
  )
end

local function terminal_label(context)
  local branch = context.branch
  if type(branch) ~= "string" or branch == "" then
    branch = "detached"
  end
  return "TERM " .. branch
end

local function valid_source(source)
  local valid = type(source) == "table"
    and source.tab
    and vim.api.nvim_tabpage_is_valid(source.tab)
    and source.win
    and vim.api.nvim_win_is_valid(source.win)
    and source.buf
    and vim.api.nvim_buf_is_valid(source.buf)
  if not valid then
    return false
  end
  local buffer_ok, buffer = pcall(vim.api.nvim_win_get_buf, source.win)
  local tab_ok, tab = pcall(vim.api.nvim_win_get_tabpage, source.win)
  return buffer_ok
    and tab_ok
    and buffer == source.buf
    and tab == source.tab
end

local function workspace_window(workspace)
  if type(workspace) ~= "table"
      or not workspace.tab
      or not vim.api.nvim_tabpage_is_valid(workspace.tab) then
    return nil
  end
  if workspace.code_win and vim.api.nvim_win_is_valid(workspace.code_win) then
    local ok, tab = pcall(
      vim.api.nvim_win_get_tabpage,
      workspace.code_win
    )
    if ok and tab == workspace.tab then
      return workspace.code_win
    end
  end
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(workspace.tab)) do
    if vim.api.nvim_win_get_config(window).relative == "" then
      workspace.code_win = window
      return window
    end
  end
end

local function normal_window(tab)
  if not tab or not vim.api.nvim_tabpage_is_valid(tab) then return nil end
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(window).relative == "" then
      return window
    end
  end
end

function M.bind_workspace_root(workspace_or_tab, root)
  local workspace = type(workspace_or_tab) == "table"
      and workspace_or_tab
    or nil
  local tab = workspace and workspace.tab or workspace_or_tab
  local canonical_root = type(root) == "string" and canonical_path(root) or nil
  local stat = canonical_root and vim.uv.fs_stat(canonical_root) or nil
  if not canonical_root or not stat or stat.type ~= "directory" then
    return Result.err(
      "workspace_root_unavailable",
      "Workspace root is unavailable",
      root
    )
  end
  if not tab or not vim.api.nvim_tabpage_is_valid(tab) then
    return Result.err("workspace_root_failed", "Workspace tab is unavailable")
  end
  local window = workspace and workspace_window(workspace) or normal_window(tab)
  if not window then
    return Result.err("workspace_root_failed", "Workspace window is unavailable")
  end

  local previous_tab_cwd = vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tab))
  local window_cwd = vim.api.nvim_win_call(window, function()
    if vim.fn.haslocaldir() == 1 then return vim.fn.getcwd() end
  end)
  local function bind_tab(path)
    vim.api.nvim_win_call(window, function()
      vim.cmd("tcd " .. vim.fn.fnameescape(path))
      if window_cwd then vim.cmd("lcd " .. vim.fn.fnameescape(window_cwd)) end
    end)
  end
  local ok, message = xpcall(function()
    bind_tab(canonical_root)
    local tab_cwd = vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tab))
    if canonical_path(tab_cwd) ~= canonical_root then
      error("workspace tab cwd was not established")
    end
    vim.api.nvim_tabpage_set_var(tab, "vigit_root", canonical_root)
    vim.api.nvim_tabpage_set_var(tab, "vigit_role", "workspace")
  end, debug.traceback)
  if not ok then
    if vim.api.nvim_win_is_valid(window) then pcall(bind_tab, previous_tab_cwd) end
    return Result.err("workspace_root_failed", "Unable to bind the workspace root", message)
  end
  return Result.ok(canonical_root)
end

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function M.find_repo_root(path)
  if type(path) ~= "string" or path == "" then
    return Result.err("not_repository", "Path is not inside a Git repository", path)
  end

  local root = vim.fs.root(path, ".git")
  if not root then
    return Result.err("not_repository", "Path is not inside a Git repository", path)
  end

  local canonical = vim.uv.fs_realpath(root)
  if not canonical then
    return Result.err(
      "repository_root_unavailable",
      "Repository root cannot be canonicalized",
      root
    )
  end

  return Result.ok(canonical)
end

function M.remember_source_buffer(resources, root, buffer)
  if type(resources) ~= "table"
      or type(root) ~= "string"
      or not buffer
      or not vim.api.nvim_buf_is_valid(buffer)
      or not vim.api.nvim_buf_is_loaded(buffer)
      or vim.bo[buffer].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buffer)
  if name == "" then return false end
  local path = canonical_path(name)
  local canonical_root = canonical_path(root)
  if not path or not canonical_root or not is_within(canonical_root, path) then
    return false
  end
  resources.source_buffers = resources.source_buffers or {}
  resources.source_buffers[buffer] = path
  return true
end

local function running_job(job)
  if type(job) ~= "number" or job <= 0 then
    return false
  end
  local ok, statuses = pcall(vim.fn.jobwait, { job }, 0)
  return ok and statuses[1] == -1
end

local function visible_buffer_window(tab, buffer)
  if not tab or not vim.api.nvim_tabpage_is_valid(tab) then return nil end
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_is_valid(window)
        and vim.api.nvim_win_get_buf(window) == buffer then
      return window
    end
  end
end

function M.open_file(context, done)
  local result
  local ok, message = xpcall(function()
    local workspace = context.workspace
    local rooted = M.bind_workspace_root(workspace, context.root)
    if not rooted.ok then error(rooted.error.message) end
    local window = workspace_window(workspace)
    if not window then
      error("Vigit workspace is unavailable")
    end
    local tab = workspace.tab
    local buffer = vim.fn.bufadd(context.path)
    vim.fn.bufload(buffer)
    vim.bo[buffer].buflisted = true

    vim.api.nvim_set_current_tabpage(tab)
    vim.api.nvim_set_current_win(window)
    vim.api.nvim_win_call(window, function()
      vim.cmd("normal! m'")
    end)
    local resources = context.resources
    if resources then
      M.remember_source_buffer(resources, context.root, buffer)
    end

    vim.api.nvim_tabpage_set_var(tab, "vigit_root", context.root)
    vim.api.nvim_tabpage_set_var(tab, "vigit_branch", context.branch or "")
    vim.api.nvim_tabpage_set_var(tab, "vigit_label", source_label(context))
    vim.api.nvim_tabpage_set_var(
      tab,
      "vigit_role",
      "workspace"
    )
    vim.api.nvim_win_set_buf(window, buffer)
    vim.api.nvim_win_set_cursor(window, { context.line, context.column })
    result = Result.ok({
      tab = tab,
      win = window,
      buf = buffer,
    })
  end, debug.traceback)

  if not ok then
    result = Result.err(
      "source_open_failed",
      "Unable to open source file",
      message
    )
  end
  done(result)
end

function M.goto_definition(context, done)
  local completed = false
  local cancel_wait
  local function complete(result)
    if completed then
      return
    end
    completed = true
    done(result)
  end

  M.open_file(context, function(open_result)
    if not open_result.ok then
      complete(open_result)
      return
    end

    local source = open_result.value
    local ok, message = xpcall(function()
      if not valid_source(source) then
        complete(Result.err(
          "source_unavailable",
          "Source window is no longer available",
          context.path
        ))
        return
      end

      local mapping
      vim.api.nvim_win_call(source.win, function()
        mapping = vim.fn.maparg("gd", "n", false, true)
      end)
      if type(mapping) == "table" and next(mapping) ~= nil then
        vim.api.nvim_set_current_tabpage(source.tab)
        vim.api.nvim_set_current_win(source.win)
        if not valid_source(source) then
          complete(Result.err(
            "source_unavailable",
            "Source window is no longer available",
            context.path
          ))
          return
        end
        local keys = vim.api.nvim_replace_termcodes(
          "gd",
          true,
          false,
          true
        )
        vim.api.nvim_feedkeys(keys, "m", false)
        complete(Result.ok({
          tab = source.tab,
          win = source.win,
          buf = source.buf,
          method = "mapping",
        }))
        return
      end

      local clients = vim.lsp.get_clients({ bufnr = source.buf }) or {}
      if #clients > 0 then
        if not valid_source(source) then
          complete(Result.err(
            "source_unavailable",
            "Source window is no longer available",
            context.path
          ))
          return
        end
        vim.api.nvim_win_call(source.win, function()
          vim.lsp.buf.definition()
        end)
        complete(Result.ok({
          tab = source.tab,
          win = source.win,
          buf = source.buf,
          method = "lsp",
        }))
        return
      end

      local autocmd
      local timer
      local waiting = true
      local function cleanup()
        if autocmd then
          pcall(vim.api.nvim_del_autocmd, autocmd)
          autocmd = nil
        end
        close_timer(timer)
        timer = nil
      end
      local function finish_wait(result)
        if not waiting then
          return
        end
        waiting = false
        cleanup()
        complete(result)
      end
      cancel_wait = function()
        if not waiting then
          return
        end
        waiting = false
        cleanup()
      end

      autocmd = vim.api.nvim_create_autocmd("LspAttach", {
        buffer = source.buf,
        once = true,
        callback = function()
          local attached, attach_error = xpcall(function()
            if not valid_source(source) then
              finish_wait(Result.err(
                "source_unavailable",
                "Source window is no longer available",
                context.path
              ))
              return
            end
            vim.api.nvim_win_call(source.win, function()
              vim.lsp.buf.definition()
            end)
            finish_wait(Result.ok({
              tab = source.tab,
              win = source.win,
              buf = source.buf,
              method = "lsp_attach",
            }))
          end, debug.traceback)
          if not attached then
            finish_wait(Result.err(
              "definition_failed",
              "Unable to request LSP definition",
              attach_error
            ))
          end
        end,
        desc = "Continue Vigit definition after source LSP attaches",
      })

      timer = assert(vim.uv.new_timer())
      timer:start(lsp_attach_timeout_ms, 0, function()
        vim.schedule(function()
          finish_wait(Result.err(
            "lsp_unavailable",
            "No LSP client attached to the source buffer",
            context.path
          ))
        end)
      end)
    end, debug.traceback)

    if not ok then
      if cancel_wait then
        cancel_wait()
      end
      complete(Result.err(
        "definition_failed",
        "Unable to open the source definition",
        message
      ))
    end
  end)
  return cancel_wait
end

function M.open_terminal(context, done)
  local result
  local tab
  local window
  local buffer
  local workspace = context.workspace
  local resources = context.resources
  local ok, message = xpcall(function()
    local rooted = M.bind_workspace_root(workspace, context.root)
    if not rooted.ok then error(rooted.error.message) end
    local code_window = workspace_window(workspace)
    if not code_window or type(resources) ~= "table" then
      error("Vigit workspace is unavailable")
    end
    tab = workspace.tab
    vim.api.nvim_set_current_tabpage(tab)
    vim.api.nvim_set_current_win(code_window)

    local existing = resources.terminal
    if existing
        and existing.buf
        and vim.api.nvim_buf_is_valid(existing.buf)
        and running_job(existing.job) then
      window = visible_buffer_window(tab, existing.buf)
      if window then
        vim.api.nvim_set_current_win(window)
      else
        vim.cmd("botright sbuffer " .. existing.buf)
        window = vim.api.nvim_get_current_win()
      end
      existing.tab = tab
      existing.win = window
      vim.cmd("startinsert")
      result = Result.ok(existing)
      return
    end

    if existing then
      if existing.buf and vim.api.nvim_buf_is_valid(existing.buf) then
        pcall(vim.api.nvim_buf_delete, existing.buf, { force = true })
      end
      resources.terminal = nil
    end

    vim.cmd("botright new")
    window = vim.api.nvim_get_current_win()
    buffer = vim.api.nvim_get_current_buf()

    vim.api.nvim_tabpage_set_var(tab, "vigit_root", context.root)
    vim.api.nvim_tabpage_set_var(tab, "vigit_branch", context.branch or "")
    vim.api.nvim_tabpage_set_var(tab, "vigit_label", terminal_label(context))
    vim.api.nvim_tabpage_set_var(
      tab,
      "vigit_role",
      "workspace"
    )

    local job = vim.fn.termopen(vim.o.shell, { cwd = context.root })
    if type(job) ~= "number" or job <= 0 then
      error("termopen returned invalid job id: " .. vim.inspect(job))
    end
    vim.cmd("startinsert")
    resources.terminal = {
      tab = tab,
      win = window,
      buf = buffer,
      job = job,
    }
    result = Result.ok({
      tab = tab,
      win = window,
      buf = buffer,
      job = job,
    })
  end, debug.traceback)

  if not ok then
    if window and vim.api.nvim_win_is_valid(window) then
      pcall(vim.api.nvim_win_close, window, true)
    end
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
    result = Result.err(
      "terminal_open_failed",
      "Unable to open a worktree terminal",
      message
    )
  end
  done(result)
end

return M
