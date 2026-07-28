local Fixture = require("tests.fixtures.git_repo")
local Reviews = require("vigit.application.reviews")
local Legacy = require("vigit.adapters.legacy_review")
local SecureRead = require("vigit.adapters.secure_read")
local Filesystem = require("vigit.adapters.filesystem")
local Result = require("vigit.core.result")

local function worktree_id(root)
  local name = root:match("([^/]+)$")
  return name:gsub("[^%w._-]+", "-") .. "-" .. vim.fn.sha256(root):sub(1, 12)
end

local function write_json(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  assert_equal(vim.fn.writefile({ vim.json.encode(value) }, path), 0)
end

local function legacy_fixture(repo)
  local base = repo.root .. "/.git/vigit/worktrees/" .. worktree_id(repo.root)
  write_json(base .. "/active/draft.json", { schema_version = 2, review_id = "review-old" })
  write_json(base .. "/reviews/review-old/session.json", {
    schema_version = 2, issue_ids = { "VIGIT-001", "VIGIT-002" },
  })
  write_json(base .. "/reviews/review-old/comments/VIGIT-001.json", {
    id = "VIGIT-001", file = "src/one.lua", line = 2, section = "unstaged",
    context = "return one", comment = "Keep existing id.", status = "open",
  })
  write_json(base .. "/reviews/review-old/comments/VIGIT-002.json", {
    id = "VIGIT-002", file = "src/two.lua", line = 4, section = "unstaged",
    context = "return two", comment = "Imported legacy comment.", status = "resolved",
    result = { summary = "Legacy response." },
  })
  return base
end

it("does not inspect legacy storage during normal load and imports only after preview and confirmation", function(done)
  local repo = Fixture.new()
  local ok, message = xpcall(function()
    local legacy_base = legacy_fixture(repo)
    local reviews = Reviews.new()
    local session = { root = repo.root, data = {} }
    local loaded = reviews:load(session)
    assert_truthy(loaded.ok)
    assert_equal(#session.data.comments, 0)
    assert_truthy(reviews:add(session, {
      path = "src/current.lua", line = 1, side = "new", section = "unstaged", context = "current",
    }, "Canonical comment wins.").ok)

    local importer = Legacy.new({ common_git_dir = function() return repo.root .. "/.git" end })
    local preview = reviews:migrate_legacy(session, importer, false)
    assert_truthy(preview.ok)
    assert_equal(preview.value.migrated, false)
    assert_equal(preview.value.preview.importable, 2)
    assert_equal(vim.fn.glob(repo.root .. "/.vigit/backups/*"), "")

    local external = Reviews.new()
    local external_session = { root = repo.root, data = {} }
    assert_truthy(external:load(external_session).ok)
    assert_truthy(external:add(external_session, {
      path = "src/external.lua", line = 3, side = "new", section = "unstaged", context = "external",
    }, "External canonical edit.").ok)
    write_json(legacy_base .. "/active/draft.json", { schema_version = 2, review_id = "review-fresh" })
    write_json(legacy_base .. "/reviews/review-fresh/session.json", {
      schema_version = 2, issue_ids = { "VIGIT-003" },
    })
    write_json(legacy_base .. "/reviews/review-fresh/comments/VIGIT-003.json", {
      id = "VIGIT-003", file = "src/fresh.lua", line = 5, section = "unstaged",
      context = "return fresh", comment = "Fresh legacy issue.", status = "open",
    })

    local migrated = reviews:migrate_legacy(session, importer, true)
    assert_truthy(migrated.ok)
    assert_equal(migrated.value.migrated, true)
    assert_equal(#session.data.comments, 3)
    assert_equal(session.data.comments[1].body, "Canonical comment wins.")
    assert_equal(session.data.comments[2].body, "External canonical edit.")
    assert_equal(session.data.comments[3].body, "Fresh legacy issue.")
    assert_truthy(vim.fn.filereadable(legacy_base .. "/reviews/review-old/comments/VIGIT-002.json") == 1)
    local backup = assert(vim.fn.glob(repo.root .. "/.vigit/backups/*-legacy-review", false, true)[1])
    for _, relative in ipairs({
      "active/draft.json", "reviews/review-fresh/session.json", "reviews/review-fresh/comments/VIGIT-003.json",
    }) do
      local backed = assert(io.open(backup .. "/" .. relative, "rb")):read("*a")
      local source = assert(io.open(legacy_base .. "/" .. relative, "rb")):read("*a")
      assert_equal(backed, source)
    end
  end, debug.traceback)
  repo:cleanup()
  if not ok then error(message, 0) end
  done()
end)

it("rejects a traversal legacy pointer without changing canonical comments", function(done)
  local repo = Fixture.new()
  local ok, message = xpcall(function()
    local base = repo.root .. "/.git/vigit/worktrees/" .. worktree_id(repo.root)
    write_json(base .. "/active/draft.json", { schema_version = 2, review_id = "../escape" })
    local reviews = Reviews.new()
    local session = { root = repo.root, data = {} }
    assert_truthy(reviews:load(session).ok)
    local importer = Legacy.new({ common_git_dir = function() return repo.root .. "/.git" end })
    local failed = reviews:migrate_legacy(session, importer, true)
    assert_equal(failed.ok, false)
    assert_equal(#session.data.comments, 0)
    assert_equal(vim.fn.filereadable(repo.root .. "/.vigit/comments.md"), 0)
  end, debug.traceback)
  repo:cleanup()
  if not ok then error(message, 0) end
  done()
end)

it("uses run then latest legacy pointers only when draft is absent", function(done)
  local repo = Fixture.new()
  local ok, message = xpcall(function()
    local base = repo.root .. "/.git/vigit/worktrees/" .. worktree_id(repo.root)
    write_json(base .. "/active/run.json", { schema_version = 2, review_id = "review-run" })
    write_json(base .. "/reviews/review-run/session.json", { schema_version = 2, issue_ids = {} })
    local importer = Legacy.new({ common_git_dir = function() return repo.root .. "/.git" end })
    local preview = importer:preview(repo.root)
    assert_truthy(preview.ok)
    assert_equal(preview.value.sources[1].relative_path, "active/run.json")
    assert_equal(preview.value.sources[1].bytes, assert(io.open(base .. "/active/run.json", "rb")):read("*a"))

    assert_equal(vim.fn.delete(base .. "/active/run.json"), 0)
    write_json(base .. "/active/latest.json", { schema_version = 2, review_id = "review-latest" })
    write_json(base .. "/reviews/review-latest/session.json", { schema_version = 2, issue_ids = {} })
    preview = importer:preview(repo.root)
    assert_truthy(preview.ok)
    assert_equal(preview.value.sources[1].relative_path, "active/latest.json")
    assert_equal(preview.value.sources[1].bytes, assert(io.open(base .. "/active/latest.json", "rb")):read("*a"))
  end, debug.traceback)
  repo:cleanup()
  if not ok then error(message, 0) end
  done()
end)

it("rejects unsupported legacy schemas and non-list issue IDs", function(done)
  local repo = Fixture.new()
  local ok, message = xpcall(function()
    local base = repo.root .. "/.git/vigit/worktrees/" .. worktree_id(repo.root)
    local importer = Legacy.new({ common_git_dir = function() return repo.root .. "/.git" end })
    write_json(base .. "/active/draft.json", { schema_version = 3, review_id = "review-old" })
    local preview = importer:preview(repo.root)
    assert_equal(preview.ok, false)
    assert_equal(preview.error.code, "unsupported_legacy_schema")

    write_json(base .. "/active/draft.json", { schema_version = 2, review_id = "review-old" })
    write_json(base .. "/reviews/review-old/session.json", { schema_version = 2, issue_ids = { first = "VIGIT-001" } })
    preview = importer:preview(repo.root)
    assert_equal(preview.ok, false)
    assert_equal(preview.error.code, "malformed_legacy")

    write_json(base .. "/reviews/review-old/session.json", { schema_version = 2, issue_ids = { "VIGIT-001" } })
    write_json(base .. "/reviews/review-old/comments/VIGIT-001.json", {
      schema_version = 3, file = "src/one.lua", line = 1, comment = "unsafe schema",
    })
    preview = importer:preview(repo.root)
    assert_equal(preview.ok, false)
    assert_equal(preview.error.code, "unsupported_legacy_schema")
  end, debug.traceback)
  repo:cleanup()
  if not ok then error(message, 0) end
  done()
end)

it("retries a colliding legacy backup directory without overwriting it", function(done)
  local repo = Fixture.new()
  local original_date = os.date
  local ok, message = xpcall(function()
    legacy_fixture(repo)
    local colliding = repo.root .. "/.vigit/backups/20260101T000000Z-fixed-1-legacy-review"
    assert_equal(vim.fn.mkdir(colliding, "p"), 1)
    assert_equal(vim.fn.writefile({ "keep" }, colliding .. "/sentinel"), 0)
    os.date = function() return "20260101T000000Z" end
    local reviews = Reviews.new({ backup_id = function(attempt) return "fixed-" .. attempt end })
    local session = { root = repo.root, data = {} }
    assert_truthy(reviews:load(session).ok)
    local importer = Legacy.new({ common_git_dir = function() return repo.root .. "/.git" end })
    local migrated = reviews:migrate_legacy(session, importer, true)
    assert_truthy(migrated.ok)
    assert_equal(migrated.value.backup_relative, ".vigit/backups/20260101T000000Z-fixed-2-legacy-review")
    assert_equal(vim.fn.readfile(colliding .. "/sentinel")[1], "keep")
  end, debug.traceback)
  os.date = original_date
  repo:cleanup()
  if not ok then error(message, 0) end
  done()
end)

it("keeps canonical state untouched when canonical persistence fails after a legacy backup", function(done)
  local repo = Fixture.new()
  local ok, message = xpcall(function()
    local legacy_base = legacy_fixture(repo)
    local delegate = Filesystem.new()
    local filesystem = {
      resolve_under = function(_, root, relative) return delegate:resolve_under(root, relative) end,
      read = function(_, path) return delegate:read(path) end,
      atomic_write = function(_, root, relative, content)
        if relative == ".vigit/comments.md" then
          return Result.err("write_failed", "Injected canonical write failure")
        end
        return delegate:atomic_write(root, relative, content)
      end,
    }
    local reviews = Reviews.new({ filesystem = filesystem })
    local session = { root = repo.root, data = {} }
    assert_truthy(reviews:load(session).ok)
    local importer = Legacy.new({ common_git_dir = function() return repo.root .. "/.git" end })
    local failed = reviews:migrate_legacy(session, importer, true)
    assert_equal(failed.ok, false)
    assert_equal(failed.error.code, "write_failed")
    assert_equal(session.data.comments_count, 0)
    assert_equal(vim.fn.filereadable(repo.root .. "/.vigit/comments.md"), 0)
    assert_truthy(vim.fn.filereadable(legacy_base .. "/active/draft.json") == 1)
    local backup = assert(vim.fn.glob(repo.root .. "/.vigit/backups/*-legacy-review", false, true)[1])
    for _, relative in ipairs({
      "active/draft.json", "reviews/review-old/session.json",
      "reviews/review-old/comments/VIGIT-001.json", "reviews/review-old/comments/VIGIT-002.json",
    }) do
      assert_equal(
        assert(io.open(backup .. "/" .. relative, "rb")):read("*a"),
        assert(io.open(legacy_base .. "/" .. relative, "rb")):read("*a")
      )
    end
  end, debug.traceback)
  repo:cleanup()
  if not ok then error(message, 0) end
  done()
end)

it("secure reader refuses symlink components and keeps descriptor-relative leaf reads", function(done)
  local repo = Fixture.new()
  local ok, message = xpcall(function()
    local base = repo.root .. "/.git/vigit/worktrees/" .. worktree_id(repo.root)
    repo:write("outside.json", "outside")
    repo:symlink(repo.root .. "/outside.json", ".git/vigit/worktrees/" .. worktree_id(repo.root) .. "/active/draft.json")
    local importer = Legacy.new({ common_git_dir = function() return repo.root .. "/.git" end })
    local preview = importer:preview(repo.root)
    assert_equal(preview.ok, false)
    assert_truthy(preview.error.code == "legacy_not_found" or preview.error.code == "unsafe_legacy_path")

    repo:write("external/inside.json", "outside")
    repo:symlink(repo.root .. "/external", "symlink-dir")
    local real_reader = SecureRead.new()
    local component_read = real_reader:read(repo.root, "symlink-dir/inside.json")
    assert_equal(component_read.ok, false)
    assert_equal(component_read.error.code, "unsafe_legacy_path")

    repo:mkfifo("legacy.fifo")
    local fifo_read = real_reader:read(repo.root, "legacy.fifo")
    assert_equal(fifo_read.ok, false)
    assert_equal(fifo_read.error.code, "unsafe_legacy_path")

    repo:write("safe/secret.json", "inside")
    repo:write("outside/secret.json", "outside-secret")
    local swapped = false
    local pinned_reader = SecureRead.new({
      after_open_directory = function(_, component)
        if component == "safe" and not swapped then
          swapped = true
          assert_equal(vim.fn.rename(repo.root .. "/safe", repo.root .. "/safe-old"), 0)
          repo:symlink(repo.root .. "/outside", "safe")
        end
      end,
    })
    local pinned_read = pinned_reader:read(repo.root .. "/safe", "secret.json")
    assert_truthy(pinned_read.ok)
    assert_equal(vim.trim(pinned_read.value.bytes), "inside")
    assert_truthy(swapped)

    local opened, closed, descriptor_swapped = {}, {}, false
    local reader = SecureRead.new({
      platform = "Linux", arch = "x64", uv = { fs_realpath = function() return "/safe/root" end },
      backend = {
        open_root = function() opened[#opened + 1] = 10; return 10 end,
        open_dir = function(fd, name)
          local next_fd = #opened * 10 + 10
          if name == "comments" then
            assert_equal(fd, 30)
            descriptor_swapped = true
          end
          opened[#opened + 1] = next_fd
          return next_fd
        end,
        open_leaf = function(fd, name, flags)
          assert_equal(fd, 40); assert_equal(name, "VIGIT-001.json"); assert_truthy(descriptor_swapped)
          assert_equal(flags % 4096, 2048)
          opened[#opened + 1] = 50
          return 50
        end,
        stat = function(fd) assert_equal(fd, 50); return { mode = 33188, size = 6 } end,
        read = function(fd, size) assert_equal(fd, 50); assert_equal(size, 6); return 6, "inside" end,
        close = function(fd) closed[#closed + 1] = fd; return true end,
      },
    })
    local read = reader:read("/ignored", "comments/VIGIT-001.json")
    assert_truthy(read.ok)
    assert_equal(read.value.bytes, "inside")
    assert_equal(#opened, 5)
    assert_equal(#closed, 5)

    local unsupported = SecureRead.new({ platform = "Darwin", arch = "arm64", uv = { fs_realpath = function() return "/safe/root" end } })
    local unsupported_read = unsupported:read("/ignored", "comments/VIGIT-001.json")
    assert_equal(unsupported_read.ok, false)
    assert_equal(unsupported_read.error.code, "secure_read_unavailable")
  end, debug.traceback)
  repo:cleanup()
  if not ok then error(message, 0) end
  done()
end)
