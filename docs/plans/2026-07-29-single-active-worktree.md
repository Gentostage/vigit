# Один активный worktree — Implementation Plan

**Цель:** оставить Vigit в одном native Neovim tab, сохранив независимое
состояние каждого Git worktree и обычное поведение пользовательского Neovim.

**Архитектура:** `Workspace` хранит active root и cached sessions.
`Layout` монтирует обратимый float-overlay. Source buffers и terminal splits
остаются пользовательскими ресурсами и никогда не закрываются Vigit.

## Ограничения

- Только одна session видима и помечена `ACTIVE`.
- Все посещённые canonical roots имеют независимую cached session.
- `e`, `gd` и `T` не создают native tabs.
- `q` скрывает review; полное уничтожение выполняет только `abandon`.
- Switch не сохраняет файлы, не завершает terminal и не использует force.
- Commit и push выполняются только по отдельной команде пользователя.

## Task 1: Workspace coordinator

- [x] Добавить `lua/vigit/application/workspace.lua`.
- [x] Хранить sessions по canonical root и восстанавливать A → B → A.
- [x] Реализовать rollback при ошибке activation.
- [x] Реализовать удаление только inactive cached session.
- [x] Покрыть coordinator unit tests.

## Task 2: Обратимый review overlay

- [x] Убрать создание и закрытие native tabs из layout.
- [x] Разделить `show`, `hide` и `dispose`.
- [x] Сохранять cursor diff/changes между code и review mode.
- [x] Оставлять Vigit buffers hidden до повторного показа session.
- [x] Проверить resize и narrow layout.

## Task 3: Source и terminal

- [x] Передавать `workspace` и per-session `resources` в `HandlerContext`.
- [x] Открывать source в `workspace.code_win`.
- [x] Открывать terminal обычным split с cwd active root.
- [x] Не добавлять Vigit mappings/autocmds/options в user buffers.
- [x] Блокировать switch для modified buffer, external tab и running terminal.
- [x] Удалить legacy `tabnew/tabclose` fallback из Neovim adapter.

## Task 4: Worktree picker

- [x] Заменить `open_session/focus_session` на `switch_session(root)`.
- [x] Показывать только один статус `ACTIVE`.
- [x] Сохранять active session при неуспешном switch.
- [x] Удалять только inactive cached session после safe worktree removal.
- [x] Проверить ROOT/WT, Windows roots и stale resolver.

## Task 5: Lifecycle и regressions

- [x] `:Vigit` возвращает review cached session.
- [x] `q` возвращает code mode без уничтожения user tab.
- [x] Закрытый hosting tab пересоздаётся при следующем `:Vigit`.
- [x] Observer обновляет только active matching session.
- [x] Source cursor и diff cursor переживают native handoff.
- [x] Подключить новые сценарии в default unit/headless gates.
- [x] Обновить README и design document.

## Проверка

```bash
lua tests/run.lua
nvim --headless --clean -u NONE -l tests/headless/run.lua
./scripts/test.sh
./scripts/demo.sh --user-config
```

Ручной smoke flow:

```text
:Vigit → W → выбрать WT → e → :Vigit → T → выйти из shell → W → ROOT
```

Ожидается один native tab, одна строка `ACTIVE`, восстановленный diff cursor и
отсутствие Vigit mappings/lifecycle autocmds в source/terminal buffers.
