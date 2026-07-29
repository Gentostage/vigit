-- User config and plugins are already loaded when this file runs. Restore the
-- compact demo chrome without replacing a user-selected colorscheme.
local project_root = assert(vim.env.VIGIT_ROOT, "VIGIT_ROOT is required")

vim.opt.termguicolors = true
vim.opt.laststatus = 3
vim.opt.showtabline = 0
vim.opt.cmdheight = 1

vim.cmd("syntax enable")
if not vim.g.colors_name then
  pcall(vim.cmd.colorscheme, "habamax")
end

-- A user's plugin manager may have loaded another Vigit checkout before this
-- file runs. Reload every Vigit module from the demo checkout so old and new
-- session contracts cannot be mixed.
local loaded = {}
for name in pairs(package.loaded) do
  if name == "vigit" or name:match("^vigit%.") then
    loaded[#loaded + 1] = name
  end
end
for _, name in ipairs(loaded) do package.loaded[name] = nil end

package.path = table.concat({
  project_root .. "/lua/?.lua",
  project_root .. "/lua/?/init.lua",
  package.path,
}, ";")

-- lazy.nvim installs its own module searcher ahead of Lua's package.path
-- searcher. Prefer the checkout explicitly so --user-config never mixes the
-- installed release with the code currently being developed.
local module_searchers = package.searchers or package.loaders
table.insert(module_searchers, 2, function(name)
  if name ~= "vigit" and not name:match("^vigit%.") then
    return nil
  end
  local path, search_error = package.searchpath(name, package.path)
  if not path or path:sub(1, #project_root + 1) ~= project_root .. "/" then
    return search_error
  end
  return assert(loadfile(path)), path
end)

local vigit = assert(loadfile(project_root .. "/lua/vigit/init.lua"))()
package.loaded.vigit = vigit
local setup_ok, setup_error = vigit.setup()
assert(setup_ok, setup_error and setup_error.message)

local session = vigit.open({ cwd = vim.env.VIGIT_DEMO_DIR })
if session and vim.api.nvim_win_is_valid(session.owned.changes_win) then
  vim.api.nvim_set_current_win(session.owned.changes_win)
end
