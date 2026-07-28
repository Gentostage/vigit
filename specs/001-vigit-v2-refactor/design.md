# Vigit v2: architecture design

## Контекст

Legacy implementation совмещает Git process execution, parsing, session state,
layout, editor lifecycle, terminal lifecycle, review storage и rendering в
крупных взаимозависимых модулях. Vigit открывает реальные файлы как часть своей
сессии, внедряет собственные mappings и закрывает editor-tabs. В результате
пользовательские LSP/navigation mappings работают непредсказуемо, jumplist
теряется, а состояние нескольких worktrees может смешиваться.

Цель v2 — оставить Vigit полноценным review companion, но вернуть обычному
Neovim исключительное владение редактированием кода.

## Архитектурные границы

```text
lua/vigit/
├── core/
│   ├── change.lua
│   ├── diff.lua
│   ├── review.lua
│   ├── result.lua
│   └── worktree.lua
├── application/
│   ├── changes.lua
│   ├── reviews.lua
│   └── worktrees.lua
├── adapters/
│   ├── git_cli.lua
│   ├── filesystem.lua
│   └── neovim.lua
├── ui/
│   ├── session.lua
│   ├── layout.lua
│   ├── keymaps.lua
│   └── views/
└── init.lua
```

- `core` — pure models, reducers и parsers без `vim`, filesystem и processes.
- `application` — use cases, mutation ordering и state transitions.
- `adapters` — Git, filesystem и Neovim public API.
- `ui` — owned buffers, rendering и перевод input в intents.
- Adapter возвращает `Result`; он не показывает notifications и не меняет UI.
- Поток операции: `key → intent → use case → adapter → state → render`.
- Циклические `actions ↔ ui` dependencies запрещены.

## Session и concurrency

Registry индексируется canonical worktree root. Session содержит только owned
review resources и serializable view state:

```lua
{
  id = "...",
  root = "/absolute/worktree",
  tab = 12,
  buffers = { diff = 42, changes = 43 },
  view = {
    selected_change = "...",
    anchor = { path = "...", side = "new", source_line = 148, column = 12 },
    mode = "one_file",
    changes_mode = "tree",
    expanded_context = {},
  },
  reads = { generation = 7, running = {} },
  mutations = { running = false, queue = {} },
  error = nil,
}
```

Status и diff reads запускаются через `vim.system`. Новый read увеличивает
generation; callback старой generation не меняет state. Mutations выполняются
FIFO и инициируют refresh только после известного результата. Render
coalescing выполняется через `vim.schedule`; закрытая session игнорирует
callbacks.

Refresh triggers: explicit `r`, успешная mutation, `BufWritePost` файла под
известным root и вход в Vigit-tab. Наблюдающие autocmds принадлежат одному
Vigit augroup, используют debounce и не изменяют source buffers.

## Native Neovim handoff

На worktree существует одна Vigit-tab и, по умолчанию, одна обычная primary
editor-tab. Default open handler:

1. Ищет normal tab с `vim.t.vigit_root == session.root`.
2. Если tab отсутствует, создаёт её рядом с Vigit-tab.
3. Устанавливает tab-local `vigit_root`, `vigit_branch` и `vigit_label`.
4. Открывает absolute file path и устанавливает source cursor.

Metadata доступна optional tabline/statusline adapters, но Vigit не меняет
глобальный tabline. Editor-tab не является owned resource: Vigit не добавляет в
неё mappings/autocmds/winbar и никогда не закрывает её автоматически.

`gd` сначала выполняет handoff на real buffer. После `BufEnter` он вызывает
существующий пользовательский `gd` mapping с remap. Если mapping отсутствует,
используется `vim.lsp.buf.definition()`. При отсутствии attached client
устанавливается bounded one-shot `LspAttach` continuation. Текстовый поиск не
используется. Переходы LSP и `Ctrl-o`/`Ctrl-i` остаются в normal editor window.

Terminal handler создаёт обычную terminal-tab через process option
`cwd=session.root`, не меняя global/tab cwd и не добавляя Vigit mappings.

## UI

Широкий layout:

```text
┌──────────────────────────────────────────┬──────────────────────┐
│ DIFF                                     │ CHANGES              │
│ worktree · branch · mode · comments      │ Staged / Unstaged    │
│                                          │ tree или compact list│
└──────────────────────────────────────────┴──────────────────────┘
```

Changes width ограничивается диапазоном 24–36 columns. На узком экране changes
становится toggle overlay. One-file preview обновляется при перемещении cursor
по file entries; all-files mode загружает blocks лениво. File blocks имеют
естественную высоту и живут в одном scrollable diff buffer.

View renderer получает state и dimensions и возвращает lines, highlights,
extmarks и hit targets. Он не выполняет Git/filesystem operations. Все keymaps
buffer-local и определены единым registry:

