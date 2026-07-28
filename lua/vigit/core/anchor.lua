local M = {}

local function normalize_context(text)
  if type(text) ~= "string" then
    return nil
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
end

local function row_anchor(row)
  if type(row) ~= "table" then
    return nil
  end
  return row.source_anchor or row
end

local function same_file(candidate, target)
  if not candidate or not target or not target.path then
    return false
  end
  if candidate.path ~= target.path then
    return false
  end
  return target.section == nil or candidate.section == target.section
end

local function nearest(rows, target, predicate)
  if type(target.source_line) ~= "number" then
    return nil
  end

  local best
  local best_distance
  local best_side
  for index, row in ipairs(rows) do
    local candidate = row_anchor(row)
    if candidate
        and type(candidate.source_line) == "number"
        and predicate(candidate) then
      local distance = math.abs(candidate.source_line - target.source_line)
      local side = candidate.side == target.side and 0 or 1
      if best == nil
          or distance < best_distance
          or (distance == best_distance and side < best_side) then
        best = index
        best_distance = distance
        best_side = side
      end
    end
  end
  return best
end

local function logical_key(change_id, old_line, new_line)
  return string.format(
    "%s\0logical:%s:%s",
    change_id,
    old_line == nil and "-" or tostring(old_line),
    new_line == nil and "-" or tostring(new_line)
  )
end

