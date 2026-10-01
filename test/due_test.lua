local H = require("harness")
local parser = require("tino.parser")
local dates = require("tino.date")
local task = require("tino.task")
local md = require("tino")

local config = {
  states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
  priorities = { "A", "B", "C" },
  completed_states = { DONE = true, CANCELLED = true },
  done_timestamp = true,
}

local function make_buf(line)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  return buf
end

local function get(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
end

local function quiet(fn)
  local original = vim.notify
  vim.notify = function() end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then error(err, 2) end
end

local function with_input(value, fn)
  local original = vim.ui.input
  local options
  vim.ui.input = function(opts, cb)
    options = opts
    cb(value)
  end
  local ok, err = pcall(fn, function() return options end)
  vim.ui.input = original
  if not ok then error(err, 2) end
end

H.describe("deadline dates", function()
  H.it("normalizes every accepted input against the local calendar", function()
    local cases = {
      { "2024-02-29", "2024-02-29" },
      { " today ", "2024-02-28" },
      { "tomorrow", "2024-02-29" },
      { "+0d", "2024-02-28" },
      { "+2d", "2024-03-01" },
      { "+2w", "2024-03-13" },
      { "  ", "" },
    }
    for _, case in ipairs(cases) do
      H.eq(dates.normalize(case[1], "2024-02-28"), case[2], case[1])
    end
    H.eq(dates.normalize("+1w", "2024-12-28"), "2025-01-04")
    H.eq(dates.normalize("+1d", "2024-03-10"), "2024-03-11", "DST calendar day")
    H.eq(dates.normalize("today"), os.date("%Y-%m-%d"))
  end)

  H.it("rejects invalid Gregorian dates and unsupported inputs", function()
    for _, value in ipairs({
      "2023-02-29", "2100-02-29", "0000-01-01", "2024-04-31", "2024-13-01",
      "2024-01-00", "2024-1-1", "next week", "-1d", "+1m", "+1.5d", "+999999999w",
    }) do
      local date, err = dates.normalize(value, "2024-01-01")
      H.eq(date, nil, value)
      H.assert(err, "validation error")
    end
    H.eq(dates.normalize("tomorrow", "9999-12-31"), nil, "four-digit year limit")
    H.eq(dates.normalize(nil), nil)
    H.assert(parser.valid_date("2000-02-29"))
  end)
end)

H.describe("deadline parser", function()
  H.it("parses a deadline and completion timestamp in either order with exact spans", function()
    local due, done = "@due(2024-02-29)", "@done(2024-02-28 10:30)"
    for _, suffix in ipairs({ due .. "\t" .. done, done .. "  " .. due }) do
      local line = "  1. [x] DONE [#B] café  text " .. suffix .. " \t\r"
      local parsed = parser.parse(line, config)
      H.assert(parsed)
      H.eq(parsed.text, "café  text")
      H.eq(parsed.due_date, "2024-02-29")
      H.eq(parsed.done_timestamp, "2024-02-28 10:30")
      H.eq(parsed.line, line)
      H.eq(line:sub(parsed.spans.due_date[1] + 1, parsed.spans.due_date[2]), due)
      H.eq(line:sub(parsed.spans.done_timestamp[1] + 1, parsed.spans.done_timestamp[2]), done)
    end
    local parsed = parser.parse("- [ ] TODO text " .. due, config)
    H.eq(parsed.due_date, "2024-02-29")
    H.eq(parsed.done_timestamp, nil)
  end)

  H.it("rejects malformed, invalid, duplicate or description-only deadlines", function()
    for _, line in ipairs({
      "- [ ] TODO x @due(2024-02-30)",
      "- [ ] TODO x @due(tomorrow)",
      "- [ ] TODO x @due(2024-02-29",
      "- [ ] TODO x @due()",
      "- [ ] TODO x @due(2024-02-29) @due(2024-03-01)",
      "- [x] DONE x @due(2024-02-29) @done(2024-01-01 10:00) @due(2024-03-01)",
      "- [ ] TODO @due(2024-02-29)",
    }) do
      H.eq(parser.parse(line, config), nil, line)
    end
  end)

  H.it("keeps embedded prose and existing custom-state rules unchanged", function()
    local line = "- [ ] TODO see @due(abc) and @done(abc) docs"
    local parsed = parser.parse(line, config)
    H.eq(parsed.text, "see @due(abc) and @done(abc) docs")
    H.eq(parsed.due_date, nil)
    H.eq(parser.parse("- [x] DONE x @done(abc) @done(2024-01-01 10:00)", config).text, "x @done(abc)")
    local custom = { states = { "OPEN", "CLOSED" }, priorities = { "H" }, completed_states = { "CLOSED" } }
    H.eq(parser.parse("- [ ] OPEN [#H] work @due(2024-02-29)", custom).due_date, "2024-02-29")
    H.eq(parser.parse("- [ ] CLOSED work @due(2024-02-29)", custom), nil)
  end)
end)

H.describe("deadline edits", function()
  H.it("sets, replaces and removes a deadline without changing other bytes", function()
    local body = "\t1) [x] DONE [#B] café  prose @other(x)\t@done(2024-02-28 10:30)"
    local tail = "  \r"
    local buf = make_buf(body .. tail)
    H.assert(task.set_due(buf, 0, "2024-02-29", config))
    H.eq(get(buf), body .. " @due(2024-02-29)" .. tail)
    H.assert(task.set_due(buf, 0, "2024-03-01", config))
    H.eq(get(buf), body .. " @due(2024-03-01)" .. tail)
    H.assert(task.set_due(buf, 0, "", config))
    H.eq(get(buf), body .. tail)
    H.assert(task.set_due(buf, 0, "", config), "removing an absent deadline is harmless")
    H.eq(get(buf), body .. tail)
  end)

  H.it("removes a deadline before @done while preserving other separators", function()
    local buf = make_buf("- [x] DONE text  @due(2024-02-29) \t@done(2024-02-28 10:30)  ")
    H.assert(task.set_due(buf, 0, "", config))
    H.eq(get(buf), "- [x] DONE text  \t@done(2024-02-28 10:30)  ")
  end)

  H.it("preserves deadlines through state and priority changes in either metadata order", function()
    local buf = make_buf("- [ ] WAITING text @due(2024-02-29)")
    H.assert(task.cycle_state(buf, 0, config))
    local parsed = parser.parse(get(buf), config)
    H.eq(parsed.state, "DONE")
    H.eq(parsed.due_date, "2024-02-29")
    H.assert(parsed.done_timestamp)
    H.assert(task.cycle_priority(buf, 0, config))
    H.eq(parser.parse(get(buf), config).due_date, "2024-02-29")
    H.assert(task.set_todo(buf, 0, config))
    H.eq(get(buf), "- [ ] TODO [#A] text @due(2024-02-29)")
    local reversed = make_buf("- [x] DONE text @done(2024-02-28 10:30) @due(2024-02-29)")
    H.assert(task.set_todo(reversed, 0, config))
    H.eq(get(reversed), "- [ ] TODO text @due(2024-02-29)")
  end)

  H.it("rejects invalid input, non-tasks, fences and non-editable buffers without changes", function()
    quiet(function()
      local buf = make_buf("- [ ] TODO keep")
      H.eq(task.set_due(buf, 0, "2024-02-30", config), false)
      H.eq(get(buf), "- [ ] TODO keep")
      local prose = make_buf("not a task")
      H.eq(task.set_due(prose, 0, "today", config), false)
      H.eq(get(prose), "not a task")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```", "- [ ] TODO keep", "```" })
      H.eq(task.set_due(buf, 1, "today", config), false)
      H.eq(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1], "- [ ] TODO keep")
      local readonly = make_buf("- [ ] TODO keep")
      vim.bo[readonly].readonly = true
      H.eq(task.set_due(readonly, 0, "today", config), false)
      H.eq(get(readonly), "- [ ] TODO keep")
      vim.bo[readonly].readonly = false
      vim.bo[readonly].modifiable = false
      H.eq(task.set_due(readonly, 0, "", config), false)
      H.eq(get(readonly), "- [ ] TODO keep")
    end)
  end)
end)

