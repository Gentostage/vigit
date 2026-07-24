# Compact Confirmations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** заменить числовые destructive-action диалоги Vigit на компактное
подтверждение `y/N`.

**Architecture:** новый `lua/vigit/confirm.lua` изолирует вызов
`vim.fn.confirm()` и безопасный default `No`. `actions.lua` и `review_ui.lua`
передают ему точный текст операции и callback.

**Tech Stack:** Lua, Neovim API, существующий Lua test harness.

## Global Constraints

- `y` подтверждает; `n`, `<Esc>` и `<Enter>` отменяют.
- Worktree продолжает требовать точный ввод `DELETE`.
- Не изменять диалоги установки Codex skill и comment editor.
- Не создавать commit/push без отдельного запроса.

---

### Task 1: Общий confirm helper

**Files:**
- Create: `lua/vigit/confirm.lua`
- Create: `tests/confirm_spec.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Produces: `confirm.ask(prompt: string, callback: function): boolean`.
- `true` означает подтверждение и выполненный callback; `false` — отмену.

- [ ] **Step 1: добавить failing-тесты**

```lua
local confirm = require("vigit.confirm")

it("runs callback only for Yes", function()
  -- vim.fn.confirm returns 1
  assert_equal(confirm.ask("Delete?", callback), true)
end)

it("defaults confirmation to No", function()
  -- verify choices == "&Yes\n&No", default == 2
  assert_equal(confirm.ask("Delete?", callback), false)
end)
```

- [ ] **Step 2: подтвердить RED**

Run: `lua tests/run.lua`

Expected: FAIL с `module 'vigit.confirm' not found`.

- [ ] **Step 3: реализовать helper**

```lua
local M = {}

function M.ask(prompt, callback)
  local choice = vim.fn.confirm(prompt, "&Yes\n&No", 2, "Question")
  if choice ~= 1 then
    return false
  end
  callback()
  return true
end

return M
```

- [ ] **Step 4: подтвердить GREEN**

Run: `lua tests/run.lua`

Expected: оба новых сценария PASS.

### Task 2: Git actions и comments

**Files:**
- Modify: `lua/vigit/actions.lua`
- Modify: `lua/vigit/review_ui.lua`
- Modify: `tests/actions_spec.lua`
- Modify: `tests/ui_regression_spec.lua`

**Interfaces:**
- Consumes: `require("vigit.confirm").ask(prompt, callback)`.

- [ ] **Step 1: перевести action-тесты на `vim.fn.confirm`**

Тесты проверяют `&Yes\n&No`, default `2`, точный prompt и отсутствие Git
операции при результате `2`.

- [ ] **Step 2: подтвердить RED**

Run: `lua tests/run.lua`

Expected: FAIL, потому что production code ещё вызывает `vim.ui.select`.

- [ ] **Step 3: заменить локальный `confirm_change`**

```lua
local confirm = require("vigit.confirm")

local function confirm_change(prompt, callback)
  confirm.ask(prompt, callback)
end
```

Удаление комментария вызывает тот же `confirm.ask()`.

- [ ] **Step 4: обновить headless untracked regression**

`tests/ui_regression_spec.lua` временно подменяет `vim.fn.confirm()` и
возвращает `1`.

- [ ] **Step 5: выполнить полный gate**

Run:

```text
lua tests/run.lua
nvim --headless -u NONE -l tests/ui_regression_spec.lua
luac -p lua/vigit/*.lua tests/*_spec.lua
git diff --check
```

Expected: все команды завершаются с exit code `0`.
