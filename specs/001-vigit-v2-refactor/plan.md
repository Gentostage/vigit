# Vigit v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Перестроить Vigit как независимый, безопасный и асинхронный review
companion, который не подменяет обычный Neovim.

**Architecture:** Strangler migration создаёт новый pure core, application use
cases, explicit adapters и owned review UI рядом с legacy implementation.
Каждая worktree получает отдельную session; обычные source/terminal tabs
остаются native Neovim resources и никогда не становятся owned Vigit UI.

**Tech Stack:** Lua 5.1/LuaJIT, Neovim 0.10+ public API, Git 2.36+, optional
Tree-sitter/LSP/Telescope/NvChad integrations, Markdown storage.

## Global Constraints

- Рабочая Git-ветка остаётся `main`; feature identifier Spec Kit не создаёт
  отдельную branch.
- Использовать два пробела и Lua 5.1-compatible syntax.
- Не добавлять обязательные plugin dependencies.
- Не устанавливать global keymaps и не менять обычные source buffers.
- Все Git processes получают argument array, explicit `cwd` и pathspec `--`.
- Git reads асинхронны; mutations сериализованы.
- Destructive операции не используют `--force` и не имеют широкого fallback.
- Единственный canonical review storage — `.vigit/comments.md`.
- `.codex/`, `.superpowers/` и `docs/superpowers/` не коммитятся.

---

**Branch**: `main` | **Feature ID**: `001-vigit-v2-refactor` |
**Date**: 2026-07-27 |
**Spec**: [spec.md](./spec.md) |
**Design**: [design.md](./design.md)

## Summary

Рефакторинг разбит на четыре independently testable vertical slices:

1. Async foundation и read-only `:VigitV2`.
2. Source anchors, Tree-sitter и native editor/LSP/terminal handoff.
3. Safe Git mutations и единый comments workflow.
4. Worktree lifecycle, public cutover и удаление legacy.

Detailed executable plans находятся в `plans/`. Каждый slice заканчивается
собственным review gate и Conventional Commit.

## Technical Context

**Language/Version**: Lua 5.1 semantics под LuaJIT Neovim

**Primary Dependencies**: Neovim 0.10+; Git 2.36+; optional runtime Tree-sitter
parsers и LSP clients

**Storage**: tracked `.vigit/comments.md`; in-memory session registry; atomic
filesystem writes

**Testing**: lightweight Lua test harness, temporary real Git repositories,
headless Neovim lifecycle scenarios, manual isolated/user-config demo

**Target Platform**: Neovim 0.10+ на платформе с Git 2.36+; automated Linux
verification и manual WSL/NvChad smoke

**Project Type**: Lua Neovim plugin с отдельно собираемым project site

**Performance Goals**:

- changes list отображается после status, не ожидая all-files diff;
- one-file diff загружается отдельным process;
- максимум два соседних file blocks prefetch в all-files mode;
- Tree-sitter parsing не задерживает первый render;
- stale generation не может перезаписать более новое состояние.

**Constraints**:

- default `max_diff_bytes = 2 * 1024 * 1024` на один file diff;
- default `max_highlight_bytes = 512 * 1024` на одну snapshot side;
- mutation queue допускает ровно одну активную Git mutation на session;
- read callbacks изменяют state только при совпадении session ID и generation.

**Scale/Scope**: до 100 changed files, 10 одновременно известных worktrees и
нескольких параллельно открытых Vigit sessions без shared selection state.

## Constitution Check

*GATE: пройден перед Phase 0 и повторно после Phase 1.*

| Принцип | Решение | Статус |
| --- | --- | --- |
| Companion, не editor | Vigit владеет только `nofile` review buffers | PASS |
| Worktree isolation | Registry keyed by canonical root; explicit session ID | PASS |
| Git safety | Patch preflight, confirmations, no force/fallback | PASS |
| Config agnostic | Neovim public API; optional adapters | PASS |
| Responsive/observable | `vim.system`, generations, queue, `:VigitLog` | PASS |
| Testable scenarios | Unit + real Git + headless lifecycle | PASS |

Нарушений constitution, требующих Complexity Tracking, нет.

## Project Structure

### Documentation

```text
specs/001-vigit-v2-refactor/
├── spec.md
├── design.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── comments-format.md
│   ├── git-adapter.md
│   └── public-api.md
├── plans/
│   ├── 01-foundation-read-only-ui.md
│   ├── 02-native-handoff-and-syntax.md
│   ├── 03-git-mutations-and-comments.md
│   └── 04-worktrees-and-cutover.md
└── tasks.md
```

