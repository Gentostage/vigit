local Fixture = require("tests.fixtures.git_repo")
local Result = require("vigit.core.result")
local Session = require("vigit.ui.session")
local controller = require("vigit.ui.controller")
local layout = require("vigit.ui.layout")
local renderer = require("vigit.ui.renderer")
local treesitter = require("vigit.adapters.treesitter")
local highlights = require("vigit.ui.highlights")

local function buffer_lines(buffer)
  return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
end

local function find_row(buffer, text)
  for row, line in ipairs(buffer_lines(buffer)) do
    if line:find(text, 1, true) then
      return row
    end
  end
end

local function extmarks(buffer, namespace)
  return vim.api.nvim_buf_get_extmarks(
    buffer,
    namespace or -1,
    0,
    -1,
    { details = true }
  )
end

local function find_extmark(buffer, namespace, row, predicate)
  for _, extmark in ipairs(extmarks(buffer, namespace)) do
    if extmark[2] == row - 1 and predicate(extmark[4]) then
      return extmark[4]
    end
  end
end

local function has_group(buffer, namespace, row, group)
  return find_extmark(buffer, namespace, row, function(details)
    return details.hl_group == group
      or details.line_hl_group == group
      or details.sign_hl_group == group
  end)
end

local function has_virtual_text(buffer, text)
  for _, extmark in ipairs(extmarks(buffer, -1)) do
    for _, chunk in ipairs(extmark[4].virt_text or {}) do
      if chunk[1]:find(text, 1, true) then
        return true
      end
    end
  end
  return false
end

local function syntax_extmarks(buffer, namespace, row, groups)
  local result = {}
  for _, extmark in ipairs(extmarks(buffer, namespace)) do
    local details = extmark[4]
    if extmark[2] == row - 1 and groups[details.hl_group] then
      details.extmark_id = extmark[1]
      result[#result + 1] = details
    end
  end
  table.sort(result, function(first, second)
    return first.extmark_id < second.extmark_id
  end)
  return result
end

local function close_session(session)
  if session and not session.closed then
    renderer.clear(session)
    layout.close(session)
  end
end

local function manual_inspection(captures, symbols)
  return {
    language = "python",
    captures = captures or {},
    symbols = symbols or {},
  }
end

it("resolves undefined language captures to colorscheme groups", function()
  local namespace = vim.api.nvim_create_namespace("vigit-test-syntax-fallback")
  local buffer = vim.api.nvim_create_buf(false, true)
  local groups = {
    ["@keyword.import.python"] = vim.api.nvim_get_hl(0, {
      name = "@keyword.import.python",
      link = true,
    }),
    ["@keyword.import"] = vim.api.nvim_get_hl(0, {
      name = "@keyword.import",
      link = true,
    }),
    ["@keyword"] = vim.api.nvim_get_hl(0, {
      name = "@keyword",
      link = true,
    }),
  }

  local ok, message = xpcall(function()
    vim.api.nvim_set_hl(0, "@keyword.import.python", { fg = 0xff0000 })
    vim.api.nvim_set_hl(0, "@keyword.import", {})
    vim.api.nvim_set_hl(0, "@keyword", { fg = 0xc678dd })
    local rendered = {
      lines = { "from package import value" },
      rows = {
        {
          text = "from package import value",
          kind = "context",
          change_id = "unstaged\0module.py",
          source_anchor = { side = "new", source_line = 1 },
        },
      },
    }
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, rendered.lines)

    highlights.apply_diff(buffer, rendered, {
      ["unstaged\0module.py"] = {
        new = manual_inspection({
          {
            group = "@keyword.import.python",
            start_row = 0,
            start_col = 0,
            end_row = 0,
            end_col = 4,
          },
          {
            group = "@none.python",
            start_row = 0,
            start_col = 5,
            end_row = 0,
            end_col = 12,
          },
        }),
      },
    }, namespace)

    local fallback = assert(find_extmark(
      buffer,
      namespace,
      1,
      function(details)
        return details.hl_group == "@keyword"
      end
    ))
    assert_equal(fallback.priority, highlights.priorities.syntax)
    assert_equal(#syntax_extmarks(buffer, namespace, 1, {
      ["@none"] = true,
      ["@none.python"] = true,
    }), 0)
  end, debug.traceback)

  for name, definition in pairs(groups) do
    vim.api.nvim_set_hl(0, name, definition)
  end
  pcall(vim.api.nvim_buf_delete, buffer, { force = true })
  if not ok then
    error(message, 0)
  end
end)

