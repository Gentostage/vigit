# Review Focus and Source-first Staging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** сохранить review-контекст после `s/S`, явно подсвечивать выбранный
файл в changes tree и поддержать сохранение комментария через `:w`.

**Architecture:** controller запоминает исходную секцию, anchor и owned window,
а после refresh выбирает source-side изменение и восстанавливает focus. Changes
view рендерит отдельный full-line highlight для `selected_change_id`. Comment
editor перехватывает buffer-local `BufWriteCmd` и переиспользует существующий
save callback.

**Tech Stack:** Lua, Neovim API, Git CLI adapter, существующие unit/headless
test runners.

## Global Constraints

- Не менять mappings, options или lifecycle пользовательских source/terminal buffers.
- Не открывать staged-копию автоматически после stage последнего hunk.
- Не создавать commit или push без отдельной команды пользователя.
- Все production-изменения выполняются после наблюдаемого RED.

---

### Task 1: Source-first выбор и восстановление focus

**Files:**
- Modify: `tests/headless/hunk_mutations_spec.lua`
- Modify: `tests/headless/file_mutations_spec.lua`
- Modify: `lua/vigit/ui/controller.lua`

**Interfaces:**
- Consumes: `refresh_file_mutation(session, path, source_section, anchor, position, focus)`.
- Produces: выбор того же файла в исходной секции либо следующего файла этой
  секции; восстановление `diff_win`/`changes_win`, если окно валидно.

- [x] **Step 1: написать failing-тест partial hunk stage**

  Смоделировать status, где после `stage_hunk` один и тот же path присутствует
  в `staged` и `unstaged`; проверить, что `selected_change_id` остаётся
  `unstaged\0file.txt`.

- [x] **Step 2: написать failing-тест последнего hunk**

  После исчезновения path из `unstaged` оставить другой unstaged-файл и
  проверить выбор его id, а не `staged\0file.txt`.

- [x] **Step 3: написать failing-тест focus**

  В fake Neovim API начать в `changes_win`, завершить `s/S` и проверить вызов
  `nvim_set_current_win(changes_win)` после refresh.

- [x] **Step 4: подтвердить RED**

  Run:

  ```text
  nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/hunk_mutations_spec.lua tests/headless/file_mutations_spec.lua
  ```

  Expected: FAIL на destination-section selection и отсутствующем focus restore.

- [x] **Step 5: реализовать минимальную selection policy**

  Перед mutation сохранить исходную секцию и owned window. После status refresh
  искать path в исходной секции; затем target с исходной секцией на прежней или
  следующей позиции. Destination section не использовать как автоматический
  fallback. После render/load_diff восстановить валидное owned window.

- [x] **Step 6: подтвердить GREEN**

  Повторить focused headless command; все сценарии должны завершиться PASS.

### Task 2: Постоянный selected-индикатор в changes tree

**Files:**
- Modify: `tests/headless/sessions_spec.lua`
- Modify: `lua/vigit/ui/views/changes.lua`
- Modify: `lua/vigit/ui/highlights.lua`

**Interfaces:**
- Consumes: `state.view.selected_change_id`.
- Produces: highlight `VigitChangesSelected` на полной строке change target;
  directory targets не подсвечиваются.

- [x] **Step 1: написать failing renderer-тест**

  Render tree с двумя файлами и выбранным id; проверить один highlight
  `VigitChangesSelected` без `start_col/end_col`, совпадающий со строкой target.

- [x] **Step 2: подтвердить RED**

  Run:

  ```text
  nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/sessions_spec.lua
  ```

  Expected: FAIL, потому что selected highlight отсутствует.

- [x] **Step 3: реализовать highlight**

  После построения list/tree найти target с `change_id == selected_change_id` и
  добавить full-line `VigitChangesSelected`. В `highlights.setup()` связать
  группу с `Visual` как default link.

- [x] **Step 4: подтвердить GREEN**

  Повторить focused sessions suite; selected row видим независимо от focus.

### Task 3: Сохранение comment editor через `:w`

**Files:**
- Modify: `tests/headless/comments_spec.lua`
- Modify: `lua/vigit/ui/views/comments.lua`
- Modify: `lua/vigit/ui/keymaps.lua`
- Regenerate: `docs/keymaps.md`

**Interfaces:**
- Consumes: существующий локальный `save()` comment editor.
- Produces: buffer-local `BufWriteCmd`, вызывающий `save()`; `<C-s>` остаётся
  без изменения.

- [x] **Step 1: написать failing `:w` regression**

  Открыть новый comment editor, изменить строки, выполнить
  `nvim_buf_call(buffer, function() vim.cmd("write") end)` и проверить созданный
  comment и закрытое editor window.

- [x] **Step 2: подтвердить RED**

  Run:

  ```text
  nvim --headless --clean -u NONE -l tests/headless/run.lua tests/headless/comments_spec.lua
  ```

  Expected: FAIL с невозможностью записи `nofile` buffer или без сохранённого comment.

- [x] **Step 3: реализовать buffer-local write handler**

  Установить comment editor `buftype=acwrite`; зарегистрировать `BufWriteCmd`
  только для editor buffer и вызывать существующий `save()`. Обновить keymap
  description так, чтобы help показывал `<C-s> / :w`, без фиктивного mapping
  для Ex-команды.

- [x] **Step 4: обновить generated keymap docs**

  Run: `lua scripts/generate-keymaps.lua`

- [x] **Step 5: подтвердить GREEN**

  Повторить comments suite и `lua scripts/generate-keymaps.lua --check`.

### Task 4: Полная проверка

**Files:**
- Verify: весь текущий незакоммиченный scope.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: проверенный незакоммиченный результат для ручного review.

- [x] **Step 1: запустить полный gate**

  Run: `./scripts/test.sh`

  Expected: unit, integration, headless и generated-keymap gates PASS.

- [x] **Step 2: проверить patch hygiene**

  Run: `git diff --check`

  Expected: exit code `0`.

- [x] **Step 3: показать scope**

  Run: `git status --short` и `git diff --stat`; commit/push не выполнять.
