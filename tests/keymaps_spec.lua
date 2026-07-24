local keymaps = require("vigit.keymaps")
local help = require("vigit.help")

local function with_fake_vim(vim_api, fn)
  local old_vim = _G.vim
  _G.vim = vim_api
  local ok, err = pcall(fn)
  _G.vim = old_vim
  if not ok then
    error(err, 0)
  end
end

it("keeps described mappings grouped by context", function()
  local contexts = keymaps.contexts()
  assert_equal(contexts[1].id, "changes")
  assert_equal(contexts[2].id, "diff")

  local has_help = false
  for _, entry in ipairs(keymaps.entries("diff")) do
    assert_truthy(entry.desc)
    if entry.key == "?" and entry.action == "show_help" then
      has_help = true
    end
  end
  assert_equal(has_help, true)
end)

it("binds available handlers with descriptions and marks the buffer context", function()
  local mappings = {}
  local buffer_vars = setmetatable({}, {
    __index = function(items, key)
      local value = {}
      rawset(items, key, value)
      return value
    end,
  })

  with_fake_vim({
    b = buffer_vars,
    keymap = {
      set = function(mode, lhs, callback, opts)
        mappings[lhs] = {
          mode = mode,
          callback = callback,
          opts = opts,
        }
      end,
    },
  }, function()
    local edit = function() end
    local help = function() end
    keymaps.bind(12, "diff", {
      edit_file = edit,
      show_help = help,
    })

    assert_equal(buffer_vars[12].vigit_keymap_context, "diff")
    assert_equal(mappings.e.callback, edit)
    assert_equal(mappings.e.opts.buffer, 12)
    assert_truthy(mappings.e.opts.desc:match("Edit"))
    assert_equal(mappings["?"].callback, help)
    assert_truthy(mappings["?"].opts.desc:match("help"))
    assert_equal(mappings.q, nil)
  end)
end)

it("renders the current help context before the full keymap reference", function()
  local lines = help.lines("worktrees")
  assert_truthy(lines[1]:match("VIGIT KEYMAPS"))
  assert_truthy(lines[3]:match("CURRENT.*WORKTREES"))

  local delete_line = nil
  for _, line in ipairs(lines) do
    if line:match("Delete selected worktree") then
      delete_line = line
      break
    end
  end
  assert_truthy(delete_line)
end)

it("keeps Vigit buffer mappings in the central registry", function()
  for _, path in ipairs({
    "lua/vigit/ui.lua",
    "lua/vigit/worktree_picker.lua",
    "lua/vigit/review_ui.lua",
    "lua/vigit/review_editor.lua",
  }) do
    local handle = assert(io.open(path, "rb"))
    local content = handle:read("*a")
    handle:close()
    assert_equal(content:match("vim%.keymap%.set"), nil)
  end
end)
