# Vigit v2 Worktrees and Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Завершить v2 безопасным lifecycle worktrees, единым справочником
keymaps, публичным cutover `:Vigit` и удалением legacy implementation после
полной проверки parity.

**Architecture:** Pure worktree policy отделена от Git/Neovim adapters.
Application use case собирает status с ограниченной concurrency, повторяет
preflight непосредственно перед удалением и закрывает только owned Vigit
resources. Keymap registry генерирует mappings, help и документацию. Legacy
удаляется только после прохождения всех v2 gates.

**Tech Stack:** Lua, Neovim public API, `git worktree list --porcelain -z`,
async `vim.system`, headless Neovim и temporary real Git repositories.

## Global Constraints

- Main worktree определяется первой записью `git worktree list`; linked
  worktrees никогда не определяются по имени directory.
- Remote state отражает локальные remote-tracking refs. Сеть используется
  только после явного `F`.
- Listing допускает не более четырёх одновременных worktree probes.
- Remove всегда повторяет status/upstream/buffer preflight после `y`.
- `git worktree remove` запускается без `--force`; branch не удаляется.
- Vigit не выгружает и не закрывает обычные source/terminal buffers.
- `:Vigit` переключается на v2 только после полного review gate.

---

### Task 1: Worktree model и read adapter

**Files:**

- Create: `lua/vigit/core/worktree.lua`
- Modify: `lua/vigit/adapters/git_cli.lua`
- Create: `tests/unit/worktree_spec.lua`
- Create: `tests/integration/git_worktree_read_spec.lua`

**Interfaces:**

- Produces:
  `worktree.parse_porcelain(raw) -> Result<Worktree[]>`,
  `worktree.removal_blocker(entry, loaded_paths) -> string|nil`.
- Produces:
  `git:worktrees(root, callback)`,
  `git:worktree_status(root, callback)`,
  `git:upstream(root, callback)`,
  `git:fetch(root, callback)`.

- [ ] **Step 1: Написать NUL parser и policy tests**

Cover main, linked, detached, bare, locked and prunable records, paths with
spaces/Unicode/newlines, empty fields and malformed input. Assert the first
valid worktree is `kind = "root"` and remaining entries are `kind = "linked"`.

```lua
local parsed = assert_ok(worktree.parse_porcelain(raw))
assert_equal(parsed[1].kind, "root")
assert_equal(parsed[2].kind, "linked")
assert_equal(parsed[2].branch, "feature/example")
```

For removal policy cover blockers in deterministic priority:
`root`, `locked`, `prunable`, `dirty`, `no_upstream`, `ahead`,
`loaded_source_buffer`. `behind > 0` alone is allowed because deleting the
local worktree cannot lose local commits.

- [ ] **Step 2: Запустить unit test и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/worktree_spec.lua
```

Expected: FAIL because worktree core does not exist.

- [ ] **Step 3: Реализовать pure parser и removal policy**

Parse NUL-terminated porcelain fields without line-based path assumptions.
Preserve `head`, `branch_ref`, detached/locked/prunable metadata. Normalize a
branch ref only after matching `refs/heads/`; never infer it from path.

`removal_blocker` consumes a fully enriched Worktree and canonical absolute
loaded source paths. It returns a stable error code, not a rendered message.

- [ ] **Step 4: Написать real-Git read matrix**

Create a primary repository plus clean, dirty, detached and locked linked
worktrees. Add a bare remote for upstream cases. Assert:

```lua
git:worktrees(primary, done)
git:worktree_status(linked, done)
git:upstream(linked, done)
```

Status must include staged, unstaged and untracked counts. Upstream cases:
tracking/equal, ahead, behind, diverged, detached and no-upstream. Commands
must not perform fetch.

- [ ] **Step 5: Реализовать read commands**

Use:

```lua
{ "git", "-C", root, "worktree", "list", "--porcelain", "-z" }
{ "git", "-C", root, "status", "--porcelain=v2", "--branch", "-z",
  "--untracked-files=all" }
{ "git", "-C", root, "rev-parse", "--abbrev-ref",
  "--symbolic-full-name", "@{upstream}" }
{ "git", "-C", root, "rev-list", "--left-right", "--count",
  "@{upstream}...HEAD" }
