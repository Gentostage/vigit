local M = {}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

function M.install()
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
  if vim.fn.filereadable(target) == 1 then
    return false, "Skill already exists: " .. target
  end
  vim.fn.mkdir(target_dir, "p")
  local ok, err = pcall(vim.fn.writefile, vim.fn.readfile(source), target)
  if not ok then
    return false, tostring(err)
  end
  local metadata_source = skill_root .. "/agents/openai.yaml"
  if vim.fn.filereadable(metadata_source) == 1 then
    local metadata_target_dir = target_dir .. "/agents"
    vim.fn.mkdir(metadata_target_dir, "p")
    local metadata_ok, metadata_err =
      pcall(vim.fn.writefile, vim.fn.readfile(metadata_source), metadata_target_dir .. "/openai.yaml")
    if not metadata_ok then
      return false, tostring(metadata_err)
    end
  end
  return true, target
end

return M
