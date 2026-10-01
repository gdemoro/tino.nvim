-- tino agenda: read-only overview of every task under the configured
-- roots, grouped by state, with a buffer-local jump back to each source line.

local parser = require("tino.parser")
local files = require("tino.files")
local M = {}

local targets = {} -- bufnr -> { [agenda_line] = { file, lnum, text } }

local function notify(msg, level)
  vim.notify("tino: " .. msg, level or vim.log.levels.INFO)
end

local function is_completed(config, state)
  return parser.completed(config, state)
end

-- True when `lines` still holds the stored raw task line at its source row and
-- the central parser plus fence eligibility still recognize it as a task.
-- Uses the shared parser (no duplicated task grammar).
local function target_still_valid(config, lines, t)
  if type(lines) ~= "table" or lines[t.lnum] ~= t.text then
    return false
  end
  if not parser.parse(t.text, config) then
    return false
  end
  if parser.row_fenced(lines, t.lnum - 1) then
    return false
  end
  return true
end

-- Open the source file for the task on the given agenda row, verifying the
-- source line still holds the same task at each stage that can run autocmds.
function M.jump(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local map = targets[bufnr]
  if not map then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local t = map[row]
  if not t then
    return false
  end
  local config = require("tino").config

  local lines, err = files.read_lines(t.file)
  if not lines then
    notify("source unavailable: " .. t.file .. " (" .. tostring(err) .. ")", vim.log.levels.WARN)
    return false
  end
  if not target_still_valid(config, lines, t) then
    notify("stale agenda entry; press r to refresh", vim.log.levels.WARN)
    return false
  end

  local ok, src = pcall(vim.fn.bufadd, t.file)
  if not ok or type(src) ~= "number" or src <= 0 or not vim.api.nvim_buf_is_valid(src) then
    notify("cannot open source buffer: " .. t.file, vim.log.levels.ERROR)
    return false
  end
  ok = pcall(vim.fn.bufload, src)
  if not ok or not vim.api.nvim_buf_is_valid(src) or not vim.api.nvim_buf_is_loaded(src) then
    notify("cannot load source buffer: " .. t.file, vim.log.levels.ERROR)
    return false
  end
  -- bufload can fire BufRead/BufEnter autocmds that edit the buffer; verify
  -- the stored line survives before touching the window.
  local read_ok, buf_lines = pcall(vim.api.nvim_buf_get_lines, src, 0, -1, false)
  if not read_ok or not target_still_valid(config, buf_lines, t) then
    notify("stale agenda entry; press r to refresh", vim.log.levels.WARN)
    return false
  end

  -- Switching the window buffer can fire further autocmds; verify again
  -- immediately before moving the cursor and, on refusal, put the agenda back.
  if not pcall(vim.api.nvim_win_set_buf, 0, src) then
    notify("cannot open source buffer: " .. t.file, vim.log.levels.ERROR)
    return false
  end
  local read_ok2, buf_lines2 = pcall(vim.api.nvim_buf_get_lines, src, 0, -1, false)
  if not read_ok2 or not target_still_valid(config, buf_lines2, t) then
    -- The agenda buffer uses bufhidden=wipe, so switching away may already
    -- have wiped it; re-render a fresh agenda view instead of restoring it.
    notify("stale agenda entry; press r to refresh", vim.log.levels.WARN)
    pcall(M.run)
    return false
  end

  pcall(vim.api.nvim_win_set_cursor, 0, { t.lnum, 0 })
  return true
end

local function source_label(path, lines)
  for row, line in ipairs(lines) do
    local title = line:match("^ ? ? ?#[ \t]+(.-)%s*$")
    if title and title ~= "" and not parser.row_fenced(lines, row - 1) then
      return (title:gsub("[ \t]+#+$", ""))
    end
  end
  return vim.fn.fnamemodify(path, ":t")
end

local function render(config)
  local errors
  local filepaths
  filepaths, errors = files.collect(config.roots)
  local include_completed = config.agenda and config.agenda.include_completed == true

  -- file path -> list of parsed task rows
  local per_file, labels = {}, {}
  for _, path in ipairs(filepaths) do
    local lines, err = files.read_lines(path)
    if not lines then
      errors[#errors + 1] = { path = path, message = tostring(err) }
    else
      per_file[path] = parser.scan_lines(lines, config)
      labels[path] = source_label(path, lines)
    end
  end

  local out = { "# tino agenda", "" }
  local map = {}
  for _, state in ipairs(config.states) do
    if include_completed or not is_completed(config, state) then
      local header_i = #out + 1
      out[#out + 1] = "## " .. state
      for _, path in ipairs(filepaths) do
        local rows = per_file[path]
        if rows then
          for _, item in ipairs(rows) do
            local task = item.task
            if task.state == state then
              local prefix = task.priority and ("[#" .. task.priority .. "] ") or ""
              local deadline = task.due_date and (" @due(" .. task.due_date .. ")") or ""
              local text = "  " .. labels[path] .. ":" .. (item.row + 1) .. "  " .. prefix .. task.text .. deadline
              out[#out + 1] = text
              map[#out] = { file = path, lnum = item.row + 1, text = item.line }
            end
          end
        end
      end
      if #out == header_i then
        out[#out + 1] = "  (none)"
      end
      out[#out + 1] = ""
    end
  end

  for _, e in ipairs(errors) do
    out[#out + 1] = "! " .. e.path .. ": " .. tostring(e.message)
  end

  return out, map
end

function M.run()
  local config = require("tino").config
  local lines, map = render(config)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, "tino-agenda")

  targets[buf] = map

  vim.keymap.set("n", "<CR>", function()
    M.jump(buf)
  end, { buffer = buf, desc = "tino: open task source" })
  vim.keymap.set("n", "r", function()
    M.run()
  end, { buffer = buf, desc = "tino: refresh agenda" })

  vim.api.nvim_set_current_buf(buf)
  return buf
end

return M
