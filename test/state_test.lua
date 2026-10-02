local H = require("harness")
local task = require("tino.task")
local md = require("tino")

local config = {
  states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
  priorities = { "A", "B", "C" },
  completed_states = { DONE = true, CANCELLED = true },
  done_timestamp = true,
}

local function make_buf(line)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].modifiable = true
  if line then
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { line })
  end
  return b
end

local function get(b)
  return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
end

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

local TS_PAT = " @done%(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d%)$"
local TS = " @done%(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d%)"

H.describe("task.set_state", function()
  H.it("sets DONE directly from every existing state", function()
    local from = {
      { "- [ ] TODO x", "- [x] DONE x" },
      { "- [ ] DOING x", "- [x] DONE x" },
      { "- [ ] WAITING x", "- [x] DONE x" },
      { "- [x] DONE x @done(2026-10-01 13:15)", "- [x] DONE x @done(2026-10-01 13:15)" },
      { "- [x] CANCELLED x @done(2026-10-01 13:15)", "- [x] DONE x @done(2026-10-01 13:15)" },
    }
    for _, case in ipairs(from) do
      local b = make_buf(case[1])
      H.assert(task.set_state(b, 0, "DONE", config), "set DONE from: " .. case[1])
      local fresh = case[1]:match(TS_PAT) == nil
      if fresh then
        H.eq(get(b):sub(1, #case[2]), case[2], "prefix: " .. get(b))
        H.assert(get(b):match(TS_PAT), "timestamp present: " .. get(b))
      else
        H.eq(get(b), case[2], "retained timestamp")
      end
    end
  end)

  H.it("sets TODO directly from every existing state", function()
    local from = {
      { "- [ ] TODO x", "- [ ] TODO x" },
      { "- [ ] DOING x", "- [ ] TODO x" },
      { "- [ ] WAITING x", "- [ ] TODO x" },
      { "- [x] DONE x @done(2026-10-01 13:15)", "- [ ] TODO x" },
      { "- [x] CANCELLED x @done(2026-10-01 13:15)", "- [ ] TODO x" },
    }
    for _, case in ipairs(from) do
      local b = make_buf(case[1])
      H.assert(task.set_state(b, 0, "TODO", config), "set TODO from: " .. case[1])
      H.eq(get(b), case[2], "reference")
    end
  end)

  H.it("bypasses cycle order in both directions", function()
    local b = make_buf("- [x] CANCELLED x @done(2026-10-01 13:15)")
    H.assert(task.set_state(b, 0, "TODO", config))
    H.eq(get(b), "- [ ] TODO x", "CANCELLED -> TODO skips the cycle order")

    local b2 = make_buf("- [ ] WAITING x")
    H.assert(task.set_state(b2, 0, "DONE", config))
    H.assert(get(b2):match("^%- %[x%] DONE x" .. TS_PAT), "WAITING -> DONE, got: " .. get(b2))
  end)

  H.it("keeps the checkbox consistent with the completed role", function()
    local b = make_buf("- [ ] DOING x")
    H.assert(task.set_state(b, 0, "CANCELLED", config))
    H.assert(get(b):match("^%- %[%-%] CANCELLED x"), "active -> completed checks box")
    H.assert(task.set_state(b, 0, "DOING", config))
    H.eq(get(b), "- [/] DOING x", "completed -> active clears box and timestamp")
  end)

  H.it("normalizes an inconsistent marker/state pair from the state word", function()
    -- Marker claims DONE but the authoritative word is DOING.
    local b = make_buf("- [x] DOING x @done(2026-10-01 13:15)")
    local parsed = task.parse_at(b, 0, config)
    H.eq(parsed.state, "DOING", "state word is authoritative")
    H.assert(task.set_state(b, 0, parsed.state, config))
    H.eq(get(b), "- [/] DOING x", "marker and word resynced from the word")
  end)

  H.it("normalizes marker-only and conflicting lines on a same-state set", function()
    local cases = {
      { "- [~] aspettare risposta", "WAITING", "- [~] WAITING aspettare risposta" },
      { "- [~] TODO prova", "TODO", "- [ ] TODO prova" },
    }
    for _, c in ipairs(cases) do
      local b = make_buf(c[1])
      local parsed = task.parse_at(b, 0, config)
      H.assert(parsed, "expected parsed task: " .. c[1])
      H.eq(parsed.state, c[2], c[1])
      H.assert(task.set_state(b, 0, parsed.state, config), c[1])
      H.eq(get(b), c[3], c[1])
    end
  end)

  H.it("preserves indentation, marker, priority, description and CR", function()
    local b = make_buf("  1. [ ] DOING [#B] Fix it\r")
    H.assert(task.set_state(b, 0, "DONE", config))
    local line = get(b)
    H.assert(line:match("^  1%. %[x%] DONE %[#B%] Fix it" .. TS .. "\r$"), "got: " .. line)
  end)

  H.it("is idempotent and never duplicates the managed timestamp", function()
    local b = make_buf("- [ ] TODO x")
    H.assert(task.set_state(b, 0, "DONE", config))
    local first = get(b)
    H.assert(first:match(TS_PAT), "timestamp added")
    H.assert(task.set_state(b, 0, "DONE", config))
    H.eq(get(b), first, "second set DONE is a no-op")
    local count = select(2, get(b):gsub("@done%(", "@done%("))
    H.eq(count, 1, "exactly one timestamp")
  end)

  H.it("honors done_timestamp=false", function()
    local cfg = vim.tbl_extend("force", config, { done_timestamp = false })
    local b = make_buf("- [ ] TODO x")
    H.assert(task.set_state(b, 0, "DONE", cfg))
    H.eq(get(b), "- [x] DONE x", "no timestamp added")
    -- An existing timestamp is still removed on the way back to an active state.
    local b2 = make_buf("- [x] DONE x @done(2026-10-01 13:15)")
    H.assert(task.set_state(b2, 0, "TODO", cfg))
    H.eq(get(b2), "- [ ] TODO x", "timestamp removed going active")
  end)

  H.it("refuses an unknown target and leaves the line unchanged", function()
    local b = make_buf("- [ ] TODO x")
    local notices = with_notify(function()
      H.eq(task.set_state(b, 0, "NOPE", config), false)
      H.eq(task.set_state(b, 0, 42, config), false)
    end)
    H.eq(get(b), "- [ ] TODO x")
    H.assert(#notices >= 2, "expected notifications")
  end)

  H.it("refuses non-task lines, including keyword-only forms", function()
    for _, line in ipairs({
      "hello world",
      "- TODO x", -- keyword-only, not a task
      "- [ ]TODOx y", -- no separator before text
    }) do
      local b = make_buf(line)
      local notices = with_notify(function()
        H.eq(task.set_state(b, 0, "DONE", config), false, "refused: " .. line)
      end)
      H.eq(get(b), line, "unchanged: " .. line)
      H.assert(#notices > 0, "notified: " .. line)
    end
  end)

  H.it("refuses fenced, readonly and non-modifiable buffers", function()
    local lines = { "```", "- [ ] TODO hidden", "```" }
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    with_notify(function()
      H.eq(task.set_state(b, 1, "DONE", config), false)
    end)
    H.eq(vim.api.nvim_buf_get_lines(b, 1, 2, false)[1], "- [ ] TODO hidden")

    local ro = make_buf("- [ ] TODO x")
    vim.bo[ro].readonly = true
    with_notify(function()
      H.eq(task.set_state(ro, 0, "DONE", config), false)
    end)
    H.eq(get(ro), "- [ ] TODO x")

    local nomod = make_buf("- [ ] TODO x")
    vim.bo[nomod].modifiable = false
    with_notify(function()
      H.eq(task.set_state(nomod, 0, "DONE", config), false)
    end)
    H.eq(get(nomod), "- [ ] TODO x")
  end)
end)

H.describe("task.set_done / task.set_todo", function()
  H.it("set_done targets the literal DONE token", function()
    local b = make_buf("- [ ] WAITING x")
    H.assert(task.set_done(b, 0, config))
    H.assert(get(b):match("^%- %[x%] DONE x" .. TS_PAT), "got: " .. get(b))
  end)

  H.it("set_todo targets the literal TODO token", function()
    local b = make_buf("- [x] CANCELLED x @done(2026-10-01 13:15)")
    H.assert(task.set_todo(b, 0, config))
    H.eq(get(b), "- [ ] TODO x")
  end)

  H.it("refuses when the literal token is not configured", function()
    local cfg = vim.tbl_extend("force", config, {
      states = { "OPEN", "CLOSED" },
      completed_states = { CLOSED = true },
    })
    local b = make_buf("- [ ] OPEN x")
    local notices = with_notify(function()
      H.eq(task.set_done(b, 0, cfg), false)
      H.eq(task.set_todo(b, 0, cfg), false)
    end)
    H.eq(get(b), "- [ ] OPEN x")
    H.assert(#notices >= 2, "expected notifications")
  end)

  H.it("refuses when the completion role contradicts the command", function()
    -- DONE configured as an active state.
    local done_active = vim.tbl_extend("force", config, {
      completed_states = { CANCELLED = true },
    })
    local b = make_buf("- [ ] TODO x")
    with_notify(function()
      H.eq(task.set_done(b, 0, done_active), false)
    end)
    H.eq(get(b), "- [ ] TODO x")

    -- TODO configured as a completed state.
    local todo_completed = vim.tbl_extend("force", config, {
      states = { "TODO", "DOING", "DONE" },
      completed_states = { TODO = true, DONE = true },
    })
    local b2 = make_buf("- [x] TODO x")
    with_notify(function()
      H.eq(task.set_todo(b2, 0, todo_completed), false)
    end)
    H.eq(get(b2), "- [x] TODO x")
  end)
end)

H.describe("TinoDone / TinoTodo commands", function()
  local function fresh()
    vim.g.tino_commands_registered = nil
    md.config = {
      states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
      priorities = { "A", "B", "C" },
      completed_states = { DONE = true, CANCELLED = true },
      done_timestamp = true,
      roots = {},
      inbox = nil,
    }
    md.setup()
  end

  local function run(cmd, line)
    local b = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { line })
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd(cmd)
    return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  end

  H.it("registers both direct commands", function()
    fresh()
    H.eq(vim.fn.exists(":TinoDone"), 2, "TinoDone exists")
    H.eq(vim.fn.exists(":TinoTodo"), 2, "TinoTodo exists")
    H.eq(vim.fn.exists(":TinoDoneTask"), 0, "no legacy alias")
  end)

  H.it("TinoDone mutates the current line to DONE", function()
    fresh()
    local line = run("TinoDone", "- [ ] DOING finish")
    H.assert(line:match("^%- %[x%] DONE finish" .. TS_PAT), "got: " .. line)
  end)

  H.it("TinoTodo mutates the current line to TODO", function()
    fresh()
    local line = run("TinoTodo", "- [x] DONE finish @done(2026-10-01 13:15)")
    H.eq(line, "- [ ] TODO finish")
  end)

  H.it("TinoTodo promotes plain text on the current line to a TODO task", function()
    fresh()
    H.eq(run("TinoTodo", "test"), "- [ ] TODO test")
  end)

  H.it("TinoTodo normalizes marker-only tasks to their inferred state", function()
    fresh()
    local cases = {
      { "- [ ] test", "- [ ] TODO test" },
      { "- [/] test", "- [/] DOING test" },
      { "- [~] test", "- [~] WAITING test" },
      { "- [x] test", "- [x] DONE test" },
      { "- [-] test", "- [-] CANCELLED test" },
      { "- [X] test", "- [x] DONE test" },
    }
    for _, case in ipairs(cases) do
      H.eq(run("TinoTodo", case[1]), case[2])
    end
  end)

  H.it("TinoDone leaves non-task lines untouched", function()
    fresh()
    H.eq(run("TinoDone", "- DONE prose"), "- DONE prose")
  end)
end)

H.describe("TinoState command", function()
  local TS_PAT = " @done%(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d%)$"

  local function fresh()
    vim.g.tino_commands_registered = nil
    md.config = {
      states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
      priorities = { "A", "B", "C" },
      completed_states = { DONE = true, CANCELLED = true },
      done_timestamp = true,
      roots = {},
      inbox = nil,
    }
    md.setup()
  end

  -- Stub the one-key prompt; `key` is the returned keypress. `nil` models an
  -- interrupt (Ctrl-C), while "\27" models Esc. `on_read`, when given, runs
  -- inside the read so the visible state during the prompt can be inspected.
  -- Returns the number of reads.
  local function with_key(key, fn, on_read)
    local orig = vim.fn.getcharstr
    local reads = 0
    vim.fn.getcharstr = function()
      reads = reads + 1
      if on_read then
        on_read()
      end
      if key == nil then
        error("Vim:Interrupt")
      end
      return key
    end
    local ok, err = pcall(fn)
    vim.fn.getcharstr = orig
    if not ok then
      error(err, 2)
    end
    return reads
  end

  -- All currently open floating windows with their buffer text.
  local function floating_wins()
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= "" then
        out[#out + 1] = {
          win = w,
          cfg = cfg,
          text = table.concat(
            vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false),
            "\n"
          ),
        }
      end
    end
    return out
  end

  local function run(key, line)
    local b = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { line })
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    with_key(key, function()
      vim.cmd("TinoState")
    end)
    return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  end

  H.it("registers TinoState", function()
    fresh()
    H.eq(vim.fn.exists(":TinoState"), 2, "TinoState exists")
  end)

  H.it("directly sets the chosen state on an existing task", function()
    fresh()
    local full = "- [x] DONE [#B] fix bug @owner(alice) @due(2026-02-01) @done(2026-10-01 13:15)"
    local cases = {
      -- Direct choice from a completed task to every active state: the managed
      -- timestamp is dropped, the marker/word resynced, text/priority/due and
      -- the unrelated @owner token all retained.
      { "t", full, "- [ ] TODO [#B] fix bug @owner(alice) @due(2026-02-01)" },
      { "d", full, "- [/] DOING [#B] fix bug @owner(alice) @due(2026-02-01)" },
      { "w", full, "- [~] WAITING [#B] fix bug @owner(alice) @due(2026-02-01)" },
      -- Completed -> completed keeps the existing timestamp verbatim.
      { "c", full, "- [-] CANCELLED [#B] fix bug @owner(alice) @due(2026-02-01) @done(2026-10-01 13:15)" },
      -- Same-state DONE is idempotent and keeps the timestamp verbatim.
      { "x", full, full },
      -- Marker-only task gains its explicit word and canonical marker.
      { "d", "- [~] aspettare risposta", "- [/] DOING aspettare risposta" },
    }
    for _, c in ipairs(cases) do
      H.eq(run(c[1], c[2]), c[3], c[1] .. " from " .. c[2])
    end

    -- Every shortcut resolves with exactly one key read: no Enter confirmation.
    local b = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "- [ ] TODO one read" })
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local reads = with_key("d", function()
      vim.cmd("TinoState")
    end)
    H.eq(reads, 1, "exactly one key read")
    H.eq(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1], "- [/] DOING one read")

    -- Active -> DONE appends exactly one fresh managed timestamp.
    local done = run("x", "- [/] DOING [#B] fix bug @due(2026-02-01)")
    H.assert(done:match("^%- %[x%] DONE %[#B%] fix bug @due%(2026%-02%-01%)" .. TS_PAT),
      "got: " .. done)
  end)

  H.it("promotes plain text directly into the chosen state", function()
    fresh()
    H.eq(run("t", "write docs"), "- [ ] TODO write docs")
    H.eq(run("d", "write docs"), "- [/] DOING write docs")
    H.eq(run("w", "  indented"), "  - [~] WAITING indented")
    for _, c in ipairs({ { "x", "DONE" }, { "c", "CANCELLED" } }) do
      local line = run(c[1], "ship it")
      H.assert(line:match("^%- %[[x%-]%] " .. c[2] .. " ship it" .. TS_PAT), "got: " .. line)
    end

    -- done_timestamp disabled: a completed target gets no timestamp.
    vim.g.tino_commands_registered = nil
    md.config = {
      states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
      priorities = { "A", "B", "C" },
      completed_states = { DONE = true, CANCELLED = true },
      done_timestamp = false,
      roots = {},
      inbox = nil,
    }
    md.setup()
    H.eq(run("x", "no ts"), "- [x] DONE no ts")
  end)

  H.it("leaves non-task, blank and list lines untouched", function()
    fresh()
    for _, line in ipairs({ "", "   ", "- [ ]TODOx y", "1. ordered item" }) do
      H.eq(run("d", line), line, "untouched: " .. vim.inspect(line))
    end
  end)

  H.it("shows a bordered floating box during the single key read and closes it", function()
    fresh()
    local b = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "- [ ] TODO popup" })
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local during
    local reads = with_key("d", function()
      vim.cmd("TinoState")
    end, function()
      during = floating_wins()
    end)

    H.eq(reads, 1, "exactly one key read")
    H.eq(#during, 1, "one floating box during the read")
    local box = during[1]
    H.assert(box.cfg.border and box.cfg.border ~= "none", "box has a border")
    H.eq(box.cfg.focusable, false, "box is non-focusable")
    for _, token in ipairs({ "TODO", "DOING", "WAITING", "DONE", "CANCELLED" }) do
      H.assert(box.text:find(token, 1, true), token .. " listed in the box")
    end
    H.eq(vim.api.nvim_get_current_buf(), b, "source buffer stays current")
    -- The box is gone before the chosen state is applied.
    H.eq(#floating_wins(), 0, "box closed after selection")
    H.eq(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1], "- [/] DOING popup")

    -- Interrupt path also tears the box down and edits nothing.
    local b2 = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "- [ ] TODO keep" })
    vim.api.nvim_set_current_buf(b2)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    with_key(nil, function()
      vim.cmd("TinoState")
    end)
    H.eq(#floating_wins(), 0, "box closed after interrupt")
    H.eq(vim.api.nvim_buf_get_lines(b2, 0, 1, false)[1], "- [ ] TODO keep")
  end)

  H.it("cancellation is a no-op", function()
    fresh()
    -- Esc and an interrupt: no edit.
    H.eq(run("\27", "- [ ] TODO keep"), "- [ ] TODO keep")
    H.eq(run(nil, "- [ ] TODO keep"), "- [ ] TODO keep")
    -- Unrecognised key: no edit.
    H.eq(run("z", "plain text keep"), "plain text keep")
  end)
end)
