local M = {}

local Fixture = {}
Fixture.__index = Fixture

local function run(args, opts)
  local result = vim.system(args, opts or { text = false }):wait()
  if result.code ~= 0 then
    error(string.format(
      "command failed (%s): %s",
      table.concat(args, " "),
      result.stderr or ""
    ))
  end
  return result
end

function M.new()
  local created = run({ "mktemp", "-d" }, { text = true })
  local self = setmetatable({
    root = vim.trim(created.stdout),
  }, Fixture)

  run({ "git", "init", "-q" }, { cwd = self.root, text = false })
  self:git({ "config", "user.name", "Vigit Tests" })
  self:git({ "config", "user.email", "vigit@example.invalid" })
  return self
end

function Fixture:write(path, lines)
  local parent = vim.fs.dirname(self.root .. "/" .. path)
  run({ "mkdir", "-p", parent }, { text = false })

  local data = type(lines) == "table" and lines or { lines }
  if vim.fn.writefile(data, self.root .. "/" .. path) ~= 0 then
    error("unable to write fixture file: " .. path)
  end
end

function Fixture:symlink(target, path)
  local parent = vim.fs.dirname(self.root .. "/" .. path)
  run({ "mkdir", "-p", parent }, { text = false })
  run({ "ln", "-s", "--", target, self.root .. "/" .. path }, { text = false })
end

function Fixture:mkfifo(path)
  local parent = vim.fs.dirname(self.root .. "/" .. path)
  run({ "mkdir", "-p", parent }, { text = false })
  run({ "mkfifo", "--", self.root .. "/" .. path }, { text = false })
end

function Fixture:git(args)
  local command = { "git" }
  vim.list_extend(command, args)
  return run(command, { cwd = self.root, text = false })
end

function Fixture:commit(message)
  self:git({ "commit", "-q", "-m", message })
end

function Fixture:cleanup()
  if not self.root then
    return
  end
  run({ "rm", "-rf", "--", self.root }, { text = false })
  self.root = nil
end

return M