it("maps old/new captures onto marker-free rows with layered priorities", function()
  local namespace = vim.api.nvim_create_namespace("vigit-test-syntax-layers")
  local buffer = vim.api.nvim_create_buf(false, true)
  local change_id = "unstaged\0service.py"
  local current_delete = vim.api.nvim_get_hl(0, {
    name = "DiffDelete",
    link = false,
  })
  assert_equal(current_delete.bg, nil)

  local source_groups = {
    DiffAdd = vim.api.nvim_get_hl(0, { name = "DiffAdd", link = true }),
    DiffDelete = vim.api.nvim_get_hl(0, {
      name = "DiffDelete",
      link = true,
    }),
  }
  local original_background = vim.o.background
  local setup_ok, setup_message = xpcall(function()
    vim.o.background = "dark"
    vim.api.nvim_set_hl(0, "DiffAdd", {
      fg = 0xfefefe,
      bg = 0x112233,
      bold = true,
    })
    vim.api.nvim_set_hl(0, "DiffDelete", {
      fg = 0xff0000,
      italic = true,
    })
    vim.api.nvim_set_hl(0, "VigitDiffAddLine", { link = "DiffAdd" })
    vim.api.nvim_set_hl(0, "VigitDiffDeleteLine", {
      link = "DiffDelete",
    })
    highlights.setup()

    local add_line = vim.api.nvim_get_hl(0, {
      name = "VigitDiffAddLine",
      link = false,
    })
    local delete_line = vim.api.nvim_get_hl(0, {
      name = "VigitDiffDeleteLine",
      link = false,
    })
    assert_equal(add_line.bg, 0x112233)
    assert_equal(add_line.fg, nil)
    assert_equal(add_line.bold, nil)
    assert_equal(delete_line.bg, 0x3b2426)
    assert_equal(delete_line.fg, nil)
    assert_equal(delete_line.italic, nil)

    vim.o.background = "light"
    highlights.setup()
    delete_line = vim.api.nvim_get_hl(0, {
      name = "VigitDiffDeleteLine",
      link = false,
    })
    assert_equal(delete_line.bg, 0xf6d6d8)
    assert_equal(delete_line.fg, nil)
  end, debug.traceback)
  vim.o.background = original_background
  for name, definition in pairs(source_groups) do
    vim.api.nvim_set_hl(0, name, definition)
  end
  highlights.setup()
  if not setup_ok then
    error(setup_message, 0)
  end

  local rendered = {
    lines = {
      "def execute(self):",
      "async def execute(self):",
      "  return value",
    },
    rows = {
      {
        text = "def execute(self):",
        kind = "delete",
        change_id = change_id,
        source_anchor = { side = "old", source_line = 2 },
      },
      {
        text = "async def execute(self):",
        kind = "add",
        change_id = change_id,
        source_anchor = { side = "new", source_line = 2 },
      },
      {
        text = "  return value",
        kind = "context",
        change_id = change_id,
        source_anchor = { side = "new", source_line = 3 },
      },
    },
  }
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, rendered.lines)

  highlights.apply_diff(buffer, rendered, {
    [change_id] = {
      old = manual_inspection({
        {
          group = "@keyword.function.python",
          start_row = 1,
          start_col = 0,
          end_row = 1,
          end_col = 3,
        },
      }),
      new = manual_inspection({
        {
          group = "@keyword.function.python",
          start_row = 1,
          start_col = 6,
          end_row = 1,
          end_col = 9,
        },
        {
          group = "@keyword.return.python",
          start_row = 2,
          start_col = 2,
          end_row = 2,
          end_col = 8,
        },
        {
          group = "@variable.python",
          ordinal = 3,
          start_row = 1,
          start_col = 12,
          end_row = 1,
          end_col = 19,
        },
        {
          group = "@type.python",
          ordinal = 4,
          start_row = 1,
          start_col = 12,
          end_row = 1,
          end_col = 19,
        },
        {
          group = "@function.method.python",
          ordinal = 5,
          priority = 125,
          start_row = 1,
          start_col = 12,
          end_row = 1,
          end_col = 19,
        },
      }),
    },
  }, namespace)

  local delete_background = assert(find_extmark(
    buffer,
    namespace,
    1,
    function(details)
      return details.line_hl_group == "VigitDiffDeleteLine"
    end
  ))
  local add_background = assert(find_extmark(
    buffer,
    namespace,
    2,
    function(details)
      return details.line_hl_group == "VigitDiffAddLine"
    end
  ))
  local delete_sign = assert(find_extmark(
    buffer,
    namespace,
    1,
    function(details)
      return details.sign_hl_group == "VigitDiffDeleteSign"
    end
  ))
  local add_sign = assert(find_extmark(
    buffer,
    namespace,
    2,
    function(details)
      return details.sign_hl_group == "VigitDiffAddSign"
    end
  ))
  local deleted_keyword = assert(has_group(
    buffer,
    namespace,
    1,
    "@keyword"
  ))
  local added_keyword = assert(has_group(
    buffer,
    namespace,
    2,
    "@keyword"
  ))
  assert_truthy(has_group(
    buffer,
    namespace,
    3,
    "@keyword"
  ))
  assert_equal(delete_background.priority, highlights.priorities.background)
  assert_equal(add_background.priority, highlights.priorities.background)
  assert_equal(delete_sign.priority, highlights.priorities.sign)
  assert_equal(add_sign.priority, highlights.priorities.sign)
  assert_equal(deleted_keyword.priority, highlights.priorities.syntax)
  assert_equal(added_keyword.priority, highlights.priorities.syntax)
  local overlaps = syntax_extmarks(buffer, namespace, 2, {
    ["@variable"] = true,
    ["@type"] = true,
    ["@function"] = true,
  })
  assert_equal(#overlaps, 3)
  assert_equal(overlaps[1].hl_group, "@variable")
  assert_equal(overlaps[1].priority, highlights.priorities.syntax)
  assert_equal(overlaps[2].hl_group, "@type")
  assert_equal(overlaps[2].priority, highlights.priorities.syntax)
  assert_equal(overlaps[3].hl_group, "@function")
  assert_equal(overlaps[3].priority, 125)
  assert_truthy(highlights.priorities.overlay > 150)
  assert_equal(rendered.lines[1]:sub(1, 1), "d")
  assert_equal(rendered.lines[2]:sub(1, 1), "a")

  local unavailable = treesitter.inspect({
    path = "service.vigit-no-parser",
    source = "value",
    max_bytes = 1024,
  })
  assert_equal(unavailable.ok, false)
  assert_equal(unavailable.error.code, "parser_unavailable")
  local oversized = treesitter.inspect({
    path = "service.py",
    source = "value",
    max_bytes = 4,
  })
  assert_equal(oversized.ok, false)
  assert_equal(oversized.error.code, "source_too_large")

  local repo = Fixture.new()
  local session
  local ok, message = xpcall(function()
    repo:write("service.py", {
      "class PaymentService:",
      "  def execute(self):",
      "    return \"old\"",
    })
    repo:git({ "add", "--", "service.py" })
    repo:commit("initial")
    repo:write("service.py", {
      "class PaymentService:",
      "  async def execute(self):",
      "    return \"new\"",
    })

    session = assert(require("vigit.v2").open({ cwd = repo.root }))
    assert_truthy(vim.wait(2000, function()
      return session.data.status
        and session.data.status.unstaged
        and session.data.status.unstaged[1]
    end, 10))
    local change = session.data.status.unstaged[1]
    controller.dispatch(session, {
      name = "select_change",
      change_id = change.id,
    })
    assert_truthy(vim.wait(2000, function()
      return session.data.diffs[change.id] ~= nil
        and find_row(session.owned.diff_buf, "async def execute")
        and find_row(session.owned.diff_buf, "def execute")
    end, 10))

    local added = assert(find_row(session.owned.diff_buf, "async def execute"))
    local deleted
    for row, line in ipairs(buffer_lines(session.owned.diff_buf)) do
      if line:find("def execute", 1, true)
          and not line:find("async def execute", 1, true) then
        deleted = row
        break
      end
    end
    assert_truthy(deleted)
    assert_truthy(buffer_lines(session.owned.diff_buf)[added]:sub(1, 1) ~= "+")
    assert_truthy(buffer_lines(session.owned.diff_buf)[deleted]:sub(1, 1) ~= "-")

    local parsed = treesitter.inspect({
      path = "service.py",
      source = table.concat({
        "class PaymentService:",
        "  async def execute(self):",
        "    return \"new\"",
        "",
        "def helper():",
        "  return None",
      }, "\n"),
      max_bytes = 1024,
    })
    if not parsed.ok and parsed.error.code == "parser_unavailable" then
      io.stdout:write("SKIP python parser/query unavailable; render assertion passed\n")
      io.stdout:flush()
      return
    end
    assert_truthy(parsed.ok)
    local symbols = {}
    for _, symbol in ipairs(parsed.value.symbols) do
      symbols[symbol.label] = symbol.kind
    end
    assert_equal(symbols.PaymentService, "class")
    assert_equal(symbols["PaymentService.execute()"], "method")
    assert_equal(symbols["helper()"], "function")

    local original_query_get = vim.treesitter.query.get
    local query_ok, ordered = xpcall(function()
      local query = vim.treesitter.query.parse("python", table.concat({
        "(identifier) @variable",
        "(identifier) @type",
        "((identifier) @function.method",
        "  (#set! @function.method priority 121))",
        "((identifier) @function",
        "  (#set! priority 122))",
      }, "\n"))
      vim.treesitter.query.get = function(language, name)
        if language == "python" and name == "highlights" then
          return query
        end
        return original_query_get(language, name)
      end
      return treesitter.inspect({
        path = "ordered.py",
        source = "value",
        max_bytes = 1024,
      })
    end, debug.traceback)
    vim.treesitter.query.get = original_query_get
    if not query_ok then
      error(ordered, 0)
    end
    assert_truthy(ordered.ok)
    local expected_groups = {
      "@variable.python",
      "@type.python",
      "@function.method.python",
      "@function.python",
    }
    local expected_priorities = { nil, nil, 121, 122 }
    for index, capture in ipairs(ordered.value.captures) do
      assert_equal(capture.group, expected_groups[index])
      assert_equal(capture.ordinal, index)
      assert_equal(capture.priority, expected_priorities[index])
    end
    assert_equal(#ordered.value.captures, #expected_groups)

    assert_truthy(vim.wait(2000, function()
      return has_group(
        session.owned.diff_buf,
        -1,
        added,
        "@keyword"
      ) and has_group(
        session.owned.diff_buf,
        -1,
        deleted,
        "@keyword"
      )
    end, 10))
    assert_truthy(has_group(
      session.owned.diff_buf,
      -1,
      added,
      "VigitDiffAddSign"
    ))
    assert_truthy(has_group(
      session.owned.diff_buf,
      -1,
      deleted,
      "VigitDiffDeleteSign"
    ))
  end, debug.traceback)

  close_session(session)
  repo:cleanup()
  vim.api.nvim_buf_delete(buffer, { force = true })
  if not ok then
    error(message, 0)
  end
end)

it("labels only hidden declarations and discards stale scheduled inspection", function()
  local namespace = vim.api.nvim_create_namespace("vigit-test-symbol-context")
  local buffer = vim.api.nvim_create_buf(false, true)
  local change_id = "unstaged\0service.py"
  local symbol = {
    kind = "method",
    name = "execute",
    label = "PaymentService.execute()",
    start_row = 1,
    end_row = 5,
    declaration_row = 1,
  }
  local inspections = {
    [change_id] = {
      new = manual_inspection({}, { symbol }),
    },
  }
  local hidden = {
    lines = { "… 3 unchanged lines …" },
    rows = {
      {
        text = "… 3 unchanged lines …",
        kind = "gap",
        change_id = change_id,
        source_anchor = { side = "new", source_line = 4 },
      },
    },
  }
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, hidden.lines)
  highlights.apply_diff(buffer, hidden, inspections, namespace)
  local context = assert(find_extmark(
    buffer,
    namespace,
    1,
    function(details)
      return details.virt_text
        and details.virt_text[1]
        and details.virt_text[1][1]:find(
          "PaymentService.execute()",
          1,
          true
        )
    end
  ))
  assert_equal(context.priority, highlights.priorities.symbol)

  local visible = {
    lines = {
      "  def execute(self):",
      "… 3 unchanged lines …",
    },
    rows = {
      {
        text = "  def execute(self):",
        kind = "context",
        change_id = change_id,
        source_anchor = { side = "new", source_line = 2 },
      },
      {
        text = "… 3 unchanged lines …",
        kind = "gap",
        change_id = change_id,
        source_anchor = { side = "new", source_line = 4 },
      },
    },
  }
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, visible.lines)
  highlights.apply_diff(buffer, visible, inspections, namespace)
  assert_equal(find_extmark(
    buffer,
    namespace,
    2,
    function(details)
      return details.virt_text ~= nil
    end
  ), nil)

  local pending = {}
  local fake_git = {}
  function fake_git:snapshot(_, _, side, callback)
    local request = {
      side = side,
      callback = callback,
      cancelled = false,
    }
    pending[#pending + 1] = request
    return {
      cancel = function()
        request.cancelled = true
      end,
    }
  end
  renderer.configure({
    git = fake_git,
    inspect = function(opts)
      return Result.ok(manual_inspection({
        {
          group = "@keyword.function.python",
          start_row = 0,
          start_col = 0,
          end_row = 0,
          end_col = math.min(3, #opts.source),
        },
      }))
    end,
  })

  local session = Session.new({
    id = "vigit-syntax-generation",
    root = "/tmp/vigit-syntax-generation",
  })
  local ok, message = xpcall(function()
    layout.open(session)
    local change = {
      id = change_id,
      section = "unstaged",
      status = "M",
      path = "service.py",
    }
    session.data.status = {
      branch = {},
      staged = {},
      unstaged = { change },
    }
    session.data.diffs[change_id] = {
      id = change_id,
      path = "service.py",
      section = "unstaged",
      status = "M",
      headers = {},
      hunks = {
        {
          id = change_id .. "\0hunk",
          header = "@@ -1 +1 @@",
          old_start = 1,
          old_count = 1,
          new_start = 1,
          new_count = 1,
          lines = {
            { kind = "delete", text = "def old():", old_line = 1 },
            { kind = "add", text = "def new():", new_line = 1 },
          },
        },
      },
    }
    session.view.selected_change_id = change_id
    session.reads.generation = 1

    renderer.render(session)
    local first_lines = buffer_lines(session.owned.diff_buf)
    assert_truthy(find_row(session.owned.diff_buf, "def old():"))
    assert_truthy(find_row(session.owned.diff_buf, "def new():"))
    assert_truthy(vim.wait(1000, function()
      return #pending == 2
    end, 10))
    assert_truthy(has_virtual_text(
      session.owned.diff_buf,
      "syntax: loading"
    ))

    local stale_pending = pending
    session.reads.generation = 2
    pending = {}
    renderer.render(session)
    assert_truthy(vim.wait(1000, function()
      return #pending == 2
    end, 10))
    assert_truthy(has_virtual_text(
      session.owned.diff_buf,
      "syntax: loading"
    ))
    for _, request in ipairs(stale_pending) do
      request.callback(Result.ok(request.side == "old"
        and "def old():"
        or "def new():"))
    end
    local stale_added = assert(find_row(session.owned.diff_buf, "def new():"))
    assert_equal(has_group(
      session.owned.diff_buf,
      -1,
      stale_added,
      "@keyword"
    ), nil)
    assert_truthy(has_virtual_text(
      session.owned.diff_buf,
      "syntax: loading"
    ))
    local set_lines_calls = 0
    local original_set_lines = vim.api.nvim_buf_set_lines
    local completion_ok, completion_message = xpcall(function()
      vim.api.nvim_buf_set_lines = function(target, ...)
        if target == session.owned.diff_buf then
          set_lines_calls = set_lines_calls + 1
        end
        return original_set_lines(target, ...)
      end
      for _, request in ipairs(pending) do
        request.callback(Result.ok(request.side == "old"
          and "def old():"
          or "def new():"))
      end
    end, debug.traceback)
    vim.api.nvim_buf_set_lines = original_set_lines
    if not completion_ok then
      error(completion_message, 0)
    end

    local current_added = assert(find_row(session.owned.diff_buf, "def new():"))
    assert_truthy(has_group(
      session.owned.diff_buf,
      -1,
      current_added,
      "@keyword"
    ))
    assert_equal(set_lines_calls, 0)
    assert_equal(has_virtual_text(
      session.owned.diff_buf,
      "syntax: loading"
    ), false)
    assert_truthy(vim.deep_equal(
      buffer_lines(session.owned.diff_buf),
      first_lines
    ))

    session.reads.generation = 3
    pending = {}
    renderer.render(session)
    assert_truthy(vim.wait(1000, function()
      return #pending == 2
        and has_virtual_text(
          session.owned.diff_buf,
          "syntax: loading"
        )
    end, 10))
    local error_lines = buffer_lines(session.owned.diff_buf)
    for _, request in ipairs(pending) do
      request.callback(Result.err(
        "file_read_failed",
        "Unable to inspect source snapshot"
      ))
    end
    assert_truthy(vim.wait(1000, function()
      return has_virtual_text(
        session.owned.diff_buf,
        "syntax: file_read_failed"
      )
    end, 10))
    assert_equal(has_virtual_text(
      session.owned.diff_buf,
      "syntax: loading"
    ), false)
    assert_truthy(vim.deep_equal(
      buffer_lines(session.owned.diff_buf),
      error_lines
    ))
    renderer.clear(session)
    assert_equal(#extmarks(session.owned.diff_buf, -1), 0)
  end, debug.traceback)

  renderer.configure()
  close_session(session)
  vim.api.nvim_buf_delete(buffer, { force = true })
  if not ok then
    error(message, 0)
  end
end)
