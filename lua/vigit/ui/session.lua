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
    },
    view = {
      changes_mode = "tree",
      diff_mode = "one_file",
      selected_change_id = nil,
      anchor = nil,
      expanded_dirs = {},
      expanded_context = {},
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
