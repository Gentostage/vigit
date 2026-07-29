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

local function absolute_path(path)
  if is_windows then
    return path:match("^%a:[/\\\\]") ~= nil
      or path:sub(1, 2) == "\\\\"
      or path:sub(1, 2) == "//"
  end
  return path:sub(1, 1) == "/"
end

local function missing_path(path)
  local stat, _, code = vim.uv.fs_lstat(path)
  return stat == nil and code == "ENOENT"
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

function M.find_source_tab(root)
  local canonical_root = canonical_path(root) or root
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      local ok_root, tab_root = pcall(
        vim.api.nvim_tabpage_get_var,
        tab,
        "vigit_root"
      )
      local ok_role, role = pcall(
        vim.api.nvim_tabpage_get_var,
        tab,
        "vigit_role"
      )
      if ok_root
          and ok_role
          and tab_root == canonical_root
          and role == "source" then
        return tab
      end
    end
  end
end

function M.loaded_source_buffers(root)
  local canonical_root = canonical_path(root)
  if not canonical_root then
    return Result.err(
      "repository_root_unavailable",
      "Repository root cannot be canonicalized",
      root
    )
  end

  local buffers = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer)
        and vim.api.nvim_buf_is_loaded(buffer)
        and vim.bo[buffer].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= "" then
        if missing_path(name)
            and absolute_path(name)
            and not is_within(canonical_root, name) then
          goto continue
        end
        local path = canonical_path(name)
        if not path then
          return Result.err(
            "source_buffer_unavailable",
            "Loaded source buffer cannot be canonicalized",
            name
          )
        end
        if is_within(canonical_root, path) then
          buffers[#buffers + 1] = {
            buf = buffer,
            path = path,
          }
        end
      end
      ::continue::
    end
  end
  table.sort(buffers, function(first, second)
    if first.path == second.path then
      return first.buf < second.buf
    end
    return first.path < second.path
  end)
  return Result.ok(buffers)
end

function M.open_file(context, done)
  local result
  local ok, message = xpcall(function()
    local buffer = vim.fn.bufadd(context.path)
    vim.fn.bufload(buffer)

    local tab = M.find_source_tab(context.root)
    local reused = tab ~= nil
    if not tab then
      vim.cmd("tabnew")
      tab = vim.api.nvim_get_current_tabpage()
    else
      vim.api.nvim_set_current_tabpage(tab)
    end

    local window = vim.api.nvim_get_current_win()
    if reused then
      vim.api.nvim_win_call(window, function()
        vim.cmd("normal! m'")
      end)
    end

    vim.api.nvim_tabpage_set_var(tab, "vigit_root", context.root)
    vim.api.nvim_tabpage_set_var(tab, "vigit_branch", context.branch or "")
    vim.api.nvim_tabpage_set_var(tab, "vigit_label", source_label(context))
    vim.api.nvim_tabpage_set_var(tab, "vigit_role", "source")
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
  local buffer
  local ok, message = xpcall(function()
    vim.cmd("tabnew")
    tab = vim.api.nvim_get_current_tabpage()
    local window = vim.api.nvim_get_current_win()
    buffer = vim.api.nvim_get_current_buf()

    vim.api.nvim_tabpage_set_var(tab, "vigit_root", context.root)
    vim.api.nvim_tabpage_set_var(tab, "vigit_branch", context.branch or "")
    vim.api.nvim_tabpage_set_var(tab, "vigit_label", terminal_label(context))
    vim.api.nvim_tabpage_set_var(tab, "vigit_role", "terminal")

    local job = vim.fn.termopen(vim.o.shell, { cwd = context.root })
    if type(job) ~= "number" or job <= 0 then
      error("termopen returned invalid job id: " .. vim.inspect(job))
    end
    result = Result.ok({
      tab = tab,
      win = window,
      buf = buffer,
      job = job,
    })
  end, debug.traceback)

  if not ok then
    if tab and vim.api.nvim_tabpage_is_valid(tab) then
      if #vim.api.nvim_list_tabpages() == 1 then
        vim.cmd("tabnew")
      end
      vim.api.nvim_set_current_tabpage(tab)
      pcall(vim.cmd, "tabclose")
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
