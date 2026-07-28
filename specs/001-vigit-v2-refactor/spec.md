# Feature Specification: Vigit v2 — независимый review companion

**Feature Branch**: `main`

**Created**: 2026-07-27

**Status**: Planned

**Input**: Полный рефакторинг Vigit без сохранения внутренних API: Vigit должен
работать рядом с обычным Neovim, поддерживать несколько worktrees, безопасный
review Git-изменений и комментарии для AI-агента.

## Пользовательские сценарии и проверки

### User Story 1 — Review изменений без подмены Neovim (Priority: P1)

Разработчик открывает Vigit в отдельной вкладке, просматривает staged и
unstaged изменения, а для редактирования переходит в обычный buffer с
пользовательскими LSP, Telescope, mappings и jumplist.

**Почему P1**: Это основная продуктовая граница и причина рефакторинга.

**Независимая проверка**: Открыть Vigit, перейти к изменённому Python-файлу,
вызвать `e` и `gd`, затем проверить пользовательские mappings и переходы
`Ctrl-o`/`Ctrl-i`.

**Acceptance Scenarios**:

1. **Given** открытая Vigit-tab, **When** пользователь нажимает `e`, **Then**
   файл открывается в обычной editor-tab без Vigit mappings, winbar и autocmds.
2. **Given** строка исходного кода в diff, **When** пользователь нажимает `gd`,
   **Then** Vigit открывает реальный buffer на source anchor и передаёт переход
   пользовательскому LSP handler без текстового fallback.
3. **Given** открытые editor и terminal tabs, **When** закрывается Vigit-tab,
   **Then** обычные tabs остаются открытыми.

---

### User Story 2 — Независимый review нескольких worktrees (Priority: P1)

Разработчик ведёт несколько задач в Git worktrees и получает отдельный review
контекст для каждой задачи без смешивания выбранных файлов и истории.

**Почему P1**: Multi-worktree — основной рабочий процесс пользователя.

**Независимая проверка**: Открыть две worktrees с одинаковым относительным
путём файла и переключаться между их Vigit/editor tabs.

**Acceptance Scenarios**:

1. **Given** две worktrees, **When** обе открыты через picker, **Then** каждая
   имеет одну независимую Vigit-tab.
2. **Given** Vigit-tab worktree уже открыта, **When** она выбирается повторно,
   **Then** фокус переходит в существующую tab без создания дубля.
3. **Given** одинаковый `src/service.py` в двух worktrees, **When** оба файла
   открыты, **Then** Neovim использует разные buffers по абсолютным путям.
4. **Given** editor-tab worktree уже существует, **When** выбирается другой
   файл той же worktree, **Then** используется её editor-tab.

---

### User Story 3 — Понятный и отзывчивый diff (Priority: P1)

Разработчик видит структурированный diff с разделением файлов, корректной
syntax highlighting добавленного и удалённого кода, управляемым context и
сохранением позиции.

**Почему P1**: Без достоверного diff невозможно безопасно проверять результат
AI-агента.

**Независимая проверка**: Открыть большой mixed staged/unstaged diff, раскрыть
context, обновить файл и убедиться, что source anchor сохранился.

**Acceptance Scenarios**:

1. **Given** установленный Treesitter parser, **When** отображается diff,
   **Then** добавленные и удалённые строки имеют syntax foreground поверх
   самостоятельного diff background.
2. **Given** скрытый интервал внутри функции, **When** её declaration не видна,
   **Then** placeholder содержит enclosing symbol; при видимой declaration имя
   не дублируется.
3. **Given** курсор на source line, **When** context раскрывается или diff
   обновляется, **Then** курсор остаётся на том же либо ближайшем source anchor.
4. **Given** большой change set, **When** открывается Vigit, **Then** changes
   list появляется до полной загрузки всех diff blocks.

---

### User Story 4 — Безопасное управление Git index (Priority: P1)

Разработчик stage/unstage целый файл или hunk и может откатить выбранный hunk
либо файл с явным подтверждением.

**Почему P1**: Ошибка здесь может привести к потере пользовательского кода.

**Независимая проверка**: Выполнить операции над staged, unstaged, added,
deleted, renamed и untracked fixtures и сравнить index/worktree до и после.

**Acceptance Scenarios**:

1. **Given** unstaged file/hunk, **When** нажимается `s`/`S`, **Then** только
   выбранный scope переносится в index.
2. **Given** staged file/hunk, **When** нажимается `s`/`S`, **Then** только
   выбранный scope переносится из index в worktree.
3. **Given** применимый unstaged hunk, **When** подтверждён `x`, **Then**
   откатывается только этот hunk.
