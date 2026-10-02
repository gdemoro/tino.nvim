-- tino refile: structural, Tree-sitter-verified move of one top-level task
-- item (including all of its nested content) to another Markdown file.
--
-- Refiling is the only operation that requires a Tree-sitter Markdown parser.
-- We locate the *direct* task-list marker of a list_item that exactly matches
-- the parsed row/checkbox span, refuse nested or block-quoted sources, and move
-- whole original lines without re-formatting them. The destination must be a
-- safe Markdown context: the appended task is only accepted if it re-parses as
-- a top-level task. No disk writes happen here; the user saves with :write.

local parser = require("tino.parser")
local files = require("tino.files")
local picker = require("tino.picker")
local M = {}

local uv = vim.uv or vim.loop

local function notify(msg, level)
  vim.notify("tino: " .. msg, level or vim.log.levels.INFO)
end

local function editable(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return vim.bo[bufnr].modifiable and not vim.bo[bufnr].readonly
end

local function lines_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- The loaded buffer displaying `path`, if any, matched by physical identity.
-- Unloaded buffers are ignored (they carry no in-memory content). Returns
-- (buf) or (nil, reason) when the lookup is ambiguous.
local function loaded_buf_for(path)
  return files.buffer_for(path)
end

-- Full source-buffer snapshot: identity, tick, complete contents and
-- editability. Used to revalidate the source inside commit after all
-- autocmd-producing work (destination loading) has happened.
function M.snapshot_source(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local real = name ~= "" and files.realpath(name) or nil
  local st = real and uv.fs_stat(real) or nil
  return {
    buf = bufnr,
    name = name,
    real = real,
    dev = st and st.dev or nil,
    ino = st and st.ino or nil,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    modifiable = vim.bo[bufnr].modifiable,
    readonly = vim.bo[bufnr].readonly,
  }
end

-- Snapshot one destination candidate *before* any selection. Loaded buffers are
-- identified by id/name/tick/contents (never preloaded); unloaded candidates
-- are identified by their on-disk identity and contents. Returns (snap) or
-- (nil, reason).
function M.snapshot_dest(path)
  local real = files.realpath(path)
  local snap = { path = path, real = real }
  local st = uv.fs_stat(real)
  if st then
    snap.dev = st.dev
    snap.ino = st.ino
  end
  local b, berr = loaded_buf_for(real)
  if berr then
    return nil, berr
  end
  if b then
    snap.loaded = true
    snap.buf = b
    snap.name = vim.api.nvim_buf_get_name(b)
    snap.tick = vim.api.nvim_buf_get_changedtick(b)
    snap.lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    snap.modifiable = vim.bo[b].modifiable
    snap.readonly = vim.bo[b].readonly
    return snap
  end
  snap.loaded = false
  if not st then
    return nil, "destination does not exist"
  end
  if st.type ~= "file" then
    return nil, "destination is not a regular file"
  end
  local lines, err = files.read_lines(real)
  if not lines then
    return nil, err
  end
  snap.lines = lines
  return snap
end

-- Snapshot a list of destination candidate paths, keyed by the exact choice
-- string that will be offered to the user before selection. Candidates that
-- cannot be snapshotted are omitted and returned in `skipped` as
-- { path, message }.
function M.snapshot_dests(paths)
  local out, skipped = {}, {}
  for _, p in ipairs(paths or {}) do
    local s, err = M.snapshot_dest(p)
    if s then
      out[p] = s
    else
      skipped[#skipped + 1] = { path = p, message = err }
    end
  end
  return out, skipped
end

local function children(node)
  local out = {}
  local i = 0
  local c = node:child(0)
  while c do
    out[#out + 1] = c
    i = i + 1
    c = node:child(i)
  end
  return out
end

-- Parse a buffer with the real Markdown Tree-sitter parser. Returns the root
-- node or (nil, reason).
local function markdown_root(bufnr)
  local ok, p = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if not ok or not p then
    return nil, "markdown parser unavailable"
  end
  local ok2, trees = pcall(function()
    return p:parse()
  end)
  if not ok2 or not trees or not trees[1] then
    return nil, "markdown parse failed"
  end
  return trees[1]:root(), nil
end

-- Find the list_item that owns a DIRECT task-list marker whose range exactly
-- equals the parser-derived row and checkbox byte span.
local function find_marker(root, row, cb_s, cb_e)
  local found
  local function visit(node)
    if found then
      return
    end
    if node:type() == "list_item" then
      for _, c in ipairs(children(node)) do
        local t = c:type()
        if t == "task_list_marker_unchecked" or t == "task_list_marker_checked" then
          local sr, sc, er, ec = c:range()
          if sr == row and sc == cb_s and er == row and ec == cb_e then
            found = c
            return
          end
        end
      end
    end
    for _, c in ipairs(children(node)) do
      visit(c)
    end
  end
  visit(root)
  return found
end

-- Nearest ancestor list_item of a marker node.
local function owning_item(marker)
  local n = marker
  while n do
    if n:type() == "list_item" then
      return n
    end
    n = n:parent()
  end
  return nil
end

-- Refuse a source whose item is nested in another list_item or a block_quote.
local function unsafe_ancestor(item)
  local p = item:parent()
  while p do
    local t = p:type()
    if t == "list_item" or t == "block_quote" then
      return t
    end
    p = p:parent()
  end
  return nil
end

-- Refuse ERROR/MISSING nodes and any unclosed fenced code block inside a
-- subtree (unclosed fences produce no ERROR but only one delimiter).
local function subtree_unsafe(root)
  local bad
  local function visit(n)
    if bad then
      return
    end
    if n:type() == "ERROR" or n:missing() then
      bad = "parse error in task content"
      return
    end
    if n:type() == "fenced_code_block" then
      local count = 0
      for _, c in ipairs(children(n)) do
        if c:type() == "fenced_code_block_delimiter" then
          count = count + 1
        end
      end
      if count ~= 2 then
        bad = "unterminated fenced code block in task content"
        return
      end
    end
    for _, c in ipairs(children(n)) do
      visit(c)
    end
  end
  visit(root)
  return bad
end

-- True when some non-descendant node starts exactly at (er, ec). Used to prove
-- that a mid-line node end is a real block boundary.
local function node_starts_at(node, er, ec)
  local cur = node
  local p = node:parent()
  while p do
    for _, c in ipairs(children(p)) do
      if c ~= cur then
        local sr, sc = c:range()
        if sr == er and sc == ec then
          return true
        end
      end
    end
    cur = p
    p = p:parent()
  end
  return false
end

-- Convert a node's exclusive range into an inclusive whole-line interval
-- [first, last], or (nil, reason) when the boundary is ambiguous.
local function interval_from_node(node, lines)
  local sr, _, er, ec = node:range()
  local er_line = lines[er + 1] or ""
  local len = #er_line
  if ec == 0 then
    return sr, er - 1
  end
  if ec == len then
    return sr, er
  end
  if ec > 0 and ec < len then
    if er_line:sub(1, ec):match("^[ \t]*$") and node_starts_at(node, er, ec) then
      -- The node range ends mid-line, with only leading horizontal whitespace
      -- before a following, non-owned sibling node. Line `er` therefore belongs
      -- to that sibling, not to this task: keep only the lines strictly before
      -- it. Never include `er` itself.
      if er - 1 < sr then
        return nil, "ambiguous partial-row boundary"
      end
      return sr, er - 1
    end
    return nil, "ambiguous partial-row boundary"
  end
  return nil, "invalid task range"
end

-- Locate the movable line interval for a task on `row` given its checkbox
-- span. Returns (item, first, last) or (nil, reason). `lines` are the buffer
-- lines (needed to resolve end-of-line ranges).
function M.locate(bufnr, lines, row, cb_s, cb_e)
  local root, err = markdown_root(bufnr)
  if not root then
    return nil, err
  end
  local marker = find_marker(root, row, cb_s, cb_e)
  if not marker then
    return nil, "could not locate task structure (stale or non-canonical line)"
  end
  local item = owning_item(marker)
  local anc = unsafe_ancestor(item)
  if anc then
    return nil, "refusing " .. (anc == "block_quote" and "block-quoted" or "nested") .. " source task"
  end
  local bad = subtree_unsafe(item)
  if bad then
    return nil, bad
  end
  local first, last, rerr = interval_from_node(item, lines)
  if not first then
    return nil, rerr
  end
  -- Descendant containment: no descendant may hold content past the interval
  -- end. The item's own range end is the boundary itself (it may land on the
  -- excluded sibling line and is not evidence of lost content), so it is not
  -- checked directly; every descendant still is.
  local function contained(n, is_root)
    if not is_root then
      local _, _, er, ec = n:range()
      if er > last + 1 or (er == last + 1 and ec ~= 0) then
        return false
      end
    end
    for _, c in ipairs(children(n)) do
      if not contained(c, false) then
        return false
      end
    end
    return true
  end
  if not contained(item, true) then
    return nil, "task content exceeds computed line range"
  end
  return item, first, last
end

-- Verify that appending `moved` to `dest_lines` yields a top-level task. Returns
-- (true) or (false, reason).
function M.dest_safe(dest_lines, moved)
  if #moved == 0 then
    return false, "empty task content"
  end
  local task = parser.parse(moved[1])
  if not task then
    return false, "moved first line is not a task"
  end
  local cand = {}
  for _, l in ipairs(dest_lines) do
    cand[#cand + 1] = l
  end
  local base = #cand
  for _, l in ipairs(moved) do
    cand[#cand + 1] = l
  end
  -- Protect scratch creation, parsing and cleanup: any failure means the
  -- destination context is not proven safe.
  local ok, res, reason = pcall(function()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, cand)
    local item, first, last = M.locate(scratch, cand, base, task.spans.checkbox[1], task.spans.checkbox[2])
    vim.api.nvim_buf_delete(scratch, { force = true })
    if not item then
      return false, "destination context would not contain a top-level task"
    end
    if first ~= base or last < base then
      return false, "destination context would absorb the task"
    end
    return true
  end)
  if not ok then
    return false, "destination parse error: " .. tostring(res)
  end
  return res, reason
end

-- Move source lines [first, last] into `destbuf`. On failure of either edit,
-- restore the exact full pre-edit contents and dirty flags of both buffers;
-- report any refused restoration explicitly.
local function perform_move(srcbuf, destbuf, first, last, src_lines, dest_lines)
  local moved = vim.api.nvim_buf_get_lines(srcbuf, first, last + 1, false)
  local dest_n = #dest_lines
  local src_modified, dest_modified = vim.bo[srcbuf].modified, vim.bo[destbuf].modified
  local failed_buffer = "source"
  local ok, err = pcall(vim.api.nvim_buf_set_lines, srcbuf, first, last + 1, false, {})
  if ok then
    failed_buffer = "destination"
    ok, err = pcall(vim.api.nvim_buf_set_lines, destbuf, dest_n, dest_n, false, moved)
  end
  if not ok then
    -- Even a failed source call can have modified either buffer before raising.
    local rb_src = pcall(function()
      vim.api.nvim_buf_set_lines(srcbuf, 0, -1, false, src_lines)
      vim.bo[srcbuf].modified = src_modified
    end)
    local rb_dst = pcall(function()
      vim.api.nvim_buf_set_lines(destbuf, 0, -1, false, dest_lines)
      vim.bo[destbuf].modified = dest_modified
    end)
    if rb_src and rb_dst then
      return false, failed_buffer .. " edit failed (both buffers restored): " .. tostring(err)
    end
    local parts = {}
    if not rb_src then
      parts[#parts + 1] = "source"
    end
    if not rb_dst then
      parts[#parts + 1] = "destination"
    end
    return false, failed_buffer .. " edit failed; ROLLBACK FAILED for "
      .. table.concat(parts, " and ") .. ": " .. tostring(err)
  end
  return true
end

-- Revalidate the source buffer against its snapshot. Returns (true) or
-- (false, reason).
local function validate_source(srcbuf, snap)
  if not vim.api.nvim_buf_is_valid(srcbuf) then
    return false, "source buffer no longer valid"
  end
  if not vim.api.nvim_buf_is_loaded(srcbuf) then
    return false, "source buffer no longer loaded"
  end
  if snap.buf and srcbuf ~= snap.buf then
    return false, "source buffer replaced since selection"
  end
  local name = vim.api.nvim_buf_get_name(srcbuf)
  if snap.name and snap.name ~= "" and name ~= snap.name then
    return false, "source renamed since selection"
  end
  if snap.real then
    -- Compare the *current* resolution of the buffer name against the original
    -- resolved path: this detects a symlink that was retargeted since the
    -- snapshot.
    local cur_real = name ~= "" and files.realpath(name) or nil
    if cur_real ~= snap.real then
      return false, "source path retargeted since selection"
    end
    local st = uv.fs_stat(snap.real)
    if not st then
      return false, "source file was replaced since selection"
    end
    if snap.dev ~= nil and st.dev ~= snap.dev then
      return false, "source file was replaced since selection"
    end
    if snap.ino ~= nil and st.ino ~= snap.ino then
      return false, "source file was replaced since selection"
    end
  end
  if snap.modifiable ~= nil and vim.bo[srcbuf].modifiable ~= snap.modifiable then
    return false, "source modifiable/readonly changed since selection"
  end
  if snap.readonly ~= nil and vim.bo[srcbuf].readonly ~= snap.readonly then
    return false, "source modifiable/readonly changed since selection"
  end
  if snap.tick ~= nil and vim.api.nvim_buf_get_changedtick(srcbuf) ~= snap.tick then
    return false, "source changed since selection"
  end
  if not lines_equal(vim.api.nvim_buf_get_lines(srcbuf, 0, -1, false), snap.lines) then
    return false, "source content changed since selection"
  end
  if not editable(srcbuf) then
    return false, "source buffer is not modifiable"
  end
  return true
end

-- Revalidate the loaded destination buffer against its snapshot and prove it is
-- physically distinct from the source. Returns (true) or (false, reason).
local function validate_dest(destbuf, destpath, dsnap, src_real)
  if not vim.api.nvim_buf_is_valid(destbuf) then
    return false, "destination buffer no longer valid"
  end
  if not vim.api.nvim_buf_is_loaded(destbuf) then
    return false, "destination buffer no longer loaded"
  end
  if files.same_physical(destpath, src_real) then
    return false, "destination is the source (or an alias of it)"
  end
  if not dsnap then
    return false, "missing destination snapshot"
  end
  local real = files.realpath(destpath)
  if dsnap.real and real ~= dsnap.real then
    return false, "destination changed since selection"
  end
  local bname = vim.api.nvim_buf_get_name(destbuf)
  local bufreal = bname ~= "" and files.realpath(bname) or nil
  if dsnap.real and bufreal and bufreal ~= dsnap.real then
    return false, "destination renamed since selection"
  end
  local st = uv.fs_stat(real)
  if not st then
    return false, "destination file was replaced since selection"
  end
  if dsnap.dev ~= nil and st.dev ~= dsnap.dev then
    return false, "destination file was replaced since selection"
  end
  if dsnap.ino ~= nil and st.ino ~= dsnap.ino then
    return false, "destination file was replaced since selection"
  end
  if dsnap.loaded then
    if dsnap.buf and destbuf ~= dsnap.buf then
      return false, "destination buffer changed since selection"
    end
    if dsnap.name and dsnap.name ~= "" and bname ~= dsnap.name then
      return false, "destination renamed since selection"
    end
    if dsnap.tick ~= nil and vim.api.nvim_buf_get_changedtick(destbuf) ~= dsnap.tick then
      return false, "destination changed since selection"
    end
    if dsnap.modifiable ~= nil and vim.bo[destbuf].modifiable ~= dsnap.modifiable then
      return false, "destination modifiable/readonly changed since selection"
    end
    if dsnap.readonly ~= nil and vim.bo[destbuf].readonly ~= dsnap.readonly then
      return false, "destination modifiable/readonly changed since selection"
    end
  end
  -- Both originally-loaded and originally-unloaded destinations must retain
  -- their exact original contents.
  if not lines_equal(vim.api.nvim_buf_get_lines(destbuf, 0, -1, false), dsnap.lines) then
    return false, "destination content changed since selection"
  end
  if not editable(destbuf) then
    return false, "destination buffer is not modifiable"
  end
  return true
end

-- Centralized observational validator run once, after every autocmd-producing
-- preparation and immediately before mutation. Checks source and destination
-- validity/loading, identity (name/resolved path/device/inode), changedtick for
-- originally loaded buffers, exact full contents, editability/readonly,
-- physical non-identity and newly divergent loaded aliases.
-- Returns (true) or (false, reason).
function M.final_validate(srcbuf, snap, destbuf, dsnap, destpath)
  local oks, sreason = validate_source(srcbuf, snap)
  if not oks then
    return false, sreason
  end
  local okd, dreason = validate_dest(destbuf, destpath, dsnap, snap.real)
  if not okd then
    return false, dreason
  end
  -- Snapshot-time lookup cannot detect aliases introduced during selection or
  -- scratch cleanup. Reuse the existing observational lookup at the barrier.
  if snap.real then
    local _, alias_error = loaded_buf_for(snap.real)
    if alias_error then
      return false, "source aliases: " .. alias_error
    end
  end
  local _, alias_error = loaded_buf_for(destpath)
  if alias_error then
    return false, "destination aliases: " .. alias_error
  end
  return true
end

-- Revalidate snapshots and commit the move to `destpath`. Returns (ok, reason).
-- Every revalidation happens immediately before mutation, after all
-- autocmd-producing destination-loading work.
function M.commit(srcbuf, row, taskline, first, last, snap, destpath)
  if type(destpath) ~= "string" or destpath == "" then
    return false, "no destination"
  end
  if type(snap) ~= "table" or type(snap.lines) ~= "table" then
    return false, "missing source snapshot"
  end

  -- Fail fast before touching the destination: the source must still be the
  -- one selected. The authoritative combined check runs again after every
  -- autocmd-producing preparation below.
  local ok, reason = validate_source(srcbuf, snap)
  if not ok then
    return false, reason
  end
  if snap.lines[row + 1] ~= taskline then
    return false, "source task changed since selection"
  end

  -- Exact original moved lines are taken from the validated snapshot so that
  -- any autocmd-driven source tampering cannot influence the payload.
  -- The destination snapshot is bound to the stable pre-selection choice
  -- string. A missing snapshot (unoffered or otherwise unknown choice) is
  -- refused here, before any destination loading or editing.
  local dsnap = snap.dests and snap.dests[destpath]
  if not dsnap then
    return false, "unknown destination selection"
  end
  local moved = {}
  for i = first + 1, last + 1 do
    moved[#moved + 1] = snap.lines[i]
  end

  -- Preparation: load the destination, mark it listed, and prove the append
  -- context (protected scratch create/parse/delete). No mutation yet.
  local okadd, destbuf = pcall(vim.fn.bufadd, destpath)
  if not okadd then
    return false, "cannot open destination: " .. tostring(destbuf)
  end
  local okl, lerr = pcall(vim.fn.bufload, destbuf)
  if not okl then
    return false, "cannot load destination: " .. tostring(lerr)
  end
  if not vim.api.nvim_buf_is_loaded(destbuf) then
    return false, "cannot load destination"
  end
  pcall(function()
    vim.bo[destbuf].buflisted = true
  end)
  local safe, sreason2 = M.dest_safe(vim.api.nvim_buf_get_lines(destbuf, 0, -1, false), moved)
  if not safe then
    return false, "unsafe destination: " .. sreason2
  end

  -- Final combined observational validator: immediately before mutation, with
  -- no further autocmd-producing preparation.
  local okv, vreason = M.final_validate(srcbuf, snap, destbuf, dsnap, destpath)
  if not okv then
    return false, vreason
  end

  -- Mutation with exact full two-buffer rollback.
  local dest_lines = vim.api.nvim_buf_get_lines(destbuf, 0, -1, false)
  local okm, merr = perform_move(srcbuf, destbuf, first, last, snap.lines, dest_lines)
  if not okm then
    return false, merr
  end
  vim.api.nvim_set_current_buf(destbuf)
  notify("refiled task; save with :write (source buffer also modified)")
  return true
end

-- Physical destination candidates: every configured-root .md file, excluding
-- every alias of the physical source (same resolved path or device+inode+type,
-- which also excludes hard links). Returns (list, errors).
function M.destinations(srcbuf, config)
  local list, errors = files.collect(config.roots)
  local src_name = vim.api.nvim_buf_get_name(srcbuf)
  local src_id = src_name ~= "" and files.identity(src_name) or nil
  local src_real = src_name ~= "" and files.realpath(src_name) or nil
  local out = {}
  for _, f in ipairs(list) do
    local skip = f == src_real
    if not skip and src_id then
      skip = files.same_identity(files.identity(f), src_id)
    end
    if not skip then
      out[#out + 1] = f
    end
  end
  return out, errors
end

function M.run()
  local config = require("tino").config
  local srcbuf = vim.api.nvim_get_current_buf()
  if not editable(srcbuf) then
    notify("buffer is not modifiable", vim.log.levels.WARN)
    return false
  end
  local row = math.max(vim.fn.line(".") - 1, 0)
  local taskline = vim.api.nvim_buf_get_lines(srcbuf, row, row + 1, false)[1]
  if not taskline then
    return false
  end
  local task = parser.parse(taskline, config)
  if not task then
    notify("not a valid task", vim.log.levels.WARN)
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(srcbuf, 0, -1, false)
  local item, first, last = M.locate(srcbuf, lines, row, task.spans.checkbox[1], task.spans.checkbox[2])
  if not item then
    notify(first, vim.log.levels.WARN) -- first holds the reason on failure
    return false
  end
  local snap = M.snapshot_source(srcbuf)
  local list, errors = M.destinations(srcbuf, config)
  for _, e in ipairs(errors or {}) do
    notify("root " .. e.path .. ": " .. tostring(e.message), vim.log.levels.WARN)
  end
  if #list == 0 then
    notify("no destination files under configured roots", vim.log.levels.WARN)
    return false
  end
  -- Snapshot every candidate *before* selection.
  local dests, skipped = M.snapshot_dests(list)
  for _, s in ipairs(skipped or {}) do
    notify("skipping destination " .. s.path .. ": " .. tostring(s.message), vim.log.levels.WARN)
  end
  snap.dests = dests
  local choices = {}
  for _, f in ipairs(list) do
    if dests[f] then
      choices[#choices + 1] = f
    end
  end
  if #choices == 0 then
    notify("no usable destination files under configured roots", vim.log.levels.WARN)
    return false
  end
  picker.select_files(choices, { prompt = "Refile task to:" }, function(choice)
    if not choice then
      return
    end
    local ok, reason = M.commit(srcbuf, row, taskline, first, last, snap, choice)
    if not ok then
      notify(reason, vim.log.levels.WARN)
    end
  end)
  return true
end

return M
