-- tino: configuration, validation and command bootstrap.

local files = require("tino.files")
local M = {}

M.config = {
  states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
  priorities = { "A", "B", "C" },
  completed_states = { DONE = true, CANCELLED = true },
  done_timestamp = true,
  roots = {},
  inbox = nil,
  agenda = { include_completed = false },
}

local function is_list_of_strings(v)
  if type(v) ~= "table" then
    return false
  end
  for k, item in pairs(v) do
    if type(k) ~= "number" or type(item) ~= "string" then
      return false
    end
  end
  return true
end

local function set_from(list_or_set)
  local set = {}
  if type(list_or_set) == "table" then
    for k, v in pairs(list_or_set) do
      if type(k) == "number" then
        set[v] = true
      else
        set[k] = v
      end
    end
  end
  return set
end

local function valid_state_token(s)
  return type(s) == "string" and s:match("^[A-Z][A-Z0-9_%-]*$") ~= nil
end

-- Validate and merge user options, then register commands. Returns true on
-- success, false after a clean vim.notify on invalid input.
function M.setup(opts)
  opts = opts or {}
  local cfg = M.config

  local function err(msg)
    vim.notify("tino: " .. msg, vim.log.levels.ERROR)
    return false
  end

  local states = cfg.states
  if opts.states ~= nil then
    if not is_list_of_strings(opts.states) or #opts.states == 0 then
      return err("invalid states: expected a non-empty list of strings")
    end
    local seen = {}
    for _, s in ipairs(opts.states) do
      if not valid_state_token(s) then
        return err("invalid state token: " .. tostring(s))
      end
      if seen[s] then
        return err("duplicate state: " .. s)
      end
      seen[s] = true
    end
    states = vim.deepcopy(opts.states)
  end

  local priorities = cfg.priorities
  if opts.priorities ~= nil then
    if not is_list_of_strings(opts.priorities) or #opts.priorities == 0 then
      return err("invalid priorities: expected a non-empty list of letters")
    end
    local seen = {}
    for _, p in ipairs(opts.priorities) do
      if not p:match("^[A-Z]$") then
        return err("invalid priority letter: " .. tostring(p))
      end
      if seen[p] then
        return err("duplicate priority: " .. p)
      end
      seen[p] = true
    end
    priorities = vim.deepcopy(opts.priorities)
  end

  local completed = set_from(cfg.completed_states)
  if opts.completed_states ~= nil then
    if type(opts.completed_states) ~= "table" then
      return err("invalid completed_states: expected a table")
    end
    completed = set_from(opts.completed_states)
    for st, v in pairs(completed) do
      if type(v) ~= "boolean" then
        return err("invalid completed_states value for " .. tostring(st) .. ": expected a boolean")
      end
      local found = false
      for _, s in ipairs(states) do
        if s == st then
          found = true
          break
        end
      end
      if not found then
        return err("completed state not in states: " .. tostring(st))
      end
    end
  end

  local done_timestamp = cfg.done_timestamp
  if opts.done_timestamp ~= nil then
    if type(opts.done_timestamp) ~= "boolean" then
      return err("invalid done_timestamp: expected a boolean")
    end
    done_timestamp = opts.done_timestamp
  end

  local roots = cfg.roots
  if opts.roots ~= nil then
    if not is_list_of_strings(opts.roots) then
      return err("invalid roots: expected a list of paths")
    end
    roots = {}
    for _, r in ipairs(opts.roots) do
      local p = files.normalize(r)
      if not p then
        return err("invalid root path: " .. tostring(r))
      end
      roots[#roots + 1] = p
    end
  end

  local inbox = cfg.inbox
  if opts.inbox ~= nil then
    if type(opts.inbox) ~= "string" then
      return err("invalid inbox: expected a path string")
    end
    local p = files.normalize(opts.inbox)
    if not p then
      return err("invalid inbox path: " .. tostring(opts.inbox))
    end
    inbox = p
  end

  local agenda = cfg.agenda or { include_completed = false }
  if opts.agenda ~= nil then
    if type(opts.agenda) ~= "table" then
      return err("invalid agenda: expected a table")
    end
    if opts.agenda.include_completed ~= nil and type(opts.agenda.include_completed) ~= "boolean" then
      return err("invalid agenda.include_completed: expected a boolean")
    end
    agenda = { include_completed = opts.agenda.include_completed == true }
  end

  if completed[states[1]] then
    return err("first configured state must be an active (non-completed) state")
  end

  cfg.states = states
  cfg.priorities = priorities
  cfg.completed_states = completed
  cfg.done_timestamp = done_timestamp
  cfg.roots = roots
  cfg.inbox = inbox
  cfg.agenda = agenda

  M._register_commands()
  local ok, hl = pcall(require, "tino.highlight")
  if ok and type(hl) == "table" and type(hl.setup) == "function" then
    hl.setup()
  end
  return true
end

local function current_row()
  return math.max(vim.fn.line(".") - 1, 0)
end

-- User commands. Cycle commands are fully implemented here; later-phase
-- commands are lazy and resolve their module on demand.
function M._register_commands()
  if vim.g.tino_commands_registered then
    return
  end
  vim.g.tino_commands_registered = true

  vim.api.nvim_create_user_command("TinoCycle", function()
    require("tino.task").cycle_state(0, current_row())
  end, { desc = "tino: cycle task state" })

  vim.api.nvim_create_user_command("TinoPriority", function()
    require("tino.task").cycle_priority(0, current_row())
  end, { desc = "tino: cycle task priority" })

  vim.api.nvim_create_user_command("TinoDone", function()
    require("tino.task").set_done(0, current_row())
  end, { desc = "tino: mark task DONE" })

  vim.api.nvim_create_user_command("TinoTodo", function()
    require("tino.task").set_todo(0, current_row())
  end, { desc = "tino: mark task TODO" })

  vim.api.nvim_create_user_command("TinoDue", function()
    require("tino.task").prompt_due(0, current_row())
  end, { desc = "tino: set or remove task deadline" })

  local lazy = {
    TinoCapture = "tino.capture",
    TinoAgenda = "tino.agenda",
    TinoRefile = "tino.refile",
  }
  for name, mod in pairs(lazy) do
    vim.api.nvim_create_user_command(name, function()
      local ok, m = pcall(require, mod)
      if not ok or type(m) ~= "table" or type(m.run) ~= "function" then
        vim.notify("tino: " .. name .. " is not available yet", vim.log.levels.WARN)
        return
      end
      m.run()
    end, { desc = "tino: " .. name })
  end
end

return M
