local H = require("harness")
local md = require("tino")
local picker = require("tino.picker")
local files = require("tino.files")
local util = require("util")
local uv = vim.uv or vim.loop
local CREATE = "Create new file..."

local function setup(roots, note_inbox, inbox)
  md.config = {
    states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
    priorities = { "A", "B", "C" }, completed_states = { DONE = true, CANCELLED = true },
    done_timestamp = true, roots = roots, note_inbox = note_inbox, inbox = inbox,
    agenda = { include_completed = false },
  }
  H.assert(md.setup())
end

local function with_ui(inputs, choose, fn)
  local input, select, notify = vim.ui.input, vim.ui.select, vim.notify
  local snacks, loaded, preload = _G.Snacks, package.loaded.snacks, package.preload.snacks
  _G.Snacks, package.loaded.snacks = nil, nil
  package.preload.snacks = function() error("Snacks unavailable in fixture") end
  local i = 0
  vim.ui.input = function(_, cb)
    i = i + 1
    cb(inputs[i])
  end
  vim.ui.select = choose
  vim.notify = function() end
  local ok, err = pcall(fn)
  vim.ui.input, vim.ui.select, vim.notify = input, select, notify
  _G.Snacks, package.loaded.snacks, package.preload.snacks = snacks, loaded, preload
  if not ok then error(err, 2) end
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function eq_lines(buf, expected)
  H.assert(vim.deep_equal(lines(buf), expected), vim.inspect(lines(buf)))
end

local function select_file(path)
  return function(_, _, cb) cb(path) end
end

local function source(dir)
  local path = util.write(dir .. "/source.md", "top\n\tMOVE  \n\nbottom\n")
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_mark(buf, "<", 2, 0, {})
  vim.api.nvim_buf_set_mark(buf, ">", 3, 0, {})
  return buf, path
end

