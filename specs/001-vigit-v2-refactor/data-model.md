# Vigit v2: data model

## Result

```lua
-- success
{ ok = true, value = any }

-- failure
{
  ok = false,
  error = {
    code = "git_failed",
    message = "Не удалось прочитать Git status",
    details = "fatal: ...",
    retryable = true,
  },
}
```

`details` предназначен для `:VigitLog`; UI использует `message`.

## Session

```lua
{
  id = "vigit-4",
  root = "/canonical/worktree",
  branch = "feature/example",
  owned = {
    tab = 12,
    diff_buf = 42,
    changes_buf = 43,
    diff_win = 1002,
    changes_win = 1003,
  },
  view = ViewState,
  data = {
    status = Status,
    diffs = { ["unstaged\0src/a.lua"] = FileDiff },
    comments = { ReviewComment },
  },
  reads = {
    generation = 7,
    jobs = {},
  },
  mutations = {
    active = false,
    queue = {},
  },
  busy = {},
  error = nil,
  closed = false,
}
```

### Session transitions

```text
missing -> opening -> ready -> closing -> closed
                    \-> error -> refreshing -> ready
```

Only owned resources закрываются при переходе `closing`.

## ViewState

```lua
{
  changes_mode = "tree",          -- tree | list
  diff_mode = "one_file",         -- one_file | all_files
  selected_change_id = "unstaged\0src/a.lua",
  anchor = SourceAnchor,
  expanded_dirs = {},
  expanded_context = {},
  all_files = {
    loaded = {},
    loading = {},
  },
}
```

## Change и Status

```lua
Change = {
  id = "unstaged\0src/a.lua",
  section = "unstaged",           -- staged | unstaged
  status = "M",                   -- M/A/D/R/C/T/U/?
  path = "src/a.lua",
  old_path = nil,
  object = {
    head = "0123...",
    index = "4567...",
  },
}

Status = {
  staged = { Change },
  unstaged = { Change },
  by_id = { [string] = Change },
}
```

`path` и `old_path` всегда repository-relative и проходят проверку, что
absolute resolution остаётся внутри canonical root.

## FileDiff, Hunk и DiffLine

```lua
FileDiff = {
  change_id = "unstaged\0src/a.lua",
  path = "src/a.lua",
  old_path = nil,
  section = "unstaged",
  status = "M",
  binary = false,
  oversize = false,
  hunks = { Hunk },
}

Hunk = {
  id = "src/a.lua\0unstaged\0-10,3+10,4",
  header = "@@ -10,3 +10,4 @@ function M.run()",
  old_start = 10,
  old_count = 3,
  new_start = 10,
  new_count = 4,
  lines = { DiffLine },
  patch = "diff --git ...",
}

DiffLine = {
  kind = "add",                   -- add | delete | context | meta
  text = "  return value",
  old_line = nil,
  new_line = 12,
}
```

`text` не содержит textual diff prefix; add/delete indication принадлежит
render metadata/signcolumn.

## SourceAnchor

```lua
{
  path = "src/a.lua",
  section = "unstaged",
  side = "new",                   -- old | new
  source_line = 12,
  column = 9,
  context = "return repository.save(item)",
  hunk_id = "...",
}
```

Match priority:

1. same path/side/exact source line;
2. same path/context fingerprint;
3. nearest source line in same hunk;
4. nearest source line in same file;
5. file header.

## ReviewComment

```lua
{
  id = "VIGIT-001",
  status = "open",                -- open | done
  anchor = SourceAnchor,
  body = "Обработать RepositoryError.",
  response = "Добавлена обработка...",
}
```

### Review transitions

```text
absent -> open -> edited -> done
            \----------------> deleted
done -> edited -> open
done -----------------------> deleted
```

Deletion removes the whole section; Git history является audit trail.

## Worktree

```lua
{
  id = "/canonical/worktree",
  kind = "root",                  -- root | linked
  path = "/canonical/worktree",
  name = "feature-example",
  branch = "feature/example",
  head = "0123...",
  detached = false,
  locked = false,
  prunable = false,
  status = {
    changed = 3,
    staged = 1,
    unstaged = 2,
    untracked = 0,
  },
  upstream = {
    name = "origin/feature/example",
    ahead = 0,
    behind = 1,
    source = "local_refs",
    fetched_at = nil,
  },
  session_id = nil,
}
```

Removal policy возвращает first typed blocker либо `nil`. Preflight
пересчитывается непосредственно перед `git worktree remove`.

`source = "local_refs"` означает, что ahead/behind рассчитаны без сети.
`fetched_at` заполняется только после успешного explicit `F` внутри текущей
Vigit session и не претендует на время внешнего `git fetch`.
