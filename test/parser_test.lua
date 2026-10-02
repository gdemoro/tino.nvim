local H = require("harness")
local parser = require("tino.parser")

local config = {
  states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
  priorities = { "A", "B", "C" },
  completed_states = { DONE = true, CANCELLED = true },
  done_timestamp = true,
}

local function parse(line)
  return parser.parse(line, config)
end

H.describe("parser grammar", function()
  H.it("parses a basic unchecked task with exact spans", function()
    local t = parse("- [ ] TODO Fix pipeline")
    H.assert(t, "expected task")
    H.eq(t.state, "TODO")
    H.eq(t.checked, false)
    H.eq(t.priority, nil)
    H.eq(t.text, "Fix pipeline")
    H.eq(t.done_timestamp, nil)
    H.eq(t.line, "- [ ] TODO Fix pipeline")
    H.eq(t.spans.checkbox[1], 2)
    H.eq(t.spans.checkbox[2], 5)
    H.eq(t.spans.state[1], 6)
    H.eq(t.spans.state[2], 10)
    H.eq(t.spans.priority, nil)
    H.eq(t.spans.done_timestamp, nil)
    H.eq(t.spans.text[1], 11)
    H.eq(t.spans.text[2], 23)
  end)

  H.it("parses checked + priority + timestamp", function()
    local line = "- [x] DONE [#B] Ship it @done(2026-10-01 13:15)"
    local t = parse(line)
    H.assert(t, "expected task")
    H.eq(t.state, "DONE")
    H.eq(t.checked, true)
    H.eq(t.priority, "B")
    H.eq(t.text, "Ship it")
    H.eq(t.done_timestamp, "2026-10-01 13:15")
    H.eq(t.spans.priority[1], 11)
    H.eq(t.spans.priority[2], 15)
    H.eq(t.spans.text[1], 16)
    H.eq(t.spans.text[2], 23)
    H.eq(t.spans.done_timestamp[1], 24)
    H.eq(t.spans.done_timestamp[2], 47)
  end)

  H.it("accepts [X] on input", function()
    local t = parse("- [X] DONE Fix")
    H.assert(t, "expected task")
    H.eq(t.checked, true)
  end)
end)

H.describe("parser states and markers", function()
  H.it("parses every configured state with its canonical marker", function()
    local markers = {
      TODO = "[ ]",
      DOING = "[/]",
      WAITING = "[~]",
      DONE = "[x]",
      CANCELLED = "[-]",
    }
    for _, state in ipairs(config.states) do
      local t = parse("- " .. markers[state] .. " " .. state .. " work")
      H.assert(t, "expected task for " .. state)
      H.eq(t.state, state)
    end
  end)

  H.it("accepts *, + and ordered markers", function()
    for _, m in ipairs({ "*", "+", "1.", "2)", "10." }) do
      local t = parse(m .. " [ ] TODO x")
      H.assert(t, "expected task for marker " .. m)
      H.eq(t.text, "x")
    end
  end)

  H.it("accepts leading indentation (spaces and tab)", function()
    local t = parse("  - [ ] TODO x")
    H.assert(t, "expected task")
    H.eq(t.spans.state[1], 8)
    local t2 = parse("\t- [ ] TODO x")
    H.assert(t2, "expected tab-indented task")
  end)

  H.it("rejects blockquote-prefixed tasks", function()
    H.eq(parse("> - [ ] TODO x"), nil)
  end)
end)

