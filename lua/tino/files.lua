-- tino file discovery: roots-only recursive Markdown listing plus
-- buffer-aware reads. Uses libuv directly (no shell), never scans $HOME.

local M = {}

local uv = vim.uv or vim.loop

-- Expand only a literal leading "~/" (or a bare "~") using the process HOME
-- (vim.env.HOME). Deliberately performs no wildcard, glob, "%"/"#"
-- buffer-token or fnamemodify expansion, and never falls back to scanning any
-- other directory. Invalid/empty input or an unset HOME with "~" returns nil.
function M.normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if path == "~" then
    local home = vim.env.HOME
    if type(home) ~= "string" or home == "" then
      return nil
    end
    return home
  end
  local rest = path:match("^~/(.*)$")
  if rest then
    local home = vim.env.HOME
    if type(home) ~= "string" or home == "" then
      return nil
    end
    return home .. "/" .. rest
  end
  return path
end

local function absolute(path)
  if path:sub(1, 1) == "/" then
    return path
  end
  local cwd = uv.cwd() or vim.fn.getcwd()
  return cwd .. "/" .. path
end

function M.realpath(path)
  local p = M.normalize(path) or path
  return uv.fs_realpath(p) or absolute(p)
end

-- Physical identity of a path: normalized current realpath plus the device,
-- inode and type reported by the filesystem. Returns a table or nil when the
-- path cannot be stat'ed. Equal inode numbers on different devices are
-- deliberately kept distinct.
function M.identity(path)
  local real = M.realpath(path)
  local st = uv.fs_stat(real)
  if not st then
    return nil
  end
  return { real = real, dev = st.dev, ino = st.ino, type = st.type }
end

-- True when two identity tables refer to the same physical file: identical
-- resolved path, or identical device+inode+type (which also catches hard
-- links). A bare inode match on different devices is not the same file.
function M.same_identity(a, b)
  if not a or not b then
    return false
  end
  if a.real and b.real and a.real == b.real then
    return true
  end
  return a.dev ~= nil
    and b.dev ~= nil
    and a.dev == b.dev
    and a.ino ~= nil
    and b.ino ~= nil
    and a.ino == b.ino
    and a.type ~= nil
    and a.type == b.type
end

-- True when two paths refer to the same physical file.
function M.same_physical(a, b)
  return M.same_identity(M.identity(a), M.identity(b))
end

-- Depth-first listing of one root into `out`, recording `errors` rather than
-- silently returning a partial result. Directory symlinks are not followed.
local function scan_dir(root, out, errors, seen_dirs)
  local real = M.realpath(root)
  if seen_dirs[real] then
    return
  end
  seen_dirs[real] = true

  local fd = uv.fs_scandir(root)
  if not fd then
    errors[#errors + 1] = { path = root, message = "cannot read directory" }
    return
  end

  while true do
    local name, typ = uv.fs_scandir_next(fd)
    if not name then
      if typ then
        errors[#errors + 1] = { path = root, message = tostring(typ) }
      end
      break
    end
    local path = root .. "/" .. name
    if typ == "directory" then
      scan_dir(path, out, errors, seen_dirs)
    elseif typ == "link" then
      -- Follow a symlink only to a regular file; never recurse into a
      -- directory symlink (avoids cycles and escaping the configured root).
      local st = uv.fs_stat(path)
      if st and st.type == "file" and path:match("%.md$") then
        out[#out + 1] = path
      end
    elseif typ == "file" then
      if path:match("%.md$") then
        out[#out + 1] = path
      end
    end
  end
end

local function scan_root(root, out, errors, seen_dirs)
  local st = uv.fs_stat(root)
  if not st then
    errors[#errors + 1] = { path = root, message = "root does not exist" }
    return
  end
  if st.type == "file" then
    if root:match("%.md$") then
      out[#out + 1] = root
    end
  elseif st.type == "directory" then
    scan_dir(root, out, errors, seen_dirs)
  else
    errors[#errors + 1] = { path = root, message = "root is not a file or directory" }
  end
end

-- Collect .md files under the configured roots.
-- Returns sorted, realpath-normalized, physically de-duplicated file paths
-- plus a list of { path, message } errors. Regular files that share the same
-- physical identity (device+inode+type, or realpath) collapse to a single
-- deterministic representative: the lexicographically smallest normalized
-- path. A non-empty error list means the result is not a complete view of the
-- roots.
function M.collect(roots)
  local out, errors, seen_dirs = {}, {}, {}
  for _, root in ipairs(roots or {}) do
    local path = M.normalize(root)
    if path then
      scan_root(path, out, errors, seen_dirs)
    end
  end
  local seen, files = {}, {}
  for _, f in ipairs(out) do
    local real = M.realpath(f)
    if not seen[real] then
      seen[real] = true
      files[#files + 1] = real
    end
  end
  table.sort(files)
  -- Physical de-duplication. `files` is already sorted, so the first path seen
  -- for an identity key is the deterministic representative.
  local by_key, result = {}, {}
  for _, f in ipairs(files) do
    local id = M.identity(f)
    local key
    if id and id.dev ~= nil and id.ino ~= nil then
      key = id.dev .. ":" .. id.ino .. ":" .. tostring(id.type)
    else
      key = "path:" .. f
    end
    if not by_key[key] then
      by_key[key] = true
      result[#result + 1] = f
    end
  end
  return result, errors
end

-- Return the loaded buffer displaying `path`, if any (so unsaved modifications
-- are honored), matching by physical identity. Returns (buf) or (nil, reason).
-- When several loaded buffers resolve to the same physical file with divergent
-- contents, the lookup is ambiguous and refuses with a reason.
function M.buffer_for(path)
  local want = M.identity(path)
  local want_real = M.realpath(path)
  local matches = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        local same = want ~= nil and M.same_identity(M.identity(name), want)
        if not same and M.realpath(name) == want_real then
          same = true
        end
        if same then
          matches[#matches + 1] = b
        end
      end
    end
  end
  if #matches == 0 then
    return nil
  end
  if #matches == 1 then
    return matches[1]
  end
  local base = vim.api.nvim_buf_get_lines(matches[1], 0, -1, false)
  for i = 2, #matches do
    if not vim.deep_equal(base, vim.api.nvim_buf_get_lines(matches[i], 0, -1, false)) then
      return nil, "ambiguous: multiple loaded aliases with divergent contents"
    end
  end
  return matches[1]
end

-- Read a file as a list of lines. Prefers any loaded buffer contents (so
-- unsaved edits are honored). Returns lines or (nil, reason).
function M.read_lines(path)
  local buf, berr = M.buffer_for(path)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  if berr then
    return nil, berr
  end
  local fd, err = uv.fs_open(path, "r", 438)
  if not fd then
    return nil, "cannot open: " .. tostring(err)
  end
  local stat = uv.fs_fstat(fd)
  local size = stat and stat.size or 0
  local data = size > 0 and uv.fs_read(fd, size, 0) or ""
  uv.fs_close(fd)
  if type(data) ~= "string" then
    return nil, "cannot read"
  end
  local lines = vim.split(data, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

return M
