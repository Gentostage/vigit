# Vigit v2 Native Handoff and Syntax Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить source-aware diff, reusable installed Tree-sitter parsers и
handoff в полностью обычные Neovim editor/LSP/terminal tabs.

**Architecture:** Diff rows хранят SourceAnchor, syntax adapter анализирует
old/new snapshots отдельно, а Neovim adapter создаёт metadata-tagged normal
tabs, которые не входят в owned session resources.

**Tech Stack:** Lua, Neovim Tree-sitter/LSP public API, extmarks/signcolumn,
headless lifecycle fixtures.

## Global Constraints

- Source/terminal buffers не получают Vigit keymaps, winbar или lifecycle
  autocmds.
- Vigit session не хранит editor/terminal tab handles как owned resources.
- `gd` не использует текстовый search fallback.
- Missing parser/LSP даёт graceful Result, не runtime exception.

---

### Task 1: SourceAnchor и context-preserving diff rows

**Files:**

- Create: `lua/vigit/core/anchor.lua`
- Modify: `lua/vigit/ui/views/diff.lua`
- Modify: `lua/vigit/application/changes.lua`
- Modify: `lua/vigit/ui/controller.lua`
- Create: `tests/unit/anchor_spec.lua`
- Create: `tests/unit/diff_view_spec.lua`

**Interfaces:**

- Consumes: `FileDiff`, `DiffLine`, Session view state.
- Produces:
  `anchor.from_row(row_meta, column) -> SourceAnchor`,
  `anchor.match(rows, source_anchor) -> row|nil`.
- Produces every rendered row as
  `{ text, kind, change_id, hunk_id, source_anchor }`.

- [ ] **Step 1: Написать anchor priority tests**

```lua
local target = {
  path = "src/a.lua",
  section = "unstaged",
  side = "new",
  source_line = 12,
  column = 4,
  context = "return value",
  hunk_id = "h1",
}

assert_equal(anchor.match(rows, target), exact_row)
rows[exact_row].source_anchor.source_line = 13
assert_equal(anchor.match(rows, target), context_row)
rows[context_row].source_anchor.context = "changed"
assert_equal(anchor.match(rows, target), nearest_hunk_row)
```

Add tests for deletion side using `old_line` and file-header fallback.

- [ ] **Step 2: Написать context placeholder tests**

```lua
local rendered = diff_view.render(state, 100)
assert_equal(rendered.rows[gap].text, "… 128 unchanged lines …")
assert_equal(rendered.rows[gap].source_anchor.source_line, 132)
```

When `state.view.expanded_context[hunk_id]` is true, rows around the current
anchor MUST be present and anchor matching MUST return the same source line.

