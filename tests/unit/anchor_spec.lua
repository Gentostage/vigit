local anchor = require("vigit.core.anchor")

local function row(kind, source_anchor)
  return {
    text = kind,
    kind = kind,
    change_id = "unstaged\0src/a.lua",
    hunk_id = source_anchor.hunk_id,
    source_anchor = source_anchor,
  }
end

local function source(overrides)
  local value = {
    path = "src/a.lua",
    section = "unstaged",
    side = "new",
    source_line = 12,
    column = 0,
    context = "return value",
    hunk_id = "h1",
  }
  for key, nested in pairs(overrides or {}) do
    value[key] = nested
  end
  return value
end

it("нормализует SourceAnchor из marker-free строки", function()
  assert_equal(anchor.from_row({
    path = "src/a.lua",
    section = "unstaged",
    kind = "add",
    text = "   return   value   ",
    new_line = 12,
    hunk_id = "h1",
  }, 4), {
    path = "src/a.lua",
    section = "unstaged",
    side = "new",
    source_line = 12,
    column = 4,
    context = "return value",
    hunk_id = "h1",
  })
end)

it("строит old-side anchor для удалённой строки", function()
  local deletion = anchor.from_row({
    path = "src/a.lua",
    section = "unstaged",
    kind = "delete",
    text = "-value",
    old_line = 9,
    hunk_id = "h1",
  }, 2)

  assert_equal(deletion.side, "old")
  assert_equal(deletion.source_line, 9)
  assert_equal(deletion.context, "-value")

  local rows = {
    row("add", source({ source_line = 9, context = "replacement" })),
    row("delete", source({
      side = "old",
      source_line = 9,
      context = "-value",
    })),
  }
  assert_equal(anchor.match(rows, deletion), 2)
end)

it("соблюдает приоритет exact, context и nearest hunk", function()
  local target = source()
  local rows = {
    row("line", source({
      source_line = 10,
      context = "near hunk",
    })),
    row("line", source({
      source_line = 15,
      context = "return value",
      hunk_id = "h2",
    })),
    row("line", source({
      source_line = 12,
      context = "exact line",
    })),
    row("line", source({
      source_line = 11,
      context = "other file",
      path = "src/b.lua",
    })),
  }

  assert_equal(anchor.match(rows, target), 3)
  rows[3].source_anchor.source_line = 13
  assert_equal(anchor.match(rows, target), 2)
  rows[2].source_anchor.context = "changed"
  assert_equal(anchor.match(rows, target), 3)
end)

it("выбирает ближайшую строку того же файла после потери hunk", function()
  local rows = {
    row("line", source({
      source_line = 30,
      context = "far",
      hunk_id = "h2",
    })),
    row("line", source({
      source_line = 14,
      context = "near",
      hunk_id = "h3",
    })),
    row("line", source({
      source_line = 12,
      context = "wrong file",
      path = "src/b.lua",
      hunk_id = "h1",
    })),
  }

  assert_equal(anchor.match(rows, source({ context = "missing" })), 2)
end)

it("возвращает заголовок файла как последний fallback", function()
  local rows = {
    row("file_header", source({
      side = nil,
      source_line = nil,
      context = nil,
      hunk_id = nil,
    })),
    row("line", source({
      path = "src/b.lua",
      source_line = 12,
      context = "return value",
    })),
  }

  assert_equal(anchor.match(rows, source({ context = "missing" })), 1)
end)

it("не переносит old-side комментарий на new-side строку в строгом режиме", function()
  local target = source({
    side = "old",
    source_line = 9,
    context = "removed value",
  })
  local rows = {
    row("add", source({
      side = "new",
      source_line = 9,
      context = "replacement value",
    })),
    row("file_header", source({
      side = nil,
      source_line = nil,
      context = nil,
      hunk_id = nil,
    })),
  }

  assert_equal(anchor.match(rows, target), 1)
  assert_equal(anchor.match(rows, target, { strict_side = true }), nil)
end)
