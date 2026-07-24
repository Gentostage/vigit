# План реализации справки и безопасного удаления worktree

> **Для agentic workers:** выполнять inline через `superpowers:executing-plans`.
> Каждый блок идёт по циклу RED → GREEN → regression.

**Цель:** добавить единый реестр сочетаний, встроенную справку, безопасное
удаление открытых worktree и исправить `X` для untracked-файлов.

**Архитектура:** `lua/vigit/keymaps.lua` хранит метаданные и создаёт реальные
buffer-local mappings, `lua/vigit/help.lua` только отображает этот реестр.
Git-слой вычисляет upstream divergence, `worktrees.lua` формирует безопасное
решение, а picker координирует закрытие Vigit session и удаление worktree.

**Tech Stack:** Lua, Neovim API, Git CLI, существующий Lua test harness.

**Статус:** реализовано и проверено 24 июля 2026 года.

## Общие ограничения

- Не добавлять обязательную зависимость от WhichKey.
- Не переопределять `?` в обычном editor и terminal.
- Не выполнять скрытый `git fetch`.
- Не удалять branch вместе с worktree.
- Не создавать commit и не выполнять push без отдельного запроса.
- Не добавлять файлы в `docs/superpowers`.

---

### Задача 1: статус untracked-файла в diff

**Файлы:**
- Modify: `tests/git_spec.lua`
- Modify: `lua/vigit/git.lua`

**Интерфейсы:**
- `git.diff(section, cwd, context, status_files)` возвращает diff-файлы с
  полями `status` и `section`.
- `git.restore_file_to_head(file, cwd)` использует `git clean` при
  `file.status == "?"`.

- [ ] Добавить сценарий, создающий untracked `scratch.md`, получающий файл
  через `git.diff()` и проверяющий `file.status == "?"`.
- [ ] В том же сценарии вызвать `restore_file_to_head()` и проверить, что файл
  удалён без ошибки.
- [ ] Запустить `lua tests/run.lua`; ожидаем FAIL на отсутствующем status.
- [ ] В `git.diff()` сопоставить `status_files` с parsed diff по `path` и
  перенести `status`, `section` и отсутствующий `old_path`.
- [ ] В `git.diff_file()` сохранить status входного файла в результате.
- [ ] Повторно запустить suite; новый сценарий должен PASS.

### Задача 2: upstream-состояние и правила удаления

**Файлы:**
- Modify: `tests/git_spec.lua`
- Create: `tests/worktrees_spec.lua`
- Modify: `tests/run.lua`
- Modify: `lua/vigit/git.lua`
- Modify: `lua/vigit/worktrees.lua`

**Интерфейсы:**
- `git.upstream_status(cwd)` возвращает
  `{ name: string, ahead: number, behind: number }` либо `nil, error`.
- `worktrees.removal_blocker(entry)` возвращает `nil`, если удаление безопасно,
  иначе человекочитаемую причину.

- [ ] Добавить Git-сценарии: pushed branch даёт `ahead=0, behind=0`; локальный
  commit даёт `ahead=1`; commit в remote clone даёт `behind=1`.
- [ ] Добавить unit-сценарии blocker для ROOT, dirty, detached, no-upstream,
  ahead и безопасного clean/pushed entry.
- [ ] Запустить suite; ожидаем FAIL из-за отсутствующих функций.
- [ ] Реализовать upstream через
  `rev-parse --abbrev-ref --symbolic-full-name @{upstream}` и
  `rev-list --left-right --count @{upstream}...HEAD`.
- [ ] Дополнить `worktrees.list()` полями `upstream`, `ahead`, `behind`,
  `upstream_error` и `detached`.
- [ ] Реализовать `removal_blocker()` с условиями из спецификации.
- [ ] Запустить suite; новые сценарии должны PASS.

### Задача 3: единый реестр mappings и встроенная справка

