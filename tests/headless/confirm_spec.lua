local function with_confirm(answer, fn)
  local original_confirm = vim.fn.confirm
  local calls = {}
  vim.fn.confirm = function(...)
    calls[#calls + 1] = { ... }
    return answer
  end

  local ok, err = pcall(fn, calls)
  vim.fn.confirm = original_confirm
  if not ok then
    error(err, 0)
  end
end

it("передаёт y/N confirmation callback without executing an action", function()
  local callback_answers = {}

  with_confirm(1, function(calls)
    local confirm = require("vigit.ui.confirm")
    local accepted = confirm.ask("Discard changes?", function(answer)
      callback_answers[#callback_answers + 1] = answer
    end)

    assert_equal(accepted, true)
    assert_equal(#calls, 1)
    assert_equal(calls[1][1], "Discard changes?")
    assert_equal(calls[1][2], "&Yes\n&No")
    assert_equal(calls[1][3], 2)
  end)

  assert_equal(callback_answers[1], true)
  assert_equal(#callback_answers, 1)
end)

it("считает default, empty и Esc ответом No", function()
  for _, answer in ipairs({ 0, 2 }) do
    local callback_answers = {}

    with_confirm(answer, function()
      local confirm = require("vigit.ui.confirm")
      local accepted = confirm.ask("Discard changes?", function(value)
        callback_answers[#callback_answers + 1] = value
      end)

      assert_equal(accepted, false)
    end)

    assert_equal(callback_answers[1], false)
    assert_equal(#callback_answers, 1)
  end

  local callback_answers = {}
  with_confirm(nil, function()
    local confirm = require("vigit.ui.confirm")
    local accepted = confirm.ask("Discard changes?", function(value)
      callback_answers[#callback_answers + 1] = value
    end)

    assert_equal(accepted, false)
  end)

  assert_equal(callback_answers[1], false)
  assert_equal(#callback_answers, 1)
end)
