-- tino parser: pure-Lua, byte-oriented task line grammar.
--
-- Grammar (after optional horizontal-whitespace indentation):
--   <marker><ws>+<checkbox><ws>+<STATE>[[#P]]?<ws>+<text>[<ws>+<metadata>]*<ws>*
--   marker   : "-", "*", "+" or one-or-more digits followed by "." or ")"
--   checkbox : "[ ]" | "[x]" | "[X]"
--   STATE    : exactly one configured uppercase token [A-Z][A-Z0-9_-]*
--   [#P]     : optional single configured uppercase-letter priority cookie
--   metadata : optional single @due(YYYY-MM-DD) and/or @done(YYYY-MM-DD HH:MM)
--              in either order at the end of the description
--
-- parse() returns nil for non-tasks and malformed/ambiguous metadata.

local M = {}

local defaults = {
  states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
  priorities = { "A", "B", "C" },
  completed_states = { DONE = true, CANCELLED = true },
  done_timestamp = true,
}

local function is_hws(c)
  return c == " " or c == "\t"
end

-- Accepts either a list {"DONE", ...} or a set { DONE = true }.
local function contains(value, key)
  if type(value) ~= "table" then
    return false
  end
  if value[key] ~= nil then
    return true
  end
  for _, v in ipairs(value) do
    if v == key then
      return true
    end
  end
  return false
end

local TS = "@done%(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d%)"
local DUE = "@due%(%d%d%d%d%-%d%d%-%d%d%)"

local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function is_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

-- Pure numeric Gregorian validation (no os.time/os.date, so no timezone or
-- host-clock dependence).
local function valid_datetime(s)
  local y, mo, d, h, mi = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d)$")
  if not y then
    return false
  end
  y, mo, d, h, mi = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
  if y < 1 or mo < 1 or mo > 12 then
    return false
  end
  local maxd = DAYS[mo]
  if mo == 2 and is_leap(y) then
    maxd = 29
  end
  if d < 1 or d > maxd then
    return false
  end
  if h < 0 or h > 23 or mi < 0 or mi > 59 then
    return false
  end
  return true
end

M.valid_datetime = valid_datetime

function M.valid_date(s)
  return type(s) == "string" and valid_datetime(s .. " 00:00")
end

-- Interpret completed_states for `state`. Returns (completed, valid).
-- A list of state names marks those states completed. A map uses boolean
-- values: true => completed, false or absent => not completed. Any other
-- (unsupported truthy non-boolean) map value yields valid=false.
local function completed_of(set, state)
  if type(set) ~= "table" then
    return false, true
  end
  local v = set[state]
  if v ~= nil then
    if type(v) == "boolean" then
      return v, true
    end
    return false, false
  end
  for _, s in ipairs(set) do
    if s == state then
      return true, true
    end
  end
  return false, true
end

-- True when completed_states is a list or a map whose values are all booleans.
local function completed_set_valid(set)
  if type(set) ~= "table" then
    return true
  end
  for k, v in pairs(set) do
    if type(k) == "string" and type(v) ~= "boolean" then
      return false
    end
  end
  return true
end

-- Public: is `state` a completed state under this config?
function M.completed(config, state)
  local set = type(config) == "table" and config.completed_states or nil
  local done = completed_of(set, state)
  return done
end

local function resolve_config(config)
  if config then
    return config
  end
  local ok, init = pcall(require, "tino")
  if ok and type(init) == "table" and init.config then
    return init.config
  end
  return defaults
end

function M.parse(line, config)
  if type(line) ~= "string" then
    return nil
  end
  config = resolve_config(config)
  -- Preserve the exact original line bytes (including a terminal CR) while
  -- tokenizing against the body without it; spans stay byte-identical because
  -- the body is a prefix.
  local original = line
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  local n = #line

  -- indentation
  local j = 1
  while j <= n and is_hws(line:sub(j, j)) do
    j = j + 1
  end

  -- list marker
  local bullet_end
  local b = line:sub(j, j)
  if b == "-" or b == "*" or b == "+" then
    bullet_end = j
  else
    local ds, de = line:find("^%d+", j)
    if not ds then
      return nil
    end
    if de - ds + 1 > 9 then
      return nil -- ordered list markers are limited to nine digits
    end
    local delim = line:sub(de + 1, de + 1)
    if delim ~= "." and delim ~= ")" then
      return nil
    end
    bullet_end = de + 1
  end

  -- whitespace after marker
  local k = bullet_end + 1
  local ws0 = k
  while k <= n and is_hws(line:sub(k, k)) do
    k = k + 1
  end
  if k == ws0 then
    return nil
  end

  -- checkbox
  local cb = line:sub(k, k + 2)
  local checked
  if cb == "[ ]" then
    checked = false
  elseif cb == "[x]" or cb == "[X]" then
    checked = true
  else
    return nil
  end
  local cb_s, cb_e = k - 1, k + 2
  k = k + 3

  local ws1 = k
  while k <= n and is_hws(line:sub(k, k)) do
    k = k + 1
  end
  if k == ws1 then
    return nil
  end

  -- state
  local st_s, st_e = line:find("^[A-Z][A-Z0-9_%-]*", k)
  if not st_s then
    return nil
  end
  local state = line:sub(st_s, st_e)
  if not contains(config.states, state) then
    return nil
  end
  k = st_e + 1

  local ws2 = k
  while k <= n and is_hws(line:sub(k, k)) do
    k = k + 1
  end
  if k == ws2 then
    return nil
  end

  -- optional priority cookie [#P]
  local priority, pr_s, pr_e
  if line:sub(k, k + 1) == "[#" then
    local p = line:match("^%[#([A-Z])%]", k)
    if not (p and contains(config.priorities, p)) then
      return nil
    end
    priority = p
    pr_s, pr_e = k - 1, k + 3
    k = k + 4
    local ws3 = k
    while k <= n and is_hws(line:sub(k, k)) do
      k = k + 1
    end
    if k == ws3 then
      return nil
    end
  end

  -- reject a repeated/unknown/malformed leading priority cookie
  if line:sub(k, k + 1) == "[#" then
    return nil
  end

  -- description region (trailing horizontal whitespace excluded)
  local e = n
  while e >= k and is_hws(line:sub(e, e)) do
    e = e - 1
  end
  if e < k then
    return nil
  end

  local text_start = k
  local text_end = e
  local metadata, metadata_spans = {}, {}

  -- Strip at most one deadline and one completion timestamp from the suffix.
  -- Embedded metadata-like prose remains description text, as before.
  for _ = 1, 2 do
    local a, name
    for _, candidate in ipairs({ "done", "due" }) do
      local p = text_start
      while true do
        local x = line:find("@" .. candidate .. "(", p, true)
        if not x or x > text_end then
          break
        end
        if not a or x > a then
          a, name = x, candidate
        end
        p = x + 1
      end
    end
    if not a or metadata[name] or (a ~= text_start and not is_hws(line:sub(a - 1, a - 1))) then
      break
    end
    local tail = line:sub(a, text_end)
    local close = tail:find(")", 1, true)
    if not close then
      return nil -- malformed trailing metadata (missing closing paren)
    end
    if close ~= #tail then
      break -- embedded prose, not a managed suffix
    end
    local value = tail:match("^@" .. name .. "%((.-)%)$")
    if not value or not ((name == "done" and valid_datetime(value)) or (name == "due" and M.valid_date(value))) then
      return nil -- malformed or invalid calendar metadata
    end
    local pattern = name == "done" and TS or DUE
    if line:sub(text_start, a - 1):find(pattern) then
      return nil -- duplicate managed metadata
    end
    metadata[name] = value
    metadata_spans[name] = { a - 1, text_end }
    text_end = a - 1
    while text_end >= text_start and is_hws(line:sub(text_end, text_end)) do
      text_end = text_end - 1
    end
  end

  if text_end < text_start then
    return nil
  end
  local text = line:sub(text_start, text_end)

  -- checkbox / completed-state consistency
  if not completed_set_valid(config.completed_states) then
    return nil -- unsupported completed_states value
  end
  local complete, valid = completed_of(config.completed_states, state)
  if not valid then
    return nil -- unsupported completed_states value
  end
  if complete ~= checked then
    return nil
  end

  return {
    line = original,
    state = state,
    checked = checked,
    priority = priority,
    text = text,
    done_timestamp = metadata.done,
    due_date = metadata.due,
    spans = {
      checkbox = { cb_s, cb_e },
      state = { st_s - 1, st_e },
      priority = priority and { pr_s, pr_e } or nil,
      done_timestamp = metadata_spans.done,
      due_date = metadata_spans.due,
      text = { text_start - 1, text_end },
    },
  }
end

-- Minimal fenced-code-context helper. Returns (char, length, info) when the
-- line is a code fence delimiter, else nil.
local function fence_delim(line)
  local s = line:gsub("\r$", "")
  local indent = #(s:match("^( *)") or "")
  if indent > 3 then
    return nil
  end
  local body = s:sub(indent + 1)
  local ticks = body:match("^(`+)")
  if ticks and #ticks >= 3 then
    local info = body:sub(#ticks + 1)
    if info:find("`") then
      return nil
    end
    return "`", #ticks, info
  end
  local tildes = body:match("^(~+)")
  if tildes and #tildes >= 3 then
    return "~", #tildes, body:sub(#tildes + 1)
  end
  return nil
end

-- Shared fence walk used by scan_lines and row_fenced. Returns a map from
-- zero-based row to true when the row lies inside (or is a delimiter of) a
-- fenced code block.
local function fence_map(lines)
  local map = {}
  local fence_char, fence_len = nil, 0
  for i, line in ipairs(lines or {}) do
    local ch, len, info = fence_delim(line)
    if fence_char then
      map[i - 1] = true
      if ch == fence_char and len >= fence_len and (info or ""):match("^%s*$") then
        fence_char, fence_len = nil, 0
      end
    elseif ch then
      map[i - 1] = true
      fence_char, fence_len = ch, len
    else
      map[i - 1] = false
    end
  end
  return map
end

-- Scan a list of lines for tasks, applying the same parse() as the interactive
-- commands. Lines inside fenced code blocks are skipped so documentation
-- examples are never treated as real tasks. Returns a list of
-- { row, line, task } with zero-based rows.
function M.scan_lines(lines, config)
  local out = {}
  local map = fence_map(lines)
  for i, line in ipairs(lines or {}) do
    if not map[i - 1] then
      local task = M.parse(line, config)
      if task then
        out[#out + 1] = { row = i - 1, line = line, task = task }
      end
    end
  end
  return out
end

-- True when the zero-based `row` is inside (or is) a fenced code block,
-- using the same scan as scan_lines.
function M.row_fenced(lines, row)
  if type(lines) ~= "table" or type(row) ~= "number" then
    return false
  end
  return fence_map(lines)[row] == true
end

return M
