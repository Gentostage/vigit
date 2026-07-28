local filesystem = require("vigit.adapters.filesystem")
local Result = require("vigit.core.result")
local git_repo = dofile("tests/fixtures/git_repo.lua")

local function read_bytes(path)
  local handle = assert(io.open(path, "rb"))
  local bytes = handle:read("*a")
  handle:close()
  return bytes
end

it("atomically replaces files and creates missing directories below the root", function(done)
  local repo = git_repo.new()
  repo:write(".vigit/comments.md", "before\n")
  local result = filesystem.atomic_write(repo.root, ".vigit/comments.md", "after\n")
  assert_truthy(result.ok)
  assert_equal(read_bytes(repo.root .. "/.vigit/comments.md"), "after\n")

  result = filesystem.atomic_write(repo.root, ".vigit/nested/review.md", "nested\n")
  assert_truthy(result.ok)
  assert_equal(read_bytes(repo.root .. "/.vigit/nested/review.md"), "nested\n")
  repo:cleanup()
  done()
end)

it("binds source bytes anonymously before linking the final absent leaf", function(done)
  local repo = git_repo.new()
  local result = filesystem.atomic_write(repo.root, "bound.md", "identity-bound\n")
  assert_truthy(result.ok)
  assert_equal(read_bytes(repo.root .. "/bound.md"), "identity-bound\n")
  assert_equal(vim.fn.glob(repo.root .. "/.bound.md.vigit-tmp-*"), "")
  repo:cleanup()
  done()
end)

