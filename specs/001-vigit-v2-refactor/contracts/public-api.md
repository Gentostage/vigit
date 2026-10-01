# Public Lua and command contract

## Setup

```lua
require("vigit").setup({
  ui = {
    changes_side = "right",
    changes_width = 32,
    changes_mode = "tree",
    context_lines = 3,
    max_diff_bytes = 2 * 1024 * 1024,
    max_highlight_bytes = 512 * 1024,
  },
  refresh = {
    on_write = true,
    on_tab_enter = true,
    debounce_ms = 120,
  },
  review = {
    path = ".vigit/comments.md",
  },
  handlers = {
    open_file = nil,
    open_terminal = nil,
    goto_definition = nil,
    open_worktrees = nil, -- optional function или false; default manager отсутствует
  },
  keymaps = {},
})
```

Unknown keys and invalid types возвращают setup error с полным option path.
User tables deep-merge с defaults; `false` отключает optional mapping.

## Public functions

```lua
local vigit = require("vigit")

vigit.setup(opts)              -- idempotent command/autocmd registration
vigit.open({ cwd = path })     -- returns Session | nil, Error
vigit.can_close({ cwd = root }) -- returns true | nil, Error; без побочных эффектов
vigit.close({ cwd = root })    -- returns true | false | nil, Error
vigit.worktrees({ cwd = path }) -- вызывает настроенный внешний manager
vigit.help()
```

`require("vigit.v2")` и `:VigitV2` являются compatibility aliases того же
runtime без отдельного state. Каждый canonical root сохраняет независимую
review-сессию. Смена review root сохраняет пользовательские source buffers и
работающие terminals. Cwd привязывается только к review tab; global cwd, другие
tabs и пользовательские window-local cwd сохраняются.

`close({ cwd = root })` освобождает только matching active/cached review-сессию
и её owned UI/resources. Active session очищается, остальные cached sessions
сохраняются. Файлы, source buffers, terminals и editor cwd не изменяются.
Возвращает `true` при закрытии и `false`, если matching session отсутствует.
`cwd` обязателен: непустая строка пути root без NUL; invalid input возвращает
`nil, Error{code="invalid_options"}`. Уже удалённый root сопоставляется через
normalized absolute path, без поиска родительского repository. Для существующего
root используется canonical path. Активная Git mutation возвращает
`mutation_in_progress`, несохранённый Vigit comment editor —
`modified_comment_editor`; session сохраняется. Host может вызывать этот API
после собственного события удаления root.

`can_close({ cwd = root })` выполняет те же root lookup и close guards без
закрытия session или изменения UI, focus, cwd, buffers, terminals и session
state. Возвращает `true`, если matching session отсутствует или может быть
закрыта, иначе `nil, Error`. Правила `cwd` и ошибки `invalid_options`,
`mutation_in_progress`, `modified_comment_editor` совпадают с `close`.
Внешний host проверяет этот API перед confirmation удаления root и повторно
непосредственно перед Git mutation; после успешного удаления вызывает `close`.
Guards относятся только к review lifecycle, управление worktree остаётся у host.

## Commands after cutover

| Command | Contract |
| --- | --- |
| `:Vigit` | Open/focus session for current or supplied cwd |
| `:VigitWorktrees` | Вызвать настроенный внешний менеджер worktree |
| `:VigitComments` | Open current session comments |
| `:VigitHelp` | Open generated keymap reference |
| `:VigitLog` | Open diagnostic ring buffer |
| `:VigitMigrateReviews` | Explicitly import legacy review data with backup |

## Handler context

```lua
HandlerContext = {
  session_id = "vigit-4",
  root = "/canonical/worktree",
  branch = "feature/example",
  path = "/canonical/worktree/src/a.lua",
  relative_path = "src/a.lua",
  line = 12,
  column = 9,
}
```

Signatures:

```lua
handlers.open_file(context, done)
handlers.open_terminal(context, done)
handlers.goto_definition(context, done)
```

`done(Result)` вызывается ровно один раз. Default native handlers выполняют
operation самостоятельно; custom handlers несут ответственность только за
handoff и не получают Session table.

## Внешний менеджер worktree

`handlers.open_worktrees` имеет отдельный synchronous контракт:

```lua
handlers.open_worktrees({
  root = "/canonical/root",
  mode = "review", -- "review" or "code"
})
```

Handler получает plain table только с `root` и `mode`, без Session, Workspace
или callback `done`. Он синхронно инициирует внешний picker. Entry points:
`vigit.worktrees({ cwd = path })`, `:VigitWorktrees` и `W` на owned review
buffers. Явный `cwd` имеет приоритет; review mode использует active review root,
code mode — текущий source buffer, затем cwd. В текущей вкладке с видимым review
передаётся `review`; в обычном editor context — `code`.

Возвращается первое значение handler, включая `false`, либо `true` для `nil`
без ошибки. `nil, Error` и `false, Error` передаются caller как `nil, Error`;
Error должна содержать непустые string `code` и `message`, иначе возвращается
`handler_failed`. Отсутствующий/отключённый (`false`) handler возвращает
`handler_unavailable`; thrown exception возвращает `handler_failed` с details.
Ошибка разрешения root возвращается до вызова handler. Команда и `W` показывают
ошибку, прямой Lua API возвращает её caller. Встроенного fallback manager нет.

Пример интеграции из пользовательского Neovim config:

```lua
require("vigit").setup({
  handlers = {
    open_worktrees = function(context)
      return require("custom.worktrees").open({
        cwd = context.root,
        on_select = context.mode == "review" and function(root)
          require("vigit").open({ cwd = root })
        end or nil,
      })
    end,
  },
})
```

`custom.worktrees` принадлежит пользовательскому config. Vigit не импортирует
пользовательские modules и не реализует выбор, fetch, удаление worktree или
переключение обычного editor workspace. `vigit.open({ cwd = root })` работает
самостоятельно без manager handler.

## Keymap registry

Каждая entry имеет stable action ID:

```lua
{
  id = "change.toggle_index",
  modes = { "n" },
  lhs = "s",
  contexts = { "diff", "changes" },
  description = "Stage or unstage current file",
  intent = "toggle_file_index",
}
```

Registry является единственным источником для `vim.keymap.set`, inline hints,
help buffer, `:VigitHelp` и generated `docs/keymaps.md`. Mappings создаются
только на owned Vigit buffers. Будущая WhichKey integration должна читать этот
же registry и не входит в v2 cutover.

## Tab metadata

Default native source/terminal handlers могут устанавливать:

```lua
vim.t.vigit_root = "/canonical/worktree"
vim.t.vigit_branch = "feature/example"
vim.t.vigit_label = "CODE feature/example · a.lua"
```

Metadata не означает ownership. Close session не закрывает такую tab.