- [ ] **Step 3: Запустить tests и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/anchor_spec.lua tests/unit/diff_view_spec.lua
```

Expected: FAIL because anchor module/row contract is absent.

- [ ] **Step 4: Реализовать stable SourceAnchor**

Use the matching order from
[`data-model.md`](../data-model.md). Context fingerprint is normalized source
text with surrounding whitespace collapsed; it MUST NOT include diff markers.

- [ ] **Step 5: Перевести diff view и `f` на anchor**

Before render-changing intent, controller captures the current row metadata and
column. After state/render completion it calls `anchor.match` and restores the
window cursor. `f` toggles only the current gap/hunk entry in
`expanded_context`, requests a larger per-file context, and never resets row 1.

- [ ] **Step 6: Запустить unit suites**

Run:

```bash
lua tests/run.lua
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lua/vigit/core/anchor.lua lua/vigit/ui/views/diff.lua lua/vigit/application/changes.lua lua/vigit/ui/controller.lua tests/unit/anchor_spec.lua tests/unit/diff_view_spec.lua
git commit -m "feat(diff): preserve source anchors and context"
```

---

### Task 2: Snapshot Tree-sitter inspection и layered highlights

**Files:**

- Create: `lua/vigit/adapters/treesitter.lua`
- Create: `lua/vigit/ui/highlights.lua`
- Modify: `lua/vigit/ui/renderer.lua`
- Modify: `lua/vigit/ui/views/diff.lua`
- Create: `tests/headless/syntax_spec.lua`

**Interfaces:**

- Consumes: `git:snapshot(root, change, side, callback)`, rendered source rows.
- Produces:
  `treesitter.inspect({ path, source, max_bytes }) -> Result<Inspection>`.
- `Inspection = { language, captures, symbols }`.
- Produces:
  `highlights.apply_diff(buf, rendered, inspections, namespace)`.

- [ ] **Step 1: Написать headless removed/new syntax tests**

With installed Python parser:

```lua
local added = find_row(session, "async def execute", "add")
local deleted = find_row(session, "def execute", "delete")
assert_extmark_group(session.owned.diff_buf, added, "@keyword.function.python")
assert_extmark_group(session.owned.diff_buf, deleted, "@keyword.function.python")
assert_sign(session.owned.diff_buf, added, "VigitDiffAddSign")
assert_sign(session.owned.diff_buf, deleted, "VigitDiffDeleteSign")
```

If parser/query unavailable, test prints `SKIP` and asserts render still
contains code without exception. Assert code text does not begin with `+`/`-`.

- [ ] **Step 2: Написать symbol context tests**

Use a Python snapshot with `class PaymentService` and `def execute`. Assert a
hidden gap below both declarations receives `PaymentService.execute()`, while a
gap whose declaration row is rendered receives no duplicate symbol.

- [ ] **Step 3: Запустить syntax tests и подтвердить failure**

Run:

```bash
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/syntax_spec.lua
```

Expected: FAIL because snapshot Tree-sitter adapter does not exist.

- [ ] **Step 4: Реализовать string parser inspection**

```lua
local language = vim.treesitter.language.get_lang(filetype) or filetype
local parser = vim.treesitter.get_string_parser(source, language)
local tree = parser:parse()[1]
local query = vim.treesitter.query.get(language, "highlights")
```

Collect capture ranges and group names from the user's runtime queries. Build a
separate symbol list from class/function/method-like node types and node text.
Return `parser_unavailable` as a non-fatal Result. Reject source larger than
`max_highlight_bytes`.

- [ ] **Step 5: Реализовать two-layer extmarks**

Use a dedicated namespace per session:

- full-line diff background priority `10`;
- signcolumn `sign_text = "▎"` priority `20`;
- Tree-sitter foreground priority `100`;
- selection/comment overlays higher than `150`.

Map old captures only to delete rows and new captures to add/context rows by
source line/column intersection.

- [ ] **Step 6: Schedule highlighting after base render**

Renderer first writes rows/background/signs, then schedules snapshot inspection
for visible/selected file blocks. Completion checks session generation before
applying extmarks and triggers no line rewrite.

- [ ] **Step 7: Запустить syntax, headless и legacy suites**

Run:

```bash
lua tests/run.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/syntax_spec.lua
```

Expected: PASS or explicit parser-dependent SKIP.

- [ ] **Step 8: Commit**

```bash
git add lua/vigit/adapters/treesitter.lua lua/vigit/ui/highlights.lua lua/vigit/ui/renderer.lua lua/vigit/ui/views/diff.lua tests/headless/syntax_spec.lua
git commit -m "feat(diff): highlight both snapshot sides with treesitter"
```

---

### Task 3: Normal editor-tab handoff

**Files:**

- Modify: `lua/vigit/adapters/neovim.lua`
- Modify: `lua/vigit/v2.lua`
- Modify: `lua/vigit/ui/controller.lua`
- Modify: `lua/vigit/ui/keymaps.lua`
- Create: `tests/headless/handoff_spec.lua`

**Interfaces:**

- Consumes: HandlerContext from
  [`contracts/public-api.md`](../contracts/public-api.md).
- Produces:
  `neovim.open_file(context, done)`,
  `neovim.find_source_tab(root) -> tab|nil`,
  `neovim.loaded_source_buffers(root) -> BufferInfo[]`.

`BufferInfo = { buf = integer, path = "/canonical/source/path" }`; only loaded
normal file buffers under the requested root are returned.

- [ ] **Step 1: Написать two-worktree editor tests**

```lua
controller.dispatch(session_a, "open_file")
local tab_a = vim.api.nvim_get_current_tabpage()
local buf_a = vim.api.nvim_get_current_buf()

controller.dispatch(session_b, "open_file")
local tab_b = vim.api.nvim_get_current_tabpage()
local buf_b = vim.api.nvim_get_current_buf()

