local patch = require("vigit.core.patch")

local function count_hunk_headers(value)
  local count = 0
  for _ in value:gmatch("\n@@ ") do
    count = count + 1
  end
  return value:match("^@@ ") and count + 1 or count
end

local function file_diff(change, headers, hunks, binary)
  return {
    id = change.id,
    change = change,
    section = change.section,
    status = change.status,
    path = change.path,
    old_path = change.old_path,
    headers = headers,
    hunks = hunks or {},
    binary = binary or false,
  }
end

local function hunk(change, suffix, lines)
  return {
    id = change.id .. "\0" .. suffix,
    header = lines[1],
    patch = table.concat(lines, "\n"),
  }
end

it("builds a modified-file patch for exactly the selected hunk", function()
  local change = {
    id = "unstaged\0lib/a.lua",
    section = "unstaged",
    status = "M",
    path = "lib/a.lua",
  }
  local selected = hunk(change, "10:10", {
    "@@ -10,2 +10,2 @@",
    " old",
    "-before",
    "+after",
  })
  local other = hunk(change, "40:40", {
    "@@ -40 +40 @@",
    "-old",
    "+new",
  })
  local result = patch.for_hunk(file_diff(change, {
    "diff --git a/lib/a.lua b/lib/a.lua",
    "index 1111111..2222222 100644",
    "--- a/lib/a.lua",
    "+++ b/lib/a.lua",
  }, { selected, other }), selected)

  assert_truthy(result.ok)
  assert_truthy(result.value:match("diff %-%-git a/lib/a%.lua b/lib/a%.lua"))
  assert_truthy(result.value:match("index 1111111%.%.2222222 100644"))
  assert_truthy(result.value:match("@@ %-10,2 %+10,2 @@"))
  assert_equal(count_hunk_headers(result.value), 1)
  assert_equal(result.value:match("@@ %-40 %+40 @@"), nil)
end)

it("preserves added-file metadata and its selected hunk", function()
  local change = {
    id = "staged\0new.lua",
    section = "staged",
    status = "A",
    path = "new.lua",
  }
  local selected = hunk(change, "0:1", {
    "@@ -0,0 +1,2 @@",
    "+first",
    "+second",
  })
  local result = patch.for_hunk(file_diff(change, {
    "diff --git a/new.lua b/new.lua",
    "new file mode 100644",
    "index 0000000..1111111",
    "--- /dev/null",
    "+++ b/new.lua",
  }, { selected }), selected)

  assert_truthy(result.ok)
  assert_truthy(result.value:match("new file mode 100644"))
  assert_truthy(result.value:match("%-%-%- /dev/null"))
  assert_truthy(result.value:match("%+%+%+ b/new%.lua"))
end)

it("preserves deleted-file metadata and its selected hunk", function()
  local change = {
    id = "unstaged\0gone.lua",
    section = "unstaged",
    status = "D",
    path = "gone.lua",
  }
  local selected = hunk(change, "1:0", {
    "@@ -1,2 +0,0 @@",
    "-first",
    "-second",
  })
  local result = patch.for_hunk(file_diff(change, {
    "diff --git a/gone.lua b/gone.lua",
    "deleted file mode 100644",
    "index 1111111..0000000",
    "--- a/gone.lua",
    "+++ /dev/null",
  }, { selected }), selected)

  assert_truthy(result.ok)
  assert_truthy(result.value:match("deleted file mode 100644"))
  assert_truthy(result.value:match("%+%+%+ /dev/null"))
end)

it("preserves rename metadata and exactly one selected hunk", function()
  local change = {
    id = "unstaged\0new/a.lua",
    section = "unstaged",
    status = "R",
    old_path = "old/a.lua",
    path = "new/a.lua",
  }
  local selected = hunk(change, "10:10", {
    "@@ -10,2 +10,3 @@",
    " old",
    "-before",
    "+after",
    "+more",
  })
  local other = hunk(change, "40:41", {
    "@@ -40 +41 @@",
    "-old",
    "+new",
  })
  local result = patch.for_hunk(file_diff(change, {
    "diff --git a/old/a.lua b/new/a.lua",
    "similarity index 97%",
    "rename from old/a.lua",
    "rename to new/a.lua",
    "index 1111111..2222222 100644",
    "--- a/old/a.lua",
    "+++ b/new/a.lua",
  }, { selected, other }), selected)

  assert_truthy(result.ok)
  assert_truthy(result.value:match("diff %-%-git a/old/a%.lua b/new/a%.lua"))
  assert_truthy(result.value:match("rename from old/a%.lua"))
  assert_truthy(result.value:match("@@ %-10,2 %+10,3 @@"))
  assert_equal(count_hunk_headers(result.value), 1)
end)

