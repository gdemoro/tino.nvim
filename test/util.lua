-- Filesystem fixtures for tests. All generated paths live under test/tmp/.
local M = {}

local uv = vim.uv or vim.loop
local this = debug.getinfo(1, "S").source:sub(2)
M.tmp = vim.fn.fnamemodify(this, ":p:h") .. "/tmp"

function M.realpath(path)
  return uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
end

function M.rmrf(path)
  local st = uv.fs_lstat(path)
  if not st then
    return
  end
  if st.type == "directory" then
    local fd = uv.fs_scandir(path)
    if fd then
      while true do
        local name = uv.fs_scandir_next(fd)
        if not name then
          break
        end
        M.rmrf(path .. "/" .. name)
      end
    end
    uv.fs_rmdir(path)
  else
    uv.fs_unlink(path)
  end
end

function M.mkdirp(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  local cur = path:sub(1, 1) == "/" and "" or "."
  for _, part in ipairs(parts) do
    cur = cur .. "/" .. part
    local st = uv.fs_stat(cur)
    if not st then
      uv.fs_mkdir(cur, 493)
    end
  end
end

function M.reset(name)
  local dir = M.tmp .. "/" .. name
  M.rmrf(dir)
  M.mkdirp(dir)
  return dir
end

function M.write(path, content)
  M.mkdirp(vim.fn.fnamemodify(path, ":h"))
  local fd = uv.fs_open(path, "w", 420)
  uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
  return path
end

function M.read(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local st = uv.fs_fstat(fd)
  local data = st.size > 0 and uv.fs_read(fd, st.size, 0) or ""
  uv.fs_close(fd)
  return data
end

return M