assert(tab_a ~= tab_b)
assert(buf_a ~= buf_b)
assert_equal(vim.api.nvim_buf_get_name(buf_a), repo_a .. "/src/service.py")
assert_equal(vim.api.nvim_buf_get_name(buf_b), repo_b .. "/src/service.py")
```

Assert second file from session A reuses `tab_a`, tab-local `vigit_root` matches
repo A, and closing session A leaves both source tabs valid.

- [ ] **Step 2: Написать non-injection test**

After handoff enumerate `nvim_buf_get_keymap(buf, "n")` and buffer autocmds.
Assert no mapping/autocmd description/source starts with `Vigit`; `Q` may still
exist globally from the user config and MUST NOT be judged as Vigit-owned.

- [ ] **Step 3: Запустить tests и подтвердить failure**

Run:

```bash
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/handoff_spec.lua
```

Expected: FAIL because native adapter/open intent is absent.

- [ ] **Step 4: Реализовать source-tab lookup**

Search all valid tabs for tab vars:

```lua
local ok_root, root = pcall(vim.api.nvim_tabpage_get_var, tab, "vigit_root")
local ok_role, role = pcall(vim.api.nvim_tabpage_get_var, tab, "vigit_role")
if ok_root and ok_role and root == context.root and role == "source" then
  return tab
end
```

Create a normal tab only when absent. Set `vigit_root`, `vigit_branch`,
`vigit_label`, `vigit_role = "source"` via public tabpage vars. Do not record
the tab under `session.owned`.

- [ ] **Step 5: Открыть real buffer без Ex path interpolation**

```lua
local buf = vim.fn.bufadd(context.path)
vim.fn.bufload(buf)
vim.api.nvim_set_current_tabpage(tab)
vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
vim.api.nvim_win_set_cursor(0, { context.line, context.column })
```

Before replacing a reused source window's position, execute `normal! m'` inside
that window so its jumplist retains the previous source location. Return
`Result.ok({ tab, win, buf })` through `done`.

- [ ] **Step 6: Wire configurable `e` handler**

Controller creates immutable HandlerContext and calls
`config.handlers.open_file or neovim.open_file`. Custom handler never receives
Session and completion errors are stored in session state.

- [ ] **Step 7: Запустить handoff tests**

Run:

```bash
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/handoff_spec.lua
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lua/vigit/adapters/neovim.lua lua/vigit/v2.lua lua/vigit/ui/controller.lua lua/vigit/ui/keymaps.lua tests/headless/handoff_spec.lua
git commit -m "feat(editor): hand off files to native neovim tabs"
```

---

### Task 4: User `gd` bridge и native terminal

**Files:**

- Modify: `lua/vigit/adapters/neovim.lua`
- Modify: `lua/vigit/ui/controller.lua`
- Modify: `lua/vigit/ui/keymaps.lua`
- Extend: `tests/headless/handoff_spec.lua`

**Interfaces:**

- Consumes: `neovim.open_file(context, done)`.
- Produces:
  `neovim.goto_definition(context, done)`,
  `neovim.open_terminal(context, done)`.

- [ ] **Step 1: Написать mapped-`gd` bridge test**

Install a buffer-local source mapping before dispatch:

```lua
vim.keymap.set("n", "gd", function()
  definition_called = vim.api.nvim_get_current_buf()
end, { buffer = source_buf })

controller.dispatch(session, "goto_definition")
assert_equal(definition_called, source_buf)
assert_equal(vim.api.nvim_win_get_cursor(0), { expected_line, expected_column })
```

Assert no Vigit `gd` mapping appears in source buffer after execution.

- [ ] **Step 2: Написать LSP fallback and timeout tests**

Mock `vim.lsp.get_clients` and `vim.lsp.buf.definition`. Without a source `gd`
mapping, assert fallback called once. With no client, emit `LspAttach` before
timeout and assert call. Without attach, assert `lsp_unavailable` and leave the
cursor on source anchor; no `/word` or native `normal! gd` runs.

- [ ] **Step 3: Написать terminal ownership test**

```lua
controller.dispatch(session, "open_terminal")
local terminal_tab = vim.api.nvim_get_current_tabpage()
local terminal_buf = vim.api.nvim_get_current_buf()
assert_equal(vim.bo[terminal_buf].buftype, "terminal")
assert_equal(tab_var(terminal_tab, "vigit_root"), session.root)
close_vigit(session)
assert_truthy(vim.api.nvim_tabpage_is_valid(terminal_tab))
```

