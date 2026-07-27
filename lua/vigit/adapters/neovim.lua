local Result = require("vigit.core.result")

local M = {}

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

return M
