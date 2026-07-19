local git = require("vigit.git")

local function run(command, cwd)
  local prefix = cwd and ("cd " .. string.format("%q", cwd) .. " && ") or ""
  local ok = os.execute(prefix .. command)
  if ok ~= true and ok ~= 0 then
    error("command failed: " .. command)
  end
end

local function temp_repo()
  local dir = os.tmpname()
  os.remove(dir)
  run("mkdir -p " .. string.format("%q", dir))
  run("git init -q", dir)
  run("git config user.email test@example.com", dir)
  run("git config user.name Test", dir)
  return dir
end

it("detects a git repository", function()
  local dir = temp_repo()
  local ok = git.is_repo(dir)
  assert_equal(ok, true)
end)

it("stages an unstaged file", function()
  local dir = temp_repo()
  run("printf 'one\n' > a.txt", dir)

  local ok, err = git.stage_file("a.txt", dir)
  assert_equal(ok, true)
  assert_equal(err, nil)

  local status = git.status(dir)
  assert_equal(#status.staged, 1)
  assert_equal(status.staged[1].path, "a.txt")
end)

it("returns unstaged diff files and hunks", function()
  local dir = temp_repo()
  run("printf 'one\n' > a.txt", dir)
  run("git add a.txt", dir)
  run("git commit -q -m initial", dir)
  run("printf 'one\ntwo\n' > a.txt", dir)

  local files, err = git.diff("unstaged", dir)

  assert_equal(err, nil)
  assert_equal(#files, 1)
  assert_equal(files[1].path, "a.txt")
  assert_equal(files[1].section, "unstaged")
  assert_equal(#files[1].hunks, 1)
  assert_equal(files[1].hunks[1].patch_lines[2], " one")
  assert_equal(files[1].hunks[1].patch_lines[3], "+two")
end)

it("returns a focused diff for one file", function()
  local dir = temp_repo()
  run("printf 'one\n' > a.txt", dir)
  run("printf 'alpha\n' > b.txt", dir)
  run("git add a.txt b.txt", dir)
  run("git commit -q -m initial", dir)
  run("printf 'one\ntwo\n' > a.txt", dir)
  run("printf 'alpha\nbeta\n' > b.txt", dir)

  local files, err = git.diff_file({ path = "a.txt", section = "unstaged" }, dir, 0)

  assert_equal(err, nil)
  assert_equal(#files, 1)
  assert_equal(files[1].path, "a.txt")
  assert_equal(files[1].section, "unstaged")
end)

it("stages a valid unstaged hunk", function()
  local dir = temp_repo()
  run("printf 'one\n' > a.txt", dir)
  run("git add a.txt", dir)
  run("git commit -q -m initial", dir)
  run("printf 'one\ntwo\n' > a.txt", dir)

  local files = git.diff("unstaged", dir)
  local ok, err = git.stage_hunk(files[1], files[1].hunks[1], dir)

  assert_equal(ok, true)
  assert_equal(err, nil)

  local status = git.status(dir)
  assert_equal(#status.staged, 1)
  assert_equal(#status.unstaged, 0)
end)

it("returns false when git apply rejects an invalid hunk", function()
  local dir = temp_repo()
  run("printf 'one\n' > a.txt", dir)
  run("git add a.txt", dir)
  run("git commit -q -m initial", dir)

  local file = { path = "a.txt", section = "unstaged" }
  local hunk = { patch_lines = { "@@ -1 +1 @@", "-missing", "+two" } }
  local ok, err = git.stage_hunk(file, hunk, dir)

  assert_equal(ok, false)
  assert_truthy(err)
end)

it("stages an added file hunk", function()
  local dir = temp_repo()
  run("git commit --allow-empty -q -m initial", dir)
  run("printf 'one\n' > a.txt", dir)
  run("git add -N a.txt", dir)

  local files = git.diff("unstaged", dir)
  local ok, err = git.stage_hunk(files[1], files[1].hunks[1], dir)

  assert_equal(ok, true)
  assert_equal(err, nil)
  local status = git.status(dir)
  assert_equal(#status.staged, 1)
  assert_equal(status.staged[1].status, "A")
end)

it("stages a deleted file hunk", function()
  local dir = temp_repo()
  run("printf 'one\n' > a.txt", dir)
  run("git add a.txt", dir)
  run("git commit -q -m initial", dir)
  run("rm a.txt", dir)

  local files = git.diff("unstaged", dir)
  local ok, err = git.stage_hunk(files[1], files[1].hunks[1], dir)

  assert_equal(ok, true)
  assert_equal(err, nil)
  local status = git.status(dir)
  assert_equal(#status.staged, 1)
  assert_equal(status.staged[1].status, "D")
end)

it("stages a hunk when diff header paths differ", function()
  local dir = temp_repo()
  run("mkdir -p old new", dir)
  run("printf 'one\n' > old/a.txt", dir)
  run("git add old/a.txt", dir)
  run("git commit -q -m initial", dir)
  run("mv old/a.txt new/a.txt", dir)
  run("printf 'one\ntwo\n' > new/a.txt", dir)
  run("git add -N new/a.txt", dir)

  local file = {
    section = "unstaged",
    path = "new/a.txt",
    old_path = "old/a.txt",
    old_header_path = "a/old/a.txt",
    new_header_path = "b/new/a.txt",
    extended_headers = { "rename from old/a.txt", "rename to new/a.txt" },
  }
  local hunk = { patch_lines = { "@@ -1 +1,2 @@", " one", "+two" } }

  local ok, err = git.stage_hunk(file, hunk, dir)

  assert_equal(ok, true)
  assert_equal(err, nil)
  local status = git.status(dir)
  assert_equal(status.staged[1].status, "R")
  assert_equal(status.staged[1].path, "new/a.txt")
end)
