local worktree = require("vigit.core.worktree")

local function assert_ok(result)
  assert_truthy(result.ok)
  return result.value
end

local function porcelain(records)
  local fields = {}
  for _, record in ipairs(records) do
    for _, field in ipairs(record) do
      fields[#fields + 1] = field
    end
    fields[#fields + 1] = ""
  end
  return table.concat(fields, "\0") .. "\0"
end

it("parses the first porcelain worktree as root without using its directory name", function()
  local parsed = assert_ok(worktree.parse_porcelain(porcelain({
    {
      "worktree /projects/not-main-name",
      "HEAD 0123456789abcdef",
      "branch refs/heads/main",
    },
    {
      "worktree /projects/feature copy",
      "HEAD fedcba9876543210",
      "branch refs/heads/feature/example",
    },
  })))

  assert_equal(parsed[1], {
    path = "/projects/not-main-name",
    head = "0123456789abcdef",
    branch_ref = "refs/heads/main",
    branch = "main",
    kind = "root",
  })
  assert_equal(parsed[2], {
    path = "/projects/feature copy",
    head = "fedcba9876543210",
    branch_ref = "refs/heads/feature/example",
    branch = "feature/example",
    kind = "linked",
  })
end)

it("preserves NUL-framed path bytes including spaces Unicode and newlines", function()
  local path = "/projects/каталог/feature name\nnext"
  local parsed = assert_ok(worktree.parse_porcelain(porcelain({
    {
      "worktree " .. path,
      "HEAD abcdef",
      "detached",
    },
  })))

  assert_equal(parsed[1].path, path)
  assert_equal(parsed[1].head, "abcdef")
  assert_equal(parsed[1].detached, true)
  assert_equal(parsed[1].branch_ref, nil)
  assert_equal(parsed[1].branch, nil)
end)

it("preserves detached locked and prunable metadata", function()
  local parsed = assert_ok(worktree.parse_porcelain(porcelain({
    {
      "worktree /projects/root",
      "HEAD root-head",
      "branch refs/heads/main",
    },
    {
      "worktree /projects/detached",
      "HEAD detached-head",
      "detached",
      "locked maintenance window",
      "prunable missing administrative files",
    },
  })))

  assert_equal(parsed[2], {
    path = "/projects/detached",
    head = "detached-head",
    detached = true,
    locked = "maintenance window",
    prunable = "missing administrative files",
    kind = "linked",
  })
end)

it("accepts only a root bare worktree with no HEAD branch or detached field", function()
  local parsed = assert_ok(worktree.parse_porcelain(porcelain({ {
    "worktree /projects/bare",
    "bare",
  } })))

  assert_equal(parsed[1], {
    path = "/projects/bare",
    bare = true,
    kind = "root",
  })
end)

it("keeps a non-local branch ref without inventing a branch name", function()
  local parsed = assert_ok(worktree.parse_porcelain(porcelain({ {
    "worktree /projects/root",
    "HEAD abcdef",
    "branch refs/remotes/origin/main",
  } })))

  assert_equal(parsed[1].branch_ref, "refs/remotes/origin/main")
  assert_equal(parsed[1].branch, nil)
end)

it("accepts optional lock and prune metadata with no reason", function()
  local parsed = assert_ok(worktree.parse_porcelain(porcelain({ {
    "worktree /projects/root",
    "HEAD abcdef",
    "branch refs/heads/main",
    "locked",
    "prunable",
  } })))

  assert_equal(parsed[1].locked, true)
  assert_equal(parsed[1].prunable, true)
end)

it("rejects non-NUL-terminated or malformed porcelain instead of guessing", function()
  local not_terminated = worktree.parse_porcelain("worktree /projects/root\0HEAD abc")
  local unknown_field = worktree.parse_porcelain(porcelain({ {
    "worktree /projects/root",
    "HEAD abc",
    "mystery value",
  } }))
  local missing_path = worktree.parse_porcelain(porcelain({ {
    "worktree ",
    "HEAD abc",
  } }))

  assert_equal(not_terminated.error.code, "malformed_worktree")
  assert_equal(unknown_field.error.code, "malformed_worktree")
  assert_equal(missing_path.error.code, "malformed_worktree")
end)

it("rejects empty records and incomplete optional metadata", function()
  local empty = worktree.parse_porcelain("\0")
  local incomplete = worktree.parse_porcelain(porcelain({ {
    "worktree /projects/root",
    "locked ",
  } }))

  assert_equal(empty.error.code, "malformed_worktree")
  assert_equal(incomplete.error.code, "malformed_worktree")
end)

it("rejects impossible bare and non-bare porcelain record unions", function()
  local cases = {
    porcelain({ {
      "worktree /projects/root",
      "HEAD abc",
      "branch refs/heads/main",
    }, {
      "worktree /projects/linked-bare",
      "bare",
    } }),
    porcelain({ {
      "worktree /projects/bare",
      "bare",
      "HEAD abc",
    } }),
    porcelain({ {
      "worktree /projects/missing-head",
      "branch refs/heads/main",
    } }),
    porcelain({ {
      "worktree /projects/missing-state",
      "HEAD abc",
    } }),
    porcelain({ {
      "worktree /projects/both-states",
      "HEAD abc",
      "branch refs/heads/main",
      "detached",
    } }),
  }

  for _, raw in ipairs(cases) do
    local result = worktree.parse_porcelain(raw)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "malformed_worktree")
  end
end)

it("returns removal blocker codes in the required priority", function()
  local entry = {
    kind = "root",
    locked = "locked",
    prunable = "prunable",
    status = { staged = 1 },
    upstream = { state = "no_upstream" },
    path = "/projects/root",
  }

  assert_equal(worktree.removal_blocker(entry, { "/projects/root/src/a.lua" }), "root")
  entry.kind = "linked"
  assert_equal(worktree.removal_blocker(entry, { "/projects/root/src/a.lua" }), "locked")
  entry.locked = nil
  assert_equal(worktree.removal_blocker(entry, { "/projects/root/src/a.lua" }), "prunable")
  entry.prunable = nil
  assert_equal(worktree.removal_blocker(entry, { "/projects/root/src/a.lua" }), "dirty")
  entry.status = { staged = 0, unstaged = 0, untracked = 0 }
  entry.probes = {
    upstream = {
      state = "error",
      error = { code = "git_upstream_failed" },
    },
  }
  assert_equal(
    worktree.removal_blocker(entry, {}),
    nil
  )
  entry.probes = nil
  assert_equal(worktree.removal_blocker(entry, {}), nil)
  entry.upstream = { state = "tracking", source = "local_refs", ahead = 2, behind = 0 }
  assert_equal(worktree.removal_blocker(entry, { "/projects/root/src/a.lua" }), "ahead")
  entry.upstream.ahead = 0
  assert_equal(worktree.removal_blocker(entry, { "/projects/root/src/a.lua" }), "loaded_source_buffer")
end)

it("allows a clean linked worktree that is only behind its upstream", function()
  local blocker = worktree.removal_blocker({
    kind = "linked",
    path = "/projects/feature",
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 3 },
    status = { staged = 0, unstaged = 0, untracked = 0 },
  }, {})

  assert_equal(blocker, nil)
end)

