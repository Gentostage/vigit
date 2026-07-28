# Vigit v2 Foundation and Read-only UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить рядом с legacy отдельный асинхронный `:VigitV2`, который
показывает changes и one/all-file diff в независимых worktree sessions.

**Architecture:** Pure Result/status/diff modules питаются через `vim.system`
Git adapter. Application use case управляет generations, а UI session владеет
только Vigit tab, `nofile` buffers и windows.

**Tech Stack:** Lua 5.1, Neovim 0.10+, Git 2.36+, existing lightweight test
harness плюс headless Neovim.

## Global Constraints

- Не менять поведение `:Vigit`.
- Не выполнять Git через shell string.
- Не добавлять global mappings.
- Все новые модули используют два пробела и `local M = {}; return M`.
- Каждый task заканчивается проходящими legacy и новыми targeted tests.

---

### Task 1: Result model и общий test harness

**Files:**

- Create: `lua/vigit/core/result.lua`
- Create: `tests/testlib.lua`
- Create: `tests/unit/result_spec.lua`
- Modify: `tests/run.lua`

**Interfaces:**

- Produces: `Result.ok(value)`, `Result.err(code, message, details, retryable)`,
  `Result.is(value)`, `Result.map(result, fn)`.
- Produces: `testlib.load(files)` и `testlib.execute()` для plain/headless
  runners.

- [ ] **Step 1: Написать failing Result tests**

```lua
local Result = require("vigit.core.result")

it("creates typed success and error results", function()
  assert_equal(Result.ok(42), { ok = true, value = 42 })
  assert_equal(Result.err("git_failed", "Git failed", "fatal", true), {
    ok = false,
    error = {
      code = "git_failed",
      message = "Git failed",
      details = "fatal",
      retryable = true,
    },
  })
end)

it("maps only successful results", function()
  assert_equal(Result.map(Result.ok(2), function(value)
    return value * 3
  end), Result.ok(6))
  local failure = Result.err("boom", "Boom")
  assert_equal(Result.map(failure, error), failure)
end)
```

Add recursive table comparison to `tests/testlib.lua` so assertions report the
first differing path, not `table: 0x...`.

- [ ] **Step 2: Запустить test и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/result_spec.lua
```

Expected: FAIL because `vigit.core.result` does not exist.

- [ ] **Step 3: Реализовать Result без зависимости от `vim`**

```lua
local M = {}

function M.ok(value)
  return { ok = true, value = value }
end

function M.err(code, message, details, retryable)
  return {
    ok = false,
    error = {
      code = assert(code),
      message = assert(message),
      details = details,
      retryable = retryable == true,
    },
  }
end

function M.is(value)
  return type(value) == "table" and type(value.ok) == "boolean"
end

function M.map(result, fn)
  if not result.ok then
    return result
  end
  return M.ok(fn(result.value))
end

return M
```

Refactor `tests/run.lua` to install globals through `testlib`, load its default
legacy list when no CLI paths are supplied, append new unit paths, execute all
cases, and exit non-zero on failures. `describe` executes its callback
immediately; `it` only registers a case.

- [ ] **Step 4: Запустить новый и legacy suites**

Run:

```bash
lua tests/run.lua tests/unit/result_spec.lua
lua tests/run.lua
```

Expected: both commands exit 0; existing PASS lines remain.

- [ ] **Step 5: Commit**

```bash
git add lua/vigit/core/result.lua tests/testlib.lua tests/unit/result_spec.lua tests/run.lua
git commit -m "refactor(core): add result model and test harness"
```

---

### Task 2: Validated config и asynchronous process adapter

**Files:**

- Create: `lua/vigit/config.lua`
- Create: `lua/vigit/adapters/process.lua`
- Create: `tests/unit/config_spec.lua`
- Create: `tests/integration/run.lua`
- Create: `tests/integration/process_spec.lua`

**Interfaces:**

- Consumes: `Result.ok`, `Result.err`.
- Produces: `config.resolve(user_opts) -> Result<Config>`,
  `config.get() -> Config`.
- Produces:
  `process.run(args, opts, callback) -> { cancel = function() end }`.

- [ ] **Step 1: Написать config validation tests**

```lua
local config = require("vigit.config")

