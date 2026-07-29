local config = require("vigit.config")

local M = {}
local commands_registered = false

function M.setup(opts)
  local configured = config.setup(opts)
  if not configured.ok then
    return nil, configured.error
  end
  if vim.uv and vim.api.nvim_create_augroup and vim.api.nvim_create_autocmd then
    require("vigit.v2").setup_observers()
  end
  if commands_registered then
    return true
  end

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
  vim.api.nvim_create_user_command("VigitV2", function(opts)
    local _, open_error = require("vigit.v2").open({
      cwd = opts.args ~= "" and opts.args or nil,
    })
    if open_error then
      vim.notify(
        string.format("[%s] %s", open_error.code, open_error.message),
        vim.log.levels.ERROR,
        { title = "Vigit" }
      )
    end
  end, {
    nargs = "?",
    complete = "dir",
    force = true,
  })
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
  vim.api.nvim_create_user_command("VigitMigrateReviews", function()
    local v2 = require("vigit.v2")
    local session = v2.active_session()
    if not session then
      vim.notify("Open a VigitV2 session first", vim.log.levels.WARN, { title = "Vigit" })
      return
    end
    local reviews = require("vigit.application.reviews").for_session(session)
    local legacy = require("vigit.adapters.legacy_review").new()
    local preview = reviews:migrate_legacy(session, legacy, false)
    if not preview.ok then
      vim.notify(
        string.format("[%s] %s", preview.error.code, preview.error.message),
        vim.log.levels.ERROR,
        { title = "Vigit" }
      )
      return
    end
    local count = preview.value.preview.importable or 0
    if count == 0 then
      vim.notify("No legacy review comments to import", vim.log.levels.INFO, { title = "Vigit" })
      return
    end
    require("vigit.ui.confirm").ask(
      string.format("Import %d legacy review comment(s)?", count),
      function(accepted)
        if not accepted then return end
        local migrated = reviews:migrate_legacy(session, legacy, true)
        if not migrated.ok then
          vim.notify(
            string.format("[%s] %s", migrated.error.code, migrated.error.message),
            vim.log.levels.ERROR,
            { title = "Vigit" }
          )
          return
        end
        require("vigit.ui.controller").dispatch(session, "refresh")
        vim.notify(
          string.format("Imported %d legacy review comment(s)", migrated.value.imported or 0),
          vim.log.levels.INFO,
          { title = "Vigit" }
        )
      end
    )
  end, {
    force = true,
    desc = "Preview and explicitly import legacy review comments into VigitV2",
  })
  vim.api.nvim_create_user_command("VigitHelp", function()
    require("vigit.ui.views.help").open()
  end, {
    force = true,
    desc = "Show Vigit key mappings",
  })
  vim.api.nvim_create_user_command("VigitLog", function()
    require("vigit.ui.log").open()
  end, {
    force = true,
    desc = "Show Vigit diagnostics",
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
  commands_registered = true
  return true
end

function M.open(opts)
  return require("vigit.ui").open(opts)
end

return M