```

Map missing upstream/detached states to typed successful values, not generic
Git failures. `fetch` resolves the upstream remote from the tracking ref and
runs:

```lua
{ "git", "-C", root, "fetch", "--prune", remote }
```

It is never called by listing or refresh.

- [ ] **Step 6: Run tests**

Run:

```bash
lua tests/run.lua tests/unit/worktree_spec.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/git_worktree_read_spec.lua
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lua/vigit/core/worktree.lua lua/vigit/adapters/git_cli.lua tests/unit/worktree_spec.lua tests/integration/git_worktree_read_spec.lua
git commit -m "feat(worktrees): model local worktree state"
```

---

### Task 2: Async worktree listing и session picker

**Files:**

- Create: `lua/vigit/application/worktrees.lua`
- Create: `lua/vigit/ui/views/worktrees.lua`
- Modify: `lua/vigit/ui/controller.lua`
- Modify: `lua/vigit/ui/keymaps.lua`
- Modify: `lua/vigit/ui/renderer.lua`
- Modify: `lua/vigit/ui/registry.lua`
- Create: `tests/unit/worktrees_spec.lua`
- Create: `tests/headless/worktrees_spec.lua`

**Interfaces:**

- Produces:
  `worktrees_app.new({ git, registry, neovim, concurrency })`,
  `worktrees_app:list(origin_session, callback)`,
  `worktrees_app:open(entry, callback)`,
  `worktrees_app:fetch(entry, callback)`.
- Produces view intents:
  `open_worktrees`, `select_worktree`, `refresh_worktrees`,
  `fetch_worktree`.

- [ ] **Step 1: Написать bounded-concurrency tests**

Use a fake Git adapter with ten entries and manually completed callbacks.
Assert no more than four status/upstream probes run simultaneously, rows render
as soon as each probe completes, stale list generation is discarded, and one
failed probe does not discard other rows.

```lua
app:list(session, done)
assert_equal(fake_git.max_active, 4)
assert_equal(view.rows[1].loading, true)
complete_probe(1)
assert_equal(view.rows[1].loading, false)
```

- [ ] **Step 2: Написать registry open/focus tests**

Open two canonical roots, then select the first twice. Assert one Vigit session
per root, distinct view state and focus of the existing tab on repeated open.
When a root disappears during open, show `worktree_missing` and leave the
origin picker usable.

- [ ] **Step 3: Запустить tests и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/worktrees_spec.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/worktrees_spec.lua
```

Expected: FAIL because worktree use case/view do not exist.

- [ ] **Step 4: Реализовать listing coordinator**

Start one `git:worktrees` read, create placeholder rows, then schedule paired
status/upstream probes through a four-slot queue. Every callback checks picker
generation and origin session liveness. Render is coalesced; it does not wait
for all rows.

Rows expose:

```lua
{
  kind = "root" | "linked",
  name = "feature-example",
  path = "/canonical/path",
  branch = "feature/example",
  files = { staged = 1, unstaged = 2, untracked = 1 },
  upstream = { name = "origin/feature/example", ahead = 0, behind = 1 },
  open = true,
  loading = false,
  error = nil,
}
```

- [ ] **Step 5: Реализовать responsive picker**

Wide view shows TYPE, NAME, BRANCH and STATUS columns. Narrow view uses two
lines per worktree and never horizontally scrolls the confirmation/help line.
ROOT and WT receive distinct labels/highlights. `Enter` opens/focuses the
selected Vigit-tab; `[w`/`]w` move rows; `r` reloads; `F` fetches only the
selected row; `d` starts safe removal.

- [ ] **Step 6: Wire `W` and public picker entry**

`W` opens an owned floating Vigit buffer from any Vigit view.
`require("vigit.v2").worktrees({ cwd })` resolves the containing repository and
opens the same picker without requiring an existing session. Closing the
picker returns to its origin tab when still valid.