H.describe("TinoDue prompt", function()
  H.it("prompts on the current task, normalizes input and removes on blank", function()
    md.config = vim.deepcopy(config)
    md._register_commands()
    local buf = make_buf("- [ ] TODO current")
    vim.api.nvim_set_current_buf(buf)
    with_input("today", function(options)
      vim.cmd("TinoDue")
      H.assert(options().prompt:find("Due", 1, true))
    end)
    H.eq(parser.parse(get(buf), config).due_date, os.date("%Y-%m-%d"))
    with_input("", function(options)
      vim.cmd("TinoDue")
      H.eq(options().default, os.date("%Y-%m-%d"))
    end)
    H.eq(get(buf), "- [ ] TODO current")
  end)

  H.it("cancellation and invalid input leave the task unchanged", function()
    local buf = make_buf("- [ ] TODO keep @due(2024-02-29)")
    with_input(nil, function() task.prompt_due(buf, 0, config) end)
    H.eq(get(buf), "- [ ] TODO keep @due(2024-02-29)")
    quiet(function()
      with_input("2024-02-30", function() task.prompt_due(buf, 0, config) end)
    end)
    H.eq(get(buf), "- [ ] TODO keep @due(2024-02-29)")
  end)

  H.it("keeps the original buffer target and refuses a task changed while prompting", function()
    local original = vim.ui.input
    local callback
    vim.ui.input = function(_, cb) callback = cb end
    local ok, err = pcall(function()
      local buf = make_buf("- [ ] TODO original")
      vim.api.nvim_set_current_buf(buf)
      task.prompt_due(0, 0, config)
      local other = make_buf("- [ ] TODO other")
      vim.api.nvim_set_current_buf(other)
      callback("2024-02-29")
      H.eq(get(buf), "- [ ] TODO original @due(2024-02-29)")
      H.eq(get(other), "- [ ] TODO other")
      task.prompt_due(buf, 0, config)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- [ ] TODO changed" })
      quiet(function() callback("2024-03-01") end)
      H.eq(get(buf), "- [ ] TODO changed")
    end)
    vim.ui.input = original
    if not ok then error(err, 2) end
  end)
end)
