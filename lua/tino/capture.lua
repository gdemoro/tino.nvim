-- tino capture: prompt for a task, then append it to the configured inbox
-- buffer. Never writes to disk automatically; the user saves with :write.

local parser = require("tino.parser")
local files = require("tino.files")
local M = {}

local function notify(msg, level)
  vim.notify("tino: " .. msg, level or vim.log.levels.INFO)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function valid_priority(config, p)
  for _, v in ipairs(config.priorities or {}) do
    if v == p then
      return true
    end
  end
  return false
end

-- Build the canonical first-active-state task line.
function M.build_line(config, text, priority)
  local line = "- [ ] " .. config.states[1]
  if priority then
    line = line .. " [#" .. priority .. "]"
  end
  return line .. " " .. text
end

-- Trim and sanity-check a task description before any buffer work. Returns
-- the trimmed description, or nil when it is unusable (empty or multiline).
local function usable_text(text)
  if type(text) ~= "string" then
    return nil
  end
  local t = trim(text)
  if t == "" or t:find("[\r\n]") then
    return nil
  end
  return t
end

-- True when the buffer is in a state safe to edit.
local function editable(buf)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_buf_is_loaded(buf)
    and not vim.bo[buf].readonly
    and vim.bo[buf].modifiable
end

-- Insert `text` (with optional priority) into `inbox`, loading the buffer
-- without saving and displaying it. Refuses (returning false after a clean
-- notification) rather than reinterpreting the chosen priority or the task
-- description as metadata, and never leaves the original inbox content
-- partially modified.
function M.insert(inbox, config, text, priority)
  local path = files.normalize(inbox)
  if not path then
    notify("invalid inbox path", vim.log.levels.ERROR)
    return false
  end

  text = usable_text(text)
  if not text then
    notify("empty or multiline task ignored", vim.log.levels.WARN)
    return false
  end
  if priority ~= nil and not valid_priority(config, priority) then
    notify("invalid priority: " .. tostring(priority), vim.log.levels.WARN)
    return false
  end

  local line = M.build_line(config, text, priority)
  local parsed = parser.parse(line, config)
  if not parsed then
    notify("could not build a valid task", vim.log.levels.ERROR)
    return false
  end
  -- The chosen priority and the intended text must survive the round trip
  -- byte-for-byte: refuse a leading [#P] cookie or trailing @done(...) that
  -- the parser would otherwise absorb as managed metadata.
  if parsed.priority ~= priority or parsed.text ~= text then
    notify("task text would be reinterpreted as metadata", vim.log.levels.WARN)
    return false
  end

  local ok, buf = pcall(vim.fn.bufadd, path)
  if not ok or type(buf) ~= "number" or buf <= 0 or not vim.api.nvim_buf_is_valid(buf) then
    notify("cannot open inbox buffer", vim.log.levels.ERROR)
    return false
  end
  ok = pcall(vim.fn.bufload, buf)
  if not ok or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    notify("cannot load inbox buffer", vim.log.levels.ERROR)
    return false
  end
  if not editable(buf) then
    notify("inbox buffer is not modifiable", vim.log.levels.WARN)
    return false
  end
  pcall(function()
    vim.bo[buf].buflisted = true
  end)

  local read_ok, existing = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not read_ok or type(existing) ~= "table" then
    notify("cannot read inbox buffer", vim.log.levels.ERROR)
    return false
  end
  -- Preparatory operations (bufadd/bufload autocmds, listing the buffer) may
  -- have changed editability; re-check immediately before editing.
  if not editable(buf) then
    notify("inbox buffer is not modifiable", vim.log.levels.WARN)
    return false
  end

  local new_lines = {}
  if #existing == 1 and existing[1] == "" then
    new_lines = { line }
  else
    for _, l in ipairs(existing) do
      new_lines[#new_lines + 1] = l
    end
    new_lines[#new_lines + 1] = line
  end

  if not pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, new_lines) then
    -- Best-effort restore so a failed edit never leaves a partial change.
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, existing)
    notify("could not update inbox buffer", vim.log.levels.ERROR)
    return false
  end

  if not pcall(vim.api.nvim_set_current_buf, buf) then
    notify("task inserted, but the inbox could not be displayed", vim.log.levels.WARN)
  end
  return true
end

function M.run()
  local config = require("tino").config
  local inbox = config.inbox
  if type(inbox) ~= "string" or inbox == "" then
    notify("no inbox configured", vim.log.levels.ERROR)
    return
  end

  vim.ui.input({ prompt = "Task: " }, function(text)
    if type(text) ~= "string" then
      return -- cancelled
    end
    text = trim(text)
    if text == "" then
      notify("empty task ignored", vim.log.levels.WARN)
      return
    end
    if text:find("[\r\n]") then
      notify("multiline tasks are not supported", vim.log.levels.WARN)
      return
    end
    local choices = table.concat(config.priorities or {}, "/")
    vim.ui.input({ prompt = "Priority (" .. choices .. ", blank for none): " }, function(pri)
      if type(pri) ~= "string" then
        return -- cancelled
      end
      pri = trim(pri)
      local priority
      if pri ~= "" then
        if not valid_priority(config, pri) then
          notify("invalid priority: " .. pri, vim.log.levels.WARN)
          return
        end
        priority = pri
      end
      M.insert(inbox, config, text, priority)
    end)
  end)
end

return M
