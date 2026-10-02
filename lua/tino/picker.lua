-- tino file picker: a thin, isolated UI adapter for choosing one existing
-- Markdown path. M.select_files is a pure UI helper: it performs no root
-- discovery, opens no buffers and owns no configuration; callers pass
-- already-validated candidate path strings. M.run is the small :TinoFiles
-- command handler built on it (discover configured roots, then open the
-- chosen file in the invoking window).
--
-- Prefers a Snacks file picker when a usable Snacks provider is present,
-- otherwise degrades to vim.ui.select with the same paths, options and
-- callback. The callback receives the chosen path string, or nil on cancel;
-- it is always invoked exactly once.

local M = {}
local files = require("tino.files")
local uv = vim.uv or vim.loop
local CREATE = "Create new file..."

-- True for a provider exposing the public Snacks picker API we rely on.
local function usable(provider)
  return type(provider) == "table"
    and type(provider.picker) == "table"
    and type(provider.picker.pick) == "function"
end

-- Resolve an optional Snacks provider. Checks the global first, then an
-- optional require. Never installs or configures Snacks and never depends on
-- AstroVim; a missing or unusable provider returns nil.
local function picker_provider()
  local g = rawget(_G, "Snacks")
  if usable(g) then
    return g
  end
  local ok, mod = pcall(require, "snacks")
  if ok and usable(mod) then
    return mod
  end
  return nil
end