### Source Code

```text
lua/vigit/
├── init.lua                         # public setup/open commands
├── config.lua                       # validated defaults and handler overrides
├── v2.lua                           # temporary :VigitV2 entrypoint
├── core/
│   ├── result.lua                   # typed success/error values
│   ├── status.lua                   # porcelain-v2 model/parser
│   ├── diff.lua                     # FileDiff/Hunk/DiffLine parser
│   ├── patch.lua                    # exact file/hunk patch construction
│   ├── anchor.lua                   # source-anchor matching
│   ├── review.lua                   # comments Markdown parser/serializer
│   └── worktree.lua                 # worktree model and removal policy
├── application/
│   ├── changes.lua                  # status/diff loading generations
│   ├── mutations.lua                # serialized Git mutation queue
│   ├── reviews.lua                  # comments use cases
│   └── worktrees.lua                # listing/fetch/removal orchestration
├── adapters/
│   ├── process.lua                  # vim.system wrapper
│   ├── git_cli.lua                  # all Git argument construction
│   ├── filesystem.lua               # safe paths and atomic writes
│   ├── legacy_review.lua            # explicit old-storage importer
│   ├── neovim.lua                   # buffers/tabs/terminal/LSP handoff
│   └── treesitter.lua               # snapshot captures and symbol context
└── ui/
    ├── registry.lua                 # root/session lookup
    ├── session.lua                  # owned resource lifecycle
    ├── controller.lua               # intents -> use cases
    ├── layout.lua                   # responsive diff/changes layout
    ├── renderer.lua                 # state -> buffers/extmarks
    ├── highlights.lua               # diff/sign/syntax extmarks
    ├── keymaps.lua                  # single mapping registry
    ├── confirm.lua                  # compact destructive confirmations
    ├── log.lua                      # diagnostic ring buffer
    └── views/
        ├── changes.lua
        ├── diff.lua
        ├── comments.lua
        ├── help.lua
        └── worktrees.lua

tests/
├── run.lua
├── testlib.lua
├── fixtures/
│   └── git_repo.lua
├── unit/
├── integration/
└── headless/
    ├── run.lua
    ├── sessions_spec.lua
    ├── handoff_spec.lua
    └── worktrees_spec.lua
```

Legacy top-level modules остаются неизменными до cutover, затем удаляются:
`actions.lua`, `changes_view.lua`, `confirm.lua`, `git.lua`, `help.lua`,
`highlights.lua`, `keymaps.lua`, `parser.lua`, `review.lua`,
`review_editor.lua`, `review_ui.lua`, `state.lua`, `syntax.lua`, `ui.lua`,
`worktree_picker.lua`, `worktrees.lua`.

**Structure Decision**: Новые directories сосуществуют с legacy top-level
files, поэтому slices можно доставлять без одномоментного rewrite. `init.lua`
сначала регистрирует `:VigitV2`, а после parity переключает `:Vigit`.

## Delivery Slices

### Slice 1 — Foundation и read-only UI

[Detailed plan](./plans/01-foundation-read-only-ui.md)

Результат: async `:VigitV2` показывает independent changes/diff sessions и не
затрагивает legacy `:Vigit`.

### Slice 2 — Native handoff и syntax

[Detailed plan](./plans/02-native-handoff-and-syntax.md)

Результат: source anchor/context, old/new Tree-sitter highlighting и обычные
editor/LSP/terminal tabs без Vigit lifecycle injection.

### Slice 3 — Mutations и comments

[Detailed plan](./plans/03-git-mutations-and-comments.md)

Результат: точные file/hunk Git операции и один agent-readable comments file.

### Slice 4 — Worktrees и cutover

[Detailed plan](./plans/04-worktrees-and-cutover.md)

Результат: безопасный multi-worktree lifecycle, public v2 API, удалённый legacy,
актуальные demo/README/keymap docs.

## Post-Design Constitution Check

- UI ownership ограничен `ui/session.lua`: PASS.
- Native tabs помечаются metadata, но не записываются как owned resources:
  PASS.
- Git adapter contract не принимает shell strings: PASS.
- Destructive flows требуют preflight и confirmation: PASS.
- Comments storage не дублируется: PASS.
- Tests разделены по pure/adapter/lifecycle границам: PASS.

## Complexity Tracking

Отсутствует: все дополнительные слои напрямую соответствуют утверждённым
границам и заменяют циклические legacy dependencies.