- [ ] **Step 7: Run Slice 4 picker gates**

Run:

```bash
lua tests/run.lua tests/unit/worktrees_spec.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/worktrees_spec.lua
```

Expected: PASS. Manual demo opens root and linked worktree, marks both
distinctly and cycles already open sessions without duplicates.

- [ ] **Step 8: Commit**

```bash
git add lua/vigit/application/worktrees.lua lua/vigit/ui/views/worktrees.lua lua/vigit/ui/controller.lua lua/vigit/ui/keymaps.lua lua/vigit/ui/renderer.lua lua/vigit/ui/registry.lua tests/unit/worktrees_spec.lua tests/headless/worktrees_spec.lua
git commit -m "feat(worktrees): add async session picker"
```

---

### Task 3: Safe worktree removal

**Files:**

- Modify: `lua/vigit/core/worktree.lua`
- Modify: `lua/vigit/application/worktrees.lua`
- Modify: `lua/vigit/adapters/git_cli.lua`
- Modify: `lua/vigit/adapters/neovim.lua`
- Modify: `lua/vigit/ui/confirm.lua`
- Modify: `lua/vigit/ui/controller.lua`
- Modify: `lua/vigit/ui/views/worktrees.lua`
- Modify: `lua/vigit/ui/registry.lua`
- Create: `tests/integration/git_worktree_remove_spec.lua`
- Create: `tests/headless/worktree_remove_spec.lua`

**Interfaces:**

- Produces:
  `neovim.loaded_source_buffers(root) -> BufferInfo[]`,
  `confirm.ask(message, callback)`,
  `git:remove_worktree(primary_root, target_root, callback)`,
  `worktrees_app:remove(entry, callback)`.

- [ ] **Step 1: Написать removal preflight matrix**

Create root, dirty, no-upstream, ahead, locked, prunable, loaded-buffer and safe
worktrees. Assert each unsafe row returns its exact blocker before asking for
confirmation. `behind > 0` with `ahead == 0` remains removable.

Loaded-buffer detection must use canonical absolute paths and path-component
boundaries, so `/repo/wt-two` does not match `/repo/wt-two-old`.
Vigit-owned `nofile` buffers and terminal buffers do not count as source
buffers.

- [ ] **Step 2: Написать y/N confirmation test**

Mock `vim.fn.confirm` and assert only `y` succeeds. `n`, empty, Esc and Enter
cancel because No is the default.

```lua
confirm.ask("Remove worktree …?", done)
confirm_callback(true)
assert_equal(confirmed, true)
```

- [ ] **Step 3: Написать race-safe real-Git test**

For a safe pushed linked worktree:

1. complete initial preflight;
2. accept `y`;
3. dirty the target before revalidation and assert no remove command runs;
4. clean it, retry and assert directory/registration disappear;
5. assert branch ref remains;
6. assert the primary root and unrelated worktrees are unchanged.

Run removal from the primary worktree, never with target as `cwd`.

- [ ] **Step 4: Запустить tests и подтвердить failure**

Run:

```bash
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/git_worktree_remove_spec.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/worktree_remove_spec.lua
```

Expected: FAIL because y/N confirmation/removal are absent.

- [ ] **Step 5: Усилить loaded source inspection**

Complete the Slice 2 adapter contract: inspect `nvim_list_bufs()`, keep only
loaded buffers with a non-empty normal file name and `buftype == ""`,
canonicalize existing paths, filter by the requested root at a path-component
boundary and return `BufferInfo[]`. Application passes only their paths into
the pure removal policy. This is read-only inspection: do not add
mappings/autocmds or close buffers.

- [ ] **Step 6: Реализовать double preflight и remove**

`remove` performs:

1. pure policy check against current picker model;
2. `y/N` confirmation with default No;
3. fresh worktree list, target status, upstream and loaded-buffer reads;
4. pure policy check of the fresh entry;
5. `{ "git", "-C", primary_root, "worktree", "remove", "--", target_root }`;
6. fresh worktree list proving target registration disappeared.

