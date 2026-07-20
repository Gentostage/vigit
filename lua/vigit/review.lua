local default_git = require("vigit.git")

local M = {}

local SCHEMA_VERSION = 1

local function timestamp()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function read_file(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function write_file(path, content)
  local temporary = path .. ".tmp"
  local handle, err = io.open(temporary, "w")
  if not handle then
    return false, err
  end
  handle:write(content)
  handle:close()
  local ok, rename_err = os.rename(temporary, path)
  if not ok then
    os.remove(temporary)
    return false, rename_err
  end
  return true, nil
end

local function review_paths(cwd)
  local git_dir, err = default_git.git_dir(cwd)
  if not git_dir then
    return nil, err
  end
  local directory = git_dir .. "/vigit"
  return {
    directory = directory,
    json = directory .. "/review.json",
    markdown = directory .. "/review.md",
  }, nil
end

local function empty_review(cwd)
  local root = default_git.root(cwd)
  return {
    schema_version = SCHEMA_VERSION,
    worktree = root or cwd,
    updated_at = timestamp(),
    issues = {},
  }
end

local function markdown_escape(value)
  return tostring(value or ""):gsub("```", "`` `")
end

local function render_markdown(review, json_path)
  local lines = {
    "# Vigit Review",
    "",
    "Worktree: `" .. markdown_escape(review.worktree) .. "`",
    "Source: `" .. markdown_escape(json_path) .. "`",
    "Updated: " .. markdown_escape(review.updated_at),
    "",
    "Use the `vigit-review` Codex skill to resolve open issues.",
    "",
  }
  if #(review.issues or {}) == 0 then
    lines[#lines + 1] = "No review issues."
  end
  for _, issue in ipairs(review.issues or {}) do
    lines[#lines + 1] = string.format("## %s [%s]", issue.id, issue.status or "open")
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("- File: `%s`", markdown_escape(issue.file))
    lines[#lines + 1] = string.format("- Line: %s", tostring(issue.line or 1))
    lines[#lines + 1] = string.format("- Section: `%s`", markdown_escape(issue.section or "unstaged"))
    if issue.hunk and issue.hunk ~= "" then
      lines[#lines + 1] = string.format("- Hunk: `%s`", markdown_escape(issue.hunk))
    end
    lines[#lines + 1] = string.format("- Created: %s", markdown_escape(issue.created_at))
    lines[#lines + 1] = ""
    lines[#lines + 1] = "### Comment"
    lines[#lines + 1] = ""
    lines[#lines + 1] = markdown_escape(issue.comment)
    if issue.context and issue.context ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "### Context"
      lines[#lines + 1] = ""
      lines[#lines + 1] = "```diff"
      lines[#lines + 1] = markdown_escape(issue.context)
      lines[#lines + 1] = "```"
    end
    if issue.resolution and issue.resolution ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "### Resolution"
      lines[#lines + 1] = ""
      lines[#lines + 1] = markdown_escape(issue.resolution)
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function next_id(review)
  local maximum = 0
  for _, issue in ipairs(review.issues or {}) do
    maximum = math.max(maximum, tonumber(tostring(issue.id or ""):match("VIGIT%-(%d+)")) or 0)
  end
  return string.format("VIGIT-%03d", maximum + 1)
end

function M.paths(cwd)
  return review_paths(cwd)
end

function M.load(cwd)
  local paths, path_err = review_paths(cwd)
  if not paths then
    return nil, path_err
  end
  local content = read_file(paths.json)
  if not content or content == "" then
    return empty_review(cwd), nil
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil, "Invalid Vigit review file: " .. paths.json
  end
  decoded.schema_version = decoded.schema_version or SCHEMA_VERSION
  decoded.issues = type(decoded.issues) == "table" and decoded.issues or {}
  return decoded, nil
end

function M.write(cwd, review)
  local paths, path_err = review_paths(cwd)
  if not paths then
    return false, path_err
  end
  vim.fn.mkdir(paths.directory, "p")
  review.schema_version = SCHEMA_VERSION
  review.worktree = default_git.root(cwd) or cwd
  review.updated_at = timestamp()
  review.issues = review.issues or {}
  local json = vim.json.encode(review)
  local json_ok, json_err = write_file(paths.json, json .. "\n")
  if not json_ok then
    return false, json_err
  end
  return write_file(paths.markdown, render_markdown(review, paths.json))
end

function M.sync_markdown(cwd)
  local review, err = M.load(cwd)
  if not review then
    return false, err
  end
  local paths, path_err = review_paths(cwd)
  if not paths then
    return false, path_err
  end
  vim.fn.mkdir(paths.directory, "p")
  return write_file(paths.markdown, render_markdown(review, paths.json))
end

function M.add(cwd, issue)
  local review, err = M.load(cwd)
  if not review then
    return nil, err
  end
  issue.id = next_id(review)
  issue.status = "open"
  issue.created_at = timestamp()
  issue.resolution = issue.resolution or ""
  review.issues[#review.issues + 1] = issue
  local ok, write_err = M.write(cwd, review)
  if not ok then
    return nil, write_err
  end
  return issue, nil
end

function M.open_count(cwd)
  local review = M.load(cwd)
  if not review then
    return 0
  end
  local count = 0
  for _, issue in ipairs(review.issues or {}) do
    if issue.status == "open" then
      count = count + 1
    end
  end
  return count
end

return M
