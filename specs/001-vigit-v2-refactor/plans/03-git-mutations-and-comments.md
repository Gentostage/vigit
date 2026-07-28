# Vigit v2 Git Mutations and Comments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить точные, сериализованные stage/unstage/rollback операции и
один tracked `.vigit/comments.md` для review loop с AI-агентом.

**Architecture:** Mutation queue исполняет Git use cases по одной на session.
Pure patch/comment modules создают проверяемые данные, Git/filesystem adapters
выполняют side effects, а Vigit views только собирают intent и показывают
Result.

**Tech Stack:** Git apply/restore, Lua, atomic filesystem rename, Markdown,
real-repository integration tests.

## Global Constraints

- Любой hunk patch проходит matching `git apply --check`.
- Failure не вызывает file-level fallback.
- `x` работает только для unstaged hunk; staged hunk сначала unstage через `S`.
- `X` и удаление untracked требуют `y/N`.
- Mutation success определяется post-operation status refresh.
- Comments не имеют второго JSON source of truth.

---

### Task 1: Serialized mutation queue и compact confirmation

**Files:**

- Create: `lua/vigit/application/mutations.lua`
- Create: `lua/vigit/ui/confirm.lua`
- Create: `tests/unit/mutations_spec.lua`
- Create: `tests/headless/confirm_spec.lua`

**Interfaces:**

- Consumes: Session mutation/error fields.
- Produces:
  `mutations.new({ on_change })`,
  `mutations:enqueue(session, operation)`.
- `operation = { id, run(done), after_success(result) }`.
- Produces: `confirm.ask(message, callback)` returning `true` only for explicit
  Yes.

- [ ] **Step 1: Написать FIFO and failure tests**

```lua
queue:enqueue(session, op("first", function(done)
  first_done = done
end))
queue:enqueue(session, op("second", function(done)
  second_started = true
  done(Result.ok(true))
end))

assert_equal(session.mutations.active, true)
assert_equal(second_started, nil)
first_done(Result.ok(true))
assert_equal(second_started, true)
```

Add cases: failed first still advances queue, closed session does not invoke
`after_success`, duplicate operation ID cannot run twice, busy/error changes
call `on_change`.

- [ ] **Step 2: Запустить queue test и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/mutations_spec.lua
```

Expected: FAIL because mutation module does not exist.

- [ ] **Step 3: Реализовать one-active-operation invariant**

`enqueue` appends immutable operation. Private `drain` starts only when
`active == false`, wraps `done` as once-only, records typed errors and always
continues with the next entry. Application code, not Git adapter, triggers
post-success refresh.

- [ ] **Step 4: Написать and implement `y/N` confirmation test**

Mock `vim.fn.confirm` and assert exact call:

```lua
local answer = vim.fn.confirm(message, "&Yes\n&No", 2)
callback(answer == 1)
```

Empty/Esc/default returns false. Confirmation module MUST NOT execute action
itself.

- [ ] **Step 5: Запустить tests**

Run:

```bash
lua tests/run.lua tests/unit/mutations_spec.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/confirm_spec.lua
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lua/vigit/application/mutations.lua lua/vigit/ui/confirm.lua tests/unit/mutations_spec.lua tests/headless/confirm_spec.lua
git commit -m "refactor(git): serialize mutation intents"
```

---

### Task 2: File stage/unstage contracts

**Files:**

- Modify: `lua/vigit/adapters/git_cli.lua`
- Modify: `lua/vigit/application/mutations.lua`
- Modify: `lua/vigit/ui/controller.lua`
- Modify: `lua/vigit/ui/keymaps.lua`
- Create: `tests/integration/git_file_mutations_spec.lua`

**Interfaces:**

- Produces:
  `git:stage_file(root, change, callback)`,
  `git:unstage_file(root, change, callback)`.
- Produces controller intent `toggle_file_index`.

- [ ] **Step 1: Написать real-Git file mutation matrix**

For each case snapshot worktree bytes plus:

```bash
git status --porcelain=v2 -z --untracked-files=all
git diff --binary
git diff --cached --binary
```

Cases: tracked modified, deleted, renamed with spaces, untracked, staged added,
mixed staged+unstaged and unborn HEAD. Assertions:

```lua
git:stage_file(root, unstaged, done)
assert_equal(status().unstaged_count, 0)
assert_equal(file_bytes(), before_bytes)

