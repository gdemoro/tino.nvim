-- Focused tests for the isolated HTML exporter (lua/tino/export.lua).
local H = require("harness")
local md = require("tino")
local util = require("util")
local export = require("tino.export")
local uv = vim.uv or vim.loop

local PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

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

-- Named, loaded Markdown buffer backed by `path`, with an untouched disk file.
local function new_buf(dir, name, content)
  local path = util.write(dir .. "/" .. name, content)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = ""
  return buf, path
end

local function run_on(buf)
  vim.api.nvim_set_current_buf(buf)
  local ret
  local notes = with_notify(function()
    ret = export.run()
  end)
  return ret, notes
end

local function count(s, pat)
  local n = 0
  for _ in s:gmatch(pat) do
    n = n + 1
  end
  return n
end

H.describe("TinoExportHtml command", function()
  H.it("is registered by setup", function()
    vim.g.tino_commands_registered = nil
    H.assert(md.setup(), "setup succeeds")
    H.eq(vim.fn.exists(":TinoExportHtml"), 2, "TinoExportHtml exists")
  end)
end)

H.describe("HTML export", function()
  H.it("exports unsaved buffer edits without saving or modifying the buffer", function()
    local dir = util.reset("export_unsaved")
    local buf, path = new_buf(dir, "notes.md", "# On disk\n\nold text\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Unsaved", "", "- [ ] TODO fresh" })
    vim.bo[buf].modified = true

    local out, notes = run_on(buf)

    H.eq(out, dir .. "/notes.html", "output beside the source")
    H.assert(notes[1] and notes[1].level == vim.log.levels.INFO, "success notice")
    H.assert(notes[1].msg:find(dir .. "/notes.html", 1, true), "absolute path reported")
    local html = util.read(out)
    H.assert(html:find("Unsaved", 1, true), "unsaved heading exported")
    H.assert(html:find("fresh", 1, true), "unsaved task exported")
    H.assert(html:find("tino-state-todo", 1, true), "task badge rendered")
    H.eq(util.read(path), "# On disk\n\nold text\n", "source file on disk unchanged")
    H.eq(vim.bo[buf].modified, true, "buffer still modified (never saved)")
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[3], "- [ ] TODO fresh", "buffer text preserved")
  end)

  H.it("badges all five marker/state pairs and token-based TINO forms", function()
    local dir = util.reset("export_states")
    local buf = new_buf(dir, "states.md", table.concat({
      "- [ ] TODO alpha",
      "- [/] DOING beta",
      "- [~] WAITING gamma",
      "- [x] DONE delta",
      "- [X] DONE delta-upper",
      "- [-] CANCELLED epsilon",
      "- [ ] DOING token-doing",
      "- [x] CANCELLED token-cancelled",
      "",
    }, "\n"))

    local out = run_on(buf)
    local html = util.read(out)
    for _, class in ipairs({ "tino-state-todo", "tino-state-doing", "tino-state-waiting", "tino-state-done", "tino-state-cancelled" }) do
      H.assert(html:find(class, 1, true), class .. " class present")
    end
    H.eq(count(html, 'data%-state="TODO"'), 1, "one TODO badge")
    H.eq(count(html, 'data%-state="DOING"'), 2, "explicit token wins over [ ]")
    H.eq(count(html, 'data%-state="DONE"'), 2, "[x] and [X]")
    H.eq(count(html, 'data%-state="CANCELLED"'), 2, "explicit token wins over [x]")
    H.assert(not html:find("%[ %] TODO alpha"), "raw marker consumed from output")
  end)

  H.it("keeps priorities and @due/@done metadata readable", function()
    local dir = util.reset("export_meta")
    local buf = new_buf(dir, "meta.md",
      "- [ ] TODO [#A] priority @due(2025-01-02) @done(2025-01-02 10:00)\n")
    local out = run_on(buf)
    local html = util.read(out)
    H.assert(html:find("[#A]", 1, true), "priority literal preserved")
    H.assert(html:find("@due(2025-01-02)", 1, true), "due metadata preserved")
    H.assert(html:find("@done(2025-01-02 10:00)", 1, true), "done metadata preserved")
  end)

  H.it("renders normal Markdown and leaves code literals untouched", function()
    local dir = util.reset("export_markdown")
    local buf = new_buf(dir, "md.md", table.concat({
      "# Heading",
      "",
      "A [link](https://example.com) and *em* and **strong**.",
      "",
      "| a | b |",
      "|---|---|",
      "| 1 | 2 |",
      "",
      "1. first",
      "   - nested",
      "",
      "`[ ] TODO inline`",
      "",
      "```",
      "- [x] DONE in code",
      "```",
      "",
    }, "\n"))
    local out = run_on(buf)
    local html = util.read(out)
    H.assert(html:find("<h1", 1, true), "heading")
    H.assert(html:find('href="https://example.com"', 1, true), "link")
    H.assert(html:find("<em>", 1, true) and html:find("<strong>", 1, true), "emphasis")
    H.assert(html:find("<table", 1, true), "table")
    H.assert(html:find("<ol", 1, true) and html:find("<ul", 1, true), "nested lists")
    H.assert(html:find("<code>[ ] TODO inline</code>", 1, true), "inline code literal")
    H.assert(html:find("- [x] DONE in code", 1, true), "fenced code literal")
    H.eq(count(html, 'class="tino%-state'), 0, "no task badges from code")
  end)

  H.it("produces standalone HTML with inline CSS and embedded images", function()
    local dir = util.reset("export_standalone")
    util.write(dir .. "/dot.png", vim.base64.decode(PNG))
    local buf = new_buf(dir, "pic.md", "# Pic\n\n![dot](dot.png)\n\n- [ ] TODO pic\n")
    local out = run_on(buf)
    local html = util.read(out)
    H.assert(html:find("<style>", 1, true), "inline style block")
    H.assert(html:find(".tino-state-todo", 1, true), "built-in CSS present")
    H.assert(html:find("data:image/png;base64,", 1, true), "local image embedded")
    H.assert(not html:find("<link", 1, true), "no external stylesheet")
    H.assert(not html:find("<script", 1, true), "no external script")
  end)

  H.it("avoids collisions, including symlinks, with exclusive creation", function()
    local dir = util.reset("export_collision")
    util.write(dir .. "/target.html", "target")

    local buf_a = new_buf(dir, "a.md", "# a\n")
    util.write(dir .. "/a.html", "existing")
    local out_a = run_on(buf_a)
    H.eq(out_a, dir .. "/a-1.html", "regular collision gets a suffix")
    H.eq(util.read(dir .. "/a.html"), "existing", "existing file untouched")

    local buf_b = new_buf(dir, "b.md", "# b\n")
    H.assert(uv.fs_symlink(dir .. "/target.html", dir .. "/b.html"), "symlink fixture")
    local out_b = run_on(buf_b)
    H.eq(out_b, dir .. "/b-1.html", "symlink counts as an existing path")
    H.eq(util.read(dir .. "/b.html"), "target", "symlink target untouched")
  end)

  H.it("refuses unnamed and non-Markdown buffers without writing", function()
    local dir = util.reset("export_refuse")

    local unnamed = vim.api.nvim_create_buf(true, true)
    local ret1, notes1 = run_on(unnamed)
    H.eq(ret1, nil, "unnamed buffer refused")
    H.assert(notes1[1] and notes1[1].level == vim.log.levels.ERROR, "error notice")

    local path = util.write(dir .. "/notes.txt", "plain\n")
    local txt = vim.fn.bufadd(path)
    vim.fn.bufload(txt)
    vim.bo[txt].filetype = "text"
    local ret2, notes2 = run_on(txt)
    H.eq(ret2, nil, "non-Markdown buffer refused")
    H.assert(notes2[1] and notes2[1].level == vim.log.levels.ERROR, "error notice")
    H.eq(uv.fs_stat(dir .. "/notes.html"), nil, "no output written")
  end)

  H.it("cleans up partial output and reports write failures", function()
    local dir = util.reset("export_write_failure")
    local buf, path = new_buf(dir, "notes.md", "# Source\n")
    local original_write = uv.fs_write
    local writes = 0
    uv.fs_write = function(fd, data, offset)
      writes = writes + 1
      if writes == 1 then
        return original_write(fd, data:sub(1, 16), offset)
      end
      return nil, "EIO: simulated write failure"
    end
    local ok, ret, notes = pcall(run_on, buf)
    uv.fs_write = original_write
    H.assert(ok, "command handles a write failure without throwing")
    H.eq(writes, 2, "failure follows a partial write")
    H.eq(ret, nil, "no successful output path")
    H.eq(#notes, 1, "only an error notice")
    H.eq(notes[1].level, vim.log.levels.ERROR, "error, not success")
    H.assert(notes[1].msg:find("simulated write failure", 1, true), "write error reported")
    H.eq(uv.fs_stat(dir .. "/notes.html"), nil, "partial file removed")
    H.eq(util.read(path), "# Source\n", "source remains unchanged")
  end)

  H.it("fails clearly and writes nothing when Pandoc is unavailable", function()
    local dir = util.reset("export_nopandoc")
    local buf = new_buf(dir, "notes.md", "# n\n")
    local orig = export.pandoc
    export.pandoc = dir .. "/definitely-missing-pandoc"
    local ret, notes = run_on(buf)
    export.pandoc = orig
    H.eq(ret, nil, "run returns nil")
    H.assert(notes[1] and notes[1].level == vim.log.levels.ERROR, "error notice, no success")
    H.eq(uv.fs_stat(dir .. "/notes.html"), nil, "no output written")
  end)
end)
