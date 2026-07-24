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

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local content = handle:read("*a")
  handle:close()
  return content
end

it("detects a git repository", function()
  local dir = temp_repo()
  local ok = git.is_repo(dir)
  assert_equal(ok, true)
end)

it("reports pushed, ahead, and behind upstream state", function()
  local remote = os.tmpname()
  os.remove(remote)
  run("mkdir -p " .. string.format("%q", remote))
  run("git init --bare -q", remote)

  local dir = temp_repo()
  run("git branch -M main", dir)
  run("printf 'initial\n' > tracked.txt", dir)
  run("git add tracked.txt", dir)
  run("git commit -q -m initial", dir)
  run("git remote add origin " .. string.format("%q", remote), dir)
  run("git push -q -u origin main", dir)
  run("git symbolic-ref HEAD refs/heads/main", remote)

  local pushed, pushed_err = git.upstream_status(dir)
  assert_equal(pushed_err, nil)
  assert_equal(pushed.name, "origin/main")
  assert_equal(pushed.ahead, 0)
  assert_equal(pushed.behind, 0)

  run("printf 'local\n' >> tracked.txt", dir)
  run("git add tracked.txt", dir)
  run("git commit -q -m local", dir)
  local ahead = git.upstream_status(dir)
  assert_equal(ahead.ahead, 1)
  assert_equal(ahead.behind, 0)
  run("git reset --hard -q origin/main", dir)

  local other = os.tmpname()
  os.remove(other)
  run("git clone -q " .. string.format("%q", remote) .. " " .. string.format("%q", other))
  run("git config user.email test@example.com", other)
  run("git config user.name Test", other)
  run("printf 'remote\n' >> tracked.txt", other)
  run("git add tracked.txt", other)
  run("git commit -q -m remote", other)
  run("git push -q", other)
  run("git fetch -q origin", dir)

  local behind = git.upstream_status(dir)
  assert_equal(behind.ahead, 0)
  assert_equal(behind.behind, 1)
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

it("returns HEAD, index, and worktree snapshots for diff sides", function()
  local dir = temp_repo()
  run("printf 'head\n' > sample.py", dir)
  run("git add sample.py", dir)
  run("git commit -q -m initial", dir)
  run("printf 'index\n' > sample.py", dir)
  run("git add sample.py", dir)
  run("printf 'worktree\n' > sample.py", dir)

  local staged = { section = "staged", path = "sample.py" }
  local unstaged = { section = "unstaged", path = "sample.py" }
  assert_equal(git.snapshot(staged, "old", dir), "head\n")
  assert_equal(git.snapshot(staged, "new", dir), "index\n")
  assert_equal(git.snapshot(unstaged, "old", dir), "index\n")
  assert_equal(git.snapshot(unstaged, "new", dir), "worktree\n")
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

it("discards one unstaged hunk and preserves another", function()
  local dir = temp_repo()
  for index = 1, 12 do
    run(string.format("printf 'line %d\\n' >> sample.txt", index), dir)
  end
  run("git add sample.txt", dir)
  run("git commit -q -m initial", dir)
  run("sed -i '1s/line 1/changed 1/;12s/line 12/changed 12/' sample.txt", dir)

  local files = git.diff("unstaged", dir, 0)
  assert_equal(#files[1].hunks, 2)
  local ok, err = git.discard_hunk(files[1], files[1].hunks[1], dir)

  assert_equal(ok, true)
  assert_equal(err, nil)
  local content = read_file(dir .. "/sample.txt")
  assert_truthy(content:match("^line 1\n"))
  assert_truthy(content:match("changed 12\n$"))
end)

it("discards an unstaged file back to the staged snapshot", function()
  local dir = temp_repo()
  run("printf 'head\n' > sample.txt", dir)
  run("git add sample.txt", dir)
  run("git commit -q -m initial", dir)
  run("printf 'index\n' > sample.txt", dir)
  run("git add sample.txt", dir)
  run("printf 'worktree\n' > sample.txt", dir)

  local file = git.status(dir).unstaged[1]
  local ok, err = git.discard_file(file, dir)

  assert_equal(ok, true)
  assert_equal(err, nil)
  assert_equal(read_file(dir .. "/sample.txt"), "index\n")
  assert_equal(git.snapshot({ path = "sample.txt", section = "staged" }, "new", dir), "index\n")
end)

it("removes an untracked file when discarding it", function()
  local dir = temp_repo()
  run("git commit --allow-empty -q -m initial", dir)
  run("printf 'temporary\n' > scratch.txt", dir)

  local file = git.status(dir).unstaged[1]
  local ok, err = git.discard_file(file, dir)

  assert_equal(ok, true)
  assert_equal(err, nil)
  assert_equal(io.open(dir .. "/scratch.txt", "rb"), nil)
end)

it("preserves untracked status in diff actions", function()
  local dir = temp_repo()
  run("git commit --allow-empty -q -m initial", dir)
  run("printf 'temporary\n' > scratch.md", dir)

  local status = git.status(dir)
  local files, diff_err = git.diff("unstaged", dir, 3, status.unstaged)

  assert_equal(diff_err, nil)
  assert_equal(files[1].status, "?")
  local ok, err = git.restore_file_to_head(files[1], dir)
  assert_equal(ok, true)
  assert_equal(err, nil)
  assert_equal(io.open(dir .. "/scratch.md", "rb"), nil)
end)

it("restores staged and unstaged changes to HEAD", function()
  local dir = temp_repo()
  run("printf 'head\n' > sample.txt", dir)
  run("git add sample.txt", dir)
  run("git commit -q -m initial", dir)
  run("printf 'index\n' > sample.txt", dir)
  run("git add sample.txt", dir)
  run("printf 'worktree\n' > sample.txt", dir)

  local file = git.status(dir).unstaged[1]
  local ok, err = git.restore_file_to_head(file, dir)

  assert_equal(ok, true)
  assert_equal(err, nil)
  assert_equal(read_file(dir .. "/sample.txt"), "head\n")
  local status = git.status(dir)
  assert_equal(#status.staged, 0)
  assert_equal(#status.unstaged, 0)
end)

it("removes a staged added file when restoring it to HEAD", function()
  local dir = temp_repo()
  run("git commit --allow-empty -q -m initial", dir)
  run("printf 'new\n' > added.txt", dir)
  run("git add added.txt", dir)

  local file = git.status(dir).staged[1]
  local ok, err = git.restore_file_to_head(file, dir)

  assert_equal(ok, true)
  assert_equal(err, nil)
  assert_equal(io.open(dir .. "/added.txt", "rb"), nil)
  local status = git.status(dir)
  assert_equal(#status.staged, 0)
  assert_equal(#status.unstaged, 0)
end)
