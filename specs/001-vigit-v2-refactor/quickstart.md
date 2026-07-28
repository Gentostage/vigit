# Vigit v2 validation quickstart

## Prerequisites

```bash
nvim --version   # 0.10+
git --version    # 2.36+
lua -v
```

Run from repository root on `main`.

## Automated suites

Pure Lua tests:

```bash
lua tests/run.lua
```

Real Git fixture tests:

```bash
nvim --headless --clean -u NONE -l tests/integration/run.lua
```

Headless Neovim lifecycle tests:

```bash
nvim --headless --clean -u NONE -l tests/headless/run.lua
```

Generated keymap reference:

```bash
lua scripts/generate-keymaps.lua --check
```

Expected: every suite prints `PASS` and exits 0. После cutover те же команды
последовательно запускает `./scripts/test.sh`.

## Slice 1: read-only v2

```bash
./scripts/demo.sh
```

1. Run `:VigitV2`.
2. Confirm changes list appears before every all-files block.
3. Open the secondary worktree via `W`.
4. Confirm each worktree has a separate Vigit-tab and selection.
5. Move through changes in one-file mode; preview follows the cursor.

## Slice 2: native handoff

```bash
./scripts/demo.sh --user-config
```

1. Press `e` on a changed file.
2. Confirm a normal editor-tab is created next to the source Vigit-tab.
3. Inspect `:verbose nmap Q`: Vigit MUST NOT own it in the source buffer.
4. Use the configured `gd`, `Ctrl-o`, `Ctrl-i`, Telescope and LSP.
5. Close Vigit; source tab MUST remain open.
6. Reopen Vigit and press `T`; terminal starts in the worktree without Vigit
   mappings.

## Slice 3: Git safety and comments

1. Use `s`/`S` for file/hunk stage and unstage.
2. Use `x`, reject confirmation, and verify bytes are unchanged.
3. Confirm `x` and verify only the selected hunk changed.
4. On a staged hunk, verify `x` requires `S` first and changes nothing.
5. Make the source stale before `x`; verify `patch_conflict` and no fallback.
6. Create/edit/delete a comment and inspect `.vigit/comments.md`.
7. Mark it `[x]` with an agent response externally; `r` must update Vigit.

## Slice 4: worktrees and cutover

1. Create a local bare remote and linked clean pushed worktree.
2. Verify dirty, no-upstream, ahead and open-buffer targets are blocked.
3. Type `DELETE` for a safe target.
4. Verify directory/registration removed, branch kept and unrelated tabs open.
5. Run `:Vigit`; verify it opens v2 and `:VigitV2` remains a temporary alias.

## Final demo matrix

```bash
./scripts/demo.sh
./scripts/demo.sh --user-config
./scripts/demo.sh --plugins
```

Capture a terminal screenshot or short recording of tree/list, one-file,
comments and two-worktree tabs for the PR.