Non-zero Git exit or remaining registration returns `unsafe_worktree`/`git_failed`
and keeps every tab open.

- [ ] **Step 7: Close only owned Vigit session after success**

Registry removes the target session and closes its Vigit-tab after Git
postcondition succeeds. It MUST NOT delete buffers, wipe source files, close
the normal editor-tab or terminal-tab. Picker remains in its origin session and
refreshes rows.

- [ ] **Step 8: Run removal gates**

Run:

```bash
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/git_worktree_remove_spec.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/worktree_remove_spec.lua
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lua/vigit/core/worktree.lua lua/vigit/application/worktrees.lua lua/vigit/adapters/git_cli.lua lua/vigit/adapters/neovim.lua lua/vigit/ui/confirm.lua lua/vigit/ui/controller.lua lua/vigit/ui/views/worktrees.lua lua/vigit/ui/registry.lua tests/integration/git_worktree_remove_spec.lua tests/headless/worktree_remove_spec.lua
git commit -m "feat(worktrees): remove completed worktrees safely"
```

---

### Task 4: Central help, refresh observers и diagnostics

**Files:**

- Create: `lua/vigit/ui/log.lua`
- Create: `lua/vigit/ui/views/help.lua`
- Create: `scripts/generate-keymaps.lua`
- Create: `docs/keymaps.md`
- Modify: `lua/vigit/config.lua`
- Modify: `lua/vigit/init.lua`
- Modify: `lua/vigit/v2.lua`
- Modify: `lua/vigit/ui/controller.lua`
- Modify: `lua/vigit/ui/keymaps.lua`
- Create: `tests/unit/keymaps_spec.lua`
- Create: `tests/unit/log_spec.lua`
- Create: `tests/headless/observers_spec.lua`

**Interfaces:**

- Produces:
  `keymaps.entries()`,
  `keymaps.for_context(context, config)`,
  `keymaps.render_markdown()`.
- Produces:
  `log.push(error)`,
  `log.entries()`,
  `log.open()`.
- Registers `:VigitHelp`, `:VigitLog` and one owned autocmd group.

- [ ] **Step 1: Написать registry consistency tests**

Assert every action ID and active `{context, lhs, mode}` is unique, disabled
mapping is absent, inline help and Markdown are generated from the same
entries, and no public mapping targets a non-existent controller intent.

Expected registry entries across all Vigit contexts:

```text
Tab Enter ]f [f ]h [h ]w [w e gd a s S x X c C P f t r T W F d ? q
```

`a` toggles one/all files. `s` acts on a file, `S` on a hunk. `x` restores an
unstaged hunk, while `X` restores the entire file.

- [ ] **Step 2: Написать bounded log tests**

Store at most 200 entries, preserve timestamp/session/error code/details and
never treat diagnostics as a successful Result. Rendering escapes control
bytes and remains read-only.

- [ ] **Step 3: Написать observer lifecycle tests**

After two idempotent `setup()` calls, assert exactly one Vigit augroup exists.
`BufWritePost` under a known root schedules one debounced refresh for that
session; unrelated file does nothing. `TabEnter` refreshes only a Vigit-tab.
Closing a session cancels pending scheduled work through liveness/generation
checks.

