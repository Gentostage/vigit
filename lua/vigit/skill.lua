local M = {}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function copy_tree(source_dir, target_dir)
  vim.fn.mkdir(target_dir, "p")
  for name, kind in vim.fs.dir(source_dir) do
    local source = source_dir .. "/" .. name
    local target = target_dir .. "/" .. name
    if kind == "directory" then
      local ok, err = copy_tree(source, target)
      if not ok then
        return false, err
      end
    elseif kind == "file" then
      local ok, err = pcall(vim.fn.writefile, vim.fn.readfile(source, "b"), target, "b")
      if not ok then
        return false, tostring(err)
      end
    end
  end
  return true, nil
end

function M.install(opts)
  opts = opts or {}
  local skill_root = plugin_root() .. "/skills/vigit-review"
  local source = skill_root .. "/SKILL.md"
  if vim.fn.filereadable(source) == 0 then
    return false, "Bundled skill not found: " .. source
  end
  local codex_home = vim.env.CODEX_HOME
  if not codex_home or codex_home == "" then
    codex_home = vim.fn.expand("~/.codex")
  end
  local target_dir = codex_home .. "/skills/vigit-review"
  local target = target_dir .. "/SKILL.md"
  if vim.fn.isdirectory(target_dir) == 1 and not opts.force then
    return false, "Skill already exists: " .. target
  end
  if vim.fn.isdirectory(target_dir) == 1 and opts.force then
    local deleted = vim.fn.delete(target_dir, "rf")
    if deleted ~= 0 then
      return false, "Cannot replace installed skill: " .. target_dir
    end
  end
  local ok, err = copy_tree(skill_root, target_dir)
  if not ok then
    return false, err
  end
  return true, target
end

return M
