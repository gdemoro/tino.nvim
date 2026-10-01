local H = require("harness")
local md = require("tino")
local highlight = require("tino.highlight")

local function set_config()
  md.config = {
    states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
    priorities = { "A", "B", "C" },
    completed_states = { DONE = true, CANCELLED = true },
    done_timestamp = true,
    roots = {},
    inbox = nil,
    agenda = { include_completed = false },
  }
end

local function make_md(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "markdown"
  return b
end

local function marks(buf)
  local ns = highlight.namespace
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local row, col, det = m[2], m[3], m[4]
    out[#out + 1] = {
      row = row,
      text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]:sub(col + 1, det.end_col),
      hl = det.hl_group,
    }
  end
  return out
end

local function find(ms, row, hl)
  for _, m in ipairs(ms) do
    if m.row == row and m.hl == hl then
      return m
    end
  end
  return nil
end

H.describe("highlights", function()
  H.it("marks state, priority and timestamp with distinct groups", function()
    set_config()
    local b = make_md({ "- [x] DONE [#A] task @done(2024-01-02 03:04)" })
    highlight.attach(b)
    local ms = marks(b)
    H.eq(find(ms, 0, "TinoState").text, "DONE")
    H.eq(find(ms, 0, "TinoPriority").text, "[#A]")
    H.eq(find(ms, 0, "TinoDone").text, "@done(2024-01-02 03:04)")
  end)

  H.it("uses byte-accurate spans around Unicode text", function()
    set_config()
    local rocket = string.char(240, 159, 154, 128)
    local b = make_md({ "- [ ] TODO fix " .. rocket .. " now" })
    highlight.attach(b)
    local ms = marks(b)
    H.eq(find(ms, 0, "TinoState").text, "TODO")
    H.eq(#ms, 1, "only the state is controlled here")
  end)

  H.it("ignores fenced code examples", function()
    set_config()
    local b = make_md({ "```", "- [ ] TODO example", "```", "- [ ] TODO real" })
    highlight.attach(b)
    local ms = marks(b)
    H.eq(find(ms, 1, "TinoState"), nil, "no mark inside fence")
    H.eq(find(ms, 3, "TinoState").text, "TODO")
  end)

  H.it("clears marks for lines that stop being tasks", function()
    set_config()
    local b = make_md({ "- [ ] TODO alpha" })
    highlight.attach(b)
    H.eq(#marks(b), 1)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "plain text" })
    highlight.update(b)
    H.eq(#marks(b), 0)
  end)

  H.it("defines overrideable default highlight links", function()
    set_config()
    highlight.define_groups()
    local hl = vim.api.nvim_get_hl(0, { name = "TinoState", link = true })
    H.eq(hl.link, "DiagnosticInfo")
  end)

  H.it("updates marks after an edit", function()
    set_config()
    local b = make_md({ "- [ ] TODO alpha" })
    highlight.attach(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "- [ ] DOING beta" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = b })
    H.eq(find(marks(b), 0, "TinoState").text, "DOING")
  end)

  H.it("attaches automatically on the markdown FileType event", function()
    set_config()
    highlight.setup()
    vim.cmd("new")
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "- [ ] TODO auto" })
    vim.bo[b].filetype = "markdown"
    H.eq(find(marks(b), 0, "TinoState").text, "TODO")
    vim.cmd("bwipeout!")
  end)

  H.it("re-reads configuration on update", function()
    set_config()
    md.config.states = { "OPEN", "DONE" }
    md.config.completed_states = { DONE = true }
    local b = make_md({ "- [ ] OPEN custom" })
    highlight.attach(b)
    H.eq(find(marks(b), 0, "TinoState").text, "OPEN")
  end)
end)