H.describe("new Markdown destinations", function()
  H.it("adds .md and rejects traversal, absolute paths, and escaping symlinks", function()
    local root = util.reset("new_dest_paths")
    local outside = util.reset("new_dest_outside")
    util.write(root .. "/existing.md", "keep\n")
    H.assert(uv.fs_symlink(outside, root .. "/escape"))
    local base = util.realpath(root)
    H.eq(picker.new_path(root, "nested/note"), base .. "/nested/note.md")
    H.eq(picker.new_path(root, "sub/../note.md"), base .. "/note.md")
    for _, name in ipairs({ "../outside", "../../outside", "/outside.md", "C:/outside.md", "escape/note", "existing.md" }) do
      H.eq(picker.new_path(root, name), nil, name)
    end
  end)

  H.it("chooses a root first and creates only an unsaved Markdown buffer", function()
    local a, b = util.reset("new_dest_a"), util.reset("new_dest_b")
    local order, got, created = {}, nil, nil
    with_ui({ "nested/new note" }, function(items, opts, cb)
      if opts.prompt == "Create file in root:" then
        order[#order + 1] = "root"
        H.eq(#items, 2)
        cb(util.realpath(b))
      else
        order[#order + 1] = "file"
        H.eq(items[#items], CREATE)
        cb(CREATE)
      end
    end, function()
      picker.select_destination({ a, b }, {}, function(path, is_new)
        got, created = path, is_new
      end)
    end)
    H.eq(table.concat(order, ","), "file,root")
    H.eq(got, util.realpath(b) .. "/nested/new note.md")
    H.eq(created, true)
    H.assert(files.buffer_for(got), "new named buffer loaded")
    H.eq(util.read(got), nil, "no file auto-saved")
  end)
end)

H.describe("plain note commands", function()
  H.it("TinoNote appends exact free text without interpreting task metadata", function()
    local dir = util.reset("note_inbox")
    local path = util.write(dir .. "/notes.md", "# Notes\n")
    setup({ dir }, path)
    with_ui({ "  free [#A] @due(not a date)\nsecond **line**  " }, function() error("no destination chooser") end, function()
      vim.cmd("TinoNote")
    end)
    eq_lines(files.buffer_for(path), { "# Notes", "  free [#A] @due(not a date)", "second **line**  " })
    H.eq(util.read(path), "# Notes\n", "disk unchanged")
  end)

  H.it("TinoNoteTo appends to existing or newly created destinations without saving", function()
    for _, new in ipairs({ false, true }) do
      local dir = util.reset("note_to_" .. tostring(new))
      local path = util.realpath(dir) .. "/note.md"
      if not new then util.write(path, "keep\n") end
      setup({ dir })
      local inputs = new and { "  plain text  ", "note" } or { "  plain text  " }
      with_ui(inputs, select_file(new and CREATE or path), function()
        vim.cmd("TinoNoteTo")
      end)
      eq_lines(files.buffer_for(path), new and { "  plain text  " } or { "keep", "  plain text  " })
      H.eq(util.read(path), not new and "keep\n" or nil, "no auto-save")
    end
  end)

  H.it("TinoNoteRefile moves exactly the visual lines to existing or new destinations", function()
    for _, new in ipairs({ false, true }) do
      local dir = util.reset("note_move_" .. tostring(new))
      local path = util.realpath(dir) .. "/dest.md"
      if not new then util.write(path, "keep\n") end
      setup({ dir })
      local src, srcpath = source(dir)
      with_ui(new and { "dest" } or {}, select_file(new and CREATE or path), function()
        vim.cmd("'<,'>TinoNoteRefile")
      end)
      eq_lines(src, { "top", "bottom" })
      eq_lines(files.buffer_for(path), new and { "\tMOVE  ", "" } or { "keep", "\tMOVE  ", "" })
      H.eq(util.read(srcpath), "top\n\tMOVE  \n\nbottom\n", "source not saved")
      H.eq(util.read(path), not new and "keep\n" or nil, "destination not saved")
    end
  end)

  H.it("requires visual selection and retains source on failed insertion or delayed edits", function()
    local dir = util.reset("note_move_refusal")
    local path = util.write(dir .. "/dest.md", "keep\n")
    setup({ dir })
    local src = source(dir)
    with_ui({}, function() error("no picker without a visual range") end, function()
      vim.cmd("TinoNoteRefile")
    end)
    local dst = vim.fn.bufadd(path)
    vim.fn.bufload(dst)
    vim.bo[dst].readonly = true
    with_ui({}, select_file(path), function() vim.cmd("'<,'>TinoNoteRefile") end)
    vim.bo[dst].readonly = false
    eq_lines(src, { "top", "\tMOVE  ", "", "bottom" })
    eq_lines(dst, { "keep" })
    local callback
    with_ui({}, function(_, _, cb) callback = cb end, function()
      vim.cmd("'<,'>TinoNoteRefile")
      vim.api.nvim_buf_set_lines(src, 0, 1, false, { "edited" })
      callback(path)
    end)
    eq_lines(src, { "edited", "\tMOVE  ", "", "bottom" })
    eq_lines(dst, { "keep" })
  end)

  H.it("inserts before source removal and rolls back when removal fails", function()
    local dir = util.reset("note_move_rollback")
    local path = util.write(dir .. "/dest.md", "keep\n")
    setup({ dir })
    local src = source(dir)
    local dst = vim.fn.bufadd(path)
    vim.fn.bufload(dst)
    local original, inserted_first = vim.api.nvim_buf_set_lines, false
    vim.api.nvim_buf_set_lines = function(buf, first, last, strict, text)
      if buf == src and first == 1 and last == 3 and #text == 0 then
        inserted_first = vim.deep_equal(lines(dst), { "keep", "\tMOVE  ", "" })
        error("injected source removal failure")
      end
      return original(buf, first, last, strict, text)
    end
    local ok, err = pcall(function()
      with_ui({}, select_file(path), function() vim.cmd("'<,'>TinoNoteRefile") end)
    end)
    vim.api.nvim_buf_set_lines = original
    H.assert(ok, err)
    H.assert(inserted_first, "destination succeeds before source removal")
    eq_lines(src, { "top", "\tMOVE  ", "", "bottom" })
    eq_lines(dst, { "keep" })
  end)
end)

H.describe("destination task commands", function()
  H.it("TinoCaptureTo reuses capture formatting and leaves the default inbox unchanged", function()
    for _, new in ipairs({ false, true }) do
      local dir = util.reset("capture_to_" .. tostring(new))
      local inbox = util.write(dir .. "/inbox.md", "original inbox\n")
      local path = util.realpath(dir) .. "/dest.md"
      if not new then util.write(path, "keep\n") end
      setup({ dir }, nil, inbox)
      local inputs = new and { "dest", "Ship release", "B", "+2d" } or { "Ship release", "B", "+2d" }
      with_ui(inputs, select_file(new and CREATE or path), function() vim.cmd("TinoCaptureTo") end)
      local task = "- [ ] TODO [#B] Ship release @due(" .. require("tino.date").normalize("+2d") .. ")"
      eq_lines(files.buffer_for(path), new and { task } or { "keep", task })
      H.eq(util.read(inbox), "original inbox\n")
      H.eq(util.read(path), not new and "keep\n" or nil, "no auto-save")
    end
    local dir = util.reset("capture_to_validation")
    local path = util.write(dir .. "/dest.md", "keep\n")
    setup({ dir })
    with_ui({ "Bad task", "Z" }, select_file(path), function() vim.cmd("TinoCaptureTo") end)
    H.eq(files.buffer_for(path), nil, "invalid capture does not edit the destination")
    H.eq(util.read(path), "keep\n")
  end)

  H.it("TinoRefile supports a new unsaved destination with no existing candidates", function()
    local dir = util.reset("task_refile_new")
    local srcpath = util.write(dir .. "/source.md", "- [ ] TODO move\n")
    setup({ dir })
    local src = vim.fn.bufadd(srcpath)
    vim.fn.bufload(src)
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    with_ui({ "dest" }, select_file(CREATE), function() vim.cmd("TinoRefile") end)
    local path = util.realpath(dir) .. "/dest.md"
    eq_lines(src, { "" })
    local dst = files.buffer_for(path)
    H.assert(dst, "destination loaded")
    H.eq(lines(dst)[#lines(dst)], "- [ ] TODO move")
    H.eq(util.read(path), nil)
    H.eq(util.read(srcpath), "- [ ] TODO move\n")
  end)
end)