it("normalizes a staged rename into a current-path patch for reverse apply", function()
  local change = {
    id = "staged\0new name.txt",
    section = "staged",
    status = "R",
    old_path = "old name.txt",
    path = "new name.txt",
  }
  local selected = hunk(change, "2:2", {
    "@@ -1,3 +1,3 @@",
    " one",
    "-two",
    "+two renamed",
    " three",
  })
  local result = patch.for_hunk(file_diff(change, {
    "diff --git a/old name.txt b/new name.txt",
    "similarity index 53%",
    "rename from old name.txt",
    "rename to new name.txt",
    "index 1111111..2222222 100644",
    "--- a/old name.txt",
    "+++ b/new name.txt",
  }, { selected }), selected, { normalize_rename_for_reverse = true })

  assert_truthy(result.ok)
  assert_truthy(result.value:match('diff %-%-git "a/new name%.txt" "b/new name%.txt"'))
  assert_truthy(result.value:match('%-%-%- "a/new name%.txt"'))
  assert_truthy(result.value:match('%+%+%+ "b/new name%.txt"'))
  assert_equal(result.value:match("rename from"), nil)
  assert_equal(result.value:match("old name"), nil)
  assert_equal(count_hunk_headers(result.value), 1)
end)

it("preserves the no-newline marker attached to the selected hunk", function()
  local change = {
    id = "unstaged\0note.txt",
    section = "unstaged",
    status = "M",
    path = "note.txt",
  }
  local selected = hunk(change, "1:1", {
    "@@ -1 +1 @@",
    "-old",
    "\\ No newline at end of file",
    "+new",
    "\\ No newline at end of file",
  })
  local result = patch.for_hunk(file_diff(change, {
    "diff --git a/note.txt b/note.txt",
    "index 1111111..2222222 100644",
    "--- a/note.txt",
    "+++ b/note.txt",
  }, { selected }), selected)

  assert_truthy(result.ok)
  assert_equal(select(2, result.value:gsub("\\ No newline at end of file", "")), 2)
end)

it("marks a selected hunk without context for Git unidiff-zero", function()
  local no_context = {
    patch = "@@ -2 +2 @@\n-two\n+two staged",
  }
  local with_context = {
    patch = "@@ -1,3 +1,3 @@\n one\n-two\n+two staged\n three",
  }

  assert_equal(patch.needs_unidiff_zero(no_context), true)
  assert_equal(patch.needs_unidiff_zero(with_context), false)
end)

it("rejects binary and metadata-only diffs as unsupported hunks", function()
  local change = {
    id = "unstaged\0image.png",
    section = "unstaged",
    status = "M",
    path = "image.png",
  }
  local selected = hunk(change, "1:1", { "@@ -1 +1 @@", "-old", "+new" })
  local binary = patch.for_hunk(file_diff(change, {
    "diff --git a/image.png b/image.png",
    "Binary files a/image.png and b/image.png differ",
  }, { selected }, true), selected)
  local metadata_only = patch.for_hunk(file_diff(change, {
    "diff --git a/image.png b/image.png",
    "old mode 100644",
    "new mode 100755",
  }), selected)

  assert_equal(binary.ok, false)
  assert_equal(binary.error.code, "unsupported_hunk")
  assert_equal(metadata_only.ok, false)
  assert_equal(metadata_only.error.code, "unsupported_hunk")
end)

it("rejects a hunk that no longer belongs to the current file diff", function()
  local change = {
    id = "unstaged\0current.lua",
    section = "unstaged",
    status = "M",
    path = "current.lua",
  }
  local current = hunk(change, "1:1", { "@@ -1 +1 @@", "-old", "+new" })
  local stale = {
    id = "unstaged\0other.lua\0" .. "1:1",
    header = current.header,
    patch = current.patch,
  }
  local result = patch.for_hunk(file_diff(change, {
    "diff --git a/current.lua b/current.lua",
    "--- a/current.lua",
    "+++ b/current.lua",
  }, { current }), stale)

  assert_equal(result.ok, false)
  assert_equal(result.error.code, "stale_hunk")
end)