git:unstage_file(root, staged, done)
assert_equal(status().staged_count, 0)
assert_equal(file_bytes(), before_bytes)
```

- [ ] **Step 2: Запустить integration test и подтвердить failure**

Run:

```bash
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/git_file_mutations_spec.lua
```

Expected: FAIL because new mutation methods are absent.

- [ ] **Step 3: Реализовать file stage**

Use exactly:

```lua
{ "git", "add", "--", change.path }
```

For rename include only current path; status refresh determines resulting
identity. Reject stale/missing paths before enqueue.

- [ ] **Step 4: Реализовать file unstage through reverse cached patch**

Read:

```lua
{ "git", "diff", "--cached", "--binary", "--full-index", "--", change.path }
```

Then run `git apply --cached --reverse --check`, followed by the same arguments
without `--check`, passing patch via stdin. This works for unborn HEAD and
preserves worktree bytes. Empty patch returns `stale_change`.

- [ ] **Step 5: Wire dynamic `s`**

`s` in staged section enqueues `unstage_file`; in unstaged section enqueues
`stage_file`. Disable while another mutation runs only for the same session.
Success refreshes status/diff and restores the closest anchor.

- [ ] **Step 6: Run mutation and full integration suites**

Run:

```bash
nvim --headless --clean -u NONE -l tests/integration/run.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lua/vigit/adapters/git_cli.lua lua/vigit/application/mutations.lua lua/vigit/ui/controller.lua lua/vigit/ui/keymaps.lua tests/integration/git_file_mutations_spec.lua
git commit -m "feat(git): toggle file index safely"
```

---

### Task 3: Exact hunk patch stage/unstage

**Files:**

- Create: `lua/vigit/core/patch.lua`
- Modify: `lua/vigit/adapters/git_cli.lua`
- Modify: `lua/vigit/ui/controller.lua`
- Modify: `lua/vigit/ui/keymaps.lua`
- Create: `tests/unit/patch_spec.lua`
- Create: `tests/integration/git_hunk_mutations_spec.lua`

**Interfaces:**

- Consumes: FileDiff/Hunk models.
- Produces:
  `patch.for_hunk(file_diff, hunk) -> Result<string>`.
- Produces:
  `git:stage_hunk(root, file_diff, hunk, callback)`,
  `git:unstage_hunk(root, file_diff, hunk, callback)`.
- Produces controller intent `toggle_hunk_index`.

- [ ] **Step 1: Написать exact patch unit tests**

```lua
local result = patch.for_hunk(renamed_file, selected_hunk)
assert_truthy(result.ok)
assert_truthy(result.value:match("diff %-%-git a/old/a%.lua b/new/a%.lua"))
assert_truthy(result.value:match("rename from old/a%.lua"))
assert_truthy(result.value:match("@@ %-10,2 %+10,3 @@"))
assert_equal(count_hunk_headers(result.value), 1)
```

Cover modified, added, deleted, rename, newline-at-EOF and binary/metadata-only
rejection.

- [ ] **Step 2: Запустить patch tests и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/patch_spec.lua
```

Expected: FAIL because patch module does not exist.

- [ ] **Step 3: Реализовать full selected-hunk patch**

Preserve `diff --git`, mode/index/rename headers, `---`/`+++`, selected hunk
header/lines and `\ No newline at end of file`. Reject any hunk whose current
file identity differs from session state.

- [ ] **Step 4: Написать hunk integration matrix**

Create two non-overlapping hunks and assert only selected hunk moves layers.
Cases: modified, delete, rename with content, added already represented in
index. For a completely untracked file, assert `unsupported_hunk` and unchanged
index; user must stage the file as a whole.

- [ ] **Step 5: Реализовать matching preflight/apply pairs**

Stage:

```lua
{ "git", "apply", "--cached", "--recount", "--check", "-" }
{ "git", "apply", "--cached", "--recount", "-" }
```

Unstage:

```lua
{ "git", "apply", "--cached", "--reverse", "--recount", "--check", "-" }
{ "git", "apply", "--cached", "--reverse", "--recount", "-" }
```

Use identical patch stdin for check and mutation. Any check error maps to
`patch_conflict`.

- [ ] **Step 6: Wire `S` and verify stale-hunk protection**

Controller obtains hunk ID from current rendered metadata, re-resolves it in
latest state immediately before enqueue, then calls stage/unstage based on
section.

- [ ] **Step 7: Run suites**

Run:

```bash
lua tests/run.lua tests/unit/patch_spec.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/git_hunk_mutations_spec.lua
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lua/vigit/core/patch.lua lua/vigit/adapters/git_cli.lua lua/vigit/ui/controller.lua lua/vigit/ui/keymaps.lua tests/unit/patch_spec.lua tests/integration/git_hunk_mutations_spec.lua
git commit -m "feat(git): toggle exact hunk patches"
```

---

### Task 4: Safe hunk/file rollback

**Files:**