it("deep merges supported options", function()
  local result = config.resolve({
    ui = { changes_width = 28 },
    refresh = { debounce_ms = 50 },
  })
  assert_truthy(result.ok)
  assert_equal(result.value.ui.changes_width, 28)
  assert_equal(result.value.ui.changes_side, "right")
  assert_equal(result.value.refresh.debounce_ms, 50)
end)

it("rejects unknown and invalid options with a full path", function()
  local unknown = config.resolve({ ui = { mystery = true } })
  assert_equal(unknown.error.code, "invalid_config")
  assert_truthy(unknown.error.message:match("ui%.mystery"))

  local invalid = config.resolve({ ui = { changes_width = "wide" } })
  assert_truthy(invalid.error.message:match("ui%.changes_width"))
end)
```

- [ ] **Step 2: Запустить config tests и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/config_spec.lua
```

Expected: FAIL because `vigit.config` does not exist.

- [ ] **Step 3: Реализовать defaults и explicit schema**

Defaults MUST точно совпадать с
[`contracts/public-api.md`](../contracts/public-api.md). Implement recursive
merge only for keys present in schema. Store one resolved snapshot in
`config.setup(opts)`; return deep copies from `config.get()` so callers cannot
mutate global config.

- [ ] **Step 4: Написать failing process integration tests**

```lua
local process = require("vigit.adapters.process")

it("runs argument arrays with cwd and captures stderr", function(done)
  process.run({ "git", "rev-parse", "--show-toplevel" }, {
    cwd = fixture.root,
  }, function(result)
    assert_truthy(result.ok)
    assert_equal(vim.trim(result.value.stdout), fixture.root)
    done()
  end)
end)

it("rejects a shell string before spawning", function(done)
  process.run("git status", {}, function(result)
    assert_equal(result.error.code, "invalid_command")
    done()
  end)
end)
```

`tests/integration/run.lua` MUST support async `done` tests with a 2-second
timeout and finish via `cquit`/`qa`.

- [ ] **Step 5: Запустить integration test и подтвердить failure**

Run:

```bash
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/process_spec.lua
```

Expected: FAIL because process adapter does not exist.

- [ ] **Step 6: Реализовать `vim.system` wrapper**

```lua
function M.run(args, opts, callback)
  if type(args) ~= "table" or type(args[1]) ~= "string" then
    vim.schedule(function()
      callback(Result.err("invalid_command", "Command must be an argument array"))
    end)
    return { cancel = function() end }
  end

  local system = vim.system(args, {
    cwd = opts.cwd,
    stdin = opts.stdin,
    text = false,
    timeout = opts.timeout_ms,
  }, vim.schedule_wrap(function(output)
    if output.code == 0 then
      callback(Result.ok(output))
    else
      callback(Result.err(
        "process_failed",
        "Process exited with code " .. output.code,
        output.stderr,
        true
      ))
    end
  end))

  return {
    cancel = function()
      if not system:is_closing() then
        system:kill("sigterm")
      end
    end,
  }
end
```

Catch spawn exceptions with `pcall(vim.system, ...)` and return
`process_unavailable`; callback MUST run exactly once.

- [ ] **Step 7: Запустить targeted suites**

Run:

```bash
lua tests/run.lua tests/unit/config_spec.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/process_spec.lua
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lua/vigit/config.lua lua/vigit/adapters/process.lua tests/unit/config_spec.lua tests/integration
git commit -m "refactor(platform): add config and async process adapter"
```

---

### Task 3: Porcelain-v2/diff core и read-only Git adapter

**Files:**

