-- tino task mutation: state/priority cycling with safe in-buffer edits.

local parser = require("tino.parser")
local dates = require("tino.date")
local M = {}

local function notify(msg, level)
  vim.notify("tino: " .. msg, level or vim.log.levels.INFO)
end

local function resolve_config(config)
  if config then
    return config
  end
  return require("tino").config
end

local function is_completed(config, state)
  return parser.completed(config, state)
end

local function is_hws_byte(c)
  return c == " " or c == "\t"
end

-- True when the buffer row lies inside / is a fenced code block delimiter,
-- using the shared parser scan.
local function row_fenced(bufnr, row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return parser.row_fenced(lines, row)
end

local function editable(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    notify("invalid buffer", vim.log.levels.WARN)
    return false
  end
  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
    notify("buffer is not modifiable", vim.log.levels.WARN)
    return false
  end
  return true
end

-- 0-based byte offset just past the horizontal-whitespace run starting at `offset`.
local function hws_after(line, offset)
  local n = #line
  local pos = offset
  while pos < n do
    local c = line:sub(pos + 1, pos + 1)
    if c ~= " " and c ~= "\t" then
      break
    end
    pos = pos + 1
  end
  return pos
end

-- Apply non-overlapping span edits on a single row, right-to-left, after
-- verifying the live line still matches the originally parsed line.
local function apply(bufnr, row, original, edits)
  local current = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if current ~= original then
    notify("task changed since parse; aborting", vim.log.levels.WARN)
    return false
  end
  table.sort(edits, function(a, b)
    return a[1] > b[1]
  end)
  for _, e in ipairs(edits) do
    if e[1] ~= e[2] or e[3] ~= "" then
      local replacement = e[3] == "" and {} or { e[3] }
      vim.api.nvim_buf_set_text(bufnr, row, e[1], row, e[2], replacement)
    end
  end
  return true
end

function M.parse_at(bufnr, row, config)
  bufnr = bufnr or 0
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return nil
  end
  if row_fenced(bufnr, row) then
    return nil
  end
  return parser.parse(line, config)
end

local function metadata_end(task)
  local due = task.spans.due_date
  local done = task.spans.done_timestamp
  return math.max(task.spans.text[2], due and due[2] or 0, done and done[2] or 0)
end

-- Build the span edits that move `task` to `newstate`, syncing the checkbox
-- and the managed completion timestamp. Shared by cycle_state and set_state so
-- cycle ordering/completion semantics stay identical. An existing canonical
-- timestamp is retained verbatim when the target is completed and removed
-- when it is active; a missing one is added only when entering a completed
-- state with done_timestamp enabled.
local function state_transition_edits(config, task, newstate)
  local complete = is_completed(config, newstate)
  local edits = {
    { task.spans.state[1], task.spans.state[2], newstate },
    { task.spans.checkbox[1], task.spans.checkbox[2], complete and "[x]" or "[ ]" },
  }
  if complete then
    if not task.done_timestamp and config.done_timestamp then
      edits[#edits + 1] = {
        metadata_end(task),
        metadata_end(task),
        " @done(" .. os.date("%Y-%m-%d %H:%M") .. ")",
      }
    end
  elseif task.done_timestamp then
    local span = task.spans.done_timestamp
    local start = span[1]
    while start > 0 and is_hws_byte(task.line:sub(start, start)) do
      start = start - 1
    end
    edits[#edits + 1] = { start, span[2], "" }
  end
  return edits
end

-- Cycle the task state forward through config.states, syncing the checkbox
-- and inserting/removing the managed completion timestamp as required.
function M.cycle_state(bufnr, row, config)
  config = resolve_config(config)
  bufnr = bufnr or 0
  if not editable(bufnr) then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return false
  end
  if row_fenced(bufnr, row) then
    notify("inside fenced code block", vim.log.levels.WARN)
    return false
  end
  local task = parser.parse(line, config)
  if not task then
    notify("not a valid task", vim.log.levels.WARN)
    return false
  end
  local states = config.states
  local idx
  for i, s in ipairs(states) do
    if s == task.state then
      idx = i
      break
    end
  end
  if not idx then
    notify("unknown state", vim.log.levels.WARN)
    return false
  end
  local newstate = states[idx % #states + 1]
  return apply(bufnr, row, line, state_transition_edits(config, task, newstate))
end

-- Directly set the task state to `state`, bypassing cycle order. The target
-- must be a configured state; its completed role is taken from
-- config.completed_states and the checkbox/timestamp are synchronized exactly
-- as the cycle command would. Repeating the same call is idempotent and never
-- duplicates the managed timestamp.
function M.set_state(bufnr, row, state, config)
  config = resolve_config(config)
  bufnr = bufnr or 0
  if not editable(bufnr) then
    return false
  end
  if type(state) ~= "string" then
    notify("invalid target state", vim.log.levels.WARN)
    return false
  end
  local known = false
  for _, s in ipairs(config.states) do
    if s == state then
      known = true
      break
    end
  end
  if not known then
    notify("unknown state: " .. state, vim.log.levels.WARN)
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return false
  end
  if row_fenced(bufnr, row) then
    notify("inside fenced code block", vim.log.levels.WARN)
    return false
  end
  local task = parser.parse(line, config)
  if not task then
    notify("not a valid task", vim.log.levels.WARN)
    return false
  end
  return apply(bufnr, row, line, state_transition_edits(config, task, state))
end

-- Shared guard for the literal direct setters: the target token must be a
-- configured state and its configured completion role must match the command's
-- intent, otherwise the request is refused rather than contradicting the
-- configured meaning of DONE/TODO.
local function direct_set(bufnr, row, target, want_completed, config)
  config = resolve_config(config)
  local known = false
  for _, s in ipairs(config.states) do
    if s == target then
      known = true
      break
    end
  end
  if not known then
    notify("state " .. target .. " is not configured", vim.log.levels.WARN)
    return false
  end
  if is_completed(config, target) ~= want_completed then
    notify(target .. " has an incompatible completion role", vim.log.levels.WARN)
    return false
  end
  return M.set_state(bufnr, row, target, config)
end

-- :TinoDone - set the current task keyword to the literal "DONE".
function M.set_done(bufnr, row, config)
  return direct_set(bufnr, row, "DONE", true, config)
end

-- :TinoTodo - set the current task keyword to the literal "TODO".
function M.set_todo(bufnr, row, config)
  return direct_set(bufnr, row, "TODO", false, config)
end

-- Set, replace or remove only the managed deadline and its separator.
function M.set_due(bufnr, row, input, config)
  config = resolve_config(config)
  bufnr = bufnr or 0
  if not editable(bufnr) then
    return false
  end
  local date, err = dates.normalize(input)
  if not date then
    notify(err, vim.log.levels.WARN)
    return false
  end
  local task = M.parse_at(bufnr, row, config)
  if not task then
    notify("not a valid task", vim.log.levels.WARN)
    return false
  end
  local span = task.spans.due_date
  if date == "" then
    if not span then
      return true
    end
    -- Remove exactly one separator byte; preserve other user whitespace.
    return apply(bufnr, row, task.line, { { span[1] - 1, span[2], "" } })
  elseif span then
    return apply(bufnr, row, task.line, { { span[1], span[2], "@due(" .. date .. ")" } })
  end
  local finish = metadata_end(task)
  return apply(bufnr, row, task.line, { { finish, finish, " @due(" .. date .. ")" } })
end

function M.prompt_due(bufnr, row, config)
  config = resolve_config(config)
  bufnr = bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not editable(bufnr) then
    return false
  end
  local task = M.parse_at(bufnr, row, config)
  if not task then
    notify("not a valid task", vim.log.levels.WARN)
    return false
  end
  vim.ui.input({
    prompt = "Due (YYYY-MM-DD, today, tomorrow, +Nd, +Nw; blank to remove): ",
    default = task.due_date or "",
  }, function(input)
    if input == nil then
      return -- cancelled
    end
    if not editable(bufnr) then
      return
    end
    local current = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    if current ~= task.line then
      notify("task changed since prompt; aborting", vim.log.levels.WARN)
      return
    end
    M.set_due(bufnr, row, input, config)
  end)
  return true
end

-- Cycle the priority cookie none -> A -> B -> C -> none, preserving all
-- other bytes exactly.
function M.cycle_priority(bufnr, row, config)
  config = resolve_config(config)
  bufnr = bufnr or 0
  if not editable(bufnr) then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return false
  end
  if row_fenced(bufnr, row) then
    notify("inside fenced code block", vim.log.levels.WARN)
    return false
  end
  local task = parser.parse(line, config)
  if not task then
    notify("not a valid task", vim.log.levels.WARN)
    return false
  end
  local priorities = config.priorities
  local edits = {}
  if task.priority then
    local idx
    for i, p in ipairs(priorities) do
      if p == task.priority then
        idx = i
        break
      end
    end
    if not idx then
      notify("unknown priority", vim.log.levels.WARN)
      return false
    end
    if idx == #priorities then
      -- Remove the cookie plus exactly one adjacent separator byte so any
      -- other whitespace the user wrote is preserved.
      local pend = task.spans.priority[2]
      if is_hws_byte(line:sub(pend + 1, pend + 1)) then
        pend = pend + 1
      end
      edits[#edits + 1] = { task.spans.priority[1], pend, "" }
    else
      local np = priorities[idx + 1]
      edits[#edits + 1] = { task.spans.priority[1], task.spans.priority[2], "[#" .. np .. "]" }
    end
  else
    if #priorities == 0 then
      return false
    end
    local start = hws_after(line, task.spans.state[2])
    edits[#edits + 1] = { start, start, "[#" .. priorities[1] .. "] " }
  end
  return apply(bufnr, row, line, edits)
end

return M
