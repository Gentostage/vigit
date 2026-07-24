local function with_fake_vim(vim_api, fn)
  local old_vim = _G.vim
  _G.vim = vim_api
  local ok, err = pcall(fn)
  _G.vim = old_vim
  if not ok then
    error(err, 0)
  end
end

local function option_table()
  return setmetatable({}, {
    __index = function(items, key)
      local value = {}
      rawset(items, key, value)
      return value
    end,
  })
end

local function reset_review_ui()
  package.loaded["vigit.review_ui"] = nil
  package.loaded["vigit.review"] = nil
  package.loaded["vigit.keymaps"] = nil
  package.loaded["vigit.confirm"] = nil
  package.loaded["vigit.ui"] = nil
end

it("deletes a review comment through compact confirmation", function()
  reset_review_ui()
  local delete_handler = nil
  local deleted_id = nil
  local prompt = nil
  local comments_calls = 0
  package.loaded["vigit.review"] = {
    comments = function()
      comments_calls = comments_calls + 1
      if comments_calls == 1 then
        return {
          {
            id = "VIGIT-001",
            file = "a.lua",
            line = 4,
            comment = "Fix this",
          },
        }, nil
      end
      return {}, nil
    end,
    delete = function(_, id)
      deleted_id = id
      return true, nil
    end,
  }
  package.loaded["vigit.keymaps"] = {
    bind = function(_, context, handlers)
      assert_equal(context, "comments")
      delete_handler = handlers.delete
    end,
  }
  package.loaded["vigit.ui"] = {
    render = function() end,
  }

  local ok, err = pcall(function()
    with_fake_vim({
      o = { columns = 120, lines = 40, cmdheight = 1 },
      bo = option_table(),
      wo = option_table(),
      fn = {
        confirm = function(actual_prompt, choices, default)
          prompt = actual_prompt
          assert_equal(choices, "&Yes\n&No")
          assert_equal(default, 2)
          return 1
        end,
      },
      log = { levels = { ERROR = 4, INFO = 2, WARN = 3 } },
      notify = function() end,
      api = {
        nvim_create_buf = function() return 1 end,
        nvim_open_win = function() return 2 end,
        nvim_buf_set_lines = function() end,
        nvim_win_set_cursor = function() end,
        nvim_win_get_cursor = function() return { 3, 0 } end,
        nvim_win_is_valid = function() return true end,
        nvim_win_close = function() end,
      },
    }, function()
      local panel = require("vigit.review_ui").open({
        root = "/repo",
        worktree_name = "demo",
        state = {},
      })
      assert_truthy(panel)
      assert_truthy(delete_handler)
      delete_handler()
    end)
  end)
  reset_review_ui()
  if not ok then
    error(err, 0)
  end

  assert_equal(prompt, "Delete VIGIT-001?")
  assert_equal(deleted_id, "VIGIT-001")
  assert_equal(comments_calls, 2)
end)