- Create: `lua/vigit/core/status.lua`
- Create: `lua/vigit/core/diff.lua`
- Create: `lua/vigit/adapters/git_cli.lua`
- Create: `tests/fixtures/git_repo.lua`
- Create: `tests/unit/status_spec.lua`
- Create: `tests/unit/diff_spec.lua`
- Create: `tests/integration/git_read_spec.lua`

**Interfaces:**

- Consumes: `process.run`, `Result`.
- Produces:
  `status.parse(raw) -> Result<Status>`,
  `diff.parse(raw, change) -> Result<FileDiff>`.
- Produces:
  `git_cli.new(process)`,
  `git:status(root, callback)`,
  `git:diff(root, change, context, max_bytes, callback)`,
  `git:snapshot(root, change, side, callback)`.

- [ ] **Step 1: Написать NUL status parser tests**

Cover ordinary, rename with second NUL pathname, untracked, Unicode, spaces,
leading dash and malformed records:

```lua
local raw = table.concat({
  "1 .M N... 100644 100644 100644 aaaa bbbb src/a b.lua",
  "? notes/новый.md",
  "2 R. N... 100644 100644 100644 aaaa bbbb R100 new/name.lua",
  "old/name.lua",
  "",
}, "\0")

local result = status.parse(raw)
assert_truthy(result.ok)
assert_equal(result.value.unstaged[1].path, "src/a b.lua")
assert_equal(result.value.unstaged[2].status, "?")
assert_equal(result.value.staged[1].old_path, "old/name.lua")
```

- [ ] **Step 2: Написать unified diff parser tests**

```lua
local parsed = diff.parse(fixture_patch, {
  id = "unstaged\0src/a.lua",
  section = "unstaged",
  status = "M",
  path = "src/a.lua",
})
assert_equal(parsed.value.hunks[1].lines[1], {
  kind = "delete",
  text = "local old = true",
  old_line = 10,
  new_line = nil,
})
assert_equal(parsed.value.hunks[1].lines[2].text, "local new = true")
```

Also assert hunk IDs, no textual prefix in `DiffLine.text`, binary detection and
`diff_too_large`.

- [ ] **Step 3: Запустить pure parser tests и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/status_spec.lua tests/unit/diff_spec.lua
```

Expected: FAIL because new parsers do not exist.

- [ ] **Step 4: Реализовать pure parsers**

Status parser MUST consume records by index because rename uses the following
NUL field as `old_path`. It also parses `# branch.*` headers so session branch
metadata does not require a second Git call. Diff parser MUST preserve full
patch headers and selected hunk patch data while stripping exactly one diff
marker from code text.

- [ ] **Step 5: Написать real-Git read contract tests**

`tests/fixtures/git_repo.lua` creates/removes temp repositories only through
argument-array `vim.system(...):wait()` and exposes:

```lua
fixture.new()
fixture:write(path, lines)
fixture:git({ "add", "--", path })
fixture:commit("message")
fixture:cleanup()
```

Test staged+unstaged same file, rename, delete, untracked Unicode/space path,
unborn HEAD and snapshots.

- [ ] **Step 6: Запустить Git tests и подтвердить failure**

Run:

```bash
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/git_read_spec.lua
```

Expected: FAIL because `vigit.adapters.git_cli` does not exist.

- [ ] **Step 7: Реализовать async Git reads**

Construct only arrays:

```lua
{ "git", "status", "--porcelain=v2", "--branch", "-z",
  "--untracked-files=all" }
{ "git", "diff", "--no-ext-diff", "--unified=" .. context, "--", change.path }
{ "git", "diff", "--cached", "--no-ext-diff", "--unified=" .. context, "--", change.path }
```

For untracked files read through injected filesystem reader and create
synthetic one-hunk `FileDiff`. Reject stdout beyond `max_diff_bytes` before
parsing. Convert process errors to Git-specific Result codes.

- [ ] **Step 8: Запустить parser, Git и legacy suites**

Run:

