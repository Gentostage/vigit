# Repository Guidelines

## Назначение проекта

Vigit — Lua-плагин Neovim для keyboard-first проверки изменений AI-агентов в
нескольких Git worktree. Новые функции должны поддерживать основной цикл:
inspect → correct → comment → handoff агенту.

## Структура

Public API находится в `lua/vigit/init.lua`; `lua/vigit/v2.lua` — временный
compatibility alias без отдельного state. Код разделён по слоям:

- `lua/vigit/core/` — чистые модели status, diff, patch, review и worktree;
- `lua/vigit/application/` — orchestration changes, mutations, comments и
  worktrees;
- `lua/vigit/adapters/` — Git CLI, Neovim, filesystem, process и TreeSitter;
- `lua/vigit/ui/` — session registry, controller, renderer, layout и views.

Unit tests лежат в `tests/unit/`, real-Git integration — в
`tests/integration/`, headless Neovim workflows — в `tests/headless/`.
Disposable demo и isolated init-файлы находятся в `scripts/`; bundled Codex
skill — в `skills/vigit-review/`; сайт — в `public/site/`.

## Команды

- `./scripts/test.sh` — полный unit/integration/headless/keymap gate.
- `./scripts/demo.sh` — disposable fixture в clean Neovim.
- `./scripts/demo.sh --user-config` — проверка с пользовательским config.
- `./scripts/demo.sh --plugins` — isolated Telescope integration.
- `lua scripts/generate-keymaps.lua --check` — проверка `docs/keymaps.md`.
- `npm run build` — production build project site в `dist/`.

`scripts/test.sh` не должен устанавливать зависимости или менять
пользовательский Neovim config.

## Стиль и архитектурные ограничения

Используйте два пробела в Lua, JavaScript, HTML и CSS; имена Lua files,
functions и variables — `snake_case`. Modules возвращают `M`, helpers держите
`local`. Git subprocesses принадлежат adapters, orchestration — application,
UI mutations — controller/renderer.

Source и terminal buffers принадлежат пользователю. Vigit не добавляет в них
свои mappings, options, winbar или lifecycle autocmds и не закрывает их.
Каждый canonical worktree имеет независимую Vigit session.

## Тестирование и PR

Добавляйте focused `it("поведение", function() ... end)` в соответствующий
suite. Для Git mutations проверяйте точный scope и неизменность index/worktree
при ошибке; для UI — ownership, anchors и async stale-result handling. Перед PR
запустите `./scripts/test.sh` и релевантный demo mode.

Commit messages используют Conventional Commits, например
`feat(ui): add side-by-side diff`. PR должен описывать пользовательский эффект,
команды проверки и содержать screenshot/recording для визуальных изменений.
Не коммитьте `dist/`, `.wrangler/`, `.next/`, `node_modules/`, `.codex/`,
`.superpowers/` и `docs/superpowers/`.
