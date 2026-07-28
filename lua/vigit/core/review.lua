local Result = require("vigit.core.result")

local M = {}

local required_metadata = {
  "path",
  "line",
  "side",
  "section",
  "context",
}

local function invalid(code, message, details)
  return Result.err(code, message, details)
end

local function valid_relative_path(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true)
      or path:sub(1, 1) == "/" or path:match("^%a:[/\\]")
      or path:find("\\", 1, true) or path:find("//", 1, true) then
    return false
  end
  for component in path:gmatch("[^/]+") do
    if component == "." or component == ".." then
      return false
    end
  end
  return path:sub(-1) ~= "/"
end

local function escape_context(context)
  return context:gsub("\\", "\\\\"):gsub("\r", "\\r"):gsub("\n", "\\n")
end

local function unescape_context(context)
  local output = {}
  local index = 1
  while index <= #context do
    local char = context:sub(index, index)
    if char == "\\" then
      if index == #context then return nil, "trailing escape" end
      local escaped = context:sub(index + 1, index + 1)
      if escaped == "n" then
        output[#output + 1] = "\n"
      elseif escaped == "r" then
        output[#output + 1] = "\r"
      elseif escaped == "\\" then
        output[#output + 1] = escaped
      else
        return nil, "unknown escape \\" .. escaped
      end
      index = index + 2
    else
      output[#output + 1] = char
      index = index + 1
    end
  end
  return table.concat(output)
end

local function decimal_normalize(value)
  value = value:gsub("^0+", "")
  return value == "" and "0" or value
end

local function decimal_greater(left, right)
  left, right = decimal_normalize(left), decimal_normalize(right)
  return #left > #right or (#left == #right and left > right)
end

local function decimal_increment(value)
  local digits = { value:byte(1, #value) }
  local carry = 1
  for index = #digits, 1, -1 do
    local digit = digits[index] - string.byte("0") + carry
    if digit == 10 then
      digits[index] = string.byte("0")
    else
      digits[index] = string.byte("0") + digit
      carry = 0
      break
    end
  end
  if carry == 1 then table.insert(digits, 1, string.byte("1")) end
  return string.char((table.unpack or unpack)(digits))
end

local function comment_id_for_suffix(suffix)
  suffix = decimal_normalize(suffix)
  return "VIGIT-" .. string.rep("0", math.max(0, 3 - #suffix)) .. suffix
end

local function contains_reserved_line(value)
  for line in (value .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    if line == "### Ответ агента" or line:match("^## %[") then
      return true
    end
  end
  return false
end

local function trim_blank_edges(value)
  value = (value or ""):gsub("\r\n", "\n")
  value = value:gsub("^\n+", "")
  return value:gsub("\n+$", "")
end

local function parse_metadata(source)
  local metadata = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local key, value = line:match("^([a-z]+):[ \t]?(.*)$")
    if not key or metadata[key] ~= nil then
      return nil, invalid("malformed_metadata", "Comment anchor metadata is malformed", line)
    end
    metadata[key] = value
  end
  for _, key in ipairs(required_metadata) do
    if metadata[key] == nil or (key ~= "context" and metadata[key] == "") then
      return nil, invalid("malformed_metadata", "Comment anchor metadata is missing " .. key)
    end
  end
  if not valid_relative_path(metadata.path) then
    return nil, invalid("invalid_path", "Comment path must be repository-relative", metadata.path)
  end
  local line = tonumber(metadata.line)
  local column = metadata.column == nil and 0 or tonumber(metadata.column)
  if not line or line < 1 or line % 1 ~= 0 or not column or column < 0 or column % 1 ~= 0 then
    return nil, invalid("malformed_metadata", "Comment line or column is invalid")
  end
  if metadata.side ~= "old" and metadata.side ~= "new" then
    return nil, invalid("malformed_metadata", "Comment side is invalid", metadata.side)
  end
  if metadata.section ~= "staged" and metadata.section ~= "unstaged" then
    return nil, invalid("malformed_metadata", "Comment section is invalid", metadata.section)
  end
  local context, context_error = unescape_context(metadata.context)
  if not context then
    return nil, invalid("malformed_metadata", "Comment context escape is invalid", context_error)
  end
  return {
    path = metadata.path,
    line = line,
    column = column,
    side = metadata.side,
    section = metadata.section,
    context = context,
  }
end

local function parse_comment(raw)
  local line_end = raw:find("\n", 1, true)
  if not line_end then
    return nil, invalid("malformed_comment", "Comment header is incomplete")
  end
  local header = raw:sub(1, line_end - 1):gsub("\r$", "")
  local checked, id, path, line = header:match("^## %[(.)%] (VIGIT%-%d+) · (.+):(%d+)$")
  if (checked ~= " " and checked ~= "x") or not id or not id:match("^VIGIT%-%d%d%d+$") then
    return nil, invalid("malformed_comment", "Comment header is malformed", header)
  end
  if not valid_relative_path(path) then
    return nil, invalid("invalid_path", "Comment path must be repository-relative", path)
  end

  local metadata_start, marker_end = raw:find("<!%-%- vigit%-anchor\r?\n", line_end + 1)
  if not metadata_start or not raw:sub(line_end + 1, metadata_start - 1):match("^%s*$") then
    return nil, invalid("malformed_metadata", "Comment metadata must follow its header")
  end
  local metadata_end, metadata_close_end = raw:find("\r?\n%-%->\r?\n", marker_end + 1)
  if not metadata_end then
    return nil, invalid("malformed_metadata", "Comment metadata is not closed")
  end
  local metadata, metadata_error = parse_metadata(raw:sub(marker_end + 1, metadata_end - 1))
  if not metadata then
    return nil, metadata_error
  end
  if metadata.path ~= path or metadata.line ~= tonumber(line) then
    return nil, invalid("malformed_metadata", "Header and anchor path or line disagree")
  end

  local content = raw:sub(metadata_close_end + 1)
  local response_start, response_marker_end = content:find("\r?\n### Ответ агента\r?\n")
  local body, response = content, ""
  if response_start then
    body = content:sub(1, response_start - 1)
    response = content:sub(response_marker_end + 1)
  elseif content:match("^### Ответ агента\r?\n") then
    body = ""
    response = content:gsub("^### Ответ агента\r?\n", "")
  else
    return nil, invalid("malformed_comment", "Comment response delimiter is missing")
  end

  metadata.id = id
  metadata.done = checked == "x"
  metadata.body = trim_blank_edges(body)
  metadata.response = trim_blank_edges(response)
  return metadata
end

local function render_comment(comment)
  local lines = {
    string.format("## [%s] %s · %s:%d", comment.done and "x" or " ", comment.id, comment.path, comment.line),
    "",
    "<!-- vigit-anchor",
    "path: " .. comment.path,
    "line: " .. comment.line,
  }
  if comment.column and comment.column ~= 0 then
    lines[#lines + 1] = "column: " .. comment.column
  end
  lines[#lines + 1] = "side: " .. comment.side
  lines[#lines + 1] = "section: " .. comment.section
  lines[#lines + 1] = "context: " .. escape_context(comment.context)
  lines[#lines + 1] = "-->"
  lines[#lines + 1] = ""
  lines[#lines + 1] = trim_blank_edges(comment.body)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "### Ответ агента"
  lines[#lines + 1] = ""
  if trim_blank_edges(comment.response) ~= "" then
    lines[#lines + 1] = trim_blank_edges(comment.response)
  end
  return table.concat(lines, "\n") .. "\n"
end

local function rebuild_comments(document)
  document.comments = {}
  for _, block in ipairs(document.blocks) do
    if block.kind == "comment" then
      document.comments[#document.comments + 1] = block.value
    end
  end
end

local function copy_comment(comment)
  local copy = {}
  for key, value in pairs(comment) do copy[key] = value end
  return copy
end

local function copy_document(document)
  local copy = { blocks = {}, max_suffix = document.max_suffix }
  for index, block in ipairs(document.blocks) do
    copy.blocks[index] = {
      kind = block.kind,
      raw = block.raw,
      dirty = block.dirty,
      value = block.kind == "comment" and copy_comment(block.value) or nil,
    }
  end
  rebuild_comments(copy)
  return copy
end

local function validate_input(input)
  if type(input) ~= "table" or not valid_relative_path(input.path) then
    return nil, invalid("invalid_path", "Comment path must be repository-relative")
  end
  if type(input.line) ~= "number" or input.line < 1 or input.line % 1 ~= 0
      or (input.column ~= nil and (type(input.column) ~= "number" or input.column < 0 or input.column % 1 ~= 0))
      or (input.side ~= "old" and input.side ~= "new")
      or (input.section ~= "staged" and input.section ~= "unstaged")
      or type(input.context) ~= "string" or type(input.body) ~= "string" then
    return nil, invalid("invalid_comment", "New comment fields are invalid")
  end
  if input.context:find("\0", 1, true) then
    return nil, invalid("invalid_comment", "Comment context contains NUL")
  end
  if contains_reserved_line(input.body)
      or (input.response ~= nil and (type(input.response) ~= "string" or contains_reserved_line(input.response))) then
    return nil, invalid("invalid_comment", "Comment text contains a reserved delimiter")
  end
  return true
end

function M.parse(markdown)
  if type(markdown) ~= "string" then
    return invalid("invalid_document", "Review document must be a string")
  end
  local headers = {}
  local offset = 1
  while offset <= #markdown do
    local newline = markdown:find("\n", offset, true)
    local line_end = newline and newline - 1 or #markdown
    local line = markdown:sub(offset, line_end):gsub("\r$", "")
    if line:match("^## %[") then
      local checked, id = line:match("^## %[(.)%] (VIGIT%-%d+)")
      if not checked or not id then
        return invalid("malformed_comment", "Comment header is malformed", line)
      end
      headers[#headers + 1] = offset
    end
    if not newline then break end
    offset = newline + 1
  end

  local document = { blocks = {}, comments = {}, max_suffix = "0" }
  local cursor = 1
  local ids = {}
  for index, start_at in ipairs(headers) do
    if start_at > cursor then
      document.blocks[#document.blocks + 1] = { kind = "raw", raw = markdown:sub(cursor, start_at - 1) }
    end
    local finish_at = headers[index + 1] and headers[index + 1] - 1 or #markdown
    local raw = markdown:sub(start_at, finish_at)
    local value, parse_error = parse_comment(raw)
    if not value then return parse_error end
    if ids[value.id] then
      return invalid("duplicate_id", "Review comment IDs must be unique", value.id)
    end
    ids[value.id] = true
    local suffix = value.id:match("(%d+)$")
    if decimal_greater(suffix, document.max_suffix) then document.max_suffix = decimal_normalize(suffix) end
    document.blocks[#document.blocks + 1] = { kind = "comment", raw = raw, value = value, dirty = false }
    cursor = finish_at + 1
  end
  if cursor <= #markdown then
    document.blocks[#document.blocks + 1] = { kind = "raw", raw = markdown:sub(cursor) }
  end
  rebuild_comments(document)
  return Result.ok(document)
end

function M.serialize(document)
  local output = {}
  for _, block in ipairs(document.blocks or {}) do
    output[#output + 1] = block.kind == "comment" and block.dirty and render_comment(block.value) or block.raw
  end
  return table.concat(output)
end

function M.add(document, input)
  local valid, input_error = validate_input(input)
  if not valid then return input_error end
  local updated = copy_document(document)
  local comment = {
    id = comment_id_for_suffix(decimal_increment(updated.max_suffix)),
    done = input.done == true,
    path = input.path,
    line = input.line,
    column = input.column or 0,
    side = input.side,
    section = input.section,
    context = input.context,
    body = input.body,
    response = type(input.response) == "string" and input.response or "",
  }
  if #updated.blocks > 0 then
    updated.blocks[#updated.blocks + 1] = { kind = "raw", raw = "\n" }
  end
  updated.blocks[#updated.blocks + 1] = { kind = "comment", raw = "", value = comment, dirty = true }
  updated.max_suffix = decimal_increment(updated.max_suffix)
  updated.last_added = comment
  rebuild_comments(updated)
  return Result.ok(updated)
end

function M.update(document, id, changes)
  if type(changes) ~= "table" then
    return invalid("invalid_comment", "Comment changes must be a table")
  end
  local updated = copy_document(document)
  for _, block in ipairs(updated.blocks) do
    if block.kind == "comment" and block.value.id == id then
      for _, key in ipairs({ "body", "response", "context" }) do
        if changes[key] ~= nil then
          if type(changes[key]) ~= "string" or changes[key]:find("\0", 1, true)
              or ((key == "body" or key == "response") and contains_reserved_line(changes[key])) then
            return invalid("invalid_comment", "Comment " .. key .. " is invalid")
          end
          block.value[key] = changes[key]
        end
      end
      if changes.done ~= nil then
        if type(changes.done) ~= "boolean" then return invalid("invalid_comment", "Comment completion is invalid") end
        block.value.done = changes.done
      elseif changes.status ~= nil then
        if changes.status ~= "[ ]" and changes.status ~= "[x]" then return invalid("invalid_comment", "Comment status is invalid") end
        block.value.done = changes.status == "[x]"
      end
      block.dirty = true
      rebuild_comments(updated)
      return Result.ok(updated)
    end
  end
  return invalid("comment_not_found", "Review comment does not exist", id)
end

function M.delete(document, id)
  local updated = copy_document(document)
  for index, block in ipairs(updated.blocks) do
    if block.kind == "comment" and block.value.id == id then
      table.remove(updated.blocks, index)
      rebuild_comments(updated)
      return Result.ok(updated)
    end
  end
  return invalid("comment_not_found", "Review comment does not exist", id)
end

function M.prompt(document, root, relative_path)
  relative_path = relative_path or ".vigit/comments.md"
  local lines = {
    "Работай только с открытыми комментариями Vigit ниже.",
    "Worktree: " .. tostring(root),
    "Файл комментариев: " .. tostring(root) .. "/" .. tostring(relative_path),
    "Исправь код или ответь на вопрос в указанном worktree.",
    "Запиши краткий результат в `### Ответ агента` и поставь `[x]` только после завершения.",
    "Если работа заблокирована, comment остаётся `[ ]`, а причина пишется в response.",
    "Не меняй ID или anchor и не stage, commit или push.",
    "",
  }
  for _, comment in ipairs(document.comments or {}) do
    if not comment.done then
      lines[#lines + 1] = string.format("%s · %s:%d", comment.id, comment.path, comment.line)
      lines[#lines + 1] = comment.body
      lines[#lines + 1] = ""
    end
  end
  return table.concat(lines, "\n")
end

return M
