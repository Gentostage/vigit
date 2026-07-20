local M = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Vigit" })
end

local function current_buffer_name(session)
  local buf = vim.api.nvim_get_current_buf()
  if buf == session.changes_buf then
    return "changes"
  end
  if buf == session.diff_buf then
    return "diff"
  end
  return nil
end

local function current_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function move_changes_cursor(session, line)
  if not session.changes_win or not vim.api.nvim_win_is_valid(session.changes_win) then
    return
  end
  local line_count = math.max(vim.api.nvim_buf_line_count(session.changes_buf), 1)
  vim.api.nvim_win_set_cursor(session.changes_win, { math.min(math.max(line or 1, 1), line_count), 0 })
end

function M.close(session)
  require("vigit.ui").close(session)
end

function M.refresh(session)
  local ok, err = session.state:refresh()
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return
  end
  require("vigit.ui").render(session)
end

function M.toggle_full_context(session)
  local ok, err = session.state:toggle_full_context()
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return
  end
  require("vigit.ui").render(session)
end

function M.select_file(session)
  local buffer_name = current_buffer_name(session)
  local line = current_line()
  if buffer_name == "changes" then
    local node = session.state:changes_node_at_line(line)
    if node then
      session.state:set_directory_collapsed(node)
      require("vigit.ui").render(session)
      move_changes_cursor(
        session,
        session.state:changes_line_for_directory(node.section, node.path) or line
      )
      return
    end
  end

  local file = session.state:file_at_line(buffer_name, line)
  local ok, err = session.state:select_file(file)
  if not ok then
    notify(err, vim.log.levels.WARN)
    return
  end
  local ui = require("vigit.ui")
  ui.render(session)
  ui.focus_file(session, session.state:selected_file())
end

function M.toggle_changes_view(session)
  local file = session.state:file_at_line("changes", current_line()) or session.state:selected_file()
  session.state:toggle_changes_mode()
  require("vigit.ui").render(session)
  move_changes_cursor(
    session,
    session.state:changes_line_for_file(file) or session.state:first_changes_file_line()
  )
end

local function set_directory_collapsed(session, collapsed)
  if current_buffer_name(session) ~= "changes" then
    return
  end
  local line = current_line()
  local node = session.state:changes_node_at_line(line)
  if not node then
    return
  end
  session.state:set_directory_collapsed(node, collapsed)
  require("vigit.ui").render(session)
  move_changes_cursor(
    session,
    session.state:changes_line_for_directory(node.section, node.path) or line
  )
end

function M.collapse_directory(session)
  set_directory_collapsed(session, true)
end

function M.expand_directory(session)
  set_directory_collapsed(session, false)
end

function M.preview_file(session)
  if current_buffer_name(session) ~= "changes" or not session.state:is_single_file() then
    return false
  end
  local file = session.state:file_at_line("changes", current_line())
  if not file then
    return false
  end
  local selected = session.state:selected_file()
  if selected and selected.path == file.path and selected.section == file.section then
    return false
  end
  local ok = session.state:select_file(file)
  if not ok then
    return false
  end
  require("vigit.ui").render_diff(session)
  return true
end

function M.show_all_files(session)
  session.state:show_all_files()
  local ui = require("vigit.ui")
  ui.render(session)
  ui.focus_overview(session)
end

function M.edit_file(session)
  local buffer_name = current_buffer_name(session)
  local file, target_line = session.state:edit_target(buffer_name, current_line())
  if not file then
    notify("No file under cursor", vim.log.levels.WARN)
    return
  end
  require("vigit.ui").open_editor(session, file, target_line)
end

function M.open_worktrees(session)
  require("vigit.worktree_picker").open(session)
end

function M.add_review_comment(session, opts)
  require("vigit.review_ui").add_comment(session, opts)
end

function M.open_reviews(session)
  require("vigit.review_ui").open(session)
end

function M.prepare_review(session)
  require("vigit.review_ui").prepare(session)
end

function M.next_worktree()
  require("vigit.ui").cycle_worktree(1)
end

function M.previous_worktree()
  require("vigit.ui").cycle_worktree(-1)
end

M.open_file = M.select_file

local function finish_index_change(session, ok, err)
  if not ok then
    notify(err or "Git index operation failed", vim.log.levels.ERROR)
  end
  M.refresh(session)
end

function M.stage(session)
  local buffer_name = current_buffer_name(session)
  local line = current_line()

  if buffer_name == "changes" then
    local file = session.state:file_at_line("changes", line)
    if not file then
      notify("No file under cursor", vim.log.levels.WARN)
      return
    end
    local ok, err
    if file.section == "staged" then
      ok, err = session.state.git.unstage_file(file, session.state.cwd)
    else
      ok, err = session.state.git.stage_file(file.path, session.state.cwd)
    end
    finish_index_change(session, ok, err)
    return
  end

  local target = session.state:hunk_at_line(line)
  if not target then
    notify("No hunk under cursor", vim.log.levels.WARN)
    return
  end
  local ok, err
  if target.file.section == "staged" then
    ok, err = session.state.git.unstage_hunk(target.file, target.hunk, session.state.cwd)
  else
    ok, err = session.state.git.stage_hunk(target.file, target.hunk, session.state.cwd)
  end
  finish_index_change(session, ok, err)
end

return M
