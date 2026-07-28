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
vigit.worktrees({ cwd = path })
vigit.help()
```

До cutover `vigit.open()` и `:Vigit` остаются legacy, а новый API доступен как
`require("vigit.v2").open()` и `:VigitV2`.

## Commands after cutover

| Command | Contract |
| --- | --- |
| `:Vigit` | Open/focus session for current or supplied cwd |
| `:VigitWorktrees` | Open picker for repository containing current path |
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
