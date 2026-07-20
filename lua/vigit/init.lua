local M = {}

function M.setup()
  local function open_comments()
    local session = require("vigit.ui").active_session()
    if session then
      require("vigit.review_ui").open(session)
    else
      vim.notify("Open Vigit first", vim.log.levels.WARN, { title = "Vigit" })
    end
  end

  vim.api.nvim_create_user_command("Vigit", function()
    require("vigit.ui").open()
  end, { force = true, desc = "Open Vigit for the current worktree" })
  vim.api.nvim_create_user_command("VigitWorktrees", function()
    local ui = require("vigit.ui")
    local session = ui.active_session()
    if not session then
      session = ui.open()
    end
    if session then
      require("vigit.worktree_picker").open(session)
    end
  end, { force = true, desc = "Open the Vigit worktree picker" })
  vim.api.nvim_create_user_command("VigitComments", open_comments, {
    force = true,
    desc = "Open comments for the active Vigit worktree",
  })
  vim.api.nvim_create_user_command("VigitReviews", open_comments, {
    force = true,
    desc = "Compatibility alias for :VigitComments",
  })
  vim.api.nvim_create_user_command("VigitInstallCodexSkill", function(opts)
    local function install(force)
      local ok, result = require("vigit.skill").install({ force = force })
      vim.notify(result, ok and vim.log.levels.INFO or vim.log.levels.ERROR, { title = "Vigit" })
    end
    if not opts.bang then
      install(false)
      return
    end
    vim.ui.select({ "Cancel", "Replace installed skill" }, {
      prompt = "Replace the installed vigit-review skill?",
    }, function(choice)
      if choice == "Replace installed skill" then
        install(true)
      end
    end)
  end, {
    bang = true,
    force = true,
    desc = "Install or update the bundled vigit-review Codex skill",
  })
end

function M.open(opts)
  return require("vigit.ui").open(opts)
end

return M
