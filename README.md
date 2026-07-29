<div align="center">

# Vigit

**Просматривайте изменения AI-агентов во всех Git worktree, не покидая Neovim.**

Keyboard-first интерфейс для проверки diff, быстрых исправлений и передачи
точечных комментариев обратно coding agent.

[Сайт](https://vigit-neovim.gentostage.chatgpt.site) · [Демо](#быстрое-демо) · [Установка](#установка) · [Клавиши](#основные-клавиши)

</div>

![Vigit one-file diff](public/site/assets/vigit-one-file.png)

## Возможности

- staged и unstaged изменения в компактном списке или дереве;
- all-files и one-file diff с TreeSitter-подсветкой обеих сторон;
- stage/unstage файла или отдельного hunk;
- безопасный откат hunk/file с `y/N` и повторной проверкой stale state;
- отдельная Vigit session для каждого Git worktree;
- обычные editable source/terminal tabs без вмешательства в mappings, LSP и
  jumplist пользователя;
- tracked `.vigit/comments.md` с anchors, ответами агента и checkbox status;
- worktree picker с dirty/ahead/behind/no-upstream состояниями и безопасным
  удалением;
- встроенные help (`?`) и diagnostics (`:VigitLog`) без обязательных плагинов.

Vigit пока является ранним MVP. Commit, branch, push/pull, log view и
side-by-side diff не реализованы.

## Требования

- Neovim 0.10+;
- Git 2.36+;
- Lua 5.1/LuaJIT, поставляемый вместе с Neovim.

Сторонние runtime dependencies не обязательны. При наличии TreeSitter Vigit
использует уже установленные parsers и queries.

## Установка

### lazy.nvim

```lua
{
  "Gentostage/vigit",
  config = function()
    require("vigit").setup()
  end,
}
```

### Вручную

```lua
vim.opt.runtimepath:append(vim.fn.expand("~/path/to/vigit"))
require("vigit").setup()
```

Откройте любой путь внутри Git worktree и выполните:

```vim
:Vigit
```

`:VigitV2` остаётся временным compatibility alias и открывает ту же canonical
session. Дополнительные команды: `:VigitWorktrees`, `:VigitComments`,
`:VigitHelp`, `:VigitLog`, `:VigitMigrateReviews` и
`:VigitInstallCodexSkill`.

## Модель worktree и editor

Vigit создаёт один принадлежащий ему review tab на canonical worktree. Внутри
находятся только read-only diff/changes buffers. Повторный `:Vigit` фокусирует
существующую session.

`e`, `gd` и `T` передают управление обычным пользовательским tab:

- `e` открывает или переиспользует source tab данного worktree;
- `gd` открывает source position и вызывает стандартный LSP definition;
- `T` открывает terminal с cwd в активном worktree.

Vigit не добавляет в эти buffers собственные `Q`, options, autocmds или
mappings. Переключайтесь обратно стандартными командами Neovim: `gt`, `gT`,
`:tabnext`, `:tabprevious` или через свою tabline. Поэтому Telescope, LSP,
WhichKey, jumplist (`Ctrl-o`/`Ctrl-i`) и пользовательские mappings работают как
обычно.

## Основные клавиши

| Key | Действие |
| --- | --- |
| `<Tab>` | Переключить diff и changes |
| `<CR>` | Открыть выбранное изменение |
| `]f` / `[f` | Следующий/предыдущий файл |
| `]h` / `[h` | Следующий/предыдущий hunk |
| `a` | Переключить one-file/all-files |
| `t` | Переключить tree/list |
| `f` | Показать/скрыть полный context |
| `e` | Открыть source file |
| `gd` | Перейти к LSP definition |
| `T` | Открыть terminal в worktree |
| `s` | Stage/unstage текущий файл |
| `S` | Stage/unstage текущий hunk |
| `x` | Откатить unstaged hunk после `y/N` |
| `X` | Восстановить файл до HEAD после `y/N` |
| `c` | Добавить/изменить comment у diff anchor |
| `C` | Открыть список comments |
| `P` | Скопировать/показать prompt для открытых comments |
| `W` | Открыть worktree picker |
| `r` | Обновить Git state |
| `?` | Context-aware help |
| `q` | Закрыть текущий Vigit UI |

Полная generated reference: [docs/keymaps.md](docs/keymaps.md).

## Comments и работа с агентом

Vigit хранит canonical document в каждом worktree:

```text
.vigit/comments.md
```

Файл намеренно находится внутри проекта и виден в Git diff. Каждый block
содержит stable ID, source anchor, пользовательский comment, секцию
`### Ответ агента` и checkbox `[ ]`/`[x]`.

1. Нажмите `c` на изменённой строке и сохраните comment через `<C-s>`.
2. Нажмите `C`, чтобы открыть общий список, перейти к anchor, изменить или
   удалить comment.
3. Нажмите `P`: в clipboard попадёт prompt только с открытыми comments и
   точным worktree root.
4. Агент исправляет код или отвечает на вопрос, записывает краткий результат
   под `### Ответ агента` и ставит `[x]` только после завершения.
5. `r` или сохранение файла обновляет markers и status с диска.

Bundled Codex skill устанавливается командами:

```vim
:VigitInstallCodexSkill
:VigitInstallCodexSkill!
```

Skill сохраняет неизвестный Markdown и чужие comments, не выполняет stage,
commit, push и не удаляет worktree без отдельного запроса. Legacy review data
импортируется только явной командой `:VigitMigrateReviews`.

## Безопасность worktree

`W` открывает picker. Он показывает `ROOT` и linked `WT`, branch, количество
изменений и upstream state. Сетевой fetch никогда не выполняется скрыто;
используйте `F` явно.

`d` удаляет только linked worktree, если:

- Git status чистый;
- branch имеет upstream;
- `ahead == 0`;
- в worktree нет загруженных source buffers;
- повторный preflight после `y` дал тот же безопасный результат.

Vigit закрывает только принадлежащую ему session, сохраняет Git branch и не
закрывает пользовательские source/terminal tabs.

## Быстрое демо

```bash
git clone git@github.com:Gentostage/vigit.git
cd vigit
./scripts/demo.sh
```

Fixture создаёт root и четыре linked worktree со staged/unstaged long files,
mixed hunks, staged deletion, untracked files, tracked open/completed comments,
а также safe, dirty, ahead и no-upstream состояниями. Всё удаляется после
закрытия Neovim.

```bash
./scripts/demo.sh --user-config  # обычный пользовательский config/plugins
./scripts/demo.sh --plugins      # изолированные Telescope + plenary
./scripts/demo.sh --check        # только автоматическая проверка fixture
```

`--plugins` требует Neovim 0.12+, использует отдельный `NVIM_APPNAME` и не
изменяет пользовательский config.

## Разработка

Единая проверка:

```bash
./scripts/test.sh
```

Скрипт последовательно запускает unit, real-Git integration, headless Neovim и
generated keymap drift check. Он останавливается на первой ошибке, ничего не
устанавливает и не изменяет пользовательский Neovim config.

## Сайт проекта

[Project card](https://vigit-neovim.gentostage.chatgpt.site) собирается из
[`public/site/`](public/site/index.html). Страница остаётся plain HTML/CSS и
готова для добавления WebM/MP4 demo.
