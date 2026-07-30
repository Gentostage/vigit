# Один workspace tab и независимые worktree sessions

## Цель

Vigit использует один native Neovim tab независимо от количества Git
worktree. В каждый момент видим только один активный worktree, но логическое
состояние каждого посещённого root сохраняется в отдельной session.

## Модель

```text
Workspace
├── tab
├── code_win
├── root
├── active session
└── sessions[canonical_root]
    ├── Git status, diffs и comments
    ├── review cursor и раскрытый context
    ├── source_buffers
    └── terminal
```

`Workspace` координирует active root и переходы. `Session` хранит состояние
одного canonical root. `Layout` владеет только двумя служебными `nofile`
buffers и их float windows. Source и terminal buffers принадлежат пользователю.

Vigit не выполняет `tabnew`, `tabedit` или `tabclose`.

## Review и code mode

- `:Vigit` показывает review overlay в текущем workspace tab.
- `q` скрывает overlay и возвращает сохранённый editor window.
- `e` открывает выбранный source file в этом editor window.
- `gd` делает тот же handoff и затем использует пользовательский mapping/LSP.
- `T` создаёт terminal split с `cwd` активного worktree.
- Повторный `:Vigit` восстанавливает cursor diff, selection и context.

Vigit не добавляет mappings, options, winbar или lifecycle autocmds в source и
terminal buffers. Их закрытие, splits, jumplist и LSP остаются обычным
поведением Neovim.

## Переключение worktree

Picker канонизирует выбранный root и вызывает одну операцию
`Workspace:switch(root)`:

1. Проверить ресурсы active session.
2. Скрыть её review overlay.
3. Выполнить tab-local `tcd` для target root.
4. Активировать cached session либо создать новую.
5. Показать review target session.

Предыдущая session не уничтожается. Поэтому A → B → A восстанавливает Git/UI
state A без второго native tab. Picker показывает `ACTIVE` только у текущего
root.

При ошибке activation workspace возвращает предыдущую session и root. Switch
блокируется, если active session содержит:

- modified source buffer;
- source buffer, одновременно показанный во внешнем tab;
- работающий terminal process.

Vigit не сохраняет файлы, не завершает shell и не закрывает пользовательские
buffers автоматически.

## Lifecycle

`q` означает только переход в code mode. Полное уничтожение workspace удаляет
все Vigit-owned buffers и отменяет reads, но не удаляет source/terminal
buffers. Если пользователь сам закрыл hosting tab, следующий `:Vigit`
обнаруживает невалидный tab, очищает старые sessions и принимает текущий tab
как новый workspace.

При безопасном удалении linked worktree удаляется только её неактивная cached
session. Active/picker-origin worktree удалить нельзя.

## Совместимость и проверка

Source buffers остаются `buflisted=true`; TreeSitter, Telescope, LSP,
file-tree, `Ctrl-o`/`Ctrl-i` и пользовательские mappings работают без
Vigit-specific слоя.

Обязательные regressions:

1. несколько worktree используют один native tab;
2. A → B → A возвращает ту же независимую session;
3. `e`, `gd` и `T` не создают tabs;
4. `q` не закрывает session или user tab;
5. review cursor переживает handoff в source;
6. blockers не меняют root и не теряют пользовательские данные;
7. удаление worktree очищает только её cached session.

## Вне scope

- несколько одновременно видимых Vigit workspaces;
- persistence sessions между запусками Neovim;
- управление tmux panes;
- force-switch с потерей modified buffers;
- собственные замены LSP, Telescope или file tree.
