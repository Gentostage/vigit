# Конституция Vigit

## Основные принципы

### I. Companion, а не редактор

Vigit MUST владеть только собственными review-buffers, окнами и вкладками.
Обычные файлы, терминалы, LSP, jumplist, tabline и пользовательские keymaps
остаются под управлением Neovim и его конфигурации. Vigit MUST NOT внедрять в
исходные buffers собственные mappings, winbar или lifecycle autocmds.

### II. Изоляция worktree и явное состояние

Каждая Git worktree получает независимую Vigit-сессию, определяемую canonical
root path. Выбор файла, source anchor, режим diff, раскрытый context, comments и
async generation MUST NOT смешиваться между worktrees. Глобальный
`active_session` запрещён; операции получают session/root явно.

### III. Git-безопасность важнее удобства

Stage, unstage и rollback MUST использовать точные pathspec/patch операции.
Destructive action требует подтверждения и предварительной проверки. Ошибка
частичного patch MUST NOT приводить к fallback на восстановление всего файла.
Worktree нельзя удалить при dirty state, unpushed commits или открытых обычных
buffers. `--force`, скрытый fetch и автоматическое удаление ветки запрещены.

### IV. Config-agnostic интеграция

Базовая версия MUST работать на Neovim 0.10+ без обязательных сторонних
плагинов. Treesitter parsers, LSP, Telescope, WhichKey и NvChad используются
только через optional adapters и публичные API. Vigit не устанавливает
глобальные keymaps; commands и handler callbacks являются публичной границей.

### V. Отзывчивость и наблюдаемость

Git-чтение MUST выполняться асинхронно через аргументные процессы без shell
конкатенации. Запоздавшие результаты отбрасываются по generation ID, mutation
операции сериализуются. Ошибка остаётся видимой в session state и доступна в
diagnostic log. Скрытые сетевые или destructive действия запрещены.

### VI. Проверяемые пользовательские сценарии

Pure domain/parser logic покрывается Lua unit tests. Git adapters проверяются на
временных реальных repositories, а Neovim lifecycle — headless-сценариями.
Тесты MUST проверять наблюдаемое поведение, а не incidental количество mappings
или точное расположение каждой UI-строки.

## Технические ограничения

- Основной язык плагина — Lua с отступом в два пробела.
- Git-команды формируются только внутри adapter-слоя и получают arguments array,
  explicit `cwd` и `--` перед пользовательскими путями.
- Core-модули не зависят от `vim`, filesystem или process API.
- UI отображает state и отправляет intents; use cases выполняют операции.
- Единственный review-артефакт проекта — `.vigit/comments.md`.
- Обычные editor/terminal tabs не закрываются вместе с Vigit.
- Слишком большой diff деградирует в явный placeholder, а не блокирует UI.

## Процесс разработки

Крупные изменения начинаются со spec и implementation plan. Рефакторинг v2
выполняется вертикальными срезами рядом с legacy implementation. Каждый срез
должен оставаться запускаемым и проходить относящиеся к нему unit, Git fixture и
headless проверки. До переключения `:Vigit` новый интерфейс доступен отдельно
как `:VigitV2`. Удаление legacy разрешено только после достижения feature
parity и прохождения acceptance scenarios.

Commit messages следуют Conventional Commits. UI-изменения сопровождаются
terminal screenshot или короткой записью. Generated site directories и
agent-local `.codex/`, `.superpowers/`, `docs/superpowers/` не коммитятся.

## Управление

Конституция имеет приоритет над implementation plan и локальными удобствами.
Изменение обязательного принципа требует обновления версии, объяснения причины
и migration plan. Каждая spec и PR MUST явно проверять соблюдение границ
Companion UI, Git safety и worktree isolation.

**Version**: 1.0.0 | **Ratified**: 2026-07-27 | **Last Amended**: 2026-07-27
