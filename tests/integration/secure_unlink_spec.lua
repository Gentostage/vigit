local SecureUnlink = require("vigit.adapters.secure_unlink")
local git_repo = dofile("tests/fixtures/git_repo.lua")

it("pins the verified parent descriptor when its pathname is replaced", function(done)
  local repo = git_repo.new()
  repo:write("inside/victim.txt", "inside\n")
  repo:write("outside/victim.txt", "outside\n")
  local unlinker = SecureUnlink.new({
    after_parent_verified = function()
      assert_equal(vim.uv.fs_rename(repo.root .. "/inside", repo.root .. "/inside-old"), true)
      assert_equal(vim.uv.fs_symlink("outside", repo.root .. "/inside"), true)
    end,
  })

  unlinker:unlink(repo.root, "inside/victim.txt", function(result)
    assert_truthy(result.ok)
    assert_equal(vim.uv.fs_lstat(repo.root .. "/inside-old/victim.txt"), nil)
    assert_truthy(vim.uv.fs_lstat(repo.root .. "/outside/victim.txt"))
    repo:cleanup()
    done()
  end)
end)

it("fails closed on an unsupported Linux FFI architecture before opening a parent", function(done)
  local calls = 0
  local unlinker = SecureUnlink.new({
    arch = "arm64",
    backend = {
      open_parent = function()
        calls = calls + 1
        error("unsupported architecture must not invoke a syscall")
      end,
    },
  })

  unlinker:unlink("/tmp", "candidate.txt", function(result)
    assert_equal(result.ok, false)
    assert_equal(result.error.code, "secure_unlink_unavailable")
    assert_equal(calls, 0)
    done()
  end)
end)