- Modify: `lua/vigit/adapters/git_cli.lua`
- Modify: `lua/vigit/application/mutations.lua`
- Modify: `lua/vigit/ui/controller.lua`
- Modify: `lua/vigit/ui/keymaps.lua`
- Create: `tests/integration/git_rollback_spec.lua`
- Create: `tests/headless/rollback_spec.lua`

**Interfaces:**

- Produces:
  `git:restore_hunk(root, file_diff, hunk, callback)`,
  `git:restore_file(root, change, callback)`.
- Produces controller intents `restore_hunk`, `restore_file`.

- [ ] **Step 1: Написать hunk rollback invariants**

For two unstaged hunks, assert `x` reverse-applies only selected hunk to
worktree and leaves index byte-identical. Modify the file after render so
`--check` fails; assert worktree/index snapshots remain byte-identical and error
code is `patch_conflict`.

For a staged hunk assert adapter/controller returns `unstage_first` without
executing a process.

- [ ] **Step 2: Написать full-file matrix**

Cases:

- unstaged tracked -> restore worktree from index;
- mixed/staged tracked -> restore index and worktree from HEAD;
- staged added -> remove index entry and worktree file;
- untracked file -> unlink exact path;
- deleted/renamed tracked -> restore HEAD identity.

Reject confirmation and assert all snapshots unchanged.

- [ ] **Step 3: Запустить tests и подтвердить failure**

Run:

```bash
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/git_rollback_spec.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/rollback_spec.lua
```

Expected: FAIL because rollback methods/intents are absent.

- [ ] **Step 4: Реализовать unstaged hunk rollback**

Use selected unstaged patch:

```lua
{ "git", "apply", "--reverse", "--recount", "--check", "-" }
{ "git", "apply", "--reverse", "--recount", "-" }
```

Do not use `--cached`; index must remain unchanged.

- [ ] **Step 5: Реализовать status-aware file restore**

After confirmation:

- untracked: filesystem adapter validates path under root and unlinks only a
  regular file/symlink;
- added with no HEAD entry: reverse cached full patch, then unlink;
- tracked: `git restore --source=HEAD --staged --worktree -- <path>`;
- unstaged-only `x` on file header: `git restore --worktree -- <path>`.

Run post-status verification; success requires target layer/path to disappear
as expected.

- [ ] **Step 6: Wire `x` and `X` confirmations**

`x` selects current unstaged hunk or unstaged file scope. `X` always describes
loss of staged and unstaged changes to HEAD; for `?` it says deletion. Both call
`confirm.ask`, default No.

- [ ] **Step 7: Run all mutation gates**

Run:

```bash
lua tests/run.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lua/vigit/adapters/git_cli.lua lua/vigit/application/mutations.lua lua/vigit/ui/controller.lua lua/vigit/ui/keymaps.lua tests/integration/git_rollback_spec.lua tests/headless/rollback_spec.lua
git commit -m "feat(git): restore hunks and files safely"
```

---

### Task 5: Canonical Markdown comments и atomic storage

**Files:**

- Create: `lua/vigit/core/review.lua`
- Create: `lua/vigit/adapters/filesystem.lua`
- Create: `tests/unit/review_spec.lua`
- Create: `tests/integration/filesystem_spec.lua`

**Interfaces:**

- Implements every pure function in
  [`contracts/comments-format.md`](../contracts/comments-format.md).
- Produces:
  `filesystem.resolve_under(root, relative) -> Result<absolute>`,
  `filesystem.read(path) -> Result<string>`,
  `filesystem.atomic_write(root, relative, content) -> Result<true>`,
  `filesystem.unlink_under(root, relative) -> Result<true>`.

- [ ] **Step 1: Написать Markdown round-trip tests**

Parse two comments plus unknown prose. Update only VIGIT-002 and assert prefix,
unknown prose and raw VIGIT-001 block remain byte-identical. Cover add, edit,
delete, `[x]`, response, escaped context, duplicate ID, invalid traversal and
malformed metadata.

```lua
local document = assert_ok(review.parse(markdown))
local updated = assert_ok(review.update(document, "VIGIT-002", {
  body = "Новый текст",
}))
assert_truthy(review.serialize(updated):find(raw_first_block, 1, true))
```

- [ ] **Step 2: Запустить review test и подтвердить failure**

Run:

```bash
lua tests/run.lua tests/unit/review_spec.lua
```

Expected: FAIL because review core does not exist.

- [ ] **Step 3: Реализовать block-preserving parser**

Document stores ordered `{ kind = "raw", raw }` and
`{ kind = "comment", raw, value }` blocks. Serializer concatenates untouched
raw blocks; only modified/new comment block is canonicalized. IDs use maximum
numeric suffix + 1.

- [ ] **Step 4: Написать filesystem safety tests**