H.describe("parser rejections", function()
  H.it("rejects plain checkbox without configured state", function()
    H.eq(parse("- [ ] just a checkbox"), nil)
    H.eq(parse("- [x] done but no state"), nil)
  end)

  H.it("rejects non-task lines", function()
    H.eq(parse("- not a task"), nil)
    H.eq(parse("# heading"), nil)
    H.eq(parse(""), nil)
    H.eq(parse("- [ ]TODO x"), nil)
    H.eq(parse("- [  ] TODO x"), nil)
    H.eq(parse("- [] TODO x"), nil)
    H.eq(parse("- [ x] TODO x"), nil)
  end)

  H.it("rejects unknown or malformed priority-like prefix", function()
    H.eq(parse("- [ ] TODO [#D] text"), nil)
    H.eq(parse("- [ ] TODO [#AB] text"), nil)
    H.eq(parse("- [ ] TODO [#a] text"), nil)
    H.eq(parse("- [ ] TODO [#A text"), nil)
    H.eq(parse("- [ ] TODO [#A]"), nil)
  end)

  H.it("treats the state word as authoritative over the checkbox", function()
    local t = parse("- [ ] DONE text")
    H.assert(t, "mismatched marker still parses")
    H.eq(t.state, "DONE")
    local u = parse("- [/] TODO text")
    H.assert(u, "marker/word mismatch still parses")
    H.eq(u.state, "TODO")
    local v = parse("- [x] CANCELLED text")
    H.assert(v, "checked marker with completed word parses")
    H.eq(v.state, "CANCELLED")
  end)

  H.it("rejects missing description", function()
    H.eq(parse("- [ ] TODO"), nil)
    H.eq(parse("- [ ] TODO   "), nil)
    H.eq(parse("- [ ] TODO [#A]"), nil)
    H.eq(parse("- [x] DONE @done(2026-10-01 10:00)"), nil)
  end)
end)

H.describe("parser timestamps", function()
  H.it("rejects malformed timestamps", function()
    H.eq(parse("- [x] DONE x @done(2026-01-01)"), nil)
    H.eq(parse("- [x] DONE x @done(2026-13-01 10:00)"), nil)
    H.eq(parse("- [x] DONE x @done(2026-02-30 10:00)"), nil)
    H.eq(parse("- [x] DONE x @done(2026-01-01 25:00)"), nil)
    H.eq(parse("- [x] DONE x @done(2026-01-01 10:60)"), nil)
    H.eq(parse("- [x] DONE x @done(20260101 1000)"), nil)
  end)

  H.it("rejects duplicate timestamps", function()
    H.eq(parse("- [x] DONE x @done(2026-01-01 10:00) @done(2026-01-02 10:00)"), nil)
  end)

  H.it("preserves embedded timestamp-like text", function()
    local t = parse("- [ ] TODO see @done(abc) docs")
    H.assert(t, "expected task")
    H.eq(t.text, "see @done(abc) docs")
    H.eq(t.done_timestamp, nil)
  end)

  H.it("validates real calendar dates", function()
    H.assert(parser.valid_datetime("2026-02-28 23:59"), "leap-adjacent valid")
    H.assert(parser.valid_datetime("2024-02-29 00:00"), "leap day valid")
    H.assert(not parser.valid_datetime("2026-02-29 00:00"), "non-leap feb29 invalid")
  end)
end)

H.describe("parser whitespace and Unicode", function()
  H.it("preserves Unicode description bytes exactly with correct spans", function()
    local line = "- [ ] TODO Café ☕"
    local t = parse(line)
    H.assert(t, "expected task")
    H.eq(t.text, "Café ☕")
    H.eq(t.spans.text[1], 11)
    H.eq(t.spans.text[2], 20)
    H.eq(line:sub(t.spans.text[1] + 1, t.spans.text[2]), "Café ☕")
  end)

  H.it("trims only separator whitespace, preserving inner spacing", function()
    local t = parse("- [ ] TODO   spaced  out   ")
    H.assert(t, "expected task")
    H.eq(t.text, "spaced  out")
  end)

  H.it("parses with custom config lists/sets", function()
    local c = {
      states = { "OPEN", "CLOSED" },
      priorities = { "H", "L" },
      completed_states = { "CLOSED" },
      done_timestamp = false,
    }
    local t = parser.parse("- [ ] OPEN [#H] thing", c)
    H.assert(t, "expected custom task")
    H.eq(t.priority, "H")
    H.eq(t.state, "OPEN")
    H.eq(parser.parse("- [x] CLOSED thing", c).checked, true)
    H.assert(parser.parse("- [ ] CLOSED thing", c), "state word is authoritative")
  end)
end)

