local H = require("harness")
local parser = require("tino.parser")

local config = {
  states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
  priorities = { "A", "B", "C" },
  completed_states = { DONE = true, CANCELLED = true },
  done_timestamp = true,
}

local function rows(lines)
  local out = {}
  for _, item in ipairs(parser.scan_lines(lines, config)) do
    out[#out + 1] = item.row
  end
  return out
end

H.describe("parser.scan_lines", function()
  H.it("finds tasks and reports zero-based rows", function()
    local lines = {
      "# notes",
      "- [ ] TODO a",
      "",
      "- [x] DONE b",
    }
    H.assert(vim.deep_equal(rows(lines), { 1, 3 }))
  end)

  H.it("skips fenced code examples with backticks and tildes", function()
    local lines = {
      "- [ ] TODO real",
      "```markdown",
      "- [ ] TODO example",
      "```",
      "~~~",
      "- [x] DONE another example",
      "~~~",
      "- [ ] TODO after",
    }
    H.assert(vim.deep_equal(rows(lines), { 0, 7 }))
  end)

  H.it("does not treat an unclosed fence as opening then closing", function()
    local lines = {
      "```",
      "- [ ] TODO hidden",
    }
    H.assert(vim.deep_equal(rows(lines), {}))
  end)

  H.it("handles a closing fence followed by trailing whitespace", function()
    local lines = {
      "```",
      "- [ ] TODO hidden",
      "```   ",
      "- [ ] TODO visible",
    }
    H.assert(vim.deep_equal(rows(lines), { 3 }))
  end)

  H.it("returns the parsed task and original line", function()
    local lines = { "- [ ] TODO top level" }
    local got = parser.scan_lines(lines, config)
    H.eq(#got, 1)
    H.eq(got[1].task.state, "TODO")
    H.eq(got[1].line, "- [ ] TODO top level")
  end)

  H.it("is robust to non-string input", function()
    H.assert(vim.deep_equal(parser.scan_lines(nil, config), {}))
  end)
end)
