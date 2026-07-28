local Result = require("vigit.core.result")

local M = {}

local symbol_node_types = {
  class_declaration = "class",
  class_definition = "class",
  class_specifier = "class",
  function_declaration = "function",
  function_definition = "function",
  function_item = "function",
  function_statement = "function",
  local_function = "function",
  method_declaration = "method",
  method_definition = "method",
}

local function unavailable(message, details)
  return Result.err("parser_unavailable", message, details)
end

local function resolve_language(path)
  local ok_filetype, filetype = pcall(vim.filetype.match, {
    filename = path,
  })
  if not ok_filetype or not filetype then
    return nil, "Unable to detect a filetype for " .. tostring(path)
  end

  local ok_language, language = pcall(
    vim.treesitter.language.get_lang,
    filetype
  )
  if not ok_language then
    return nil, language
  end
  return language or filetype
end

local function capture_group(name, language)
  local group = tostring(name or "")
  if group:sub(1, 1) ~= "@" then
    group = "@" .. group
  end
  if group:sub(-#language - 1) ~= "." .. language then
    group = group .. "." .. language
  end
  return group
end

local function node_text(node, source)
  local ok, text = pcall(vim.treesitter.get_node_text, node, source)
  if not ok or type(text) ~= "string" then
    return nil
  end
  return vim.trim(text)
end

local function identifier_node(node)
  if not node then
    return nil
  end
  local node_type = node:type()
  if node_type:find("identifier", 1, true)
      or node_type == "name"
      or node_type == "property_name" then
    return node
  end

  for index = 0, node:named_child_count() - 1 do
    local found = identifier_node(node:named_child(index))
    if found then
      return found
    end
  end
end

local function symbol_name(node, source)
  for _, field_name in ipairs({ "name", "declarator" }) do
    local ok, field = pcall(node.field, node, field_name)
    local candidate = ok and field and identifier_node(field[1]) or nil
    local name = candidate and node_text(candidate, source) or nil
    if name and name ~= "" then
      return name
    end
  end

  local fallback = identifier_node(node)
  local name = fallback and node_text(fallback, source) or nil
  if name ~= "" then
    return name
  end
end

local function class_parent(symbols)
  for index = #symbols, 1, -1 do
    if symbols[index].kind == "class" then
      return symbols[index]
    end
  end
end

local function collect_symbols(root, source)
  local symbols = {}

  local function visit(node, parents)
    local kind = symbol_node_types[node:type()]
    local current_parents = parents
    if kind then
      local name = symbol_name(node, source)
      if name then
        local class = class_parent(parents)
        if kind == "function" and class then
          kind = "method"
        end
        local start_row, start_col, end_row, end_col = node:range()
        local label = name
        if kind == "function" or kind == "method" then
          label = (class and class.name .. "." or "") .. name .. "()"
        end
        local symbol = {
          kind = kind,
          name = name,
          label = label,
          start_row = start_row,
          start_col = start_col,
          end_row = end_row,
          end_col = end_col,
          declaration_row = start_row,
        }
        symbols[#symbols + 1] = symbol
        current_parents = {}
        for index, parent in ipairs(parents) do
          current_parents[index] = parent
        end
        current_parents[#current_parents + 1] = symbol
      end
    end

    for index = 0, node:named_child_count() - 1 do
      visit(node:named_child(index), current_parents)
    end
  end

  visit(root, {})
  table.sort(symbols, function(first, second)
    if first.start_row ~= second.start_row then
      return first.start_row < second.start_row
    end
    if first.end_row ~= second.end_row then
      return first.end_row > second.end_row
    end
    return first.label < second.label
  end)
  return symbols
end

local function collect_captures(query, root, source, language)
  local captures = {}
  local ordinal = 0
  for id, node, metadata in query:iter_captures(root, source, 0, -1) do
    ordinal = ordinal + 1
    local start_row, start_col, end_row, end_col = node:range()
    local capture_metadata = type(metadata) == "table"
        and type(metadata[id]) == "table"
        and metadata[id]
      or nil
    local priority_value = type(metadata) == "table"
        and (metadata.priority
          or capture_metadata and capture_metadata.priority)
      or nil
    local priority = tonumber(priority_value)
    if priority and priority % 1 ~= 0 then
      priority = nil
    end
    captures[#captures + 1] = {
      group = capture_group(query.captures[id], language),
      ordinal = ordinal,
      priority = priority,
      start_row = start_row,
      start_col = start_col,
      end_row = end_row,
      end_col = end_col,
    }
  end
  return captures
end

function M.inspect(opts)
  opts = opts or {}
  local source = opts.source
  if type(source) ~= "string" then
    return unavailable("Tree-sitter source must be a string")
  end

  local max_bytes = tonumber(opts.max_bytes)
  if max_bytes and #source > max_bytes then
    return Result.err(
      "source_too_large",
      "Source exceeds configured highlight byte limit"
    )
  end

  local language, language_error = resolve_language(opts.path)
  if not language then
    return unavailable("Tree-sitter language is unavailable", language_error)
  end

  local ok_parser, parser = pcall(
    vim.treesitter.get_string_parser,
    source,
    language
  )
  if not ok_parser then
    return unavailable("Tree-sitter parser is unavailable", parser)
  end

  local ok_tree, trees = pcall(parser.parse, parser)
  local tree = ok_tree and trees and trees[1] or nil
  if not tree then
    return unavailable("Tree-sitter parser did not return a syntax tree", trees)
  end

  local ok_query, query = pcall(vim.treesitter.query.get, language, "highlights")
  if not ok_query or not query then
    return unavailable("Tree-sitter highlight query is unavailable", query)
  end

  local ok_inspection, inspection = pcall(function()
    local root = tree:root()
    return {
      language = language,
      captures = collect_captures(query, root, source, language),
      symbols = collect_symbols(root, source),
    }
  end)
  if not ok_inspection then
    return unavailable("Tree-sitter inspection failed", inspection)
  end
  return Result.ok(inspection)
end

return M
