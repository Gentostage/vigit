local function with_fake_vim(vim_api, fn)
  local old_vim = _G.vim
  _G.vim = vim_api
  local ok, err = pcall(fn)
  _G.vim = old_vim
  if not ok then
    error(err, 0)
  end
end

it("runs confirmation callback only for Yes", function()
  local called = false

  with_fake_vim({
    fn = {
      confirm = function(prompt, choices, default, kind)
        assert_equal(prompt, "Delete file?")
        assert_equal(choices, "&Yes\n&No")
        assert_equal(default, 2)
        assert_equal(kind, "Question")
        return 1
      end,
    },
  }, function()
    local confirm = require("vigit.confirm")
    local accepted = confirm.ask("Delete file?", function()
      called = true
    end)

    assert_equal(accepted, true)
    assert_equal(called, true)
  end)
end)

it("defaults confirmation to No", function()
  local called = false

  with_fake_vim({
    fn = {
      confirm = function(_, choices, default)
        assert_equal(choices, "&Yes\n&No")
        assert_equal(default, 2)
        return 2
      end,
    },
  }, function()
    local confirm = require("vigit.confirm")
    local accepted = confirm.ask("Delete file?", function()
      called = true
    end)

    assert_equal(accepted, false)
    assert_equal(called, false)
  end)
end)
