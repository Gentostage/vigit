local M = {}

function M.ok(value)
  return { ok = true, value = value }
end

function M.err(code, message, details, retryable)
  return {
    ok = false,
    error = {
      code = assert(code),
      message = assert(message),
      details = details,
      retryable = retryable == true,
    },
  }
end

function M.is(value)
  return type(value) == "table" and type(value.ok) == "boolean"
end

function M.map(result, fn)
  if not result.ok then
    return result
  end
  return M.ok(fn(result.value))
end

return M