**Файлы:**
- Create: `lua/vigit/keymaps.lua`
- Create: `lua/vigit/help.lua`
- Create: `tests/keymaps_spec.lua`
- Modify: `tests/run.lua`
- Modify: `tests/ui_spec.lua`
- Modify: `lua/vigit/ui.lua`
- Modify: `lua/vigit/worktree_picker.lua`
- Modify: `lua/vigit/review_ui.lua`
- Modify: `lua/vigit/review_editor.lua`
- Modify: `lua/vigit/init.lua`
- Modify: `lua/vigit/highlights.lua`

**Интерфейсы:**
- `keymaps.entries(context)` возвращает ordered mapping specs.
- `keymaps.bind(buf, context, handlers)` вызывает `vim.keymap.set()` с `desc`.
- `keymaps.mark(buf, context)` сохраняет `vim.b[buf].vigit_keymap_context`.
- `help.open(context?)` открывает context-first popup.
- `:VigitHelp` вызывает `help.open()` для текущего buffer context.

- [ ] Добавить unit-сценарии порядка contexts, наличия `desc`, установки
  buffer-local mappings и context marker.
- [ ] Обновить UI fixture: ожидать `?` в changes/diff и `VigitHelp` среди
  команд.
- [ ] Запустить suite; ожидаем FAIL из-за отсутствующих модулей/команды.
- [ ] Создать реестр contexts `changes`, `diff`, `worktrees`, `comments`,
  `comment_editor`, `editor`, `terminal`, `help`.
- [ ] Реализовать `bind()` так, чтобы callback выбирался по полю `action`, а
  отсутствующий handler не создавал mapping.
- [ ] Реализовать adaptive floating help с current context первым, закрытием
  по `q`/`Esc` и fallback на полный список.
- [ ] Перевести mappings собственных Vigit buffers на реестр; editor/terminal
  только пометить context и оставить их `?` нетронутым.
- [ ] Зарегистрировать `:VigitHelp`.
- [ ] Сократить winbar hints до основных действий и `? help`.
- [ ] Запустить suite; новые и существующие сценарии должны PASS.

### Задача 4: удаление открытой безопасной worktree

**Файлы:**
- Modify: `tests/ui_spec.lua`
- Create: `tests/worktree_picker_spec.lua`
- Modify: `tests/run.lua`
- Modify: `lua/vigit/ui.lua`
- Modify: `lua/vigit/worktree_picker.lua`

**Интерфейсы:**
- `ui.close_worktree(path)` закрывает существующую Vigit session и возвращает
  `true`, либо `false, reason`.
- Picker вызывает `worktrees.removal_blocker(entry)` до confirmation.

- [ ] Добавить UI-сценарий: close_worktree закрывает нужную session; modified
  editor блокирует закрытие.
- [ ] Добавить picker-сценарии: blocked entry не показывает confirmation;
  clean/pushed open entry закрывает session, удаляет worktree без `--force` и
  сохраняет branch.
- [ ] Запустить suite; ожидаем FAIL на новом поведении.
- [ ] Реализовать `ui.close_worktree(path)` поверх существующего `M.close()`.
- [ ] В picker отобразить `PUSHED`, `↑N`, `↓N`, `NO UPSTREAM` и точную причину
  блокировки.
- [ ] После confirmation закрыть target session; использовать ROOT path как
  Git cwd; при удалении текущей session переключиться на ROOT, иначе обновить
  существующий picker.
- [ ] Запустить suite; новые сценарии должны PASS.

### Задача 5: документация и полная проверка

**Файлы:**
- Modify: `README.md`
- Modify: `docs/design/2026-07-24-keymap-help-and-safe-worktree-removal.md`

- [ ] Обновить таблицу mappings: `?`, `:VigitHelp`, ограничения editor/terminal.
- [ ] Описать статусы upstream и условия удаления worktree.
- [ ] Запустить `lua tests/run.lua`; ожидаем все PASS.
- [ ] Запустить
  `nvim --headless -u NONE -l tests/ui_regression_spec.lua`; ожидаем все PASS.
- [ ] Запустить `luac -p lua/vigit/*.lua tests/*_spec.lua`,
  `git diff --check` и `bash -n scripts/demo.sh`; ожидаем exit code 0.
- [ ] Проверить `git status --short` и оставить изменения без commit/push.