local function primitive_backend(plan)
  local closed, cleanup, renames, links = {}, 0, 0, 0
  local backend = {
    open_root = function() return 10 end,
    open_directory = function() return 11 end,
    mkdir = function() return true end,
    inspect_target = function() return { mode = 32768 } end,
    open_anonymous = function() return 12 end,
    write = function(_, content) return plan.write(content) end,
    fsync = function()
      if plan.fsync == false then return false, "fsync failed" end
      return true
    end,
    close = function(descriptor)
      closed[#closed + 1] = descriptor
      if descriptor == 12 and plan.close == false then return false, "close failed" end
      return true
    end,
    unlink = function() cleanup = cleanup + 1; return true end,
    link_anonymous = function()
      links = links + 1
      if plan.link == false then return false, 17 end
      return true
    end,
    rename = function()
      renames = renames + 1
      if plan.rename == false then return false, "rename failed" end
      return true
    end,
    rename_noreplace = function()
      renames = renames + 1
      if plan.noreplace == false then return false, 17 end
      return true
    end,
  }
  return backend, function() return closed, cleanup, renames, links end
end

it("keeps the original file when write, close, fsync or rename fails", function(done)
  local repo = git_repo.new()
  repo:write(".vigit/comments.md", "original\n")
  local original = read_bytes(repo.root .. "/.vigit/comments.md")
  for _, plan in ipairs({
    { phase = "zero", write = function() return 0 end },
    { phase = "fsync", write = function(content) return #content end, fsync = false },
    { phase = "close", write = function(content) return #content end, close = false },
    { phase = "rename", write = function(content) return #content end, rename = false },
  }) do
    local backend, observed = primitive_backend(plan)
    local fs = filesystem.new({ backend = backend })
    local failed = fs:atomic_write(repo.root, ".vigit/comments.md", "new\n")
    assert_equal(failed.ok, false)
    assert_equal(read_bytes(repo.root .. "/.vigit/comments.md"), original)
    local closed, cleanup, renames = observed()
    local source_closes = 0
    local root_closes, parent_closes = 0, 0
    for _, descriptor in ipairs(closed) do
      if descriptor == 12 then source_closes = source_closes + 1 end
      if descriptor == 10 then root_closes = root_closes + 1 end
      if descriptor == 11 then parent_closes = parent_closes + 1 end
    end
    assert_equal(source_closes, 1)
    assert_equal(root_closes, 1)
    assert_equal(parent_closes, 1)
    assert_equal(cleanup, 0)
    if plan.phase ~= "rename" then assert_equal(renames, 0) end
  end
  repo:cleanup()
  done()
end)

it("keeps an absent final leaf absent when anonymous source close fails", function(done)
  local repo = git_repo.new()
  local backend, observed = primitive_backend({ write = function(content) return #content end, close = false })
  backend.inspect_target = function() return nil, 2 end
  local result = filesystem.new({ backend = backend }):atomic_write(repo.root, "absent.md", "new")
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "cleanup_required")
  local _, _, renames = observed()
  assert_equal(renames, 0)
  assert_equal(vim.uv.fs_lstat(repo.root .. "/absent.md"), nil)
  repo:cleanup()
  done()
end)

it("preserves a concurrently created absent leaf through no-replace publication", function(done)
  local repo = git_repo.new()
  local backend, observed = primitive_backend({ write = function(content) return #content end, noreplace = false })
  backend.inspect_target = function() return nil, 2 end
  local result = filesystem.new({ backend = backend }):atomic_write(repo.root, "absent.md", "new")
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "path_conflict")
  local _, _, renames = observed()
  assert_equal(renames, 1)
  repo:cleanup()
  done()
end)

it("reports non-EEXIST no-replace publication failure with the staging path", function(done)
  local repo = git_repo.new()
  local backend = primitive_backend({ write = function(content) return #content end })
  backend.inspect_target = function() return nil, 2 end
  backend.rename_noreplace = function() return false, 13 end
  local result = filesystem.new({ backend = backend }):atomic_write(repo.root, "absent.md", "new")
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "cleanup_required")
  assert_equal(result.error.details.reason, 13)
  assert_truthy(result.error.details.path:match("^%.absent%.md%.vigit%-tmp%-"))
  repo:cleanup()
  done()
end)

it("returns conflict when syscall-boundary injection creates a target symlink", function(done)
  local repo = git_repo.new()
  local outside = vim.fn.tempname()
  vim.fn.writefile({ "outside" }, outside)
  local backend = primitive_backend({ write = function(content) return #content end })
  backend.inspect_target = function() return nil, 2 end
  backend.rename_noreplace = function(_, _, leaf)
    assert_equal(leaf, "absent.md")
    assert_equal(vim.uv.fs_symlink(outside, repo.root .. "/absent.md"), true)
    return false, 17
  end
  local result = filesystem.new({ backend = backend }):atomic_write(repo.root, "absent.md", "new")
  assert_equal(result.error.code, "path_conflict")
  assert_equal(read_bytes(outside), "outside\n")
  assert_equal(vim.uv.fs_lstat(repo.root .. "/absent.md").type, "link")
  vim.fn.delete(outside)
  repo:cleanup()
  done()
end)

it("rejects a non-regular existing target before creating a temporary sibling", function(done)
  local repo = git_repo.new()
  repo:write(".vigit/original.md", "original\n")
  local original = read_bytes(repo.root .. "/.vigit/original.md")
  assert_equal(vim.fn.mkdir(repo.root .. "/.vigit/comments.md", "p"), 1)

  local result = filesystem.atomic_write(repo.root, ".vigit/comments.md", "new\n")
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "unsupported_file_type")
  assert_equal(read_bytes(repo.root .. "/.vigit/original.md"), original)
  assert_equal(vim.fn.glob(repo.root .. "/.vigit/.comments.md.vigit-tmp-*"), "")
  repo:cleanup()
  done()
end)

it("rejects existing symlink and FIFO targets without following either", function(done)
  local repo = git_repo.new()
  repo:write("inside.txt", "inside\n")
  repo:symlink("inside.txt", "target-link")
  repo:mkfifo("target-fifo")
  assert_equal(filesystem.atomic_write(repo.root, "target-link", "new\n").error.code, "unsupported_file_type")
  assert_equal(filesystem.atomic_write(repo.root, "target-fifo", "new\n").error.code, "unsupported_file_type")
  repo:cleanup()
  done()
end)

it("renameat replaces an injected target symlink inside the pinned parent without touching its referent", function(done)
  local ffi = require("ffi")
  pcall(ffi.cdef, [[
    int openat(int dirfd, const char *pathname, int flags, ...);
    int renameat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath);
    int close(int fd);
  ]])
  local repo = git_repo.new()
  local outside = vim.fn.tempname()
  repo:write("bound-source", "inside\n")
  local source_bytes = read_bytes(repo.root .. "/bound-source")
  vim.fn.writefile({ "outside" }, outside)
  assert_equal(vim.uv.fs_symlink(outside, repo.root .. "/target"), true)
  local parent = ffi.C.openat(-100, repo.root, 65536 + 524288)
  assert_truthy(parent >= 0)
  assert_equal(tonumber(ffi.C.renameat(parent, "bound-source", parent, "target")), 0)
  ffi.C.close(parent)
  assert_equal(read_bytes(outside), "outside\n")
  assert_equal(read_bytes(repo.root .. "/target"), source_bytes)
  vim.fn.delete(outside)
  repo:cleanup()
  done()
end)

it("returns a typed path-open error for an ENOTDIR parent", function(done)
  local repo = git_repo.new()
  repo:write("not-a-directory", "file\n")
  local result = filesystem.atomic_write(repo.root, "not-a-directory/comments.md", "new\n")
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "path_open_failed")
  repo:cleanup()
  done()
end)

it("retries EINTR, completes partial writes and retries bounded temp collisions", function(done)
  local repo = git_repo.new()
  local writes, attempts = {}, 0
  local backend, observed = primitive_backend({
    write = function(content)
      writes[#writes + 1] = content
      if #writes == 1 then return -1, 4 end
      if #writes == 2 then return 2 end
      return #content
    end,
  })
  backend.link_anonymous = function()
    attempts = attempts + 1
    if attempts == 1 then return false, 17 end
    return true
  end
  local result = filesystem.new({ backend = backend }):atomic_write(repo.root, "nested/comments.md", "abcdef")
  assert_truthy(result.ok)
  assert_equal(#writes, 3)
  assert_equal(writes[1], "abcdef")
  assert_equal(writes[2], "abcdef")
  assert_equal(writes[3], "cdef")
  assert_equal(attempts, 2)
  local closed, cleanup, renames, links = observed()
  assert_truthy(#closed >= 3)
  assert_equal(cleanup, 0)
  assert_equal(renames, 1)
  repo:cleanup()
  done()
end)

it("fails safely without path cleanup when linked temporary cleanup is required", function(done)
  local repo = git_repo.new()
  local backend, observed = primitive_backend({ write = function(content) return #content end, rename = false })
  local result = filesystem.new({ backend = backend }):atomic_write(repo.root, "nested/comments.md", "new")
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "cleanup_required")
  local _, cleanup, renames = observed()
  assert_equal(cleanup, 0)
  assert_equal(renames, 1)
  repo:cleanup()
  done()
end)

it("fails closed when the fd-relative writer ABI is unsupported", function(done)
  local repo = git_repo.new()
  local result = filesystem.new({ platform = "Darwin", arch = "arm64" }):atomic_write(repo.root, "comments.md", "new")
  assert_equal(result.ok, false)
  assert_equal(result.error.code, "secure_write_unavailable")
  repo:cleanup()
  done()
end)

it("rejects symlink parents, traversal and directory deletion outside safe containment", function(done)
  local repo = git_repo.new()
  local outside = vim.fn.tempname()
  assert_equal(vim.fn.mkdir(outside, "p"), 1)
  assert_equal(vim.uv.fs_symlink(outside, repo.root .. "/.vigit"), true)

  local escaped = filesystem.resolve_under(repo.root, ".vigit/comments.md")
  assert_equal(escaped.ok, false)
  assert_equal(escaped.error.code, "path_outside_root")
  assert_equal(filesystem.atomic_write(repo.root, ".vigit/comments.md", "nope\n").error.code, "path_outside_root")
  assert_equal(filesystem.resolve_under(repo.root, "../outside.md").error.code, "invalid_path")

  assert_equal(vim.fn.mkdir(repo.root .. "/directory", "p"), 1)
  local unlinked = filesystem.unlink_under(repo.root, "directory")
  assert_equal(unlinked.ok, false)
  assert_equal(unlinked.error.code, "unsupported_file_type")
  assert_equal(filesystem.unlink_under(repo.root, "../outside").error.code, "invalid_path")
  vim.fn.delete(outside, "rf")
  repo:cleanup()
  done()
end)

it("uses only the synchronous secure unlink capability", function(done)
  local repo = git_repo.new()
  repo:write("victim.txt", "victim\n")
  local async_calls, sync_calls = 0, 0
  local fs = filesystem.new({
    secure_unlink = {
      unlink = function()
        async_calls = async_calls + 1
        error("filesystem must not start an async unlink")
      end,
      unlink_sync = function(_, root, path)
        sync_calls = sync_calls + 1
        assert_equal(root, repo.root)
        assert_equal(path, "victim.txt")
        return Result.err("safe_rejection", "deliberate test rejection")
      end,
    },
  })
  local result = fs:unlink_under(repo.root, "victim.txt")
  assert_equal(result.error.code, "safe_rejection")
  assert_equal(async_calls, 0)
  assert_equal(sync_calls, 1)
  assert_truthy(vim.uv.fs_lstat(repo.root .. "/victim.txt"))
  repo:cleanup()
  done()
end)
