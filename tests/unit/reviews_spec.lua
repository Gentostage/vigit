local Result = require("vigit.core.result")
local Reviews = require("vigit.application.reviews")

local canonical_empty = "# Vigit Review\n\n<!-- vigit-format: 1 -->\n"

local function memory_filesystem(initial)
  local files = initial or {}
  local fail_write = false
  return {
    resolve_under = function(_, root, relative)
      return Result.ok(root .. "/" .. relative)
    end,
    read = function(_, path)
      if files[path] == nil then
        return Result.err("not_found", "Comment file does not exist")
      end
      return Result.ok(files[path])
    end,
    atomic_write = function(_, root, relative, content)
      if fail_write then
        return Result.err("write_failed", "Injected comment write failure")
      end
      files[root .. "/" .. relative] = content
      return Result.ok(true)
    end,
    files = files,
    fail_writes = function(value) fail_write = value end,
  }
end

local function session()
  return { root = "/repo", data = { comments = {} } }
end

local function assert_ok(result)
  assert_truthy(result.ok)
  return result.value
end

it("loads a missing canonical comments file as an empty vigit document", function()
  local filesystem = memory_filesystem()
  local reviews = Reviews.new({ filesystem = filesystem })
  local current = session()

  local document = assert_ok(reviews:load(current))

  assert_equal(#document.comments, 0)
  assert_equal(current.data.comments_document, document)
  assert_equal(current.data.comments_count, 0)
  assert_equal(reviews:prompt(current):find("/repo/.vigit/comments.md", 1, true) ~= nil, true)
end)

it("adds writes and reloads a canonical comment", function()
  local filesystem = memory_filesystem()
  local reviews = Reviews.new({ filesystem = filesystem })
  local current = session()
  assert_ok(reviews:load(current))

  local added = assert_ok(reviews:add(current, {
    path = "src/service.lua", line = 14, column = 2, side = "new",
    section = "unstaged", context = "return repository.save(item)",
  }, "Handle RepositoryError."))

  assert_equal(added.id, "VIGIT-001")
  assert_truthy(filesystem.files["/repo/.vigit/comments.md"]:find("Handle RepositoryError.", 1, true))
  local reloaded = assert_ok(reviews:load(current))
  assert_equal(reloaded.comments[1].id, "VIGIT-001")
  assert_equal(current.data.comments_count, 1)
end)

it("uses a configured relative path for storage and prompt instructions", function()
  local filesystem = memory_filesystem()
  local reviews = Reviews.new({ filesystem = filesystem, relative_path = ".custom/review.md" })
  local current = session()
  assert_ok(reviews:load(current))
  assert_ok(reviews:add(current, {
    path = "src/service.lua", line = 14, side = "new", section = "unstaged", context = "return value",
  }, "Write only here."))

  assert_truthy(filesystem.files["/repo/.custom/review.md"]:find("Write only here.", 1, true) ~= nil)
  assert_equal(filesystem.files["/repo/.vigit/comments.md"], nil)
  assert_truthy(reviews:prompt(current):find("/repo/.custom/review.md", 1, true) ~= nil)
end)

it("refuses an invalid injected review path before filesystem access", function()
  local reviews = Reviews.new({ filesystem = memory_filesystem(), relative_path = "../review.md" })
  local loaded = reviews:load(session())

  assert_equal(loaded.ok, false)
  assert_equal(loaded.error.code, "invalid_config")
  assert_truthy(loaded.error.message:find("review.path", 1, true) ~= nil)
end)

it("refreshes external completion and response from canonical markdown", function()
  local filesystem = memory_filesystem({
    ["/repo/.vigit/comments.md"] = table.concat({
      canonical_empty,
      "\n## [x] VIGIT-001 · src/service.lua:14\n\n",
      "<!-- vigit-anchor\npath: src/service.lua\nline: 14\nside: new\nsection: unstaged\ncontext: return value\n-->\n\n",
      "Fix it.\n\n### Ответ агента\n\nDone externally.\n",
    }),
  })
  local reviews = Reviews.new({ filesystem = filesystem })
  local current = session()

  local document = assert_ok(reviews:load(current))

  assert_equal(document.comments[1].done, true)
  assert_equal(document.comments[1].response, "Done externally.")
end)

it("finds the nearest rendered source anchor for a comment", function()
  local reviews = Reviews.new({ filesystem = memory_filesystem() })
  local row = reviews:nearest_anchor({
    { path = "src/service.lua", section = "unstaged", side = "new", source_line = 5 },
    { path = "src/service.lua", section = "unstaged", side = "old", source_line = 14 },
    { path = "src/service.lua", section = "unstaged", side = "new", source_line = 15 },
  }, {
    path = "src/service.lua", section = "unstaged", side = "new", line = 14,
  })

  assert_equal(row, 3)
end)

it("preserves the installed session document when comment persistence fails", function()
  local filesystem = memory_filesystem()
  local reviews = Reviews.new({ filesystem = filesystem })
  local current = session()
  local original = assert_ok(reviews:load(current))
  filesystem.fail_writes(true)

  local failed = reviews:add(current, {
    path = "src/service.lua", line = 14, side = "new", section = "unstaged", context = "return value",
  }, "Must not replace state.")

  assert_equal(failed.ok, false)
  assert_equal(current.data.comments_document, original)
  assert_equal(current.data.comments_count, 0)
end)

it("mutates the freshly reread canonical document and retains external changes", function()
  local filesystem = memory_filesystem()
  local reviews = Reviews.new({ filesystem = filesystem })
  local current = session()
  assert_ok(reviews:load(current))
  assert_ok(reviews:add(current, {
    path = "src/service.lua", line = 14, side = "new", section = "unstaged", context = "return value",
  }, "Cached body."))

  local review = require("vigit.core.review")
  local external = assert_ok(review.parse(filesystem.files["/repo/.vigit/comments.md"]))
  external = assert_ok(review.update(external, "VIGIT-001", { done = true, response = "External answer." }))
  external = assert_ok(review.add(external, {
    path = "src/external.lua", line = 3, side = "new", section = "unstaged", context = "external", body = "Added externally.",
  }))
  filesystem.files["/repo/.vigit/comments.md"] = review.serialize(external)

  assert_ok(reviews:update(current, "VIGIT-001", "Fresh local body."))

  assert_equal(#current.data.comments, 2)
  assert_equal(current.data.comments[1].body, "Fresh local body.")
  assert_equal(current.data.comments[1].done, true)
  assert_equal(current.data.comments[1].response, "External answer.")
  assert_equal(current.data.comments[2].body, "Added externally.")
end)

it("leaves partial legacy backups but never installs canonical comments after a backup failure", function()
  local filesystem = memory_filesystem()
  local original_write = filesystem.atomic_write
  filesystem.atomic_write = function(self, root, relative, content)
    if relative:find("session.json", 1, true) then
      return Result.err("backup_failed", "Injected legacy backup failure")
    end
    return original_write(self, root, relative, content)
  end
  local reviews = Reviews.new({ filesystem = filesystem, backup_id = function() return "test" end })
  local current = session()
  assert_ok(reviews:load(current))
  local legacy = {
    preview = function()
      return Result.ok({
        comments = {
          {
            id = "VIGIT-001", path = "src/a.lua", line = 1, column = 0,
            side = "new", section = "unstaged", context = "line", body = "Import me.",
          },
        },
        sources = {
          { relative_path = "active/draft.json", bytes = "pointer-bytes" },
          { relative_path = "reviews/review-old/session.json", bytes = "session-bytes" },
        },
      })
    end,
  }

  local original_vim = _G.vim
  _G.vim = { uv = { fs_lstat = function() return nil end } }
  local failed = reviews:migrate_legacy(current, legacy, true)
  _G.vim = original_vim

  assert_equal(failed.ok, false)
  assert_equal(failed.error.code, "backup_failed")
  assert_equal(current.data.comments_count, 0)
  assert_equal(filesystem.files["/repo/.vigit/comments.md"], nil)
  local backup
  for path, bytes in pairs(filesystem.files) do
    if path:find("/active/draft.json", 1, true) then backup = bytes end
  end
  assert_equal(backup, "pointer-bytes")
end)

it("builds a prompt from only open comments and contains no execution instruction", function()
  local filesystem = memory_filesystem()
  local reviews = Reviews.new({ filesystem = filesystem })
  local current = session()
  assert_ok(reviews:load(current))
  assert_ok(reviews:add(current, {
    path = "src/open.lua", line = 2, side = "new", section = "unstaged", context = "open",
  }, "Open only."))
  assert_ok(reviews:add(current, {
    path = "src/done.lua", line = 3, side = "new", section = "unstaged", context = "done",
  }, "Done."))
  assert_ok(reviews:update(current, "VIGIT-002", "Done.", { done = true }))

  local prompt = reviews:prompt(current)
  assert_truthy(prompt:find("VIGIT-001", 1, true))
  assert_equal(prompt:find("VIGIT-002", 1, true), nil)
  assert_truthy(prompt:find("/repo/.vigit/comments.md", 1, true))
  assert_truthy(prompt:find("не stage, commit или push", 1, true))
end)
