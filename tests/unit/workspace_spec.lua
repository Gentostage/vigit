local Result = require("vigit.core.result")
local Workspace = require("vigit.application.workspace")

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, nested in pairs(value) do
    result[key] = copy(nested)
  end
  return result
end

local function fake_dependencies()
  local calls = {
    created = {},
    mounted = {},
    hidden = {},
    disposed = {},
    roots = {},
  }

  local deps = {
    canonicalize = function(path)
      return path:gsub("/+$", "")
    end,
    inspect = function()
      return Result.ok(true)
    end,
    set_root = function(_, root)
      calls.roots[#calls.roots + 1] = root
      return Result.ok(root)
    end,
    create_session = function(root, snapshot)
      local session = {
        id = root .. ":" .. (#calls.created + 1),
        root = root,
        closed = false,
        view = {
          changes_mode = "tree",
          diff_mode = "one_file",
          selected_change_id = nil,
          anchor = nil,
          expanded_dirs = {},
          expanded_context = {},
        },
      }
      if snapshot then
        for key, value in pairs(snapshot) do
          session.view[key] = copy(value)
        end
      end
      calls.created[#calls.created + 1] = session
      return Result.ok(session)
    end,
    mount = function(session)
      calls.mounted[#calls.mounted + 1] = session
      return Result.ok(session)
    end,
    hide = function(session)
      calls.hidden[#calls.hidden + 1] = session
    end,
    dispose = function(session)
      session.closed = true
      calls.disposed[#calls.disposed + 1] = session
    end,
    show = function(session)
      calls.mounted[#calls.mounted + 1] = session
      return Result.ok(session)
    end,
  }

  return deps, calls
end

it("держит одну active session и восстанавливает логический snapshot", function()
  local deps, calls = fake_dependencies()
  local workspace = Workspace.new(deps)

  local first = assert(workspace:open("/repo-a/").value)
  first.view.selected_change_id = "unstaged:src/a.py"
  first.view.anchor = { change_id = "unstaged:src/a.py", source_line = 17 }
  first.view.expanded_dirs.src = true
  first.view.expanded_context.hunk_a = 40

  assert_truthy(workspace:switch("/repo-b").ok)
  assert_truthy(workspace:switch("/repo-a").ok)

  local restored = workspace:active_session()
  assert_equal(restored, first)
  assert_equal(restored.root, "/repo-a")
  assert_equal(restored.view.selected_change_id, "unstaged:src/a.py")
  assert_equal(restored.view.anchor, {
    change_id = "unstaged:src/a.py",
    source_line = 17,
  })
  assert_equal(restored.view.expanded_dirs, { src = true })
  assert_equal(restored.view.expanded_context, { hunk_a = 40 })
  assert_equal(#calls.created, 2)
  assert_equal(#calls.disposed, 0)
  assert_equal(workspace:mode_name(), "review")
end)

it("не уничтожает active session, когда inspection блокирует switch", function()
  local deps, calls = fake_dependencies()
  local blocker = Result.err(
    "modified_source_buffers",
    "Save modified files before switching",
    { "/repo-a/src/a.py" }
  )
  deps.inspect = function()
    return blocker
  end
  local workspace = Workspace.new(deps)
  local active = assert(workspace:open("/repo-a").value)

  local result = workspace:switch("/repo-b")

  assert_equal(result, blocker)
  assert_equal(workspace:active_session(), active)
  assert_equal(active.closed, false)
  assert_equal(#calls.hidden, 0)
  assert_equal(#calls.disposed, 0)
end)

it("повторное открытие active root только показывает review", function()
  local deps, calls = fake_dependencies()
  local workspace = Workspace.new(deps)
  local active = assert(workspace:open("/repo-a").value)
  assert_truthy(workspace:show_code().ok)

  local reopened = assert(workspace:open("/repo-a/").value)

  assert_equal(reopened, active)
  assert_equal(#calls.created, 1)
  assert_equal(workspace:mode_name(), "review")
  assert_equal(calls.mounted[#calls.mounted], active)
end)

it("повторно привязывает active root при входе в code и review", function()
  local deps, calls = fake_dependencies()
  local workspace = Workspace.new(deps)

  assert_truthy(workspace:open("/repo-a").ok)
  assert_truthy(workspace:show_code().ok)
  assert_truthy(workspace:show_review().ok)

  assert_equal(calls.roots, { "/repo-a", "/repo-a", "/repo-a" })
end)

it("восстанавливает предыдущий root при ошибке activation", function()
  local deps, calls = fake_dependencies()
  deps.set_root = function(_, root)
    calls.roots[#calls.roots + 1] = root
    if root == "/repo-b" then
      return Result.err("workspace_root_failed", "Unable to set workspace root")
    end
    return Result.ok(root)
  end
  local workspace = Workspace.new(deps)
  local first = assert(workspace:open("/repo-a").value)
  first.view.selected_change_id = "unstaged:a.py"

  local result = workspace:switch("/repo-b")

  assert_equal(result.ok, false)
  assert_equal(result.error.code, "workspace_root_failed")
  assert_equal(workspace:active_session().root, "/repo-a")
  assert_equal(
    workspace:active_session().view.selected_change_id,
    "unstaged:a.py"
  )
  assert_equal(calls.roots, { "/repo-a", "/repo-b", "/repo-a" })
end)

it("закрывает только active session и очищает workspace state", function()
  local deps, calls = fake_dependencies()
  local workspace = Workspace.new(deps)
  local first = assert(workspace:open("/repo-a").value)
  local second = assert(workspace:switch("/repo-b").value)

  assert_truthy(workspace:close())

  assert_equal(first.closed, true)
  assert_equal(second.closed, true)
  assert_equal(workspace:active_session(), nil)
  assert_equal(workspace:mode_name(), "closed")
  assert_equal(calls.disposed, { first, second })
  assert_equal(workspace:close(), false)
end)

it("удаляет только inactive session из workspace", function()
  local deps, calls = fake_dependencies()
  local workspace = Workspace.new(deps)
  local first = assert(workspace:open("/repo-a").value)
  local second = assert(workspace:switch("/repo-b").value)

  assert_truthy(workspace:remove_session("/repo-a"))
  assert_equal(first.closed, true)
  assert_equal(second.closed, false)
  assert_equal(workspace:active_session(), second)
  assert_equal(workspace:all_sessions(), { second })
  assert_equal(calls.disposed, { first })
  assert_equal(workspace:remove_session("/repo-b"), false)
end)
