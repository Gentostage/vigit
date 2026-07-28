# `.vigit/comments.md` format contract

## Document

```md
# Vigit Review

<!-- vigit-format: 1 -->

## [ ] VIGIT-001 · src/service.py:42

<!-- vigit-anchor
path: src/service.py
line: 42
column: 8
side: new
section: unstaged
context: await repository.save(item)
-->

Нужно обработать ошибку сохранения и объяснить выбранное поведение.

### Ответ агента

```

Completed entry:

```md
## [x] VIGIT-001 · src/service.py:42

<!-- vigit-anchor
path: src/service.py
line: 42
column: 8
side: new
section: unstaged
context: await repository.save(item)
-->

Нужно обработать ошибку сохранения и объяснить выбранное поведение.

### Ответ агента

Добавил обработку RepositoryError и сохранил исходное исключение как cause.
```

## Grammar

- Header MUST быть `## [ ] ID · path:line` либо `## [x] ID · path:line`.
- ID MUST match `VIGIT-[0-9]{3,}` и быть уникальным.
- Metadata block MUST следовать за header до body.
- Required metadata: `path`, `line`, `side`, `section`, `context`.
- `column` optional и defaults to `0`.
- `path` repository-relative; absolute/path traversal values invalid.
- Body заканчивается перед exact `### Ответ агента`.
- Response продолжается до следующего comment header или EOF.
- Unknown top-level prose сохраняется byte-for-byte при unrelated operation.

## Operations

```lua
review.parse(markdown) -> Result<Document>
review.serialize(document) -> string
review.add(document, input) -> Result<Document, ReviewComment>
review.update(document, id, changes) -> Result<Document>
review.delete(document, id) -> Result<Document>
review.prompt(document, root) -> string
```

Новый ID равен максимальному numeric suffix + 1. Deletion удаляет только
section выбранного ID и нормализует один разделительный blank line.

## Atomic storage

1. Resolve configured path under canonical worktree root.
2. Reject symlink/path resolution outside root.
3. Write complete content to sibling temporary file.
4. Flush/close temporary file.
5. Rename temporary file over canonical path.
6. On failure remove only temporary file and preserve original.

## Agent protocol

Prompt instructs agent:

1. Обработать только `[ ]` entries.
2. Исправить код либо ответить на вопрос в указанной worktree.
3. Записать краткий результат в `### Ответ агента`.
4. Поставить `[x]` только после завершения.
5. Не менять ID/anchor и не stage/commit/push.

Blocked comment остаётся `[ ]`; объяснение можно добавить в response.