it("blocks dirty fully loaded picker rows and allows clean picker rows", function()
  local entry = {
    kind = "linked",
    path = "/projects/feature",
    files = { staged = 0, unstaged = 1, untracked = 0 },
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }

  assert_equal(worktree.removal_blocker(entry, {}), "dirty")

  entry.files = { staged = 0, unstaged = 0, untracked = 0 }
  assert_equal(worktree.removal_blocker(entry, {}), nil)
end)

it("only blocks loaded source paths within the exact worktree path", function()
  local entry = {
    kind = "linked",
    path = "/projects/feature",
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }

  assert_equal(worktree.removal_blocker(entry, {
    "/projects/feature-copy/src/a.lua",
  }), nil)
  assert_equal(worktree.removal_blocker(entry, {
    "/projects/feature/src/a.lua",
  }), "loaded_source_buffer")
end)

it("normalizes Windows loaded source paths without matching sibling prefixes", function()
  local entry = {
    kind = "linked",
    path = "C:\\Repo\\Wt-Two",
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }

  assert_equal(worktree.removal_blocker(entry, { "c:/repo/wt-two/SOURCE.lua" }), "loaded_source_buffer")
  assert_equal(worktree.removal_blocker(entry, { "C:\\REPO\\WT-TWO-OLD\\source.lua" }), nil)
end)

it("uses component-safe Windows loaded-source containment without rewriting path bytes", function()
  local entry = {
    kind = "linked",
    path = "C:\\Projects\\Feature",
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }

  assert_equal(worktree.removal_blocker(entry, {
    "C:\\Projects\\Feature-copy\\src\\a.lua",
  }), nil)
  assert_equal(worktree.removal_blocker(entry, {
    "C:\\Projects\\Feature\\src\\a.lua",
  }), "loaded_source_buffer")
end)

it("treats Windows UNC slash spellings as the same worktree path", function()
  local upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 }
  local backslash_entry = {
    kind = "linked",
    path = "\\\\Server\\Share\\Feature",
    upstream = upstream,
  }
  local slash_entry = {
    kind = "linked",
    path = "//Server/Share/Feature",
    upstream = upstream,
  }

  assert_equal(worktree.removal_blocker(backslash_entry, {
    "//server/share/feature/src/a.lua",
  }, "win32"), "loaded_source_buffer")
  assert_equal(worktree.removal_blocker(slash_entry, {
    "\\\\server\\share\\feature\\src\\a.lua",
  }, "win32"), "loaded_source_buffer")
  assert_equal(worktree.removal_blocker(backslash_entry, {
    "//server/share/feature-copy/src/a.lua",
  }, "win32"), nil)
end)

it("does not reinterpret POSIX double-slash roots as Windows UNC", function()
  local entry = {
    kind = "linked",
    path = "//tmp/feature\\copy",
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }

  assert_equal(worktree.removal_blocker(entry, {
    "//tmp/feature\\copy\\src/a.lua",
  }, "posix"), nil)
  assert_equal(worktree.removal_blocker(entry, {
    "//tmp/feature\\copy/src/a.lua",
  }, "posix"), "loaded_source_buffer")
end)

it("does not treat POSIX backslashes as path separators", function()
  local entry = {
    kind = "linked",
    path = "/tmp/feature\\copy",
    upstream = { state = "tracking", source = "local_refs", ahead = 0, behind = 0 },
  }

  assert_equal(worktree.removal_blocker(entry, {
    "/tmp/feature\\copy\\src\\a.lua",
  }), nil)
  assert_equal(worktree.removal_blocker(entry, {
    "/tmp/feature\\copy/src/a.lua",
  }), "loaded_source_buffer")
end)