local function logical_position(key, change_id)
  if type(key) ~= "string" then
    return nil
  end
  local prefix = change_id .. "\0logical:"
  if key:sub(1, #prefix) ~= prefix then
    return nil
  end
  local old_line, new_line = key:sub(#prefix + 1):match("^([^:]+):([^:]+)$")
  if not old_line then
    return nil
  end
  return {
    old_line = old_line == "-" and nil or tonumber(old_line),
    new_line = new_line == "-" and nil or tonumber(new_line),
  }
end

local function logical_distance(first, second)
  local distance
  for _, side in ipairs({ "old_line", "new_line" }) do
    if first[side] ~= nil and second[side] ~= nil then
      local side_distance = math.abs(first[side] - second[side])
      distance = distance and math.max(distance, side_distance) or side_distance
    end
  end
  return distance
end

function M.from_row(row_meta, column)
  row_meta = type(row_meta) == "table" and row_meta or {}
  local existing = row_anchor(row_meta) or {}
  local file = row_meta.file or existing.file or {}
  local kind = row_meta.kind
  local side = existing.side or row_meta.side
  if not side then
    if kind == "delete" and row_meta.old_line ~= nil then
      side = "old"
    elseif row_meta.new_line ~= nil then
      side = "new"
    elseif row_meta.old_line ~= nil then
      side = "old"
    end
  end

  local source_line = existing.source_line or row_meta.source_line
  if source_line == nil then
    source_line = side == "old" and row_meta.old_line or row_meta.new_line
  end

  local context = existing.context
  if context == nil
      and (kind == "add" or kind == "delete" or kind == "context") then
    context = row_meta.text
  end

  return {
    path = existing.path or row_meta.path or file.path,
    section = existing.section or row_meta.section or file.section,
    side = side,
    source_line = source_line,
    column = tonumber(column) or tonumber(existing.column) or 0,
    context = normalize_context(context),
    hunk_id = existing.hunk_id or row_meta.hunk_id,
  }
end

function M.logical_clusters(change, hunk, context_lines)
  local clusters = {}
  local current
  local context_since_change = 0
  local threshold = math.max(0, context_lines * 2)

  for index, line in ipairs(hunk.lines or {}) do
    if line.kind == "add" or line.kind == "delete" then
      if not current or context_since_change > threshold then
        current = {
          first_index = index,
          last_index = index,
          fingerprint_parts = {},
        }
        clusters[#clusters + 1] = current
      end
      current.last_index = index
      local context = normalize_context(line.text)
      if context ~= nil then
        current.fingerprint_parts[#current.fingerprint_parts + 1] =
          line.kind .. "\0" .. context
      end
      if line.old_line ~= nil and current.first_old == nil then
        current.first_old = line.old_line
      end
      if line.new_line ~= nil and current.first_new == nil then
        current.first_new = line.new_line
      end
      context_since_change = 0
    elseif line.kind == "context" and current then
      context_since_change = context_since_change + 1
    end
  end

  if #clusters == 0 then
    clusters[1] = {
      first_index = 1,
      last_index = math.max(1, #(hunk.lines or {})),
      first_old = hunk.old_start,
      first_new = hunk.new_start,
      fingerprint_parts = {},
    }
  end

  for _, cluster in ipairs(clusters) do
    if #cluster.fingerprint_parts > 0 then
      cluster.fingerprint = table.concat(cluster.fingerprint_parts, "\1")
    end
    cluster.fingerprint_parts = nil
    cluster.key = logical_key(
      change.id,
      cluster.first_old,
      cluster.first_new
    )
  end
  return clusters
end

function M.cluster_for_index(clusters, index)
  local best
  local best_distance
  for _, cluster in ipairs(clusters) do
    local distance
    if index < cluster.first_index then
      distance = cluster.first_index - index
    elseif index > cluster.last_index then
      distance = index - cluster.last_index
    else
      distance = 0
    end
    if best == nil or distance < best_distance then
      best = cluster
      best_distance = distance
    end
  end
  return best
end

function M.logical_keys(change, diff, context_lines)
  local keys = {}
  for _, logical_hunk in ipairs(
      M.logical_hunks(change, diff, context_lines)
  ) do
    keys[#keys + 1] = logical_hunk.key
  end
  return keys
end

function M.logical_hunks(change, diff, context_lines)
  local logical_hunks = {}
  local by_key = {}
  for _, hunk in ipairs(diff.hunks or {}) do
    for _, cluster in ipairs(M.logical_clusters(change, hunk, context_lines)) do
      local logical_hunk = by_key[cluster.key]
      if not logical_hunk then
        logical_hunk = {
          key = cluster.key,
          fingerprints = {},
        }
        logical_hunks[#logical_hunks + 1] = logical_hunk
        by_key[cluster.key] = logical_hunk
      end
      if cluster.fingerprint then
        logical_hunk.fingerprints[cluster.fingerprint] = true
      end
    end
  end
  return logical_hunks
end

local function logical_descriptors(items, change_id)
  local keys = {}
  local by_key = {}
  for _, item in ipairs(items or {}) do
    local descriptor = type(item) == "table" and item or { key = item }
    local key = descriptor.key
    if type(key) == "string" and logical_position(key, change_id) then
      if not by_key[key] then
        keys[#keys + 1] = key
        by_key[key] = descriptor
      end
    end
  end
  table.sort(keys)
  return keys, by_key
end

local function related_logical_hunks(first, second)
  if not first or not second then
    return false
  end
  for fingerprint in pairs(first.fingerprints or {}) do
    if second.fingerprints and second.fingerprints[fingerprint] then
      return true
    end
  end
  return false
end

function M.reconcile_logical_keys(
    active,
    change_id,
    available,
    previous,
    max_distance
)
  local result = {}
  local active_keys = {}
  local prefix = change_id .. "\0"
  for key, value in pairs(active or {}) do
    if value and type(key) == "string" and key:sub(1, #prefix) == prefix then
      active_keys[#active_keys + 1] = key
    elseif value then
      result[key] = true
    end
  end
  table.sort(active_keys)

  local available_keys, available_by_key =
    logical_descriptors(available, change_id)
  local _, previous_by_key = logical_descriptors(previous, change_id)
  local available_positions = {}
  local available_set = {}
  for _, key in ipairs(available_keys) do
    available_set[key] = true
    available_positions[key] = logical_position(key, change_id)
  end

  local used = {}
  local unmatched = {}
  for _, key in ipairs(active_keys) do
    if available_set[key] and not used[key] then
      result[key] = true
      used[key] = true
    else
      unmatched[#unmatched + 1] = key
    end
  end

  for _, key in ipairs(unmatched) do
    local replacement
    local position = logical_position(key, change_id)
    local best_distance
    if position then
      for _, candidate in ipairs(available_keys) do
        local distance = available_positions[candidate]
            and logical_distance(position, available_positions[candidate])
        if not used[candidate]
            and related_logical_hunks(
              previous_by_key[key],
              available_by_key[candidate]
            )
            and distance
            and distance <= max_distance
            and (best_distance == nil or distance < best_distance) then
          replacement = candidate
          best_distance = distance
        end
      end
    end
    if replacement then
      result[replacement] = true
      used[replacement] = true
    end
  end
  return result
end

function M.match(rows, source_anchor, opts)
  if type(rows) ~= "table" or type(source_anchor) ~= "table" then
    return nil
  end

  local target = M.from_row(source_anchor, source_anchor.column)
  local strict_side = opts and opts.strict_side == true
  if type(target.source_line) == "number" then
    for index, row in ipairs(rows) do
      local candidate = row_anchor(row)
      if same_file(candidate, target)
          and candidate.side == target.side
          and candidate.source_line == target.source_line then
        return index
      end
    end
  end

  local target_context = normalize_context(target.context)
  if target_context and target_context ~= "" then
    for index, row in ipairs(rows) do
      local candidate = row_anchor(row)
      if same_file(candidate, target)
          and (not strict_side or candidate.side == target.side)
          and normalize_context(candidate.context) == target_context then
        return index
      end
    end
  end

  if target.hunk_id then
    local hunk_row = nearest(rows, target, function(candidate)
      return same_file(candidate, target)
        and (not strict_side or candidate.side == target.side)
        and candidate.hunk_id == target.hunk_id
    end)
    if hunk_row then
      return hunk_row
    end
  end

  local file_row = nearest(rows, target, function(candidate)
    return same_file(candidate, target)
      and (not strict_side or candidate.side == target.side)
  end)
  if file_row then
    return file_row
  end

  for index, row in ipairs(rows) do
    local candidate = row_anchor(row)
    if same_file(candidate, target)
        and (not strict_side or candidate.side == target.side)
        and (row.kind == "file_header" or row.kind == "file")
        and candidate.source_line == nil then
      return index
    end
  end
  return nil
end

return M
