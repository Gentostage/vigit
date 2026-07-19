<div align="center">

# Vigit

**Review, navigate, edit, stage, and unstage Git changes without leaving Neovim.**

A keyboard-first Git workspace built entirely in Lua.

[Quick demo](#quick-demo) · [Installation](#installation) · [Key mappings](#key-mappings) · [Project site](site/index.html)

</div>

![Vigit one-file diff](site/assets/vigit-one-file.png)

## Why Vigit

- Keep staged and unstaged changes clearly separated.
- Switch between a compact file list and a VS Code-style collapsed tree.
- Review every changed file in one scrollable view or focus on a single file.
- Stage or unstage a whole file or the hunk under the cursor.
- Read Lua changes with syntax-aware highlighting and restrained diff colors.
- Open the real file in a normal, editable Neovim tab and return to a refreshed
  diff.
- Preview a different file simply by moving through the changes panel in
  one-file mode.

## Status

Vigit is an early MVP for hands-on evaluation. File and hunk staging,
unstaging, tree navigation, one-file preview, editing, and untracked files are
implemented. Commit, branch, push, pull, log, and side-by-side diff interfaces
are not available yet.

## Quick demo

```bash
git clone git@github.com:Gentostage/vigit.git
cd vigit
./scripts/demo.sh
```

The script creates a temporary Git repository with staged, unstaged, deleted,
untracked, deeply nested, and long-file changes. It launches Vigit in a clean
Neovim session and removes the fixture when Neovim exits.

Use your own Neovim configuration:

```bash
./scripts/demo.sh --user-config
```

Try the isolated Telescope integration:

```bash
./scripts/demo.sh --plugins
```

The plugin demo requires Neovim and Git. The `--plugins` mode requires Neovim
0.12+, installs Telescope v0.2.1 and plenary.nvim into the isolated
`vigit-demo` package namespace, and does not modify `~/.config/nvim`.

## Installation

### lazy.nvim

```lua
{
  "Gentostage/vigit",
  config = function()
    require("vigit").setup()
  end,
}
```

### Manual

Clone Vigit somewhere on your machine, append it to `runtimepath`, and call
`setup()`:

```lua
vim.opt.runtimepath:append(vim.fn.expand("~/path/to/vigit"))
require("vigit").setup()
```

## Setup

Open any Git worktree in Neovim and run:

```vim
:Vigit
```

## Workflow

```text
All changes  ── Enter ──>  One-file diff  ── e ──>  Normal edit tab
     ▲                           │                        │
     └──────────── a ────────────┴────────── Q ──────────┘
```

The edit tab uses an ordinary modifiable file buffer. Filetype detection,
syntax highlighting, LSP, user mappings, and installed plugins keep working.
After `:w`, press `Q` to return to an updated Vigit view. If any file in the
edit workspace is still modified, Vigit blocks the return and lists the files
that must be saved or explicitly discarded.

## Key mappings

| Key | Action |
| --- | --- |
| `t` | Toggle compact `LIST` and collapsed `TREE` |
| `<CR>` | Focus the selected file; collapse or expand a tree directory |
| `h` / `l` | Collapse or expand the directory under the cursor |
| `a` | Return to the all-files diff |
| `e` | Edit the selected file in a normal Neovim tab |
| `s` | Stage an unstaged file/hunk or unstage a staged file/hunk |
| `r` | Refresh Git status and diff |
| `f` | Toggle compact and expanded diff context |
| `q` | Close the Vigit interface |
| `Q` | Return from the edit tab to Vigit |
| `:qa!` | Exit Neovim completely |

## Plugin-friendly edit mode

Inside the edit workspace, use normal Neovim navigation:

```vim
:edit path/to/file
:find filename
gf
:vimgrep /text/gj **/* | copen
```

With `./scripts/demo.sh --plugins`, Telescope mappings are available:

| Key | Action |
| --- | --- |
| `<leader>ff` | Find files |
| `<leader>fg` | Live grep |
| `<leader>fb` | Open buffers |

Every regular file buffer opened in the edit tab is attached to the Vigit
workspace, so `Q` remains available after navigating to another file.

## Project site

The minimal static project card lives in [`site/`](site/index.html). It shares
the repository screenshots and is ready for a real WebM or MP4 demo recording.

## Roadmap

- Commit and branch workflows.
- Push, pull, and log views.
- Side-by-side diff mode.
- Configurable mappings and layout.
- Recorded demo and richer project gallery.
