-- Minimal dependency-free test harness for headless Neovim.
local M = { passed = 0, failed = 0, failures = {}, current = nil }

function M.describe(name, fn)
  M.current = name
  fn()
end

function M.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = (M.current or "?") .. " > " .. name .. ": " .. tostring(err)
  end
end

function M.assert(cond, msg)
  if not cond then
    error(msg or "assertion failed", 2)
  end
end

function M.eq(a, b, msg)
  if a ~= b then
    error((msg or "eq") .. ": expected " .. vim.inspect(b) .. " got " .. vim.inspect(a), 2)
  end
end

function M.ne(a, b, msg)
  if a == b then
    error((msg or "ne") .. ": both " .. vim.inspect(a), 2)
  end
end

function M.summary()
  io.write(("\n%d passed, %d failed\n"):format(M.passed, M.failed))
  for _, f in ipairs(M.failures) do
    io.write("FAIL " .. f .. "\n")
  end
  io.stdout:flush()
  return M.failed
end

return M