- [ ] **Step 4: Запустить tests и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/keymaps_spec.lua tests/unit/log_spec.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/observers_spec.lua
```

Expected: FAIL because generated help/log/observers are incomplete.

- [ ] **Step 5: Реализовать central registry и generated docs**

Keep registry data free of `vim` side effects. `vim.keymap.set` consumes it only
for owned buffer IDs. `scripts/generate-keymaps.lua` writes
`docs/keymaps.md`; `--check` compares generated content and exits non-zero on
drift.

The full help view groups keys by navigation, view, Git, comments, worktrees
and lifecycle. Header hints remain a width-aware subset, never an independent
hard-coded list.

- [ ] **Step 6: Реализовать diagnostics**

Every adapter/application error is appended to the ring buffer before compact
UI rendering. `:VigitLog` opens an owned read-only scratch buffer with newest
entries last and includes argument arrays/cwd/exit status without reconstructing
a shell command.

- [ ] **Step 7: Реализовать read-only observers**

Create one named augroup with `clear = true`. Global `BufWritePost` and
`TabEnter` callbacks only identify affected sessions and request debounced
refresh. They do not modify source buffer options, mappings, winbar or
autocmd-local state.

WhichKey integration is intentionally not added in this refactor. The central
registry is the future extension point, while clean Neovim remains the required
runtime.

- [ ] **Step 8: Run help/observer gates**

Run:

```bash
lua tests/run.lua tests/unit/keymaps_spec.lua tests/unit/log_spec.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/observers_spec.lua
lua scripts/generate-keymaps.lua --check
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lua/vigit/config.lua lua/vigit/init.lua lua/vigit/v2.lua lua/vigit/ui/log.lua lua/vigit/ui/views/help.lua lua/vigit/ui/controller.lua lua/vigit/ui/keymaps.lua scripts/generate-keymaps.lua docs/keymaps.md tests/unit/keymaps_spec.lua tests/unit/log_spec.lua tests/headless/observers_spec.lua
git commit -m "feat(ui): centralize help and diagnostics"
```

---

### Task 5: Public cutover, legacy removal и project documentation

**Files:**

- Modify: `lua/vigit/init.lua`
- Modify: `lua/vigit/v2.lua`
- Delete: `lua/vigit/actions.lua`
- Delete: `lua/vigit/changes_view.lua`
- Delete: `lua/vigit/confirm.lua`
- Delete: `lua/vigit/git.lua`
- Delete: `lua/vigit/help.lua`
- Delete: `lua/vigit/highlights.lua`
- Delete: `lua/vigit/keymaps.lua`
- Delete: `lua/vigit/parser.lua`
- Delete: `lua/vigit/review.lua`
- Delete: `lua/vigit/review_editor.lua`
- Delete: `lua/vigit/review_ui.lua`
- Delete: `lua/vigit/state.lua`
- Delete: `lua/vigit/syntax.lua`
- Delete: `lua/vigit/ui.lua`
- Delete: `lua/vigit/worktree_picker.lua`
- Delete: `lua/vigit/worktrees.lua`
- Modify: `tests/run.lua`
- Delete: legacy `tests/*_spec.lua` after equivalent v2 scenario coverage
- Modify: `scripts/demo.sh`
- Modify: `scripts/demo_init.lua`
- Modify: `scripts/demo_user_init.lua`
- Modify: `scripts/demo_plugins_init.lua`
- Modify: `skills/vigit-review/SKILL.md`
- Modify: `skills/vigit-review/agents/openai.yaml`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/keymaps.md`
- Create: `scripts/test.sh`
- Create: `tests/headless/cutover_spec.lua`

**Interfaces:**

- `require("vigit").open()` and `:Vigit` use v2.
- `require("vigit.v2")` and `:VigitV2` remain compatibility aliases for one
  release cycle.
- Removes all legacy internal Lua API guarantees.

- [ ] **Step 1: Написать cutover characterization test**

Before switching commands, assert the v2 API can independently perform:

1. open/focus two worktree sessions;
2. render tree/list and one/all modes;
3. hand off editor, `gd` and terminal without ownership;
4. stage/unstage/rollback exact scopes;
5. create/read comments;
6. open help/log/worktree picker.

Run this test against `:VigitV2` and confirm PASS before deleting legacy.

- [ ] **Step 2: Написать public command test**

After cutover assert one registration for:

```text
Vigit
VigitV2
VigitWorktrees
VigitComments
VigitHelp
VigitLog
VigitMigrateReviews
VigitInstallCodexSkill
```

`:Vigit` and `:VigitV2` must focus the same canonical-root session. Repeated
`setup()` must not duplicate commands/autocmds.

- [ ] **Step 3: Switch public API**

Move v2 setup/open/worktrees/help exports to `lua/vigit/init.lua`.
Keep `lua/vigit/v2.lua` as a thin forwarding module with no independent state.
Remove legacy commands only after v2 commands are registered and headless
characterization passes.

- [ ] **Step 4: Replace legacy tests before deleting modules**

For every legacy test, record the user behavior it protects and point it to an
equivalent unit/integration/headless v2 test. Port missing behavior first.
Then remove obsolete module-coupled mocks and update `tests/run.lua` to discover
only v2 suites. Do not delete a failing test merely because its internal API
changed.

- [ ] **Step 5: Delete legacy implementation**

Remove the listed top-level modules and run:

```bash
rg -n 'require\\(\"vigit\\.(actions|changes_view|confirm|git|help|highlights|keymaps|parser|review|review_editor|review_ui|state|syntax|ui|worktree_picker|worktrees)\"\\)' lua tests scripts
```

Expected: no references. `skill.lua` remains because installation of the
bundled Codex skill is still public functionality.

- [ ] **Step 6: Update demo fixtures**

The isolated demo creates:

- root plus at least one linked worktree;
- long staged/unstaged files and mixed hunks;
- tracked `.vigit/comments.md` with open and completed comments;
- a local bare remote with safe, dirty, ahead and no-upstream worktree states.

`demo.sh` keeps EXIT cleanup working by launching Neovim normally, not through
`exec`. `--user-config` and `--plugins` reuse the same fixture without changing
the user's config.

- [ ] **Step 7: Update bundled agent skill**

The prompt/skill tells the agent to:

1. read only open entries from `.vigit/comments.md`;
2. inspect anchors and modify project source as needed;
3. write a concise answer under `### Ответ агента`;
4. set `[x]` only after the requested change/question is resolved;
5. leave unknown Markdown and other comments unchanged;
6. never stage, commit, push or delete a worktree unless the user separately
   asks.

Legacy review storage is mentioned only in the explicit migration section.

- [ ] **Step 8: Update README, contributor guide and keymap reference**

README documents product purpose, Neovim/Git requirements, lazy.nvim setup,
`:Vigit`, worktree/editor model, canonical comments workflow, safety rules,
keymap summary and all demo modes. Link `docs/keymaps.md` for the generated
complete reference.

AGENTS documents new directories, `scripts/test.sh`, real-Git/headless tests
and the no-source-buffer-ownership invariant. Remove legacy module guidance.

- [ ] **Step 9: Add one validation entrypoint**

`scripts/test.sh` runs, in order:

```bash
lua tests/run.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua
lua scripts/generate-keymaps.lua --check
```

The script stops on first failure and never installs dependencies or mutates
the user's Neovim config.

- [ ] **Step 10: Run full automated and manual matrix**

Run:

```bash
./scripts/test.sh
./scripts/demo.sh
./scripts/demo.sh --user-config
./scripts/demo.sh --plugins
```

Manual gates:

- two worktrees keep independent Vigit/editor state;
- source buffer mappings, LSP and jumplist remain user-owned;
- syntax works before any editor handoff;
- staged deletion and added/old snapshots are highlighted;
- stale patch does not mutate Git;
- comment response/checkbox refresh from disk;
- safe open Vigit worktree can be removed while source-buffer blocker remains;
- narrow layout keeps all header hints discoverable through `?`.

- [ ] **Step 11: Commit**

```bash
git add lua/vigit tests scripts skills/vigit-review README.md AGENTS.md docs/keymaps.md
git commit -m "refactor!: cut over to vigit v2"
```

### Slice 4 Review Gate

- [ ] Picker distinguishes ROOT/WT and never performs implicit fetch.
- [ ] Remove revalidates safety, requires explicit `y` and keeps branch.
- [ ] Only owned Vigit resources close after successful removal.
- [ ] Help/header/docs are generated from one keymap registry.
- [ ] `:Vigit` and `:VigitV2` reach the same v2 session.
- [ ] No legacy module reference remains.
- [ ] `./scripts/test.sh` and all three demo modes complete successfully.
