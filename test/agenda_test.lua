local H = require("harness")
local md = require("tino")
local agenda = require("tino.agenda")
local util = require("util")

local function set_config(roots, include_completed)
  md.config = {
    states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
    priorities = { "A", "B", "C" },
    completed_states = { DONE = true, CANCELLED = true },
    done_timestamp = true,
    roots = roots,
    inbox = nil,
    agenda = { include_completed = include_completed == true },
  }
end

local function find_line(buf, needle)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return i, l
    end
  end
  return nil
end

local function with_notify(fn)
  local captured = {}
  local orig = vim.notify
  vim.notify = function(msg)
    captured[#captured + 1] = msg
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  if not ok then
    error(err, 2)
  end
  return captured
end

H.describe("agenda", function()
  H.it("groups tasks by configured state order and excludes completed", function()
    local dir = util.reset("agenda_group")
    util.write(dir .. "/a.md", table.concat({
      "- [ ] TODO alpha [#A]",
      "- [ ] DOING beta",
      "- [x] DONE gamma",
      "",
    }, "\n"))
    set_config({ dir })
    local buf = agenda.run()
    H.eq(vim.bo[buf].buftype, "nofile")
    H.eq(vim.bo[buf].readonly, true)
    H.eq(vim.bo[buf].modifiable, false)
    H.eq(vim.bo[buf].filetype, "markdown")
    local t = find_line(buf, "## TODO")
    local d = find_line(buf, "## DOING")
    H.assert(t and d and t < d, "TODO heading before DOING")
    H.eq(find_line(buf, "## DONE"), nil, "completed group hidden by default")
    H.assert(find_line(buf, "alpha"), "active task shown")
  end)

  H.it("includes completed states when configured", function()
    local dir = util.reset("agenda_completed")
    util.write(dir .. "/a.md", "- [x] DONE gamma\n")
    set_config({ dir }, true)
    local buf = agenda.run()
    H.assert(find_line(buf, "## DONE"), "DONE heading present")
    H.assert(find_line(buf, "gamma"), "completed task shown")
  end)

  H.it("shows task text above indented source metadata highlighted as Comment", function()
    local dir = util.reset("agenda_fields")
    util.write(dir .. "/a.md", "- [ ] TODO [#B] description here\n")
    set_config({ dir })
    local buf = agenda.run()
    local i, metadata = find_line(buf, "a.md:1")
    H.assert(i, "file:line shown")
    H.eq(metadata, "    a.md:1")
    H.eq(vim.api.nvim_buf_get_lines(buf, i - 2, i - 1, false)[1], "  [#B] description here")
    local ns = vim.api.nvim_get_namespaces()["tino-agenda-metadata"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    H.eq(#marks, 1, "only source metadata highlighted")
    H.eq(marks[1][2], i - 1)
    H.eq(marks[1][4].hl_group, "Comment")
  end)

  H.it("uses the first unfenced top-level title instead of the source path", function()
    local dir = util.reset("agenda_title")
    util.write(dir .. "/project.md", table.concat({
      "> # Quoted title", "## Section", "```markdown", "# Example title", "```",
      "  # Project title ##", "- [ ] TODO work", "# Another title", "",
    }, "\n"))
    set_config({ dir })
    local buf = agenda.run()
    local row, line = find_line(buf, "Project title:7")
    H.assert(row, "first real H1 used")
    H.assert(not line:find(dir, 1, true), "full path hidden")
    H.assert(not line:find("project.md", 1, true), "title replaces basename")
  end)

  H.it("shows deadlines with priority and description, including completed tasks when enabled", function()
    local dir = util.reset("agenda_due")
    util.write(dir .. "/a.md", table.concat({
      "- [ ] TODO [#A] active @due(2024-02-29)",
      "- [x] DONE finished @done(2024-02-28 10:30) @due(2024-03-01)",
      "- [ ] TODO no deadline",
      "",
    }, "\n"))
    set_config({ dir }, true)
    local buf = agenda.run()
    local active_row, active = find_line(buf, "a.md:1")
    local completed_row, completed = find_line(buf, "a.md:2")
    local _, plain = find_line(buf, "a.md:3")
    H.eq(active, "    a.md:1  @due(2024-02-29)")
    H.eq(completed, "    a.md:2  @due(2024-03-01)")
    H.eq(vim.api.nvim_buf_get_lines(buf, active_row - 2, active_row - 1, false)[1], "  [#A] active")
    H.eq(vim.api.nvim_buf_get_lines(buf, completed_row - 2, completed_row - 1, false)[1], "  finished")
    H.eq(select(2, active:gsub("@due%(", "")), 1, "deadline shown once")
    H.assert(not plain:find("@due(", 1, true))
  end)

  H.it("skips fenced code examples", function()
    local dir = util.reset("agenda_fence")
    util.write(dir .. "/a.md", "```\n- [ ] TODO example\n```\n- [ ] TODO real\n")
    set_config({ dir })
    local buf = agenda.run()
    H.assert(find_line(buf, "real"), "real task shown")
    H.eq(find_line(buf, "example"), nil, "fenced example hidden")
  end)

  H.it("honors modified buffer contents for a discovered file", function()
    local dir = util.reset("agenda_modified")
    local path = util.write(dir .. "/a.md", "# Disk title\n- [ ] TODO ondisk\n")
    local b = vim.fn.bufadd(path)
    vim.fn.bufload(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "# Buffer title", "- [ ] TODO inbuffer" })
    set_config({ dir })
    local buf = agenda.run()
    H.assert(find_line(buf, "Buffer title:2"), "modified title used")
    H.assert(find_line(buf, "inbuffer"), "modified content used")
    H.eq(find_line(buf, "ondisk"), nil, "disk content not shown")
    vim.api.nvim_buf_delete(b, { force = true })
  end)

  H.it("reports bad roots in the agenda buffer", function()
    local dir = util.reset("agenda_badroot")
    util.write(dir .. "/a.md", "- [ ] TODO ok\n")
    set_config({ dir, dir .. "/missing" })
    local buf = agenda.run()
    H.assert(find_line(buf, "missing"), "bad root surfaced")
  end)

  H.it("installs buffer-local CR and r mappings", function()
    local dir = util.reset("agenda_maps")
    util.write(dir .. "/a.md", "- [ ] TODO alpha\n")
    set_config({ dir })
    local buf = agenda.run()
    local cr = vim.fn.maparg("<CR>", "n", false, true)
    local r = vim.fn.maparg("r", "n", false, true)
    H.eq(cr.buffer, 1)
    H.eq(r.buffer, 1)
  end)

  H.it("jumps to the verified source line", function()
    local dir = util.reset("agenda_jump")
    local path = util.write(dir .. "/a.md", "# t\n- [ ] TODO alpha\n")
    set_config({ dir })
    local buf = agenda.run()
    local i = find_line(buf, "t:2")
    H.assert(i, "title label keeps the full-path jump target")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { i, 0 })
    H.assert(agenda.jump(buf))
    H.eq(vim.api.nvim_buf_get_name(0), util.realpath(path))
    H.eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  end)

  H.it("notifies and does not jump when the source is stale", function()
    local dir = util.reset("agenda_stale")
    local path = util.write(dir .. "/a.md", "# t\n- [ ] TODO alpha\n")
    set_config({ dir })
    local buf = agenda.run()
    local i = find_line(buf, "alpha")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { i, 0 })
    util.write(path, "# t\n- [ ] TODO changed\n")
    local notes = with_notify(function()
      H.eq(agenda.jump(buf), false)
    end)
    H.assert(#notes == 1 and notes[1]:match("stale"), vim.inspect(notes))
    H.eq(vim.api.nvim_get_current_buf(), buf, "stayed on agenda")
  end)

  H.it("refreshes on a repeated run", function()
    local dir = util.reset("agenda_refresh")
    util.write(dir .. "/a.md", "- [ ] TODO first\n")
    set_config({ dir })
    local buf = agenda.run()
    H.assert(find_line(buf, "first"))
    util.write(dir .. "/a.md", "- [ ] TODO second\n")
    local buf2 = agenda.run()
    H.assert(find_line(buf2, "second"), "refresh picks up new content")
    H.eq(find_line(buf2, "first"), nil)
  end)

  -- PHASE B: verify the target at every stage that can run autocmds.

  local function place_on(buf, needle)
    local i = find_line(buf, needle)
    H.assert(i, "row for " .. needle)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { i, 0 })
    return i
  end

  H.it("jumps to a source path containing spaces", function()
    local dir = util.reset("agenda jump spaces")
    local path = util.write(dir .. "/a b.md", "# t\n- [ ] TODO alpha\n")
    set_config({ dir })
    local buf = agenda.run()
    place_on(buf, "alpha")
    H.assert(agenda.jump(buf))
    H.eq(vim.api.nvim_buf_get_name(0), util.realpath(path))
    H.eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  end)

  H.it("refuses when a BufRead autocmd rewrites the target", function()
    local dir = util.reset("agenda_bufread_edit")
    util.write(dir .. "/a.md", "# t\n- [ ] TODO alpha\n")
    set_config({ dir })
    local buf = agenda.run()
    place_on(buf, "alpha")
    vim.api.nvim_create_autocmd("BufRead", {
      once = true,
      callback = function(ev)
        vim.api.nvim_buf_set_lines(ev.buf, 1, 2, false, { "- [ ] TODO changed" })
      end,
    })
    local notes = with_notify(function()
      H.eq(agenda.jump(buf), false)
    end)
    H.assert(#notes == 1 and notes[1]:match("stale"), vim.inspect(notes))
    H.eq(vim.api.nvim_get_current_buf(), buf, "stayed on agenda")
  end)

  H.it("refuses and restores the agenda when BufEnter rewrites the target", function()
    local dir = util.reset("agenda_bufenter_edit")
    local path = util.write(dir .. "/a.md", "# t\n- [ ] TODO alpha\n")
    -- Preload so the BufEnter autocmd only fires after the window switches.
    local pre = vim.fn.bufadd(path)
    vim.fn.bufload(pre)
    set_config({ dir })
    local buf = agenda.run()
    place_on(buf, "alpha")
    vim.api.nvim_create_autocmd("BufEnter", {
      once = true,
      callback = function(ev)
        if ev.buf == pre then
          vim.api.nvim_buf_set_lines(pre, 1, 2, false, { "- [ ] TODO changed" })
        end
      end,
    })
    local notes = with_notify(function()
      H.eq(agenda.jump(buf), false)
    end)
    H.assert(#notes == 1 and notes[1]:match("stale"), vim.inspect(notes))
    local cur = vim.api.nvim_get_current_buf()
    H.eq(vim.bo[cur].buftype, "nofile", "restored an agenda view")
    H.eq(vim.bo[cur].filetype, "markdown", "restored an agenda view")
    vim.api.nvim_buf_delete(pre, { force = true })
  end)

  H.it("refuses when the source buffer cannot be loaded", function()
    local dir = util.reset("agenda_load_fail")
    util.write(dir .. "/a.md", "# t\n- [ ] TODO alpha\n")
    set_config({ dir })
    local buf = agenda.run()
    place_on(buf, "alpha")
    local orig = vim.fn.bufload
    vim.fn.bufload = function()
      error("injected load failure")
    end
    local notes = with_notify(function()
      H.eq(agenda.jump(buf), false)
    end)
    vim.fn.bufload = orig
    H.assert(#notes == 1 and notes[1]:match("load"), vim.inspect(notes))
    H.eq(vim.api.nvim_get_current_buf(), buf, "stayed on agenda")
  end)

  H.it("refuses when the source row is now inside a fence", function()
    local dir = util.reset("agenda_fence_stale")
    local path = util.write(dir .. "/a.md", "# t\n- [ ] TODO alpha\n")
    set_config({ dir })
    local buf = agenda.run()
    place_on(buf, "alpha")
    -- Same raw line still present, but now it is fenced and therefore not a task.
    util.write(path, "```\n- [ ] TODO alpha\n```\n")
    local notes = with_notify(function()
      H.eq(agenda.jump(buf), false)
    end)
    H.assert(#notes == 1 and notes[1]:match("stale"), vim.inspect(notes))
    H.eq(vim.api.nvim_get_current_buf(), buf, "stayed on agenda")
  end)
end)