H.describe("parser priority-cookie repair", function()
  H.it("rejects repeated/unknown/malformed cookies after the optional cookie", function()
    H.eq(parse("- [ ] TODO [#A] [#B] x"), nil)
    H.eq(parse("- [ ] TODO [#A] [#Z] x"), nil)
    H.eq(parse("- [ ] TODO [#A] [#B text"), nil)
    H.eq(parse("- [ ] TODO [#A] [#AB] x"), nil)
  end)

  H.it("preserves non-leading cookie-like text", function()
    local t = parse("- [ ] TODO review [#A] later")
    H.assert(t, "expected task")
    H.eq(t.text, "review [#A] later")
  end)
end)

H.describe("parser trailing metadata repair", function()
  H.it("rejects missing closing parenthesis", function()
    H.eq(parse("- [x] DONE x @done(2026-01-01 10:00"), nil)
    H.eq(parse("- [x] DONE x @done("), nil)
  end)

  H.it("keeps embedded timestamp-like prose followed by text", function()
    local t = parse("- [ ] TODO see @done(abc) docs")
    H.assert(t, "expected task")
    H.eq(t.text, "see @done(abc) docs")
    H.eq(t.done_timestamp, nil)
  end)
end)

H.describe("parser ordered markers and CR", function()
  H.it("accepts up to nine marker digits and rejects ten or more", function()
    H.assert(parse("123456789. [ ] TODO x"), "nine digits ok")
    H.assert(parse("123456789) [ ] TODO x"), "nine digits ) ok")
    H.eq(parse("1234567890. [ ] TODO x"), nil)
    H.eq(parse("12345678901) [ ] TODO x"), nil)
  end)

  H.it("preserves a terminal CR in the original line while tokenizing", function()
    local t = parse("- [ ] TODO x\r")
    H.assert(t, "expected task")
    H.eq(t.line, "- [ ] TODO x\r")
    H.eq(t.text, "x")
    H.eq(t.spans.text[1], 11)
    H.eq(t.spans.text[2], 12)
  end)
end)

H.describe("parser completed-state semantics", function()
  H.it("treats a false completed-state value as absent", function()
    local c = {
      states = { "TODO", "DONE" },
      priorities = { "A" },
      completed_states = { DONE = false },
      done_timestamp = true,
    }
    H.assert(parser.parse("- [x] DONE x", c), "DONE is an active state")
    H.eq(parser.parse("- [x] DONE x", c).checked, false, "active despite [x]")
    H.assert(parser.parse("- [ ] DONE x", c), "DONE is an active state")
  end)

  H.it("rejects unsupported truthy non-boolean completed-state values", function()
    local c = {
      states = { "TODO", "DONE" },
      priorities = { "A" },
      completed_states = { DONE = 1 },
      done_timestamp = true,
    }
    H.eq(parser.parse("- [x] DONE x", c), nil)
    H.eq(parser.parse("- [ ] TODO x", c), nil)
  end)

  H.it("validates states against the configured list", function()
    H.eq(parse("- [ ] DOINGx work"), nil, "not a configured state")
    H.assert(parse("- [ ] DONE work"), "state word is authoritative over marker")
  end)
end)

H.describe("parser timezone-independent datetime", function()
  H.it("validates Gregorian dates and wall-clock times numerically", function()
    H.assert(parser.valid_datetime("2026-07-15 02:30"), "portable 02:30")
    H.assert(parser.valid_datetime("2026-12-31 23:59"), "end of year")
    H.assert(parser.valid_datetime("2024-02-29 00:00"), "leap day")
    H.assert(not parser.valid_datetime("2023-02-29 00:00"), "non-leap feb29")
    H.assert(not parser.valid_datetime("2100-02-29 00:00"), "century non-leap")
    H.assert(parser.valid_datetime("2000-02-29 00:00"), "400-year leap")
    H.assert(not parser.valid_datetime("2026-04-31 10:00"), "april 31")
    H.assert(not parser.valid_datetime("2026-13-01 10:00"), "month 13")
    H.assert(not parser.valid_datetime("2026-01-01 24:00"), "hour 24")
    H.assert(not parser.valid_datetime("2026-01-01 10:60"), "minute 60")
  end)
end)
