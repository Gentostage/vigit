# Задачи: Vigit v2

**Источник требований:** [spec.md](./spec.md)

**Архитектура:** [design.md](./design.md)

**Общий план:** [plan.md](./plan.md)

Каждый пункт ниже ссылается на детальный executable plan. Внутри него есть
точные файлы, failing test, реализация, verification command и commit boundary.
Работа идёт последовательно по slices; legacy `:Vigit` удаляется только в
последней фазе.

## Phase 1 — Async foundation и read-only UI

- [x] T001 [P] Реализовать `Result`, общий test harness и Git fixture по
  [Plan 01, Task 1](./plans/01-foundation-read-only-ui.md#task-1-result-model-и-общий-test-harness).
- [x] T002 Добавить validated config и async `vim.system` adapter по
  [Plan 01, Task 2](./plans/01-foundation-read-only-ui.md#task-2-validated-config-и-asynchronous-process-adapter).
- [x] T003 Реализовать porcelain-v2 status, diff core и read-only Git adapter
  по [Plan 01, Task 3](./plans/01-foundation-read-only-ui.md#task-3-porcelain-v2diff-core-и-read-only-git-adapter).
- [x] T004 Реализовать canonical-root session registry и generation-safe reads
  по [Plan 01, Task 4](./plans/01-foundation-read-only-ui.md#task-4-session-registry-и-changes-application-use-case).
- [x] T005 Собрать owned responsive layout и временный `:VigitV2` по
  [Plan 01, Task 5](./plans/01-foundation-read-only-ui.md#task-5-owned-layout-renderers-и-vigitv2).

**Checkpoint:** `:VigitV2` показывает независимый read-only diff для двух
worktrees; legacy `:Vigit` остаётся доступен.

## Phase 2 — Native Neovim handoff и syntax

- [x] T006 Реализовать `SourceAnchor`, context rows и устойчивое восстановление
  позиции по [Plan 02, Task 1](./plans/02-native-handoff-and-syntax.md#task-1-sourceanchor-и-context-preserving-diff-rows).
- [x] T007 Добавить old/new Tree-sitter snapshots, symbol labels и layered
  highlights по [Plan 02, Task 2](./plans/02-native-handoff-and-syntax.md#task-2-snapshot-tree-sitter-inspection-и-layered-highlights).
- [x] T008 Реализовать обычную editor-tab на worktree без Vigit ownership по
  [Plan 02, Task 3](./plans/02-native-handoff-and-syntax.md#task-3-normal-editor-tab-handoff).
- [x] T009 Передавать `gd` пользовательскому mapping/LSP и открывать native
  terminal по [Plan 02, Task 4](./plans/02-native-handoff-and-syntax.md#task-4-user-gd-bridge-и-native-terminal).
- [x] T010 Завершить one/all, tree/list, progressive diff и narrow layout по
  [Plan 02, Task 5](./plans/02-native-handoff-and-syntax.md#task-5-complete-slice-2-ui-integration).

**Checkpoint:** source buffers сохраняют пользовательские mappings, LSP,
jumplist и lifecycle; syntax работает до открытия файла.

## Phase 3 — Git mutations и comments

- [x] T011 Реализовать FIFO mutation queue и compact `y/N` confirmation по
  [Plan 03, Task 1](./plans/03-git-mutations-and-comments.md#task-1-serialized-mutation-queue-и-compact-confirmation).
- [x] T012 Добавить file stage/unstage для tracked, untracked, mixed и unborn
  HEAD по [Plan 03, Task 2](./plans/03-git-mutations-and-comments.md#task-2-file-stageunstage-contracts).
- [x] T013 Добавить exact hunk patch stage/unstage с matching preflight по
  [Plan 03, Task 3](./plans/03-git-mutations-and-comments.md#task-3-exact-hunk-patch-stageunstage).
- [x] T014 Реализовать safe hunk/file rollback без broad fallback по
  [Plan 03, Task 4](./plans/03-git-mutations-and-comments.md#task-4-safe-hunkfile-rollback).
- [x] T015 Реализовать block-preserving `.vigit/comments.md` и atomic storage
  по [Plan 03, Task 5](./plans/03-git-mutations-and-comments.md#task-5-canonical-markdown-comments-и-atomic-storage).
- [x] T016 Добавить comment list/edit/delete, prompt и explicit legacy importer
  по [Plan 03, Task 6](./plans/03-git-mutations-and-comments.md#task-6-comment-use-cases-ui-prompt-и-explicit-importer).

**Checkpoint:** unrelated index/worktree bytes сохраняются, destructive default
равен No, а один Markdown-файл воспроизводит весь review.

## Phase 4 — Worktrees, observability и cutover

- [x] T017 Реализовать NUL worktree model, status/upstream reads и explicit
  fetch по [Plan 04, Task 1](./plans/04-worktrees-and-cutover.md#task-1-worktree-model-и-read-adapter).
- [x] T018 Добавить bounded-concurrency picker и open/focus session flow по
  [Plan 04, Task 2](./plans/04-worktrees-and-cutover.md#task-2-async-worktree-listing-и-session-picker).
- [x] T019 Реализовать `y/N`, double preflight и safe worktree remove
  по [Plan 04, Task 3](./plans/04-worktrees-and-cutover.md#task-3-safe-worktree-removal).
- [x] T020 Централизовать keymaps/help/docs, refresh observers и `:VigitLog` по
  [Plan 04, Task 4](./plans/04-worktrees-and-cutover.md#task-4-central-help-refresh-observers-и-diagnostics).
- [x] T021 Переключить public API/commands на v2 и сохранить `:VigitV2` alias
  по [Plan 04, Task 5](./plans/04-worktrees-and-cutover.md#task-5-public-cutover-legacy-removal-и-project-documentation).
- [ ] T022 Заменить legacy tests эквивалентными v2 scenarios и только затем
  удалить legacy modules по
  [Plan 04, Task 5, Steps 4–5](./plans/04-worktrees-and-cutover.md#task-5-public-cutover-legacy-removal-и-project-documentation).
- [ ] T023 Обновить demo, bundled Codex skill, README, AGENTS и единый
  `scripts/test.sh` по
  [Plan 04, Task 5, Steps 6–10](./plans/04-worktrees-and-cutover.md#task-5-public-cutover-legacy-removal-и-project-documentation).

**Checkpoint:** `:Vigit` и `:VigitV2` открывают одну v2 session, worktree
удаляется только при доказанной безопасности, legacy references отсутствуют.

## Final verification

- [ ] T024 Выполнить `./scripts/test.sh`; сохранить точный вывод unit,
  real-Git integration, headless и generated-doc gates.
- [ ] T025 Выполнить `./scripts/demo.sh`, `--user-config` и `--plugins`;
  проверить wide/narrow layout, два worktrees, native LSP/jumplist и comments.
- [ ] T026 Проверить destructive matrix: mixed index, stale hunk, untracked
  file, dirty/ahead/no-upstream/open-buffer worktree; при отказе сравнить Git
  state byte-for-byte.
- [ ] T027 Проверить clean Neovim 0.10+ без optional plugins и WSL/NvChad smoke
  перед утверждением cutover.

## Зависимости

```text
T001 → T002 → T003 → T004 → T005
                         ↓
T006 → T007 → T008 → T009 → T010
                         ↓
T011 → T012 → T013 → T014 → T015 → T016
                                      ↓
T017 → T018 → T019 → T020 → T021 → T022 → T023
                                      ↓
                              T024 → T025 → T026 → T027
```

- `[P]` означает, что задача не меняет shared production modules и может
  готовиться отдельно; integration всё равно выполняется в указанном порядке.
- Новый slice начинается только после review gate предыдущего.
- T021 нельзя начинать до зелёных T001–T020.
- T022 удаляет legacy только после parity table для каждого старого test.

## Покрытие требований

| Требования | Задачи |
| --- | --- |
| FR-001, FR-002, FR-019 | T004, T018 |
| FR-003, FR-004, FR-005, FR-006, FR-007, FR-008, FR-009, FR-010 | T005, T008–T010 |
| FR-011, FR-012, FR-013, FR-014, FR-015, FR-016, FR-017 | T003, T006–T007 |
| FR-018 | T009 |
| FR-020, FR-021, FR-022, FR-023, FR-024, FR-025 | T011–T014 |
| FR-026, FR-027, FR-028, FR-029, FR-039 | T015–T016, T023 |
| FR-030, FR-031, FR-032, FR-033, FR-034 | T017–T019 |
| FR-035, FR-038 | T020 |
| FR-036, FR-037 | T002, T007–T009, T020, T027 |
| FR-040 | T021–T023 |
| SC-001, SC-002, SC-003, SC-004, SC-005, SC-006, SC-007, SC-008 | T024–T027 |
