# Git adapter contract

## Process boundary

```lua
process.run(args, opts, callback) -> Job

args = {
  "git", "status", "--porcelain=v2", "--branch", "-z",
  "--untracked-files=all",
}
opts = {
  cwd = "/canonical/worktree",
  stdin = nil,
  timeout_ms = 10000,
}

callback(Result<ProcessOutput>)

ProcessOutput = {
  code = 0,
  signal = 0,
  stdout = "...",
  stderr = "",
}
```

`args` MUST быть array. String command отклоняется. `Job.cancel()` посылает
termination signal, но caller всё равно проверяет generation.

## Read API

```lua
git.status(root, callback)               -- Result<Status>
git.diff(root, change, context, callback) -- Result<FileDiff>
git.snapshot(root, change, side, callback) -- Result<string>
git.worktrees(root, callback)            -- Result<Worktree[]>
git.upstream(root, callback)             -- Result<Upstream>
git.fetch(root, callback)                -- Result<true>
```

Commands:

```text
git -C <root> status --porcelain=v2 --branch -z --untracked-files=all
git -C <root> diff --no-ext-diff --unified=<n> -- <path>
git -C <root> diff --cached --no-ext-diff --unified=<n> -- <path>
git -C <root> show <revision>:<path>
git -C <root> worktree list --porcelain -z
git -C <root> rev-list --left-right --count @{upstream}...HEAD
git -C <root> fetch --prune <upstream-remote>
```

Untracked diff строится как synthetic FileDiff из filesystem content; внешний
`git diff --no-index /dev/null` не требуется.

## Mutation API

```lua
git.stage_file(root, change, callback)
git.unstage_file(root, change, callback)
git.stage_hunk(root, file_diff, hunk, callback)
git.unstage_hunk(root, file_diff, hunk, callback)
git.restore_hunk(root, file_diff, hunk, callback)
git.restore_file(root, change, callback)
git.remove_worktree(repo_root, target_root, callback)
```

Hunk flow:

1. Build full patch with exact old/new headers and selected hunk.
2. Run matching `git apply --check` command.
3. Only on code 0 run the same command without `--check`.
4. Return `patch_conflict` without broader fallback on any failure.

File/hunk operation receives model identity from latest state. Application layer
rejects an intent when selected `change_id`/`hunk_id` is no longer present.

## Error codes

| Code | Meaning |
| --- | --- |
| `not_repository` | Path is not inside a worktree |
| `git_unavailable` | Process could not start |
| `git_failed` | Git exited non-zero |
| `invalid_status` | Porcelain record violated parser contract |
| `invalid_diff` | Patch could not be parsed |
| `diff_too_large` | stdout exceeded configured file limit |
| `stale_change` | Model identity disappeared before mutation |
| `patch_conflict` | `git apply --check` rejected patch |
| `unsafe_worktree` | Removal preflight returned blocker |

Diagnostic details include argument list, cwd, exit code and stderr, but never
shell-escaped reconstructed execution.