Assert terminal buffer has no buffer-local Vigit mappings and global cwd did not
change.

- [ ] **Step 4: Запустить new tests и подтвердить failure**

Run:

```bash
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/handoff_spec.lua
```

Expected: new cases FAIL.

- [ ] **Step 5: Реализовать remappable user mapping bridge**

Inside the real source buffer inspect `vim.fn.maparg("gd", "n", false, true)`.
When non-empty, feed encoded `gd` with remap:

```lua
local keys = vim.api.nvim_replace_termcodes("gd", true, false, true)
vim.api.nvim_feedkeys(keys, "m", false)
```

Otherwise call LSP. Use a one-shot buffer-scoped `LspAttach` autocmd and timer;
whichever fires first removes the other. Completion callback is once-only.

- [ ] **Step 6: Реализовать normal terminal tab**

Create/tag a normal tab with `vigit_role = "terminal"`, then start:

```lua
local job = vim.fn.termopen(vim.o.shell, { cwd = context.root })
```

Do not run `tcd`/`lcd`, attach mappings, store the tab in session or implement a
return action.

- [ ] **Step 7: Запустить handoff and full headless suites**

Run:

```bash
nvim --headless --clean -u NONE -l tests/headless/run.lua
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lua/vigit/adapters/neovim.lua lua/vigit/ui/controller.lua lua/vigit/ui/keymaps.lua tests/headless/handoff_spec.lua
git commit -m "feat(editor): bridge native lsp and terminal flows"
```

---

### Task 5: Complete Slice 2 UI integration

**Files:**

- Modify: `lua/vigit/ui/keymaps.lua`
- Modify: `lua/vigit/ui/views/diff.lua`
- Modify: `lua/vigit/ui/renderer.lua`
- Modify: `tests/headless/sessions_spec.lua`
- Modify: `tests/headless/syntax_spec.lua`
- Modify: `scripts/demo_init.lua`

**Interfaces:**

- Consumes: native handlers, anchor and syntax inspection.
- Produces buffer-local actions `e`, `gd`, `T`, `f`.

- [ ] **Step 1: Добавить failing end-to-end cursor scenario**

Open a long Python fixture, select changed source line 90, dispatch `f`, wait for
new generation, dispatch `e`, and assert the real buffer cursor remains
`{ 90, original_column }`. Return to Vigit by standard tab selection and assert
the diff anchor still resolves to line 90.

- [ ] **Step 2: Запустить headless suite и подтвердить failure**

Run:

```bash
nvim --headless --clean -u NONE -l tests/headless/run.lua
```

Expected: new end-to-end case FAIL until keymaps/render completion are wired.

- [ ] **Step 3: Add key entries and loading/error rows**

Register `e`, `gd`, `T`, `f` only for applicable Vigit contexts. While syntax or
context reload is busy, retain code rows and show a non-blocking status badge.
`diff_too_large` renders an explicit file placeholder with `e` available.

- [ ] **Step 4: Update isolated demo startup**

Keep legacy default for now, but allow:

```bash
VIGIT_DEMO_V2=1 ./scripts/demo.sh
```

`scripts/demo_init.lua` chooses `require("vigit.v2").open()` only when this env
flag equals `1`.

- [ ] **Step 5: Run Slice 2 gates**

Run:

```bash
lua tests/run.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua
VIGIT_DEMO_V2=1 ./scripts/demo.sh
```

Expected automated suites PASS. Manual demo: source `e`/`gd`/`T` use normal
Neovim and Vigit tab remains independently open.

- [ ] **Step 6: Commit**

```bash
git add lua/vigit/ui tests/headless scripts/demo_init.lua
git commit -m "feat(v2): complete native review handoff"
```

### Slice 2 Review Gate

- [ ] Deleted and added code both receive syntax foreground when parser exists.
- [ ] Gap symbol is shown only when declaration is hidden.
- [ ] `f`, refresh and handoff preserve source anchor.
- [ ] Same relative path in two worktrees produces distinct buffers.
- [ ] Source/terminal buffers have zero Vigit-owned behavior.
- [ ] Closing Vigit leaves normal tabs and jumplists intact.