Inside a real temp root test atomic replacement, missing directory creation and
preservation after simulated rename/write failure. Create `.vigit` symlink to
an outside directory and assert `path_outside_root`. Test unlink refuses a
directory and path traversal.

- [ ] **Step 5: Реализовать safe atomic writer**

Normalize lexical path, resolve parent realpath after directory creation, verify
root prefix at path-component boundary, write sibling temp with `vim.uv`,
`fs_fsync`, close and `fs_rename`. Cleanup only the temp path after failure.

- [ ] **Step 6: Run pure and filesystem suites**

Run:

```bash
lua tests/run.lua tests/unit/review_spec.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua tests/integration/filesystem_spec.lua
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lua/vigit/core/review.lua lua/vigit/adapters/filesystem.lua tests/unit/review_spec.lua tests/integration/filesystem_spec.lua
git commit -m "feat(review): add canonical markdown comment storage"
```

---

### Task 6: Comment use cases, UI, prompt и explicit importer

**Files:**

- Create: `lua/vigit/application/reviews.lua`
- Create: `lua/vigit/adapters/legacy_review.lua`
- Create: `lua/vigit/ui/views/comments.lua`
- Modify: `lua/vigit/ui/controller.lua`
- Modify: `lua/vigit/ui/keymaps.lua`
- Modify: `lua/vigit/ui/renderer.lua`
- Modify: `lua/vigit/init.lua`
- Create: `tests/unit/reviews_spec.lua`
- Create: `tests/headless/comments_spec.lua`
- Create: `tests/integration/legacy_review_spec.lua`

**Interfaces:**

- Consumes: Review core, filesystem, SourceAnchor, confirmation.
- Produces:
  `reviews:load(session)`,
  `reviews:add(session, anchor, body)`,
  `reviews:update(session, id, body)`,
  `reviews:delete(session, id)`,
  `reviews:prompt(session)`,
  `reviews:migrate_legacy(session)`.

- [ ] **Step 1: Написать application use-case tests**

Use in-memory filesystem adapter. Assert add/write/reload, `[x]` external
completion, nearest anchor lookup, write failure preserving state, and prompt
containing only open comments plus exact root/path instructions.

- [ ] **Step 2: Написать headless comment flow**

Create comment with `c`, assert marker text contains ID and body preview, press
`c` again to edit, open `C`, jump with Enter, delete with default-No/Yes, and
invoke `P`. Comment editor/list/help buffers MUST be owned Vigit UI.

- [ ] **Step 3: Run tests and confirm failure**

Run:

```bash
lua tests/run.lua tests/unit/reviews_spec.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/comments_spec.lua
```

Expected: FAIL because use case/view do not exist.

- [ ] **Step 4: Implement comment use cases and UI**

Write `.vigit/comments.md` after every accepted operation, then install the new
Document in session state. Marker virtual text:

```text
● VIGIT-001 · Need to handle RepositoryError…
```

`C` lists open first, then done; Enter closes list and selects nearest diff
anchor. `P` copies prompt when clipboard exists, otherwise opens read-only
Vigit prompt buffer.

- [ ] **Step 5: Написать explicit legacy importer tests**

Build current `<git-common-dir>/vigit/worktrees/<id>` fixture. Assert importer:

1. returns preview before mutation;
2. requires confirmation;
3. copies legacy source to timestamped `backups/`;
4. merges comments without overwriting existing IDs;
5. leaves legacy data untouched;
6. does nothing automatically during normal load.

- [ ] **Step 6: Implement `:VigitMigrateReviews`**

`legacy_review` is the only module aware of old JSON/pointer paths.
`init.setup()` registers command; it operates on the current Vigit v2 session
and refreshes comments after successful import.

- [ ] **Step 7: Run Slice 3 gates**

Run:

```bash
lua tests/run.lua
nvim --headless --clean -u NONE -l tests/integration/run.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua
```

Expected: PASS. Manual V2 demo creates `.vigit/comments.md`, Git status shows
it, and external checkbox/response edits appear after `r`.

- [ ] **Step 8: Commit**

```bash
git add lua/vigit/application/reviews.lua lua/vigit/adapters/legacy_review.lua lua/vigit/ui lua/vigit/init.lua tests/unit/reviews_spec.lua tests/headless/comments_spec.lua tests/integration/legacy_review_spec.lua
git commit -m "feat(review): connect comments to agent markdown"
```

### Slice 3 Review Gate

- [ ] File and hunk operations preserve unrelated worktree/index bytes.
- [ ] Patch conflict leaves all Git layers unchanged.
- [ ] Staged hunk requires `S` before `x`.
- [ ] Destructive default is No.
- [ ] One `.vigit/comments.md` reproduces all comments/statuses/responses.
- [ ] Prompt neither stages nor invokes an agent.
