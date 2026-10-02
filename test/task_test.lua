local H = require("harness")
local task = require("tino.task")

-- ASCII-safe byte sequences for Unicode fixtures.
local ROCKET = string.char(240, 159, 154, 128) -- U+1F680
local CAFE = "caf" .. string.char(195, 169) -- cafe-acute

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

H.describe("task.cycle_state", function()
  H.it("cycles through every state and back, syncing checkbox/timestamp", function()
    local b = make_buf("- [ ] TODO Fix " .. ROCKET)
    H.assert(task.cycle_state(b, 0, config))
    H.eq(get(b), "- [/] DOING Fix " .. ROCKET, "TODO->DOING")
    H.assert(task.cycle_state(b, 0, config))
    H.eq(get(b), "- [~] WAITING Fix " .. ROCKET, "DOING->WAITING")
    H.assert(task.cycle_state(b, 0, config))
    local done = get(b)
    H.assert(done:match("^%- %[x%] DONE Fix " .. ROCKET .. TS_PAT), "WAITING->DONE: " .. done)
    H.assert(task.cycle_state(b, 0, config))
    local cancelled = get(b)
    H.assert(
      cancelled:match("^%- %[%-%] CANCELLED Fix " .. ROCKET .. TS_PAT),
      "DONE->CANCELLED: " .. cancelled
    )
    H.assert(task.cycle_state(b, 0, config))
    H.eq(get(b), "- [ ] TODO Fix " .. ROCKET, "CANCELLED->TODO")
  end)

  H.it("retains the same timestamp from DONE to CANCELLED", function()
    local b = make_buf("- [ ] TODO x")
    task.cycle_state(b, 0, config) -- DOING
    task.cycle_state(b, 0, config) -- WAITING
    task.cycle_state(b, 0, config) -- DONE
    local ts = get(b):match("@done%(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d%)")
    H.assert(ts, "timestamp added on DONE")
    task.cycle_state(b, 0, config) -- CANCELLED
    H.eq(get(b):match("@done%(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d%)"), ts, "same timestamp kept")
    task.cycle_state(b, 0, config) -- TODO
    H.eq(get(b), "- [ ] TODO x", "timestamp removed on return to active")
  end)

  H.it("does not add a timestamp when done_timestamp is disabled", function()
    local cfg = vim.tbl_extend("force", config, { done_timestamp = false })
    local b = make_buf("- [ ] TODO x")
    task.cycle_state(b, 0, cfg) -- DOING
    task.cycle_state(b, 0, cfg) -- WAITING
    task.cycle_state(b, 0, cfg) -- DONE
    H.eq(get(b), "- [x] DONE x")
    task.cycle_state(b, 0, cfg) -- CANCELLED
    H.eq(get(b), "- [-] CANCELLED x")
  end)

  H.it("preserves priority, marker, indentation and Unicode", function()
    local b = make_buf("  1. [ ] TODO [#B] " .. CAFE .. " " .. ROCKET)
    H.assert(task.cycle_state(b, 0, config))
    H.eq(get(b), "  1. [/] DOING [#B] " .. CAFE .. " " .. ROCKET)
  end)
end)

