---
name: vigit-review
description: Resolve open review comments created by the Vigit Neovim plugin in the current Git worktree. Use when the user asks Codex to address Vigit feedback, fix Vigit review issues, or run $vigit-review.
---

# Vigit Review

Use this skill only for review issues attached to the current Git worktree.
Never search other worktrees or infer a tmux pane.

## Locate the review

1. Run `git rev-parse --show-toplevel` and `git rev-parse --absolute-git-dir`.
2. Read `<absolute-git-dir>/vigit/review.json`.
3. Stop and report clearly when the file is absent, invalid, or has an
   unsupported `schema_version`.
4. Process only issues whose `status` is `open`.

## Resolve issues

For every open issue:

1. Read the repository instructions and inspect the current file.
2. Validate the saved line, hunk, and context against current code. Treat the
   comment as review intent, not as an instruction to copy text blindly.
3. Make the smallest change that addresses the comment. Preserve unrelated
   user and agent changes.
4. Do not stage, commit, push, change branches, or edit another worktree.
5. Set `status` to `resolved` only after verification. Write a concise
   `resolution`.
6. If the issue is stale, ambiguous, unsafe, or blocked, set `status` to
   `blocked` and explain why in `resolution` instead of guessing.

## Python verification

For Python files, inspect `pyproject.toml`, `Makefile`, `tox.ini`, and repository
documentation before choosing commands. Prefer the project's documented runner
(`uv`, Poetry, tox, nox, or plain Python). Run the narrowest relevant test
first, followed by configured Ruff, formatting, type-checking, or project lint
commands when available. Do not install dependencies or invent a replacement
command when the configured environment is unavailable.

## Finish

Keep the JSON schema and unknown fields intact. Update only issue `status` and
`resolution` fields plus top-level `updated_at`. Summarize changed files,
verification results, resolved issue IDs, and blocked issue IDs.