-- Select one path from `paths` (precomputed Markdown choices).
-- `opts` is passed through to the underlying UI (prompt/title are derived from
-- opts.prompt). `on_choice(path_or_nil)` is called exactly once after the UI
-- has closed.
function M.select_files(paths, opts, on_choice)
  if type(on_choice) ~= "function" then
    return
  end
  opts = opts or {}
  paths = type(paths) == "table" and paths or {}
  local choices = paths
  if opts.create_new then
    choices = vim.list_extend(vim.deepcopy(paths), { CREATE })
  end

  local provider = picker_provider()
  local completed = false

  -- Snacks path: deliver a terminal value at most once, deferred so the picker
  -- UI has closed and the source window is restored before the caller mutates
  -- state. The vim.ui.select fallback below does not use this guard and never
  -- schedules: it hands the backend's callback straight to on_choice.
  local function finish(value)
    if completed then
      return
    end
    completed = true
    vim.schedule(function()
      on_choice(value)
    end)
  end

  if provider then
    local items = {}
    for _, path in ipairs(paths) do
      items[#items + 1] = { file = path, text = path }
    end
    local format = "file"
    if opts.create_new then
      items[#items + 1] = { text = CREATE, create = true }
      format = function(item, p)
        if item.create then
          return { { CREATE, "Special" } }
        end
        local formatter = provider.picker.format and provider.picker.format.file
        return formatter and formatter(item, p) or { { item.file } }
      end
    end
    local ok = pcall(provider.picker.pick, {
      items = items,
      format = format,
      preview = "file",
      title = opts.prompt or "Select file",
      actions = {
        confirm = function(picker, item)
          if completed or item == nil or (item.file == nil and not item.create) then
            return
          end
          -- Mark completed before closing so on_close does not also cancel.
          completed = true
          picker:close()
          vim.schedule(function()
            on_choice(item.create and CREATE or item.file)
          end)
        end,
      },
      on_close = function()
        finish(nil)
      end,
    })
    if ok then
      return
    end
    -- Picker construction failed before any completed selection: fall back
    -- to vim.ui.select without having delivered a callback.
    completed = false
  end

  -- vim.ui.select already invokes this callback after its own UI has closed,
  -- so deliver directly (no extra scheduling) to preserve the caller's
  -- synchronous contract.
  vim.ui.select(choices, opts, function(choice)
    on_choice(choice)
  end)
end

local function inside(path, root)
  return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

-- Resolve a new name against a real directory root, including existing parent
-- symlinks. Missing path components remain within that root; no files are written.
function M.new_path(root, name)
  if type(name) ~= "string" or name:find("[%z\r\n]") then
    return nil, "invalid relative path"
  end
  name = vim.trim(name):gsub("\\", "/")
  if name == "" or name:match("^/") or name:match("^%a:") then
    return nil, "expected a relative path inside the root"
  end
  local base = uv.fs_realpath(files.normalize(root) or "")
  local stat = base and uv.fs_stat(base)
  if not stat or stat.type ~= "directory" then
    return nil, "root is not an existing directory"
  end
  local parts = {}
  for part in name:gmatch("[^/]+") do
    if part == ".." then
      if #parts == 0 then
        return nil, "path escapes the configured root"
      end
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  if #parts == 0 then
    return nil, "expected a file name"
  end
  if not parts[#parts]:match("%.md$") then
    parts[#parts] = parts[#parts] .. ".md"
  end
  local path = base
  for i, part in ipairs(parts) do
    path = (path:sub(-1) == "/" and path or path .. "/") .. part
    if uv.fs_lstat(path) then
      local real = uv.fs_realpath(path)
      if not real or not inside(real, base) then
        return nil, "path escapes the configured root"
      end
      if i == #parts then
        return nil, "file already exists; choose it from the picker"
      end
      local parent = uv.fs_stat(real)
      if not parent or parent.type ~= "directory" then
        return nil, "parent is not a directory"
      end
      path = real
    end
  end
  return path
end

local function create_destination(roots, on_choice)
  local dirs, seen = {}, {}
  for _, root in ipairs(roots or {}) do
    local real = uv.fs_realpath(files.normalize(root) or "")
    local stat = real and uv.fs_stat(real)
    if stat and stat.type == "directory" and not seen[real] then
      dirs[#dirs + 1], seen[real] = real, true
    end
  end
  local function choose_name(root)
    if not root then
      return on_choice(nil)
    end
    if not seen[root] then
      vim.notify("tino: root was not offered by the picker", vim.log.levels.WARN)
      return on_choice(nil)
    end
    vim.ui.input({ prompt = "New Markdown file (relative path): " }, function(name)
      if name == nil then
        return on_choice(nil)
      end
      local path, err = M.new_path(root, name)
      if not path then
        vim.notify("tino: " .. err, vim.log.levels.WARN)
        return on_choice(nil)
      end
      -- Create only parent directories; the new Markdown file stays unsaved.
      local parent = vim.fn.fnamemodify(path, ":h")
      if not uv.fs_stat(parent) then
        local ok = pcall(vim.fn.mkdir, parent, "p")
        if not ok or not uv.fs_stat(parent) then
          vim.notify("tino: cannot create destination directory", vim.log.levels.WARN)
          return on_choice(nil)
        end
      end
      local buf, berr = files.buffer_for(path)
      if berr then
        vim.notify("tino: " .. berr, vim.log.levels.WARN)
        return on_choice(nil)
      end
      local ok
      if not buf then
        ok, buf = pcall(vim.fn.bufadd, path)
        if not ok or type(buf) ~= "number" or buf <= 0 then
          return on_choice(nil)
        end
        ok = pcall(vim.fn.bufload, buf)
        if not ok or not vim.api.nvim_buf_is_loaded(buf) then
          vim.notify("tino: cannot load new destination", vim.log.levels.WARN)
          return on_choice(nil)
        end
      end
      if M.new_path(root, name) ~= path
        or files.realpath(vim.api.nvim_buf_get_name(buf)) ~= path or uv.fs_lstat(path) then
        vim.notify("tino: new destination changed while opening", vim.log.levels.WARN)
        return on_choice(nil)
      end
      vim.bo[buf].buflisted = true
      on_choice(path, true)
    end)
  end
  if #dirs == 0 then
    vim.notify("tino: no directory roots configured", vim.log.levels.WARN)
    return on_choice(nil)
  elseif #dirs == 1 then
    choose_name(dirs[1])
  else
    vim.ui.select(dirs, { prompt = "Create file in root:" }, choose_name)
  end
end

-- Destination chooser for notes/capture/refile. Refile supplies its already
-- snapshotted paths; other callers reuse the normal Markdown discovery.
function M.select_destination(roots, opts, on_choice)
  opts = opts or {}
  local paths = opts.paths
  if not paths then
    local errors
    paths, errors = files.collect(roots)
    for _, err in ipairs(errors or {}) do
      vim.notify("tino: root " .. err.path .. ": " .. err.message, vim.log.levels.WARN)
    end
  end
  M.select_files(paths, { prompt = opts.prompt or "Destination:", create_new = true }, function(choice)
    if choice == CREATE then
      create_destination(roots, on_choice)
    else
      on_choice(choice, false)
    end
  end)
end

-- :TinoFiles handler. Discovers every .md file under the configured roots and
-- offers them via M.select_files; the chosen file is opened in the window the
-- command was invoked from, using native `:hide edit` so an unsaved source
-- buffer is preserved (hidden, never discarded or auto-saved) and no split is
-- created. Cancelling, an empty candidate list, or a vanished target window is
-- a safe no-op. Usable from any buffer and cursor location; it parses no task.
function M.run()
  local win = vim.api.nvim_get_current_win()
  local config = require("tino").config
  local paths, errors = require("tino.files").collect(config.roots)
  for _, e in ipairs(errors or {}) do
    vim.notify("tino: root " .. e.path .. ": " .. tostring(e.message), vim.log.levels.WARN)
  end
  if #paths == 0 then
    vim.notify("tino: no Markdown files under configured roots", vim.log.levels.WARN)
    return
  end
  M.select_files(paths, { prompt = "Open file:" }, function(choice)
    if not choice then
      return
    end
    if not vim.api.nvim_win_is_valid(win) then
      vim.notify("tino: original window is gone", vim.log.levels.WARN)
      return
    end
    vim.api.nvim_win_call(win, function()
      vim.cmd("hide edit " .. vim.fn.fnameescape(choice))
    end)
  end)
end

return M
