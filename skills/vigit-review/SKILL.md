---
name: vigit-review
description: Use when a user asks Codex to resolve open Vigit comments, answer review questions, or process the canonical .vigit/comments.md file in the current Git worktree.
---

# Vigit Review

Обработай только открытые комментарии Vigit в текущем worktree и запиши
результат обратно в canonical `.vigit/comments.md`.

## Проверь handoff

1. Прочитай repository instructions и выполни `git rev-parse --show-toplevel`.
2. Открой абсолютный путь `.vigit/comments.md`, указанный в prompt.
3. Убедись, что `Worktree` в prompt совпадает с текущим Git root.
4. Остановись до изменений, если путь отсутствует, выходит за пределы root
   или файл не содержит открытых `## [ ] VIGIT-*` блоков.

## Обработай комментарии

Для каждого открытого блока по порядку:

1. Прочитай anchor, сохранённый context и актуальный project file.
2. Исправь код или ответь на вопрос минимальным безопасным изменением.
3. Запусти документированные проверки проекта, если они доступны.
4. При успехе запиши краткий результат под `### Ответ агента` и замени только
   checkbox этого блока с `[ ]` на `[x]`.
5. При блокировке запиши точную причину под `### Ответ агента`, но оставь
   checkbox `[ ]`.

Перед записью перечитай comment file. Сохрани ID, anchor metadata, неизвестный Markdown,
закрытые блоки и остальные комментарии без изменений. Не удаляй комментарии
и не перезаписывай внешние изменения.

Никогда не stage, commit или push. Не переключай branch, не используй другой
worktree и не удаляй worktree без отдельного прямого запроса пользователя.

## Legacy migration

Не ищи legacy review storage во время обычной обработки. Используй
`:VigitMigrateReviews` только когда пользователь явно запросил migration.

## Отчёт

Кратко перечисли:

- завершённые ID и изменённые project files;
- заблокированные ID и причины;
- выполненные проверки и их результат.
