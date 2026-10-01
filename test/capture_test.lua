local H = require("harness")
local md = require("tino")
local capture = require("tino.capture")
local util = require("util")

local function set_config(inbox)
  md.config = {
    states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
    priorities = { "A", "B", "C" },
    completed_states = { DONE = true, CANCELLED = true },
    done_timestamp = true,
    roots = {},
    inbox = inbox,
    agenda = { include_completed = false },
  }
end

local function with_input(queue, fn)
  local orig = vim.ui.input
  local i, prompts = 0, {}
  vim.ui.input = function(opts, cb)
    i = i + 1
    prompts[i] = opts.prompt
    local v = queue[i]
    cb(v)
  end
  local ok, err = pcall(fn, prompts)
  vim.ui.input = orig
  if not ok then
    error(err, 2)
  end
end

local function buf_lines(name)
  local b = vim.fn.bufnr(name)
  if b >= 0 then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  local raw = util.read(name)
  if not raw then
    return nil
  end
  local lines = vim.split(raw, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

H.describe("capture", function()
  H.it("inserts a canonical first-state task with no priority", function()
    local dir = util.reset("capture_basic")
    local inbox = dir .. "/inbox.md"
    set_config(inbox)
    with_input({ "Buy milk", "", "" }, function()
      capture.run()
    end)
    local lines = buf_lines(inbox)
    H.assert(lines, "inbox buffer exists")
    H.assert(vim.deep_equal(lines, { "- [ ] TODO Buy milk" }), vim.inspect(lines))
    H.eq(util.read(inbox), nil, "no file written to disk")
  end)

  H.it("inserts an optional configured priority after the state", function()
    local dir = util.reset("capture_priority")
    local inbox = dir .. "/inbox.md"
    set_config(inbox)
    with_input({ "Ship release", "A", "" }, function()
      capture.run()
    end)
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] TODO [#A] Ship release" }))
  end)

  H.it("prompts text then priority then due, normalizing all deadline formats", function()
    local dates = require("tino.date")
    for i, input in ipairs({ "2024-02-29", "today", "tomorrow", "+2d", "+1w" }) do
      local dir = util.reset("capture_due_" .. i)
      local inbox = dir .. "/inbox.md"
      set_config(inbox)
      with_input({ "café  task", "B", input }, function(prompts)
        capture.run()
        H.eq(#prompts, 3)
        H.eq(prompts[1], "Task: ")
        H.assert(prompts[2]:find("Priority", 1, true))
        H.assert(prompts[3]:find("Due", 1, true))
      end)
      H.assert(vim.deep_equal(buf_lines(inbox), {
        "- [ ] TODO [#B] café  task @due(" .. dates.normalize(input) .. ")",
      }), vim.inspect(buf_lines(inbox)))
      H.eq(util.read(inbox), nil, "still unsaved")
    end
  end)

  H.it("cancels capture when the due prompt is cancelled", function()
    local dir = util.reset("capture_cancel_due")
    local inbox = dir .. "/inbox.md"
    set_config(inbox)
    with_input({ "Task", "A" }, function(prompts)
      capture.run()
      H.eq(#prompts, 3, "third prompt cancelled with nil")
    end)
    H.eq(vim.fn.bufnr(inbox), -1)
    H.eq(util.read(inbox), nil)
  end)

  H.it("rejects invalid deadlines without changing or opening the inbox", function()
    local dir = util.reset("capture_bad_due")
    local inbox = util.write(dir .. "/inbox.md", "- [ ] TODO keep\n")
    set_config(inbox)
    with_input({ "New task", "", "2024-02-30" }, function()
      capture.run()
    end)
    H.eq(vim.fn.bufnr(inbox), -1)
    H.eq(util.read(inbox), "- [ ] TODO keep\n")
    H.eq(capture.insert(inbox, md.config, "New", nil, "+1m"), false)
    H.eq(util.read(inbox), "- [ ] TODO keep\n")
  end)

  H.it("refuses deadline metadata hidden in the capture description", function()
    local dir = util.reset("capture_ambiguous_due")
    local inbox = dir .. "/inbox.md"
    set_config(inbox)
    with_input({ "Task @due(2024-02-29)", "", "" }, function()
      capture.run()
    end)
    H.eq(vim.fn.bufnr(inbox), -1)
    H.eq(util.read(inbox), nil)
  end)

  H.it("preserves existing inbox contents", function()
    local dir = util.reset("capture_preserve")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO existing\n\nsome notes\n")
    set_config(inbox)
    with_input({ "New task", "", "" }, function()
      capture.run()
    end)
    local lines = buf_lines(inbox)
    H.eq(lines[1], "- [ ] TODO existing")
    H.eq(lines[#lines], "- [ ] TODO New task")
    H.eq(#lines, 4)
  end)

  H.it("opens a buffer for a nonexistent inbox with an existing parent dir", function()
    local dir = util.reset("capture_newfile")
    local inbox = dir .. "/inbox.md"
    set_config(inbox)
    with_input({ "Fresh", "", "" }, function()
      capture.run()
    end)
    H.eq(vim.api.nvim_buf_get_name(0), vim.fn.fnamemodify(inbox, ":p"))
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] TODO Fresh" }))
    H.eq(util.read(inbox), nil, "still unsaved")
  end)

  H.it("cancels cleanly when the initial prompt is cancelled", function()
    local dir = util.reset("capture_cancel")
    local inbox = dir .. "/inbox.md"
    set_config(inbox)
    with_input({ nil }, function()
      capture.run()
    end)
    H.eq(vim.fn.bufnr(inbox), -1, "no inbox buffer created")
  end)

  H.it("rejects empty and multiline input without modifying the inbox", function()
    local dir = util.reset("capture_reject")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    with_input({ "   ", "", "" }, function()
      capture.run()
    end)
    with_input({ "line one\nline two", "", "" }, function()
      capture.run()
    end)
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] TODO keep" }))
  end)

  H.it("rejects an unconfigured priority", function()
    local dir = util.reset("capture_badpri")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    with_input({ "Task", "Z", "" }, function()
      capture.run()
    end)
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] TODO keep" }))
  end)

  H.it("notifies when no inbox is configured", function()
    local captured = {}
    local orig = vim.notify
    vim.notify = function(msg)
      captured[#captured + 1] = msg
    end
    set_config(nil)
    capture.run()
    vim.notify = orig
    H.assert(#captured == 1, "one notification")
    H.assert(captured[1]:match("no inbox"), captured[1])
  end)

  H.it("re-inserts into an unsaved inbox buffer (stale buffer honored)", function()
    local dir = util.reset("capture_stale")
    local inbox = dir .. "/inbox.md"
    set_config(inbox)
    with_input({ "first", "", "" }, function()
      capture.run()
    end)
    with_input({ "second", "", "" }, function()
      capture.run()
    end)
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] TODO first", "- [ ] TODO second" }))
  end)

  H.it("refuses a readonly inbox without modifying it", function()
    local dir = util.reset("capture_readonly")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    local buf = vim.fn.bufadd(inbox)
    vim.fn.bufload(buf)
    vim.bo[buf].readonly = true
    local notices = {}
    local orig = vim.notify
    vim.notify = function(m)
      notices[#notices + 1] = m
    end
    local ok = capture.insert(inbox, md.config, "New", nil)
    vim.notify = orig
    H.eq(ok, false)
    H.assert(#notices > 0, "clean notification")
    H.assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "- [ ] TODO keep" }))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  H.it("refuses a non-modifiable inbox without modifying it", function()
    local dir = util.reset("capture_nomod")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    local buf = vim.fn.bufadd(inbox)
    vim.fn.bufload(buf)
    vim.bo[buf].modifiable = false
    local notices = {}
    local orig = vim.notify
    vim.notify = function(m)
      notices[#notices + 1] = m
    end
    local ok = capture.insert(inbox, md.config, "New", nil)
    vim.notify = orig
    H.eq(ok, false)
    H.assert(#notices > 0, "clean notification")
    H.assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "- [ ] TODO keep" }))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  H.it("captures into the first active state with custom states/checkbox", function()
    local dir = util.reset("capture_custom")
    local inbox = dir .. "/inbox.md"
    md.config = {
      states = { "OPEN", "CLOSED" },
      priorities = { "H" },
      completed_states = { CLOSED = true },
      done_timestamp = false,
      roots = {},
      inbox = inbox,
      agenda = { include_completed = false },
    }
    with_input({ "Custom task", "H", "" }, function()
      capture.run()
    end)
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] OPEN [#H] Custom task" }))
  end)

  H.it("expands a ~ inbox using the process HOME", function()
    local stub = util.reset("capture_home")
    local orig = vim.env.HOME
    vim.env.HOME = stub
    set_config("~/inbox.md")
    local ok = capture.insert("~/inbox.md", md.config, "Tilde task", nil)
    vim.env.HOME = orig
    H.assert(ok, "insert succeeded")
    local buf = vim.fn.bufnr(stub .. "/inbox.md")
    H.assert(buf > 0, "expanded buffer exists")
    H.assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "- [ ] TODO Tilde task" }))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- PHASE B: data guards and truthfulness.

  local function capture_notify(fn)
    local notes = {}
    local orig = vim.notify
    vim.notify = function(m)
      notes[#notes + 1] = m
    end
    local ok, err = pcall(fn)
    vim.notify = orig
    if not ok then
      error(err, 2)
    end
    return notes
  end

  local function cleanup_buf(path)
    local b = vim.fn.bufnr(path)
    if b > 0 then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end

  H.it("refuses a blank-priority capture whose text begins with a cookie", function()
    local dir = util.reset("capture_ambiguous_cookie")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    with_input({ "[#A] buy milk", "", "" }, function()
      capture.run()
    end)
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] TODO keep" }))
    cleanup_buf(inbox)
  end)

  H.it("refuses a capture whose text would reread as a done timestamp", function()
    local dir = util.reset("capture_trailing_meta")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    with_input({ "write docs @done(2024-05-01 09:30)", "", "" }, function()
      capture.run()
    end)
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] TODO keep" }))
    cleanup_buf(inbox)
  end)

  H.it("refuses when the text repeats the chosen priority cookie", function()
    local dir = util.reset("capture_dup_cookie")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    with_input({ "[#A] ship release", "A", "" }, function()
      capture.run()
    end)
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] TODO keep" }))
    cleanup_buf(inbox)
  end)

  H.it("captures Unicode descriptions verbatim with the chosen priority", function()
    local dir = util.reset("capture_unicode")
    local inbox = dir .. "/inbox.md"
    set_config(inbox)
    local desc = "café — naïve ✨ 日本語"
    with_input({ desc, "B", "" }, function()
      capture.run()
    end)
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] TODO [#B] " .. desc }), vim.inspect(buf_lines(inbox)))
    H.eq(util.read(inbox), nil, "still unsaved")
    cleanup_buf(inbox)
  end)

  H.it("refuses invalid/empty/multiline input in insert without edits", function()
    local dir = util.reset("capture_insert_validate")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    H.eq(capture.insert(inbox, md.config, "   ", nil), false)
    H.eq(capture.insert(inbox, md.config, "a\nb", nil), false)
    H.eq(capture.insert(inbox, md.config, "ok", "Z"), false)
    H.assert(vim.deep_equal(buf_lines(inbox), { "- [ ] TODO keep" }))
    cleanup_buf(inbox)
  end)

  H.it("refuses cleanly when bufadd fails", function()
    local dir = util.reset("capture_bufadd_err")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    local orig = vim.fn.bufadd
    vim.fn.bufadd = function()
      error("injected bufadd failure")
    end
    local notes = capture_notify(function()
      H.eq(capture.insert(inbox, md.config, "New", nil), false)
    end)
    vim.fn.bufadd = orig
    H.assert(#notes > 0, "clean notification")
    H.eq(util.read(inbox), "- [ ] TODO keep\n", "disk unchanged")
    cleanup_buf(inbox)
  end)

  H.it("refuses cleanly when bufload fails", function()
    local dir = util.reset("capture_bufload_err")
    local inbox = dir .. "/inbox.md"
    set_config(inbox)
    local orig = vim.fn.bufload
    vim.fn.bufload = function()
      error("injected bufload failure")
    end
    local notes = capture_notify(function()
      H.eq(capture.insert(inbox, md.config, "New", nil), false)
    end)
    vim.fn.bufload = orig
    H.assert(#notes > 0, "clean notification")
    H.eq(util.read(inbox), nil, "no file written")
    cleanup_buf(inbox)
  end)

  H.it("refuses cleanly when reading the buffer fails", function()
    local dir = util.reset("capture_read_err")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    local orig = vim.api.nvim_buf_get_lines
    vim.api.nvim_buf_get_lines = function()
      error("injected read failure")
    end
    local notes = capture_notify(function()
      H.eq(capture.insert(inbox, md.config, "New", nil), false)
    end)
    vim.api.nvim_buf_get_lines = orig
    H.assert(#notes > 0, "clean notification")
    H.eq(util.read(inbox), "- [ ] TODO keep\n", "disk unchanged")
    cleanup_buf(inbox)
  end)

  H.it("restores content when the edit fails", function()
    local dir = util.reset("capture_edit_err")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    local orig = vim.api.nvim_buf_set_lines
    vim.api.nvim_buf_set_lines = function()
      error("injected edit failure")
    end
    local notes = capture_notify(function()
      H.eq(capture.insert(inbox, md.config, "New", nil), false)
    end)
    vim.api.nvim_buf_set_lines = orig
    H.assert(#notes > 0, "clean notification")
    local b = vim.fn.bufnr(inbox)
    H.assert(b > 0)
    H.assert(vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "- [ ] TODO keep" }))
    H.eq(util.read(inbox), "- [ ] TODO keep\n", "disk unchanged")
    cleanup_buf(inbox)
  end)

  H.it("refuses an inbox made readonly during buffer preparation", function()
    local dir = util.reset("capture_prep_readonly")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    vim.api.nvim_create_autocmd("BufRead", {
      once = true,
      callback = function(ev)
        vim.bo[ev.buf].readonly = true
      end,
    })
    local notes = capture_notify(function()
      H.eq(capture.insert(inbox, md.config, "New", nil), false)
    end)
    H.assert(#notes > 0, "clean notification")
    H.eq(util.read(inbox), "- [ ] TODO keep\n", "disk unchanged")
    cleanup_buf(inbox)
  end)

  H.it("reports success when the inbox cannot be displayed", function()
    local dir = util.reset("capture_display_err")
    local inbox = dir .. "/inbox.md"
    util.write(inbox, "- [ ] TODO keep\n")
    set_config(inbox)
    local orig = vim.api.nvim_set_current_buf
    vim.api.nvim_set_current_buf = function()
      error("injected display failure")
    end
    local notes = capture_notify(function()
      H.eq(capture.insert(inbox, md.config, "New", nil), true)
    end)
    vim.api.nvim_set_current_buf = orig
    H.assert(#notes > 0 and notes[1]:match("inserted"), vim.inspect(notes))
    local b = vim.fn.bufnr(inbox)
    H.assert(b > 0)
    H.assert(vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "- [ ] TODO keep", "- [ ] TODO New" }))
    cleanup_buf(inbox)
  end)
end)