4. **Given** staged hunk, **When** нажимается `x`, **Then** Vigit требует
   сначала выполнить hunk unstage через `S` и не изменяет Git state.
5. **Given** patch conflict, **When** запрошен hunk rollback, **Then** операция
   блокируется без fallback на весь файл.
6. **Given** untracked file, **When** подтверждён `X`, **Then** удаляется только
   выбранный path.

---

### User Story 5 — Комментарии для AI-агента (Priority: P2)

Разработчик оставляет комментарий на строке diff, редактирует или удаляет его,
переходит к источнику из общего списка и передаёт единый файл агенту. Агент
фиксирует ответ и завершение в этом же файле.

**Почему P2**: Функция расширяет review loop после надёжного просмотра Git.

**Независимая проверка**: Создать комментарий, сформировать prompt, вручную
добавить ответ и `[x]`, затем обновить Vigit.

**Acceptance Scenarios**:

1. **Given** source line в diff, **When** создаётся комментарий, **Then** он
   атомарно записывается в `.vigit/comments.md` со стабильным ID и anchor.
2. **Given** существующий комментарий, **When** он редактируется или удаляется,
   **Then** Git diff показывает соответствующее изменение единственного файла.
3. **Given** список comments, **When** нажимается `Enter`, **Then** Vigit
   переходит к source anchor либо ближайшему совпадению context.
4. **Given** комментарий с `[x]` и ответом агента, **When** выполняется refresh,
   **Then** UI показывает его как выполненный и отображает ответ.

---

### User Story 6 — Безопасный lifecycle worktree (Priority: P2)

Разработчик видит root и дополнительные worktrees, их branches, изменения и
upstream state, может открыть либо безопасно удалить законченную worktree.

**Почему P2**: Ускоряет переключение задач, но не должно рисковать данными.

**Независимая проверка**: Создать clean/dirty/ahead/no-upstream worktrees и
проверить разрешение удаления.

**Acceptance Scenarios**:

1. **Given** root worktree, **When** запрошено удаление, **Then** операция
   запрещена.
2. **Given** dirty, ahead либо no-upstream worktree, **When** запрошено
   удаление, **Then** Vigit показывает конкретную причину блокировки.
3. **Given** clean worktree с `ahead=0` и без открытых buffers, **When**
   пользователь вводит `DELETE`, **Then** выполняется `git worktree remove`
   без `--force`, а branch сохраняется.
4. **Given** remote-tracking state, **When** пользователь нажимает `F`, **Then**
   выполняется явный fetch и upstream status пересчитывается.

### Edge Cases

- Repository без commit (`unborn HEAD`) и added files.
- Файл одновременно содержит staged и unstaged изменения.
- Rename с дополнительными правками, file mode change и binary file.
- Пути содержат пробелы, Unicode, leading dash или похожи на path traversal.
- Файл изменился между render и stage/rollback.
- Worktree была удалена или перемещена внешним процессом.
- LSP/Tree-sitter parser/WhichKey/Telescope отсутствуют либо загружаются лениво.
- Async refresh завершается после более нового refresh или после закрытия tab.
- Comments anchor больше не существует после исправления агента.
- Один файл или общий diff превышает установленный безопасный размер.

## Требования

### Functional Requirements

- **FR-001**: Vigit MUST создавать не более одной Vigit-сессии на canonical
  worktree root.
- **FR-002**: Каждая сессия MUST хранить собственные view state, source anchor,
  async generation и errors.
- **FR-003**: Vigit MUST владеть только собственными `nofile` buffers и
  review-tabs.
- **FR-004**: Vigit MUST NOT добавлять mappings, winbar или lifecycle autocmds
  в обычные source buffers.
- **FR-005**: Default open handler MUST создавать или использовать обычную
  editor-tab соответствующей worktree.
- **FR-006**: Editor-tab MUST иметь tab-local worktree metadata для optional
  tabline/statusline integration.
- **FR-007**: Close Vigit MUST NOT закрывать editor или terminal tabs.
- **FR-008**: Changes panel MUST поддерживать tree и compact list.
- **FR-009**: One-file preview MUST обновляться при перемещении selection.
- **FR-010**: All-files mode MUST загружать diff blocks постепенно.
- **FR-011**: Diff lines MUST хранить old/new source coordinates.
- **FR-012**: Cursor restoration MUST использовать source anchor, а не screen
  row.
- **FR-013**: Context expansion MUST сохранять текущий anchor.
- **FR-014**: Symbol context MUST скрываться, если declaration уже видна.
- **FR-015**: При доступном parser Vigit MUST подсвечивать old и new versions
  через Treesitter.