```bash
lua tests/run.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/git_read_spec.lua
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lua/vigit/core/status.lua lua/vigit/core/diff.lua lua/vigit/adapters/git_cli.lua tests/fixtures tests/unit/status_spec.lua tests/unit/diff_spec.lua tests/integration/git_read_spec.lua
git commit -m "refactor(git): add async read models and adapter"
```

---

### Task 4: Session registry и changes application use case

**Files:**

- Create: `lua/vigit/ui/registry.lua`
- Create: `lua/vigit/ui/session.lua`
- Create: `lua/vigit/application/changes.lua`
- Create: `tests/unit/registry_spec.lua`
- Create: `tests/unit/changes_spec.lua`

**Interfaces:**

- Consumes: `git:status`, `git:diff`.
- Produces:
  `registry.new(canonicalize)`,
  `registry:get(root)`,
  `registry:put(session)`,
  `registry:remove(session_id)`,
  `registry:all()`.
- Produces:
  `session.new({ id, root, branch }) -> Session`.
- Produces:
  `changes.new({ git, on_change })`,
  `changes:refresh(session)`,
  `changes:select(session, change_id)`,
  `changes:load_all_visible(session, ids)`.

- [ ] **Step 1: Написать registry isolation tests**

```lua
local registry = Registry.new(function(path)
  return path:gsub("/+$", "")
end)
local a = Session.new({ id = "a", root = "/repo/a/" })
local b = Session.new({ id = "b", root = "/repo/b" })
registry:put(a)
registry:put(b)
assert_equal(registry:get("/repo/a"), a)
assert_equal(registry:get("/repo/b"), b)
```

Assert duplicate canonical root returns the existing session and removal by one
ID cannot remove another root.

- [ ] **Step 2: Написать stale-generation test**

Use fake Git adapter that captures callbacks:

```lua
changes:refresh(session)
local first = fake.status_callbacks[1]
changes:refresh(session)
local second = fake.status_callbacks[2]

second(Result.ok(new_status))
first(Result.ok(old_status))

assert_equal(session.data.status, new_status)
assert_equal(session.reads.generation, 2)
```

Also assert closed session ignores completion and errors preserve last
successful status.

- [ ] **Step 3: Запустить unit tests и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/registry_spec.lua tests/unit/changes_spec.lua
```

Expected: FAIL because modules do not exist.

- [ ] **Step 4: Реализовать explicit session state**

Session constructor initializes the exact fields in
[`data-model.md`](../data-model.md). Registry stores by canonical root and ID;
it MUST NOT inspect current tab or expose `active_session`.

- [ ] **Step 5: Реализовать generation-aware changes use case**

`refresh` increments generation, marks `busy.status`, and installs status only
when `session.closed == false` and callback generation matches. Selected diff
loads after status. `select` stores change ID before requesting diff so UI can
render a loading placeholder.

- [ ] **Step 6: Запустить unit и legacy suites**

Run:

```bash
lua tests/run.lua
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lua/vigit/ui/registry.lua lua/vigit/ui/session.lua lua/vigit/application/changes.lua tests/unit/registry_spec.lua tests/unit/changes_spec.lua
git commit -m "refactor(state): isolate asynchronous worktree sessions"
```

---

### Task 5: Owned layout, renderers и `:VigitV2`

**Files:**

- Create: `lua/vigit/ui/layout.lua`
- Create: `lua/vigit/ui/renderer.lua`
- Create: `lua/vigit/ui/controller.lua`
- Create: `lua/vigit/ui/keymaps.lua`
- Create: `lua/vigit/ui/views/changes.lua`
- Create: `lua/vigit/ui/views/diff.lua`
- Create: `lua/vigit/adapters/neovim.lua`
- Create: `lua/vigit/v2.lua`
- Modify: `lua/vigit/init.lua`
- Create: `tests/headless/run.lua`
- Create: `tests/headless/sessions_spec.lua`

**Interfaces:**

- Consumes: Session registry, changes use case, Git adapter, config.
- Produces:
  `layout.open(session)`,
  `layout.resize(session)`,
  `layout.close(session)`.
- Produces:
  `renderer.render(session)`,
  `controller.dispatch(session, intent)`.
- Produces:
  `neovim.find_repo_root(path) -> Result<string>`.
- Produces:
  `require("vigit.v2").open({ cwd }) -> Session`.

- [ ] **Step 1: Написать headless ownership tests**

Create two real repositories and assert nested cwd, symlinked cwd and root cwd
resolve to the same canonical path while a non-repository returns
`not_repository`. Then assert:

```lua
local a = assert(v2.open({ cwd = repo_a }))
local b = assert(v2.open({ cwd = repo_b }))
assert(a.id ~= b.id)
assert(a.root ~= b.root)
assert(vim.api.nvim_tabpage_is_valid(a.owned.tab))
assert(vim.api.nvim_tabpage_is_valid(b.owned.tab))

