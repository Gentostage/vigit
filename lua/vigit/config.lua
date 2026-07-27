local Result = require("vigit.core.result")

local M = {}

local defaults = {
  ui = {
    changes_side = "right",
    changes_width = 32,
    changes_mode = "tree",
    context_lines = 3,
    max_diff_bytes = 2 * 1024 * 1024,
    max_highlight_bytes = 512 * 1024,
  },
  refresh = {
    on_write = true,
    on_tab_enter = true,
    debounce_ms = 120,
  },
  review = {
    path = ".vigit/comments.md",
  },
  handlers = {},
  keymaps = {},
}

local schema = {
  ui = {
    changes_side = "string",
    changes_width = "integer",
    changes_mode = "string",
    context_lines = "number",
    max_diff_bytes = "number",
    max_highlight_bytes = "number",
  },
  refresh = {
    on_write = "boolean",
    on_tab_enter = "boolean",
    debounce_ms = "number",
  },
  review = {
    path = "string",
  },
  handlers = {
    open_file = "handler",
    open_terminal = "handler",
    goto_definition = "handler",
  },
  keymaps = "table",
}

local function copy(value, seen)
  if type(value) ~= "table" then
    return value
  end

  seen = seen or {}
  if seen[value] then
    return seen[value]
  end

  local result = {}
  seen[value] = result
  for key, nested in pairs(value) do
    result[copy(key, seen)] = copy(nested, seen)
  end
  return result
end

local function invalid(path, expected)
  return Result.err("invalid_config", path .. " must be " .. expected)
end

local function merge_object(default_value, object_schema, user_value, path)
  if type(user_value) ~= "table" then
    return nil, invalid(path, "a table")
  end

  local result = copy(default_value)
  for key, value in pairs(user_value) do
    local field = object_schema[key]
    local field_path = path == "" and tostring(key) or path .. "." .. tostring(key)
    if field == nil then
      return nil, invalid(field_path, "a supported option")
    end

    if type(field) == "table" then
      local merged, error_result = merge_object(default_value[key] or {}, field, value, field_path)
      if error_result then
        return nil, error_result
      end
      result[key] = merged
    elseif field == "handler" then
      if value ~= false and type(value) ~= "function" then
        return nil, invalid(field_path, "a function or false")
      end
      result[key] = value
    elseif field == "integer" then
      if type(value) ~= "number" or value % 1 ~= 0 then
        return nil, invalid(field_path, "an integer")
      end
      result[key] = value
    elseif type(value) ~= field then
      return nil, invalid(field_path, field)
    else
      result[key] = copy(value)
    end
  end
  return result
end

local resolved = copy(defaults)

function M.resolve(user_opts)
  if user_opts == nil then
    return Result.ok(copy(defaults))
  end

  local value, error_result = merge_object(defaults, schema, user_opts, "")
  if error_result then
    return error_result
  end
  return Result.ok(value)
end

function M.setup(opts)
  local result = M.resolve(opts)
  if result.ok then
    resolved = copy(result.value)
  end
  return result
end

function M.get()
  return copy(resolved)
end

return M
