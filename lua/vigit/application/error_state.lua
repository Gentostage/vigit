local M = {}

function M.resolve(session)
  session.errors = session.errors or {}
  local errors = session.errors
  errors.diffs = errors.diffs or {}
  if errors.status then session.error = errors.status; return session.error end
  local selected = session.view and session.view.selected_change_id
  if selected and errors.diffs[selected] then session.error = errors.diffs[selected]; return session.error end
  local first
  for id in pairs(errors.diffs) do if not first or id < first then first = id end end
  if first then session.error = errors.diffs[first]
  elseif errors.comments then session.error = errors.comments
  elseif errors.mutation then session.error = errors.mutation
  elseif errors.handler then session.error = errors.handler
  else session.error = nil end
  return session.error
end

return M
