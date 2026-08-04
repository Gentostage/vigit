# Устойчивый focus и source-first staging

## Цель

После Git mutation пользователь должен продолжать review там, где он работал:
Vigit не переносит выбор в staged-копию файла и не отдаёт focus скрытому
базовому окну Neovim. Comment editor должен сохраняться обычной командой
`:w` наряду с `<C-s>`.

## Выбранное поведение

- `S` запоминает исходную секцию, файл, source anchor и активную Vigit-панель.
- После stage hunk сначала выбирается оставшееся изменение того же файла в
  `Unstaged`. Курсор восстанавливается на ближайшей сохранившейся строке.
- Если файл полностью исчез из `Unstaged`, выбирается следующий доступный
  `Unstaged` файл. Staged-копия автоматически не открывается.
- Для unstage hunk применяется симметричное правило: сначала остаёмся в
  `Staged`, затем выбираем следующий staged-файл.
- После `s` и `S` focus возвращается в исходную Vigit-панель (`diff` или
  `changes`), если она ещё существует.
- `<C-w><Left>` и `<C-w><Right>` переключают только две принадлежащие Vigit
  floating-панели. Скрытое source-окно не становится активным.
- В changes tree выбранный для diff файл имеет постоянную подсветку всей
  строки, даже когда focus находится в diff. Cursorline остаётся отдельным,
  более контрастным состоянием навигации и не заменяет selected-индикатор.
- В comment editor `:w` вызывает тот же save callback, что и `<C-s>`.
  Успешное сохранение закрывает editor по текущему flow; ошибка оставляет его
  открытым и показывается через существующий error path.

## Границы реализации

Логика выбора после mutation остаётся в controller/application flow. Layout
отвечает только за восстановление focus между owned windows. Comment editor
использует buffer-local `BufWriteCmd`, поэтому Vigit не изменяет mappings или
autocmds пользовательских source/terminal buffers.

## Проверка

- Headless regression: после `s` и `S` активным остаётся owned Vigit window,
  а `<C-w>` переводит focus во вторую Vigit-панель.
- Renderer regression: selected change получает отдельную подсветку в tree
  независимо от активного окна; directory rows её не получают.
- Hunk regression: partial stage остаётся на том же unstaged-файле; последний
  hunk не открывает staged-копию.
- Comment regression: `:w` сохраняет новый и отредактированный комментарий
  тем же путём, что `<C-s>`.
- После focused checks выполняется полный `./scripts/test.sh`.