H.describe("task.cycle_priority", function()
  H.it("cycles none -> A -> B -> C -> none preserving the rest", function()
    local b = make_buf("- [ ] TODO Ship it")
    H.assert(task.cycle_priority(b, 0, config))
    H.eq(get(b), "- [ ] TODO [#A] Ship it")
    H.assert(task.cycle_priority(b, 0, config))
    H.eq(get(b), "- [ ] TODO [#B] Ship it")
    H.assert(task.cycle_priority(b, 0, config))
    H.eq(get(b), "- [ ] TODO [#C] Ship it")
    H.assert(task.cycle_priority(b, 0, config))
    H.eq(get(b), "- [ ] TODO Ship it", "back to no priority")
  end)

  H.it("preserves state, checkbox, timestamp and Unicode", function()
    local b = make_buf("- [x] DONE [#A] " .. CAFE .. " @done(2026-10-01 13:15)")
    H.assert(task.cycle_priority(b, 0, config))
    H.eq(get(b), "- [x] DONE [#B] " .. CAFE .. " @done(2026-10-01 13:15)")
  end)

  H.it("preserves multiple spaces between state and text", function()
    local b = make_buf("- [ ] TODO   spaced")
    H.assert(task.cycle_priority(b, 0, config))
    H.eq(get(b), "- [ ] TODO   [#A] spaced")
    task.cycle_priority(b, 0, config)
    task.cycle_priority(b, 0, config) -- C
    task.cycle_priority(b, 0, config) -- none
    H.eq(get(b), "- [ ] TODO   spaced")
  end)

  H.it("round-trips exact multi-whitespace separators", function()
    for _, line in ipairs({
      "- [ ] TODO    wide",
      "  1. [ ] TODO\tthing",
      "  + [ ] TODO  kept",
      "- [x] DONE [#C] caf" .. CAFE .. " @done(2026-10-01 13:15)",
    }) do
      local b = make_buf(line)
      local original = get(b)
      for _ = 1, #config.priorities + 1 do
        task.cycle_priority(b, 0, config)
      end
      H.eq(get(b), original, "exact roundtrip for " .. original)
    end
  end)

  H.it("removes the cookie and only one adjacent whitespace byte", function()
    local b = make_buf("- [ ] TODO [#C]   wide")
    H.assert(task.cycle_priority(b, 0, config))
    H.eq(get(b), "- [ ] TODO   wide", "two post-cookie spaces preserved")
  end)
end)

H.describe("task fence eligibility", function()
  local function make_lines(lines)
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    return b
  end

  H.it("ignores tasks inside backtick and tilde fences", function()
    local lines = {
      "```markdown",
      "- [ ] TODO hidden",
      "```",
      "~~~",
      "- [x] DONE also hidden",
      "~~~",
      "- [ ] TODO real",
    }
    local b = make_lines(lines)
    H.eq(task.parse_at(b, 1, config), nil, "backtick fence skipped")
    H.eq(task.parse_at(b, 4, config), nil, "tilde fence skipped")
    H.assert(task.parse_at(b, 6, config), "task after closing fence eligible")
  end)

  H.it("refuses to mutate a fenced task and leaves it unchanged", function()
    local b = make_lines({ "```", "- [ ] TODO hidden", "```" })
    local notices = with_notify(function()
      H.eq(task.cycle_state(b, 1, config), false)
      H.eq(task.cycle_priority(b, 1, config), false)
    end)
    H.eq(vim.api.nvim_buf_get_lines(b, 1, 2, false)[1], "- [ ] TODO hidden")
    H.assert(#notices >= 2, "expected notifications")
  end)

  H.it("treats an unclosed fence as hiding the rest of the buffer", function()
    local b = make_lines({ "- [ ] TODO real", "```", "- [ ] TODO hidden" })
    H.assert(task.parse_at(b, 0, config), "task before fence eligible")
    H.eq(task.parse_at(b, 2, config), nil, "unclosed fence hides remainder")
    H.eq(task.cycle_state(b, 2, config), false)
  end)

  H.it("preserves a terminal CR through a state cycle", function()
    local b = make_buf("- [ ] TODO x\r")
    H.assert(task.cycle_state(b, 0, config))
    H.eq(get(b), "- [/] DOING x\r")
  end)
end)

H.describe("task safety", function()
  H.it("makes no change and notifies on an invalid task", function()
    local b = make_buf("hello world")
    local notices = with_notify(function()
      H.eq(task.cycle_state(b, 0, config), false)
    end)
    H.eq(get(b), "hello world")
    H.assert(#notices > 0, "expected a notification")
    H.assert(notices[1].msg:match("not a valid task"), "clean message: " .. tostring(notices[1].msg))
  end)

  H.it("makes no change and notifies on a non-modifiable buffer", function()
    local b = make_buf("- [ ] TODO x")
    vim.bo[b].modifiable = false
    local notices = with_notify(function()
      H.eq(task.cycle_state(b, 0, config), false)
      H.eq(task.cycle_priority(b, 0, config), false)
    end)
    H.eq(get(b), "- [ ] TODO x")
    H.assert(#notices >= 2, "expected notifications")
  end)

  H.it("aborts on a readonly buffer and leaves it unchanged", function()
    local b = make_buf("- [ ] TODO x")
    vim.bo[b].readonly = true
    local notices = with_notify(function()
      H.eq(task.cycle_state(b, 0, config), false)
    end)
    H.eq(get(b), "- [ ] TODO x")
    H.assert(#notices > 0, "expected a notification")
  end)
end)