| Key | Действие |
| --- | --- |
| `Tab` | Перейти между diff и changes |
| `Enter` | Выбрать entry |
| `]f` / `[f` | Следующий/предыдущий файл |
| `]h` / `[h` | Следующий/предыдущий hunk |
| `e` | Открыть real file |
| `gd` | Native definition handoff |
| `a` | One/all files |
| `s` / `S` | Toggle index для файла/hunk |
| `x` / `X` | Restore hunk/file |
| `c` / `C` | Comment edit/list |
| `P` | Agent prompt |
| `f` | Раскрыть current context |
| `t` | Tree/list |
| `r` | Refresh |
| `T` | Terminal |
| `W` | Worktree picker |
| `F` / `d` | Fetch/remove selected worktree в picker |
| `?` | Полная help |
| `q` | Закрыть current Vigit-tab |

Registry создаёт mappings, inline hints, `:VigitHelp`, help buffer и generated
keymap reference. Он оставляет extension point для будущей WhichKey
интеграции, но сам refactor её не добавляет. Global mappings не
устанавливаются.

## Diff pipeline

Status читается в NUL-separated porcelain v2. Diff запрашивается отдельно для
каждого path, поэтому file names не извлекаются из неоднозначного patch header.
Parser строит `FileDiff → Section → Hunk → DiffLine`, сохраняя old/new line
numbers и text без встроенного `+`/`-`.

Для syntax highlighting adapter получает old и new full texts, определяет
filetype через public Neovim API и при наличии parser применяет Treesitter к
обеим версиям. Captures отображаются обратно на deletion/context/addition
lines. Diff background имеет меньший extmark priority, syntax foreground —
больший. Add/delete markers выводятся через signcolumn.

Hidden interval содержит число строк и smallest enclosing symbol. Symbol
определяется Treesitter outline, затем Git hunk function context. Если
declaration symbol уже видна рядом, label не выводится. Binary/oversize input
получает явный placeholder.

Source anchor состоит из path, section, side, source line, column и context
fingerprint. После refresh renderer ищет exact coordinate, затем context
fingerprint, затем ближайшую строку того же hunk/file.

## Git mutations

- File stage: `git add -- <path>`.
- File unstage/restore выбирает команду по HEAD/status и сохраняет worktree.
- Hunk stage: patch применяется к index.
- Hunk unstage: staged patch reverse-применяется к index.
- Hunk restore: reverse patch предварительно проверяется для затронутых слоёв.
- Full restore ветвится для tracked, added и untracked state.

Patch передаётся через stdin, а до mutation выполняется `git apply --check`.
При race/conflict операция завершается typed error. `x`/`X` требуют `y/N`.
Ошибка не запускает расширенный fallback и не скрывает последний успешный diff.

## Review comments

Canonical storage — один tracked `.vigit/comments.md`:

```md
# Vigit Review

## [ ] VIGIT-001 · src/service.py:42

<!-- vigit-anchor
path: src/service.py
line: 42
side: new
context: await repository.save(item)
-->

Нужно обработать ошибку сохранения.

### Ответ агента
```

Checkbox является canonical status. Parser сохраняет unknown Markdown между
известными sections и не переписывает файл без операции. Запись выполняется во
временный файл в той же директории с последующим atomic rename.

Prompt содержит незавершённые sections и требует от агента исправить/ответить,
заполнить `### Ответ агента` и поставить `[x]` только после завершения. Anchor
lookup использует line, затем context. Legacy format импортируется только
explicit command с backup.

## Worktree lifecycle

Picker читает `git worktree list --porcelain` и независимо получает status и
upstream для каждого root с ограниченной concurrency. Он показывает ROOT/WT,
branch, file counts, upstream и ahead/behind. Remote state явно помечается
как `local refs`; после успешного явного `F` UI показывает время fetch,
выполненного текущей Vigit session.

Перед remove повторно проверяются:

1. target не ROOT;
2. status полностью clean;
3. upstream существует;
4. `ahead == 0`;
5. нет loaded source buffers под canonical target path.

После typed `DELETE` команда запускается из другой worktree через
`git worktree remove <path>` без `--force`. При успехе закрывается только owned
Vigit-tab; branch сохраняется.

## Ошибки

Adapter errors имеют `code`, user-facing `message`, diagnostic `details` и
`retryable`. Session сохраняет последнее успешное state и current error.
Краткое сообщение отображается внутри UI, подробности — в `:VigitLog`.
Controller boundary перехватывает runtime failures, освобождает busy state и
записывает traceback; programmer error не превращается в успешный результат.

## Миграция

1. Characterization tests существующих пользовательских сценариев.
2. `core`, Result, process runner, session registry и keymap registry.
3. Новый status/diff vertical slice под `:VigitV2`.
4. Native editor, terminal и LSP handoff.
5. File/hunk Git mutations.
6. Единый comments storage и legacy importer.
7. Worktree picker и safe removal.
8. Feature parity, переключение `:Vigit`, удаление legacy.
9. README, keymap reference, optional integrations и demo fixtures.

До этапа 8 legacy implementation остаётся доступной. Каждый этап проходит
относящиеся к нему unit, real-Git fixture и headless Neovim scenarios.

## Не входит в scope

- Управление tmux panes или Codex processes.
- Автоматическая отправка prompt агенту.
- Side-by-side diff.
- GitHub/GitLab review API.
- Обязательная зависимость от конкретного Neovim distribution.