- **FR-016**: Diff background MUST NOT перекрывать syntax foreground.
- **FR-017**: Diff markers MUST использовать signcolumn, не изменяя code text.
- **FR-018**: `gd` MUST передавать управление пользовательскому mapping либо
  native LSP и MUST NOT выполнять текстовый поиск.
- **FR-019**: Git read operations MUST выполняться async и отбрасывать stale
  generations.
- **FR-020**: Git mutation operations MUST выполняться последовательно.
- **FR-021**: Git commands MUST использовать argument arrays, explicit `cwd` и
  path separator `--`.
- **FR-022**: File и hunk stage/unstage MUST поддерживать mixed index/worktree
  state без потери другого слоя.
- **FR-023**: Hunk mutation MUST пройти patch preflight до изменения Git state.
- **FR-024**: Destructive rollback MUST требовать подтверждение.
- **FR-025**: Ошибка hunk rollback MUST NOT вызывать file-level fallback.
- **FR-026**: Review comments MUST храниться только в
  `.vigit/comments.md`.
- **FR-027**: Comment MUST содержать stable ID, checkbox status, source anchor,
  текст и секцию ответа агента.
- **FR-028**: Comment writes MUST быть atomic.
- **FR-029**: Prompt MUST включать все незавершённые comments и инструкцию
  обновить checkbox/response.
- **FR-030**: Worktree picker MUST различать root и linked worktrees.
- **FR-031**: Worktree status MUST показывать dirty files, branch, upstream,
  ahead и behind.
- **FR-032**: Worktree removal MUST блокироваться для root, dirty, ahead,
  no-upstream или открытых source buffers.
- **FR-033**: Worktree removal MUST использовать typed confirmation `DELETE`,
  не использовать `--force` и сохранять branch.
- **FR-034**: Network fetch MUST выполняться только явным действием.
- **FR-035**: Все Vigit keymaps MUST быть buffer-local и происходить из одного
  registry, используемого UI help и документацией.
- **FR-036**: Плагин MUST работать на Neovim 0.10+ без обязательных сторонних
  plugins.
- **FR-037**: Optional integrations MUST загружаться лениво и не ломать startup
  при отсутствии plugin.
- **FR-038**: Ошибка MUST оставлять последнее успешное view state и быть
  доступна через `:VigitLog`.
- **FR-039**: Legacy review data MUST NOT удаляться автоматически; importer
  требует явного запуска и создаёт backup.
- **FR-040**: Новый UI MUST быть доступен как `:VigitV2` до feature parity,
  после чего `:Vigit` переключается на v2.

### Key Entities

- **Session**: Canonical worktree root, owned Vigit tab/buffers, current view
  state, generation counters, mutation queue и current error.
- **Change**: Git path, status, staged/unstaged sections и old/new identity.
- **FileDiff**: Набор hunks и source-coordinate lines для одного Change.
- **SourceAnchor**: Path, section, side, source line, column и context
  fingerprint.
- **ReviewComment**: Stable ID, checkbox status, SourceAnchor, user text и agent
  response.
- **Worktree**: Type, canonical path, name, branch, dirty counts, upstream,
  ahead/behind и open-session state.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Две одновременно открытые worktrees сохраняют независимый
  selection/anchor во всех headless lifecycle scenarios.
- **SC-002**: После handoff ни один обычный source buffer не содержит
  buffer-local mappings или autocmds Vigit.
- **SC-003**: Все destructive fixture scenarios либо дают ожидаемое точное
  изменение, либо оставляют index/worktree byte-identical исходному состоянию.
- **SC-004**: Changes list становится доступен до загрузки all-files diff и
  остаётся управляемым во время Git/Tree-sitter работы.
- **SC-005**: Refresh/context toggle возвращает пользователя на исходный либо
  ближайший source anchor во всех regression fixtures.
- **SC-006**: Один tracked `.vigit/comments.md` полностью воспроизводит список,
  anchors, statuses и ответы без дополнительного storage.
- **SC-007**: Plugin startup и основной review flow проходят на чистом Neovim
  0.10+ без Telescope, WhichKey, NvChad и nvim-treesitter.
- **SC-008**: Unit, real-Git fixture и headless Neovim suites проходят перед
  удалением legacy implementation.

## Допущения

- Пользователь работает в Git repository и имеет Git 2.36+ с поддержкой
  NUL-separated `worktree list --porcelain -z` и используемых restore
  операций.
- Remote-tracking refs считаются состоянием последнего fetch; автоматическая
  проверка сети не выполняется.
- В первой версии существует один тип review comment: незавершённый или
  выполненный.
- Vigit не управляет tmux panes, Codex processes или transport к агенту.
- Side-by-side diff и remote hosting integrations не входят в этот рефакторинг.
- Breaking changes внутренних Lua API и старых keymaps разрешены.
