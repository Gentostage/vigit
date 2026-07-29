# Vigit v2: research decisions

## Async process API

**Decision**: Использовать `vim.system(args, opts, callback)` через один
`adapters/process.lua`; callback всегда переводится в main loop через
`vim.schedule`.

**Rationale**: API принимает argument array, поддерживает explicit `cwd`, stdin,
async completion и cancellation без shell.

**Alternatives considered**:

- `vim.fn.system`: блокирует UI.
- `jobstart`: требует больше version-specific glue.
- direct `vim.uv.spawn`: дублирует готовый Neovim process API.

## Минимальная версия Git

**Decision**: Git 2.36+.

**Rationale**: В 2.36 появился `git worktree list --porcelain -z`, позволяющий
безопасно разбирать worktree paths с newline. Status также читается в
NUL-separated porcelain v2.

**Alternatives considered**:

- Git 2.23+ и newline-delimited worktrees: создаёт отдельный небезопасный parser
  path.
- runtime fallback без `-z`: усложняет contract и скрывает различия поведения.

## Git status и diff

**Decision**: Status — один
`status --porcelain=v2 --branch -z --untracked-files=all`; diff — отдельный
`git diff` на каждую selected/prefetched path.

**Rationale**: Status быстро строит navigation, а per-file diff ограничивает
memory и не требует извлекать pathname из неоднозначного `diff --git` header.

**Alternatives considered**:

- Один общий diff: задерживает первый render и может быть очень большим.
- libgit2 binding: новая обязательная native dependency.

## Session concurrency

**Decision**: Reads используют monotonically increasing generation; mutations
исполняются FIFO по одной на session.

**Rationale**: Status/diff можно безопасно заменять новым запросом, но index
operations должны видеть последовательное Git state.

**Alternatives considered**:

- Global mutex: блокирует независимые worktrees.
- Cancellation как единственная защита: process может завершиться одновременно
  с cancel; generation всё равно необходима.

## Native editor handoff

**Decision**: На worktree выбирается одна primary normal editor-tab по
`vim.t.vigit_root`; Vigit не считает её owned resource.

**Rationale**: Пользователь получает обычные LSP/plugins/jumplist, но tabline
может различать одинаковые filenames через metadata.

**Alternatives considered**:

- Vigit-managed editor tab: повторяет legacy проблему lifecycle ownership.
- Новый tab на каждый `e`: создаёт tab clutter.
- Открытие в Vigit diff window: разрушает review layout.

## LSP definition bridge

**Decision**: После handoff проверить пользовательский normal `gd` mapping через
`maparg`; при наличии отправить remappable keys. Без mapping вызвать
`vim.lsp.buf.definition()`. Если client ещё не attached, использовать bounded
one-shot `LspAttach`.

**Rationale**: Feedkeys активирует lazy-loaded пользовательскую интеграцию, а
fallback остаётся публичным Neovim LSP API.

**Alternatives considered**:

- Вызвать callback mapping напрямую: не покрывает string/expr/lazy mappings.
- Всегда вызывать LSP API: игнорирует Telescope и пользовательский handler.
- Text search: выдаёт похожее слово вместо definition.

## Tree-sitter для mixed diff

**Decision**: Parse old/new snapshots как strings и перенести query captures по
source coordinates на diff extmarks. Background и syntax используют разные
priorities.

**Rationale**: Один mixed-file scratch buffer не может иметь корректный
filetype/highlighter для всех blocks; snapshots дают syntax удалённым строкам.

**Alternatives considered**:

- Установить filetype diff buffer: подсвечивает только один язык.
- Временные source buffers: запускают пользовательские autocmds/plugins.
- Собственный regex highlighter: плохо расширяется на другие языки.

## Comments storage

**Decision**: `.vigit/comments.md` — canonical versioned Markdown document;
checkbox хранит status, HTML block хранит anchor metadata.

**Rationale**: Файл читаем пользователем и агентом, видим в Git diff и
достаточно структурирован для стабильных ID/anchors.

**Alternatives considered**:

- JSON + generated Markdown: два представления могут рассинхронизироваться.
- JSON-only: неудобен для prompt и ручного review.
- Свободный Markdown: невозможно надёжно редактировать конкретный comment.

## Worktree removal

**Decision**: Блокировать remove для root, dirty, no-upstream, ahead>0,
locked/prunable или любого loaded source buffer под target root. После
подтверждения `y` повторить preflight и вызвать remove без force из другой
worktree.

**Rationale**: Vigit закрывает только owned review tab и не решает судьбу
пользовательских buffers/branches.

**Alternatives considered**:

- Автоматически закрыть clean buffers: Vigit снова управляет editor lifecycle.
- Разрешить remove по dirty=false без upstream: можно потерять локальные commits.
- Hidden fetch: неожиданная network mutation и latency.

## Test strategy

**Decision**: Pure tests остаются runnable обычным `lua`; Git contracts
используют real temporary repositories; Neovim ownership проверяется headless.

**Rationale**: Mocks не доказывают patch/index и tab/buffer lifecycle, а полный
headless test для каждого parser case будет медленным.

**Alternatives considered**:

- Только mocks: пропускают quoting, race и Git semantics.
- Только end-to-end: медленные и плохо локализуют failure.