local again = assert(v2.open({ cwd = repo_a }))
assert_equal(again.id, a.id)
assert_equal(vim.api.nvim_get_current_tabpage(), a.owned.tab)
```

Assert only two owned `nofile` buffers per session, `q` closes only selected
session, and no `tcd`/global cwd change occurs.

- [ ] **Step 2: Запустить headless test и подтвердить failure**

Run:

```bash
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/sessions_spec.lua
```

Expected: FAIL because `vigit.v2` does not exist.

- [ ] **Step 3: Реализовать root discovery и responsive owned layout**

Resolve the root through `vim.fs.root(path, ".git")`, then canonicalize it with
`vim.uv.fs_realpath`. This synchronous filesystem lookup is the only work done
before returning/focusing Session; Git status remains async. A `.git` file in a
linked worktree is valid. Reject a missing/non-canonical root before registry
mutation.

Create tab, diff buffer/window and right changes split. Set buffers:

```lua
vim.bo[buf].buftype = "nofile"
vim.bo[buf].bufhidden = "wipe"
vim.bo[buf].swapfile = false
vim.bo[buf].modifiable = false
```

Store only these handles under `session.owned`. Width is clamped to 24–36;
below 80 columns changes becomes a toggleable floating overlay.

- [ ] **Step 4: Реализовать pure-ish views**

`views.changes.render(state, width)` returns lines plus hit targets for tree/list
entries. `views.diff.render(state, width)` returns loading/no-changes/file
headers/hunks without syntax work. Renderer is the only module that mutates
buffer lines/extmarks.

- [ ] **Step 5: Реализовать controller и basic key registry**

Register buffer-local `<Tab>`, `<CR>`, `]f`, `[f`, `a`, `t`, `r`, `q`.
Changes cursor movement in one-file mode dispatches `select_change`; controller
never calls Git directly.

- [ ] **Step 6: Wire `:VigitV2` without changing `:Vigit`**

`init.setup()` registers one additional command:

```lua
vim.api.nvim_create_user_command("VigitV2", function(opts)
  require("vigit.v2").open({ cwd = opts.args ~= "" and opts.args or nil })
end, {
  nargs = "?",
  complete = "dir",
  force = true,
})
```

Use `neovim.find_repo_root` before registry lookup; render a session immediately
with loading status, then start async refresh.

- [ ] **Step 7: Запустить all Slice 1 gates**

Run:

```bash
lua tests/run.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua
```

Expected: PASS. Manual: `./scripts/demo.sh`, then `:VigitV2`; legacy `:Vigit`
still works separately.

- [ ] **Step 8: Commit**

```bash
git add lua/vigit/ui lua/vigit/adapters/neovim.lua lua/vigit/v2.lua lua/vigit/init.lua tests/headless
git commit -m "feat(v2): add asynchronous read-only review UI"
```

### Slice 1 Review Gate

- [ ] `:Vigit` retains legacy behavior.
- [ ] `:VigitV2` opens one owned review tab per canonical root.
- [ ] Status appears before selected/all diff completion.
- [ ] Stale callbacks and closed sessions do not render.
- [ ] No source or terminal buffer is created by this slice.
