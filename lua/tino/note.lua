-- Plain Markdown notes. All insertion/moves are buffer-only; never auto-save.
local files = require("tino.files")
local picker = require("tino.picker")
local M = {}

local function notify(message)
  vim.notify("tino: " .. message, vim.log.levels.WARN)
end

local function editable(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].modifiable and not vim.bo[buf].readonly
end

local function destination(path)
  path = files.normalize(path)
  if not path then
    return nil, "invalid note destination"
  end
  local buf, err = files.buffer_for(path)
  if err then
    return nil, err
  end
  if not buf then
    local ok
    ok, buf = pcall(vim.fn.bufadd, path)
    if not ok or type(buf) ~= "number" or buf <= 0 then
      return nil, "cannot open note destination"
    end
    ok = pcall(vim.fn.bufload, buf)
    if not ok or not vim.api.nvim_buf_is_loaded(buf) then
      return nil, "cannot load note destination"
    end
  end
  vim.bo[buf].buflisted = true
  if not editable(buf) then
    return nil, "note destination is not modifiable"
  end
  return buf
end

local function restore(buf, lines, modified)
  local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  if ok then
    vim.bo[buf].modified = modified
  end
  return ok
end

local function append(buf, lines)
  if not editable(buf) then
    return nil, "note destination is not modifiable"
  end
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local modified = vim.bo[buf].modified
  local after = #before == 1 and before[1] == "" and {} or vim.deepcopy(before)
  vim.list_extend(after, lines)
  if not pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, after) then
    local ok = restore(buf, before, modified)
    return nil, "note insertion failed" .. (ok and "" or "; destination rollback failed")
  end
  if not vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), after) then
    return nil, "destination changed during note insertion"
  end
  return { buf = buf, before = before, modified = modified,
    tick = vim.api.nvim_buf_get_changedtick(buf) }
end

local function show(buf, win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_buf, win, buf)
  else
    pcall(vim.api.nvim_set_current_buf, buf)
  end
end

local function insert(path, lines, win)
  local buf, err = destination(path)
  if buf then
    local result
    result, err = append(buf, lines)
    if result then
      show(buf, win)
      return true
    end
  end
  notify(err)
  return false
end

local function prompt(on_text)
  vim.ui.input({ prompt = "Note: " }, function(text)
    if type(text) == "string" and text:find("%S") then
      on_text(vim.split(text, "\n", { plain = true }))
    end
  end)
end

function M.run()
  local path = require("tino").config.note_inbox
  if type(path) ~= "string" or path == "" then
    notify("no note_inbox configured")
    return
  end
  local win = vim.api.nvim_get_current_win()
  prompt(function(lines)
    insert(path, lines, win)
  end)
end

function M.run_to()
  local win = vim.api.nvim_get_current_win()
  prompt(function(lines)
    picker.select_destination(require("tino").config.roots, { prompt = "Append note to:" }, function(path)
      if path then
        insert(path, lines, win)
      end
    end)
  end)
end

local function unchanged(snap)
  return editable(snap.buf)
    and vim.api.nvim_buf_get_name(snap.buf) == snap.name
    and vim.api.nvim_buf_get_changedtick(snap.buf) == snap.tick
    and vim.deep_equal(vim.api.nvim_buf_get_lines(snap.buf, 0, -1, false), snap.lines)
end

local function undo_append(record)
  return editable(record.buf) and vim.api.nvim_buf_get_changedtick(record.buf) == record.tick
    and restore(record.buf, record.before, record.modified)
end

local function move(snap, path)
  if not unchanged(snap) then
    return notify("source changed since selection")
  end
  local buf, err = destination(path)
  if not buf then
    return notify(err)
  end
  if buf == snap.buf or (snap.name ~= "" and files.same_physical(path, snap.name)) then
    return notify("destination is the source (or an alias of it)")
  end
  -- Loading/listing the destination can run user autocmds: recheck before editing.
  if not unchanged(snap) then
    return notify("source changed since selection")
  end
  local selected = {}
  for i = snap.first, snap.last do
    selected[#selected + 1] = snap.lines[i]
  end
  local record
  record, err = append(buf, selected)
  if not record then
    return notify(err)
  end
  if not unchanged(snap) then
    local restored = undo_append(record)
    return notify("source changed during insertion" .. (restored and "" or "; destination retains a copy"))
  end
  -- Destination succeeded first. A failed source edit must not lose the note.
  if not pcall(vim.api.nvim_buf_set_lines, snap.buf, snap.first - 1, snap.last, false, {}) then
    local restored = restore(snap.buf, snap.lines, snap.modified)
    local rolled_back = restored and undo_append(record)
    return notify("source removal failed" .. (rolled_back and "; move rolled back" or "; destination retains a copy"))
  end
  show(buf, snap.win)
end

function M.refile(opts)
  local buf = vim.api.nvim_get_current_buf()
  local first = vim.api.nvim_buf_get_mark(buf, "<")[1]
  local last = vim.api.nvim_buf_get_mark(buf, ">")[1]
  if not opts or opts.range ~= 2 or first < 1 or last < first
    or opts.line1 ~= first or opts.line2 ~= last then
    return notify("TinoNoteRefile requires a visual selection")
  end
  if not editable(buf) then
    return notify("source is not modifiable")
  end
  local snap = { buf = buf, win = vim.api.nvim_get_current_win(),
    name = vim.api.nvim_buf_get_name(buf), first = first, last = last,
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    tick = vim.api.nvim_buf_get_changedtick(buf), modified = vim.bo[buf].modified }
  picker.select_destination(require("tino").config.roots, { prompt = "Move selected lines to:" }, function(path)
    if path then
      move(snap, path)
    end
  end)
end

return M
