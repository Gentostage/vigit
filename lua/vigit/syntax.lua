local M = {}

local MAX_FILE_BYTES = 1024 * 1024
local cache = {}

local function absolute_path(root, path)
  return vim.fn.fnamemodify(vim.fs.joinpath(root, path), ":p")
end

local function signature(stat)
  local mtime = stat.mtime or {}
  return table.concat({
    tostring(stat.size or 0),
    tostring(mtime.sec or 0),
    tostring(mtime.nsec or 0),
  }, ":")
end

local function read_source(path, stat)
  if not stat or stat.type ~= "file" or (stat.size or 0) > MAX_FILE_BYTES then
    return nil
  end
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local source = handle:read("*a")
  handle:close()
  if source:find("\0", 1, true) then
    return nil
  end
  return source
end

local function language_for(path)
  local ok, filetype = pcall(vim.filetype.match, { filename = path })
  if not ok or not filetype or filetype == "" then
    return nil
  end
  return vim.treesitter.language.get_lang(filetype) or filetype
end

local function parser_and_query(source, language)
  local loaded = vim.treesitter.language.add(language)
  if not loaded then
    return nil, nil
  end
  local query = vim.treesitter.query.get(language, "highlights")
  if not query then
    return nil, nil
  end
  local parser = vim.treesitter.get_string_parser(source, language)
  local trees = parser:parse()
  return trees and trees[1] or nil, query
end

local function add_capture(captures, source_lines, group, range)
  local start_row, start_col = range[1], range[2]
  local end_row, end_col
  if #range >= 6 then
    end_row, end_col = range[4], range[5]
  else
    end_row, end_col = range[3], range[4]
  end
  local last_row = end_row
  if end_row > start_row and end_col == 0 then
    last_row = end_row - 1
  end
  for source_row = start_row, last_row do
    local line = source_lines[source_row + 1] or ""
    local segment_start = source_row == start_row and start_col or 0
    local segment_end = source_row == end_row and end_col or #line
    if segment_end > segment_start then
      captures[source_row + 1] = captures[source_row + 1] or {}
      captures[source_row + 1][#captures[source_row + 1] + 1] = {
        start_col = segment_start,
        end_col = segment_end,
        group = group,
      }
    end
  end
end

local function collect_captures(source, source_lines, language, tree, query)
  local captures = {}
  local root = tree:root()
  for id, node, metadata in query:iter_captures(root, source, 0, -1) do
    local name = query.captures[id]
    if name
      and name ~= "conceal"
      and name ~= "spell"
      and name:sub(1, 1) ~= "_"
    then
      local range = vim.treesitter.get_range(node, source, metadata and metadata[id])
      add_capture(captures, source_lines, "@" .. name .. "." .. language, range)
    end
  end
  return captures
end

local function symbol_kind(node_type)
  if node_type:find("class", 1, true) then
    return "class"
  end
  if node_type:find("function", 1, true) or node_type:find("method", 1, true) then
    return "function"
  end
  return nil
end

local function symbol_name(node, source)
  local names = node:field("name")
  local name_node = names and names[1] or nil
  if not name_node then
    return nil
  end
  local name = vim.trim(vim.treesitter.get_node_text(name_node, source) or "")
  return name ~= "" and name or nil
end

local function context_at(data, target_line)
  local source_row = math.max(math.min((tonumber(target_line) or 1) - 1, #data.lines - 1), 0)
  local line = data.lines[source_row + 1] or ""
  local first_nonblank = line:find("%S") or 1
  local node = data.root:named_descendant_for_range(
    source_row,
    first_nonblank - 1,
    source_row,
    math.max(#line, first_nonblank)
  )
  local symbols = {}
  while node do
    local kind = symbol_kind(node:type())
    if kind then
      local name = symbol_name(node, data.source)
      if name then
        table.insert(symbols, 1, name .. (kind == "function" and "()" or ""))
      end
    end
    node = node:parent()
  end
  return #symbols > 0 and table.concat(symbols, ".") or nil
end

local function load_file(root, path)
  local absolute = absolute_path(root, path)
  local stat = vim.uv.fs_stat(absolute)
  if not stat then
    cache[absolute] = nil
    return nil
  end
  local current_signature = signature(stat)
  local cached = cache[absolute]
  if cached and cached.signature == current_signature then
    return cached.data
  end

  local source = read_source(absolute, stat)
  local language = source and language_for(absolute) or nil
  if not source or not language then
    cache[absolute] = { signature = current_signature, data = nil }
    return nil
  end
  local ok, tree, query = pcall(function()
    local parsed_tree, parsed_query = parser_and_query(source, language)
    return parsed_tree, parsed_query
  end)
  if not ok or not tree or not query then
    return nil
  end

  local lines = vim.split(source, "\n", { plain = true })
  local data = {
    source = source,
    lines = lines,
    language = language,
    tree = tree,
    root = tree:root(),
    captures = collect_captures(source, lines, language, tree, query),
  }
  data.context_at = function(target_line)
    return context_at(data, target_line)
  end
  cache[absolute] = { signature = current_signature, data = data }
  return data
end

function M.decorate(opts)
  local handled_rows = {}
  local files = {}
  for row, line in ipairs(opts.lines or {}) do
    local meta = opts.diff_map and opts.diff_map[row] or nil
    local file = meta and meta.file or nil
    if file and file.path then
      local key = tostring(file.section) .. ":" .. file.path
      if files[key] == nil then
        files[key] = load_file(opts.root, file.path) or false
      end
      local data = files[key] or nil
      if data and meta.kind == "gap" then
        local context = data.context_at(meta.target_line)
        if context and opts.add_gap_context then
          opts.add_gap_context(opts.buf, row, context)
        end
      elseif data and not meta.kind then
        local target_line = tonumber(meta.target_line)
        if target_line and data.lines[target_line] == line then
          handled_rows[row] = true
          for _, capture in ipairs(data.captures[target_line] or {}) do
            opts.add_token(
              opts.buf,
              row,
              0,
              capture.start_col + 1,
              capture.end_col,
              capture.group
            )
          end
        end
      end
    end
  end
  return handled_rows
end

return M
