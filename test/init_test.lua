local H = require("harness")
local md = require("tino")

local function with_notify(fn)
  local captured = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    captured[#captured + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn, captured)
  vim.notify = orig
  if not ok then
    error(err, 2)
  end
  return captured
end

local function fresh_config()
  vim.g.tino_commands_registered = nil
  md.config = {
    states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
    priorities = { "A", "B", "C" },
    completed_states = { DONE = true, CANCELLED = true },
    done_timestamp = true,
    roots = {},
    inbox = nil,
  }
end

H.describe("configuration", function()
  H.it("exposes validated defaults and registers commands", function()
    fresh_config()
    md.setup()
    H.eq(md.config.states[1], "TODO")
    H.eq(md.config.done_timestamp, true)
    H.eq(md.config.completed_states.DONE, true)
    H.eq(md.config.inbox, nil)
    H.assert(vim.fn.exists(":TinoCycle") == 2, "cycle command exists")
    H.assert(vim.fn.exists(":TinoPriority") == 2, "priority command exists")
    H.assert(vim.fn.exists(":TinoAgenda") == 2, "lazy agenda command exists")
  end)

  H.it("accepts a minimal valid custom setup", function()
    fresh_config()
    local ok = md.setup({
      states = { "OPEN", "DONE" },
      priorities = { "X" },
      completed_states = { "DONE" },
      done_timestamp = false,
      roots = { "/tmp/notes" },
      inbox = "/tmp/notes/inbox.md",
    })
    H.eq(ok, true)
    H.eq(md.config.states[2], "DONE")
    H.eq(md.config.completed_states.DONE, true)
    H.eq(md.config.completed_states.OPEN, nil)
    H.eq(md.config.done_timestamp, false)
    H.eq(md.config.roots[1], "/tmp/notes")
    H.eq(md.config.inbox, "/tmp/notes/inbox.md")
  end)

  H.it("rejects invalid states", function()
    fresh_config()
    with_notify(function()
      H.eq(md.setup({ states = { "todo" } }), false)
      H.eq(md.setup({ states = {} }), false)
      H.eq(md.setup({ states = { "TODO", "TODO" } }), false)
    end)
    H.eq(md.config.states[1], "TODO", "config unchanged on error")
  end)

  H.it("rejects invalid priorities and done_timestamp", function()
    fresh_config()
    with_notify(function()
      H.eq(md.setup({ priorities = { "AB" } }), false)
      H.eq(md.setup({ done_timestamp = "yes" }), false)
      H.eq(md.setup({ completed_states = { "NOPE" } }), false)
    end)
  end)

  H.it("rejects unsupported truthy non-boolean completed-state values", function()
    fresh_config()
    with_notify(function()
      H.eq(md.setup({ completed_states = { DONE = 1 } }), false)
      H.eq(md.setup({ completed_states = { DONE = "yes" } }), false)
    end)
    H.eq(md.config.completed_states.DONE, true, "config unchanged on error")
  end)

  H.it("accepts a boolean false completed-state value", function()
    fresh_config()
    with_notify(function()
      H.eq(md.setup({ completed_states = { DONE = false, CANCELLED = true } }), true)
    end)
    H.eq(md.config.completed_states.DONE, false)
    H.eq(md.config.completed_states.CANCELLED, true)
  end)

  H.it("normalizes ~ roots and inbox using the process HOME", function()
    local stub = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/tmp/home_setup"
    local orig = vim.env.HOME
    vim.env.HOME = stub
    fresh_config()
    local ok = md.setup({ roots = { "~/notes" }, inbox = "~/inbox.md" })
    vim.env.HOME = orig
    H.eq(ok, true)
    H.eq(md.config.roots[1], stub .. "/notes")
    H.eq(md.config.inbox, stub .. "/inbox.md")
  end)

  H.it("rejects a completed first state (capture default must be active)", function()
    fresh_config()
    with_notify(function()
      H.eq(md.setup({ states = { "DONE", "TODO" }, completed_states = { "DONE" } }), false)
    end)
  end)
end)

H.describe("command registration", function()
  local required = { "TinoCycle", "TinoPriority", "TinoDone", "TinoTodo", "TinoDue", "TinoCapture", "TinoAgenda", "TinoRefile" }

  H.it("registers exactly the required commands and no legacy aliases", function()
    fresh_config()
    H.eq(md.setup(), true)
    for _, name in ipairs(required) do
      H.eq(vim.fn.exists(":" .. name), 2, name .. " exists")
    end
    H.eq(vim.fn.exists(":TinoCycleState"), 0, "no legacy cycle-state command")
    H.eq(vim.fn.exists(":TinoCyclePriority"), 0, "no legacy cycle-priority command")
  end)

  H.it("is idempotent across repeated setup calls", function()
    fresh_config()
    H.eq(md.setup(), true)
    H.eq(md.setup({ done_timestamp = false }), true)
    H.eq(md.config.done_timestamp, false)
    for _, name in ipairs(required) do
      H.eq(vim.fn.exists(":" .. name), 2, name .. " still exists")
    end
  end)

  H.it("TinoCycle mutates the task on the current line", function()
    fresh_config()
    md.setup()
    local b = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "- [ ] TODO command cycle" })
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("TinoCycle")
    H.eq(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1], "- [ ] DOING command cycle")
  end)

  H.it("TinoPriority mutates the task on the current line", function()
    fresh_config()
    md.setup()
    local b = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "- [ ] TODO command priority" })
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("TinoPriority")
    H.eq(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1], "- [ ] TODO [#A] command priority")
  end)
end)

H.describe("namespace", function()
  H.it("resolves require('tino') and require('tino.*')", function()
    local modules = {
      "tino",
      "tino.files",
      "tino.parser",
      "tino.date",
      "tino.task",
      "tino.highlight",
      "tino.capture",
      "tino.agenda",
      "tino.refile",
    }
    for _, mod in ipairs(modules) do
      H.eq(type(require(mod)), "table", mod .. " resolves")
    end
  end)
end)

H.describe("plugin bootstrap", function()
  local plugin_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    .. "/plugin/tino.lua"

  H.it("registers Tino commands and sets the loaded guard", function()
    vim.g.loaded_tino = nil
    vim.g.tino_commands_registered = nil
    vim.cmd("source " .. vim.fn.fnameescape(plugin_path))
    H.eq(vim.g.loaded_tino, 1, "bootstrap sets loaded guard")
    for _, name in ipairs({ "TinoCycle", "TinoPriority", "TinoDone", "TinoTodo", "TinoDue", "TinoCapture", "TinoAgenda", "TinoRefile" }) do
      H.eq(vim.fn.exists(":" .. name), 2, "bootstrap registers " .. name)
    end
  end)

  H.it("is idempotent via the loaded guard", function()
    vim.g.loaded_tino = 1
    local ok = pcall(vim.cmd, "source " .. vim.fn.fnameescape(plugin_path))
    H.eq(ok, true, "re-sourcing is a no-op")
    H.eq(vim.g.loaded_tino, 1, "loaded guard preserved")
  end)
end)
