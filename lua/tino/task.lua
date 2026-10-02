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

-- Canonical visual marker written alongside each built-in state token. Custom
-- states fall back to the completed/active checkbox pair so configured state
-- names keep their prior rendering.
local STATE_MARKER = {
  TODO = "[ ]",
  DOING = "[/]",
  WAITING = "[~]",
  DONE = "[x]",
  CANCELLED = "[-]",
}

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

-- Canonical state/checkbox sync edits. An explicit state token is rewritten
-- in place; a marker-only task (no word yet) gains "<ws><state>" inserted
-- just after the checkbox.
local function state_sync_edits(config, task, state)
  local complete = is_completed(config, state)
  local marker = STATE_MARKER[state] or (complete and "[x]" or "[ ]")
  local edits = {
    { task.spans.checkbox[1], task.spans.checkbox[2], marker },
  }
  if task.implicit_state then
    edits[#edits + 1] = { task.spans.state[1], task.spans.state[2], " " .. state }
  else
    edits[#edits + 1] = { task.spans.state[1], task.spans.state[2], state }
  end
  return edits
end

-- Apply non-overlapping span edits on a single row, right-to-left, after
-- verifying the live line still matches the originally parsed line. Unless the
-- caller already supplied synchronized state/checkbox edits (`state_change`),
-- the parsed state and its canonical marker are normalized as part of every
-- rewrite, so marker-only tasks gain their explicit word here.
local function apply(bufnr, row, task, edits, config, state_change)
  local current = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if current ~= task.line then
    notify("task changed since parse; aborting", vim.log.levels.WARN)
    return false
  end
  if not state_change and config then
    for _, e in ipairs(state_sync_edits(config, task, task.state)) do
      edits[#edits + 1] = e
    end
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
  local edits = state_sync_edits(config, task, newstate)
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
  return apply(bufnr, row, task, state_transition_edits(config, task, newstate), config, true)
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
  return apply(bufnr, row, task, state_transition_edits(config, task, state), config, true)
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

-- Promote a non-task line into a task in `state` (default TODO), preserving
-- the original text, its leading indentation and a terminal CR. A
-- blank/whitespace-only line, or a line that already looks like a list item
-- (a malformed or unsupported task), is left untouched rather than
-- double-prefixed. A completed target gains the managed timestamp when
-- done_timestamp is enabled, matching on-task state transitions.
local function plain_text_task(bufnr, row, line, state, config)
  state = state or "TODO"
  local body = line
  local cr = ""
  if body:sub(-1) == "\r" then
    cr = "\r"
    body = body:sub(1, -2)
  end
  if body:match("^[ \t]*$") then
    return false
  end
  if body:match("^[ \t]*[%-%*%+]%s") or body:match("^[ \t]*%d+[%.%)]%s") then
    return false
  end
  local indent = body:match("^[ \t]*") or ""
  local complete = config ~= nil and is_completed(config, state)
  local marker = STATE_MARKER[state] or (complete and "[x]" or "[ ]")
  local ts = ""
  if complete and config.done_timestamp then
    ts = " @done(" .. os.date("%Y-%m-%d %H:%M") .. ")"
  end
  local new = indent .. "- " .. marker .. " " .. state .. " " .. body:sub(#indent + 1) .. ts .. cr
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { new })
  return true
end

-- :TinoTodo - set the current task keyword to the literal "TODO".
--
-- Only this command is broadened: a marker-only supported Markdown task keeps
-- its inferred state (its explicit word is normalized instead of forced to
-- TODO), and a nonempty plain-text line is promoted to a TODO task. An
-- explicit-state task keeps the literal direct-set behavior. The other
-- commands and M.set_state are unchanged.
function M.set_todo(bufnr, row, config)
  config = resolve_config(config)
  bufnr = bufnr or 0
  if not editable(bufnr) then
    return false
  end
  -- Same configured-state validation as the literal direct setter.
  local known = false
  for _, s in ipairs(config.states) do
    if s == "TODO" then
      known = true
      break
    end
  end
  if not known then
    notify("state TODO is not configured", vim.log.levels.WARN)
    return false
  end
  if is_completed(config, "TODO") then
    notify("TODO has an incompatible completion role", vim.log.levels.WARN)
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
  if task and not task.implicit_state then
    return M.set_state(bufnr, row, "TODO", config)
  end
  if task then
    -- Marker-only task: reuse the shared normalization to keep the inferred
    -- state and write its canonical word, instead of forcing TODO.
    return apply(bufnr, row, task, {}, config)
  end
  return plain_text_task(bufnr, row, line, "TODO", config)
end

-- Built-in :TinoState choices. Each label is the exact select entry; its index
-- maps unambiguously to the configured state token.
local STATE_CHOICES = {
  { label = "t -> TODO", state = "TODO" },
  { label = "d -> DOING", state = "DOING" },
  { label = "w -> WAITING", state = "WAITING" },
  { label = "x -> DONE", state = "DONE" },
  { label = "c -> CANCELLED", state = "CANCELLED" },
}

-- Direct-set worker for :TinoState. An existing task (explicit or marker-only)
-- is set straight to `state` through the shared direct-set path; a nonempty
-- plain-text line is promoted into a task already in `state`. The target must
-- be a configured state. Any other line is left untouched.
function M.set_state_or_create(bufnr, row, state, config)
  config = resolve_config(config)
  bufnr = bufnr or 0
  if not editable(bufnr) then
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
    notify("unknown state: " .. tostring(state), vim.log.levels.WARN)
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
  if task then
    return M.set_state(bufnr, row, state, config)
  end
  return plain_text_task(bufnr, row, line, state, config)
end

-- :TinoState - prompt once through the built-in vim.ui.select and directly set
-- the current task (or promote plain text) to the chosen state. The target
-- buffer and row are captured before the asynchronous callback so a later
-- window/buffer change cannot retarget the edit. Dismissing the prompt is a
-- no-op.
function M.prompt_state(bufnr, row, config)
  config = resolve_config(config)
  bufnr = bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local items = {}
  for i, c in ipairs(STATE_CHOICES) do
    items[i] = c.label
  end
  vim.ui.select(items, { prompt = "Set state" }, function(_, idx)
    if idx == nil then
      return -- cancelled
    end
    M.set_state_or_create(bufnr, row, STATE_CHOICES[idx].state, config)
  end)
  return true
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
    return apply(bufnr, row, task, { { span[1] - 1, span[2], "" } }, config)
  elseif span then
    return apply(bufnr, row, task, { { span[1], span[2], "@due(" .. date .. ")" } }, config)
  end
  local finish = metadata_end(task)
  return apply(bufnr, row, task, { { finish, finish, " @due(" .. date .. ")" } }, config)
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
  return apply(bufnr, row, task, edits, config)
end

return M
