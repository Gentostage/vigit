local M = {}

function M.new(opts)
  opts = assert(opts)

  return {
    id = assert(opts.id),
    root = assert(opts.root),
    branch = opts.branch,
    owned = {
      tab = nil,
      diff_buf = nil,
      changes_buf = nil,
      diff_win = nil,
      changes_win = nil,
      comments_buf = nil,
      comments_win = nil,
      comment_editor_buf = nil,
      comment_editor_win = nil,
      comment_editor_id = nil,
      prompt_buf = nil,
      prompt_win = nil,
    },
    view = {
      changes_mode = "tree",
      diff_mode = "one_file",
      selected_change_id = nil,
      anchor = nil,
      expanded_dirs = {},
      expanded_context = {},
      applied_expanded_context = {},
      all_files = {
        loaded = {},
        loading = {},
      },
    },
    data = {
      status = nil,
      diffs = {},
      comments = {},
    },
    reads = {
      generation = 0,
      jobs = {},
    },
    mutations = {
      active = false,
      queue = {},
    },
    resources = {
      source_buffers = {},
      terminal = nil,
    },
    busy = {},
    errors = {
      status = nil,
      diffs = {},
    },
    error = nil,
    closed = false,
  }
end

return M
