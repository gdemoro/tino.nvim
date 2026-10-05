local H = require("harness")
local md = require("tino")
local refile = require("tino.refile")
local parser = require("tino.parser")
local util = require("util")
local uv = vim.uv or vim.loop

local function set_config(roots)
  md.config = {
    states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
    priorities = { "A", "B", "C" },
    completed_states = { DONE = true, CANCELLED = true },
    done_timestamp = true,
    roots = roots,
    inbox = nil,
    agenda = { include_completed = false },
  }
end

local function split(s)
  local l = vim.split(s, "\n", { plain = true })
  if l[#l] == "" then
    l[#l] = nil
  end
  return l
end

local function scratch(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

-- Locate the movable interval for the task on `row` in a scratch buffer.
local function locate_str(src, row)
  local lines = split(src)
  local b = scratch(lines)
  local task = parser.parse(lines[row + 1])
  if not task then
    vim.api.nvim_buf_delete(b, { force = true })
    return nil, "not a task"
  end
  local item, first, last = refile.locate(b, lines, row, task.spans.checkbox[1], task.spans.checkbox[2])
  vim.api.nvim_buf_delete(b, { force = true })
  return item, first, last
end

local function load_file(path, content)
  util.write(path, content)
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  return b
end

local function buflines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function snapshot(src, _row, _first, _last, destpath)
  local snap = refile.snapshot_source(src)
  if destpath then
    snap.dests = refile.snapshot_dests({ destpath })
  end
  return snap
end

local function cleanup(...)
  for _, b in ipairs({ ... }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
end

H.describe("refile locate", function()
  set_config({})
  H.it("moves a one-line top-level item", function()
    local item, first, last = locate_str("- [ ] TODO a\n- [ ] TODO b\n", 0)
    H.assert(item, first)
    H.eq(first, 0)
    H.eq(last, 0)
  end)

  H.it("selects only the requested item among siblings", function()
    local item, first, last = locate_str("- [ ] TODO a\n- [ ] TODO b\n", 1)
    H.assert(item, first)
    H.eq(first, 1)
    H.eq(last, 1)
  end)

  H.it("excludes an indented following top-level sibling (0<ec<line length)", function()
    -- The first item's TS range ends mid-line at (1,2) where only the sibling's
    -- leading indent precedes a non-owned node, so line 1 belongs to the
    -- sibling and must not be moved.
    local item, first, last = locate_str("  - [ ] TODO a\n  - [ ] TODO b\n", 0)
    H.assert(item, first)
    H.eq(first, 0)
    H.eq(last, 0)
    local item2, first2, last2 = locate_str("  - [ ] TODO a\n  - [ ] TODO b\n", 1)
    H.assert(item2, first2)
    H.eq(first2, 1)
    H.eq(last2, 1)
  end)

  H.it("captures nested lists, paragraphs, blanks and closed fences", function()
    local item, first, last = locate_str("- [ ] TODO a\n  - [x] DONE c\n\n  para\n\n  ```\n  code\n  ```\n- [ ] TODO other\n", 0)
    H.assert(item, first)
    H.eq(first, 0)
    H.eq(last, 7)
  end)

  H.it("captures lazy continuations", function()
    local item, first, last = locate_str("- [ ] TODO a\n  lazy text\n", 0)
    H.assert(item, first)
    H.eq(first, 0)
    H.eq(last, 1)
  end)

  H.it("accepts indented top-level and every marker/checkbox form", function()
    for _, s in ipairs({ "  - [ ] TODO i\n", "* [x] DONE s\n", "+ [ ] TODO p\n", "1. [ ] TODO d\n", "1) [ ] TODO e\n" }) do
      local item, first, last = locate_str(s, 0)
      H.assert(item, "should locate: " .. s .. " -> " .. tostring(first))
      H.eq(first, 0)
    end
  end)

  H.it("accepts uppercase [X] checkbox", function()
    local item = locate_str("- [X] DONE a\n", 0)
    H.assert(item)
  end)

  H.it("refuses a nested source task", function()
    local item, reason = locate_str("- [ ] TODO parent\n  - [ ] TODO child\n", 1)
    H.assert(not item)
    H.assert(reason:match("nested"), reason)
  end)

  H.it("refuses a source containing an unterminated fence", function()
    local item, reason = locate_str("- [ ] TODO a\n  ```\n  unclosed\n", 0)
    H.assert(not item)
    H.assert(reason:match("fence"), reason)
  end)

  H.it("refuses a block-quoted task (not parseable at column 0)", function()
    local item = locate_str("> - [ ] TODO q\n", 0)
    H.assert(not item)
  end)

  H.it("reports a missing parser", function()
    set_config({})
    local orig = vim.treesitter.get_parser
    local ok, err = pcall(function()
      vim.treesitter.get_parser = function()
        error("no parser")
      end
      local lines = { "- [ ] TODO a" }
      local b = scratch(lines)
      local task = parser.parse(lines[1])
      local item, reason = refile.locate(b, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
      vim.api.nvim_buf_delete(b, { force = true })
      H.assert(not item)
      H.assert(reason:match("parser"), reason)
    end)
    vim.treesitter.get_parser = orig
    H.assert(ok, err)
  end)
end)

H.describe("refile.dest_safe", function()
  set_config({})
  H.it("accepts a normal destination", function()
    H.eq(refile.dest_safe({ "# Title", "", "- [ ] TODO x" }, { "- [ ] TODO moved" }), true)
  end)

  H.it("accepts an empty destination", function()
    H.eq(refile.dest_safe({ "" }, { "- [ ] TODO moved" }), true)
  end)

  H.it("refuses an unclosed-fence destination", function()
    local ok, reason = refile.dest_safe({ "# T", "```", "code" }, { "- [ ] TODO moved" })
    H.assert(not ok)
    H.assert(reason, "reason present")
  end)
end)

H.describe("refile.commit", function()
  H.it("moves one task and preserves surroundings exactly", function()
    local dir = util.reset("refile_basic")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "before line\n\n- [ ] TODO alpha\n- [ ] TODO beta\n")
    local dest = load_file(dir .. "/dest.md", "# Dest\n\ntail\n")
    local lines = buflines(src)
    local task = parser.parse(lines[3])
    local item, first, last = refile.locate(src, lines, 2, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    H.eq(first, 2)
    H.eq(last, 2)
    local ok, reason = refile.commit(src, 2, lines[3], first, last, snapshot(src, 2, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    H.assert(ok, reason)
    H.eq(table.concat(buflines(src), "\n"), "before line\n\n- [ ] TODO beta")
    H.eq(table.concat(buflines(dest), "\n"), "# Dest\n\ntail\n- [ ] TODO alpha")
    cleanup(src, dest)
  end)

  H.it("moves nested content intact", function()
    local dir = util.reset("refile_nested")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO parent\n  - [x] DONE child\n\n  ```\n  code\n  ```\n- [ ] TODO other\n")
    local dest = load_file(dir .. "/dest.md", "keep\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local moved = vim.deepcopy(vim.api.nvim_buf_get_lines(src, first, last + 1, false))
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snapshot(src, 0, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    H.assert(ok, reason)
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO other")
    local dl = buflines(dest)
    H.eq(dl[1], "keep")
    for i, l in ipairs(moved) do
      H.eq(dl[1 + i], l, "moved line " .. i)
    end
    cleanup(src, dest)
  end)

  H.it("moves blank paragraphs inside an item", function()
    local dir = util.reset("refile_blankpara")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO parent\n  para1\n\n  para2\n- [ ] TODO other\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    H.eq(last, 3)
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snapshot(src, 0, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    H.assert(ok, reason)
    H.eq(table.concat(buflines(dest), "\n"), "d\n- [ ] TODO parent\n  para1\n\n  para2")
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO other")
    cleanup(src, dest)
  end)

  H.it("moves a lazy continuation", function()
    local dir = util.reset("refile_lazy")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n  lazy text\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snapshot(src, 0, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    H.assert(ok, reason)
    H.eq(table.concat(buflines(dest), "\n"), "d\n- [ ] TODO a\n  lazy text")
    cleanup(src, dest)
  end)

  H.it("handles EOF without a final newline", function()
    local dir = util.reset("refile_eof")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "keep\n- [ ] TODO last")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[2])
    local item, first, last = refile.locate(src, lines, 1, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local ok, reason = refile.commit(src, 1, lines[2], first, last, snapshot(src, 1, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    H.assert(ok, reason)
    H.eq(table.concat(buflines(src), "\n"), "keep")
    H.eq(table.concat(buflines(dest), "\n"), "d\n- [ ] TODO last")
    cleanup(src, dest)
  end)

  H.it("handles EOF with a final newline", function()
    local dir = util.reset("refile_eof2")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "keep\n- [ ] TODO last\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[2])
    local item, first, last = refile.locate(src, lines, 1, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local ok, reason = refile.commit(src, 1, lines[2], first, last, snapshot(src, 1, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    H.assert(ok, reason)
    H.eq(table.concat(buflines(src), "\n"), "keep")
    cleanup(src, dest)
  end)

  H.it("works with spaces in paths", function()
    local dir = util.reset("refile spaces")
    set_config({ dir })
    local src = load_file(dir .. "/my tasks.md", "- [ ] TODO sp\n")
    local dest = load_file(dir .. "/other file.md", "x\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snapshot(src, 0, first, last, dir .. "/other file.md"), dir .. "/other file.md")
    H.assert(ok, reason)
    H.eq(table.concat(buflines(dest), "\n"), "x\n- [ ] TODO sp")
    cleanup(src, dest)
  end)

  H.it("refuses a stale source snapshot without editing", function()
    local dir = util.reset("refile_stale")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local snap = snapshot(src, 0, first, last, dir .. "/dest.md")
    -- mutate after snapshot
    vim.api.nvim_buf_set_lines(src, 0, 1, false, { "- [ ] TODO changed" })
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snap, dir .. "/dest.md")
    H.assert(not ok)
    H.assert(reason:match("changed"), reason)
    H.eq(buflines(dest)[1], "d")
    cleanup(src, dest)
  end)

  H.it("refuses a non-modifiable source", function()
    local dir = util.reset("refile_nomod")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    local snap = snapshot(src, 0, first, last, dir .. "/dest.md")
    vim.bo[src].modifiable = false
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snap, dir .. "/dest.md")
    vim.bo[src].modifiable = true
    H.assert(not ok)
    H.assert(reason:match("modifiable"), reason)
    cleanup(src, dest)
  end)

  H.it("refuses a non-modifiable destination", function()
    local dir = util.reset("refile_destnomod")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    vim.bo[dest].modifiable = false
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snapshot(src, 0, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    vim.bo[dest].modifiable = true
    H.assert(not ok)
    H.assert(reason:match("destination"), reason)
    cleanup(src, dest)
  end)

  H.it("refuses an unsafe destination and leaves both files untouched", function()
    local dir = util.reset("refile_unsafe")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    local dest = load_file(dir .. "/dest.md", "# T\n```\ncode\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snapshot(src, 0, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    H.assert(not ok)
    H.assert(reason:match("unsafe"), reason)
    H.eq(buflines(src)[1], "- [ ] TODO a")
    H.eq(table.concat(buflines(dest), "\n"), "# T\n```\ncode")
    cleanup(src, dest)
  end)

  H.it("rolls back both buffers when the destination edit fails", function()
    local dir = util.reset("refile_rollback")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "head\n- [ ] TODO a\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[2])
    local item, first, last = refile.locate(src, lines, 1, task.spans.checkbox[1], task.spans.checkbox[2])
    local snap = snapshot(src, 1, first, last, dir .. "/dest.md")
    local orig = vim.api.nvim_buf_set_lines
    vim.api.nvim_buf_set_lines = function(buf, s, e, strict, l)
      -- fail only the destination append (not the s==0 rollback)
      if buf == dest and s ~= 0 then
        error("injected destination failure")
      end
      return orig(buf, s, e, strict, l)
    end
    local ok, reason = refile.commit(src, 1, lines[2], first, last, snap, dir .. "/dest.md")
    vim.api.nvim_buf_set_lines = orig
    H.assert(not ok)
    H.assert(reason:match("restored"), reason)
    H.eq(table.concat(buflines(src), "\n"), "head\n- [ ] TODO a")
    H.eq(table.concat(buflines(dest), "\n"), "d")
    cleanup(src, dest)
  end)

  H.it("restores exact contents of both buffers after a partial destination edit", function()
    local dir = util.reset("refile_partial")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "head\ntail\n- [ ] TODO a\n")
    local dest = load_file(dir .. "/dest.md", "d1\nd2\n")
    local lines = buflines(src)
    local task = parser.parse(lines[3])
    local item, first, last = refile.locate(src, lines, 2, task.spans.checkbox[1], task.spans.checkbox[2])
    local snap = snapshot(src, 2, first, last, dir .. "/dest.md")
    local orig = vim.api.nvim_buf_set_lines
    vim.api.nvim_buf_set_lines = function(buf, s, e, strict, l)
      -- intercept the destination append: apply a partial edit, then fail
      if buf == dest and s == #buflines(dest) and e == s and l and l[1] and l[1]:match("TODO") then
        orig(buf, s, s, strict, { "- [ ] TODO partial" })
        error("injected partial destination failure")
      end
      return orig(buf, s, e, strict, l)
    end
    local ok, reason = refile.commit(src, 2, lines[3], first, last, snap, dir .. "/dest.md")
    vim.api.nvim_buf_set_lines = orig
    H.assert(not ok)
    H.assert(reason:match("restored"), reason)
    H.eq(table.concat(buflines(src), "\n"), "head\ntail\n- [ ] TODO a")
    H.eq(table.concat(buflines(dest), "\n"), "d1\nd2")
    cleanup(src, dest)
  end)

  H.it("reports rollback failure honestly", function()
    local dir = util.reset("refile_rbfail")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    local snap = snapshot(src, 0, first, last, dir .. "/dest.md")
    local orig = vim.api.nvim_buf_set_lines
    local dumped = false
    vim.api.nvim_buf_set_lines = function(buf, s, e, strict, l)
      if buf == dest and l and l[1] and l[1]:match("TODO") then
        orig(buf, s, s, strict, { "- [ ] TODO partial" })
        dumped = true
        error("injected partial destination failure")
      end
      if dumped and buf == dest and s == 0 then
        error("injected rollback failure")
      end
      return orig(buf, s, e, strict, l)
    end
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snap, dir .. "/dest.md")
    vim.api.nvim_buf_set_lines = orig
    H.assert(not ok)
    H.assert(reason:match("ROLLBACK FAILED"), reason)
    cleanup(src, dest)
  end)

  H.it("moves only the indented task, preserving the indented sibling exactly", function()
    local dir = util.reset("refile_indent_sib")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "  - [ ] TODO a\n  - [ ] TODO b\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    H.eq(first, 0)
    H.eq(last, 0)
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snapshot(src, 0, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    H.assert(ok, reason)
    H.eq(table.concat(buflines(src), "\n"), "  - [ ] TODO b")
    H.eq(table.concat(buflines(dest), "\n"), "d\n  - [ ] TODO a")
    cleanup(src, dest)
  end)

  H.it("moves a whole single-task buffer without extra blank lines", function()
    local dir = util.reset("refile_whole_single")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO only\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snapshot(src, 0, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    H.assert(ok, reason)
    H.eq(table.concat(buflines(src), "\n"), "")
    H.eq(table.concat(buflines(dest), "\n"), "d\n- [ ] TODO only")
    cleanup(src, dest)
  end)

  H.it("moves a whole multiline task buffer exactly", function()
    local dir = util.reset("refile_whole_multi")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO parent\n  child\n\n  para\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snapshot(src, 0, first, last, dir .. "/dest.md"), dir .. "/dest.md")
    H.assert(ok, reason)
    H.eq(table.concat(buflines(src), "\n"), "")
    H.eq(table.concat(buflines(dest), "\n"), "d\n- [ ] TODO parent\n  child\n\n  para")
    cleanup(src, dest)
  end)

  H.it("refuses a missing destination snapshot before loading or editing", function()
    local dir = util.reset("refile_missing_snap")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    -- Unloaded destination: refusal must happen before it is loaded.
    util.write(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local snap = refile.snapshot_source(src) -- no destination snapshots at all
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snap, dir .. "/dest.md")
    H.assert(not ok)
    H.assert(reason:match("unknown destination"), reason)
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    H.eq(util.read(dir .. "/dest.md"), "d\n")
    H.eq(vim.fn.bufnr(dir .. "/dest.md"), -1, "destination must not be loaded")
    cleanup(src)
  end)

  H.it("refuses an unoffered destination choice before loading or editing", function()
    local dir = util.reset("refile_unoffered")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    util.write(dir .. "/other.md", "o\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    -- Snapshot binds only dest.md; other.md was never offered.
    local snap = snapshot(src, 0, first, last, dir .. "/dest.md")
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snap, dir .. "/other.md")
    H.assert(not ok)
    H.assert(reason:match("unknown destination"), reason)
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    H.eq(table.concat(buflines(dest), "\n"), "d")
    H.eq(util.read(dir .. "/other.md"), "o\n")
    H.eq(vim.fn.bufnr(dir .. "/other.md"), -1, "unoffered choice must not be loaded")
    cleanup(src, dest)
  end)
end)

H.describe("refile.destinations", function()
  H.it("excludes the physical source via realpath aliases", function()
    local dir = util.reset("refile_alias")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/other.md", "x\n")
    uv.fs_symlink(dir .. "/src.md", dir .. "/alias.md")
    local list = refile.destinations(src, md.config)
    local real_src = util.realpath(dir .. "/src.md")
    H.eq(#list, 1)
    H.ne(list[1], real_src, "source must not be a destination")
    cleanup(src)
  end)
end)

H.describe("refile.run", function()
  H.it("refiles via vim.ui.select into the chosen file", function()
    local dir = util.reset("refile_run")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO run\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local orig = vim.ui.select
    vim.ui.select = function(items, _, cb)
      H.eq(#items, 2)
      H.eq(items[2], "Create new file...")
      cb(items[1])
    end
    local ret = refile.run()
    vim.ui.select = orig
    H.assert(ret)
    H.eq(buflines(src)[1], "")
    H.eq(buflines(dest)[2], "- [ ] TODO run")
    cleanup(src, dest)
  end)

  local function delayed_run(src, cb_holder)
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local orig = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb_holder.cb = cb
    end
    local ok = refile.run()
    vim.ui.select = orig
    H.assert(ok, "run should schedule selection")
    return cb_holder.cb
  end

  H.it("refuses a loaded destination edited during selection", function()
    local dir = util.reset("refile_async_dest")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local cb = delayed_run(src, {})
    vim.api.nvim_buf_set_lines(dest, -1, -1, false, { "external" })
    cb(dir .. "/dest.md")
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    H.eq(table.concat(buflines(dest), "\n"), "d\nexternal")
    cleanup(src, dest)
  end)

  H.it("refuses a destination whose file changed on disk while unloaded", function()
    local dir = util.reset("refile_disk_change")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    local cb = delayed_run(src, {})
    util.write(dir .. "/dest.md", "changed\n")
    cb(dir .. "/dest.md")
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    H.eq(util.read(dir .. "/dest.md"), "changed\n")
    cleanup(src)
  end)

  H.it("refuses a destination replaced by a self-alias", function()
    local dir = util.reset("refile_selfalias")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    local cb = delayed_run(src, {})
    uv.fs_unlink(dir .. "/dest.md")
    uv.fs_symlink(dir .. "/src.md", dir .. "/dest.md")
    cb(dir .. "/dest.md")
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    cleanup(src)
  end)

  H.it("refuses a destination deleted during selection", function()
    local dir = util.reset("refile_deleted")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    local cb = delayed_run(src, {})
    uv.fs_unlink(dir .. "/dest.md")
    cb(dir .. "/dest.md")
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    cleanup(src)
  end)

  H.it("refuses when destination loading fires an autocmd that edits the source", function()
    local dir = util.reset("refile_bufread")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    local group = vim.api.nvim_create_augroup("TinoRefileBufRead", { clear = true })
    vim.api.nvim_create_autocmd("BufRead", {
      group = group,
      pattern = dir .. "/dest.md",
      callback = function()
        vim.api.nvim_buf_set_lines(src, 0, 1, false, { "- [ ] TODO tampered" })
      end,
    })
    local cb = delayed_run(src, {})
    cb(dir .. "/dest.md")
    vim.api.nvim_del_augroup_by_id(group)
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO tampered")
    cleanup(src)
  end)

  H.it("refuses a loaded destination whose editability changed during selection", function()
    local dir = util.reset("refile_destedit")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    local dest = load_file(dir .. "/dest.md", "d\n")
    local cb = delayed_run(src, {})
    vim.bo[dest].modifiable = false
    cb(dir .. "/dest.md")
    vim.bo[dest].modifiable = true
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    H.eq(table.concat(buflines(dest), "\n"), "d")
    cleanup(src, dest)
  end)

  H.it("refuses when the chosen destination path is replaced by a symlink to another file", function()
    local dir = util.reset("refile_choice_symlink")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    util.write(dir .. "/other.md", "o\n")
    local cb = delayed_run(src, {})
    -- Delayed selection: replace the chosen canonical path with a symlink to a
    -- different, non-source file.
    uv.fs_unlink(dir .. "/dest.md")
    uv.fs_symlink(dir .. "/other.md", dir .. "/dest.md")
    cb(dir .. "/dest.md")
    -- Refusal must preserve the source, both destination files and the
    -- intentional external replacement (the symlink itself).
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    H.eq(util.read(dir .. "/other.md"), "o\n")
    local st = uv.fs_lstat(dir .. "/dest.md")
    H.eq(st.type, "link")
    H.eq(vim.fn.resolve(dir .. "/dest.md"), util.realpath(dir .. "/other.md"))
    local db = vim.fn.bufnr(dir .. "/dest.md")
    cleanup(src, db ~= -1 and db or nil)
  end)

  H.it("refuses an unoffered choice passed to the delayed selection", function()
    local dir = util.reset("refile_run_unknown")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    local cb = delayed_run(src, {})
    cb(dir .. "/not-offered.md")
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    H.eq(util.read(dir .. "/dest.md"), "d\n")
    H.eq(vim.fn.bufnr(dir .. "/not-offered.md"), -1, "unoffered choice must not be loaded")
    cleanup(src)
  end)
end)

H.describe("refile physical identity guards", function()
  H.it("excludes hardlinked source aliases from destinations", function()
    local dir = util.reset("refile_hardlink_dest")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    uv.fs_link(dir .. "/src.md", dir .. "/alias.md")
    local list = refile.destinations(src, md.config)
    H.eq(#list, 0)
    cleanup(src)
  end)

  H.it("refuses a hardlinked self-alias destination at commit", function()
    local dir = util.reset("refile_hardlink_self")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    uv.fs_link(dir .. "/src.md", dir .. "/alias.md")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local ok, reason = refile.commit(src, 0, lines[1], first, last,
      snapshot(src, 0, first, last, dir .. "/alias.md"), dir .. "/alias.md")
    H.assert(not ok)
    H.assert(reason:match("source") or reason:match("alias"), reason)
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    cleanup(src)
  end)

  H.it("refuses a source whose symlink was retargeted since selection", function()
    local dir = util.reset("refile_symlink_retarget")
    set_config({ dir })
    util.write(dir .. "/real1.md", "- [ ] TODO a\n")
    util.write(dir .. "/real2.md", "- [ ] TODO b\n")
    uv.fs_symlink(dir .. "/real1.md", dir .. "/link.md")
    local src = vim.fn.bufadd(dir .. "/link.md")
    vim.fn.bufload(src)
    local dest = load_file(dir .. "/dest.md", "d\n")
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    local snap = snapshot(src, 0, first, last, dir .. "/dest.md")
    uv.fs_unlink(dir .. "/link.md")
    uv.fs_symlink(dir .. "/real2.md", dir .. "/link.md")
    local ok, reason = refile.commit(src, 0, lines[1], first, last, snap, dir .. "/dest.md")
    H.assert(not ok)
    H.assert(reason:match("retarget"), reason)
    H.eq(table.concat(buflines(dest), "\n"), "d")
    cleanup(src, dest)
  end)
end)

-- Autocmd-driven guards run after every preparation step and are caught by the
-- single observational validator immediately before mutation.
H.describe("refile late-autocmd guards", function()
  local function with_group(name, fn)
    local group = vim.api.nvim_create_augroup(name, { clear = true })
    local ok, err = pcall(fn, group)
    vim.api.nvim_del_augroup_by_id(group)
    if not ok then
      error(err, 2)
    end
  end

  local function run_commit(dir, src, destpath)
    local lines = buflines(src)
    local task = parser.parse(lines[1])
    local item, first, last = refile.locate(src, lines, 0, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    return refile.commit(src, 0, lines[1], first, last, snapshot(src, 0, first, last, destpath), destpath)
  end

  H.it("refuses when a scratch BufWipeout autocmd edits the source", function()
    local dir = util.reset("refile_scratch_wipe_src")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    with_group("TinoScratchWipeSrc", function(group)
      vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        pattern = "*",
        callback = function()
          vim.api.nvim_buf_set_lines(src, 0, 1, false, { "- [ ] TODO tampered" })
        end,
      })
      local ok, reason = run_commit(dir, src, dir .. "/dest.md")
      H.assert(not ok, "must refuse")
      H.assert(reason, "reason present")
    end)
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO tampered")
    cleanup(src)
  end)

  H.it("refuses when a destination BufAdd autocmd edits the source", function()
    local dir = util.reset("refile_bufadd_src")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    with_group("TinoBufAddSrc", function(group)
      vim.api.nvim_create_autocmd("BufAdd", {
        group = group,
        pattern = dir .. "/dest.md",
        callback = function()
          vim.api.nvim_buf_set_lines(src, 0, 1, false, { "- [ ] TODO tampered" })
        end,
      })
      local ok, reason = run_commit(dir, src, dir .. "/dest.md")
      H.assert(not ok, "must refuse")
      H.assert(reason, "reason present")
    end)
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO tampered")
    cleanup(src)
  end)

  H.it("refuses when an OptionSet(buflisted) autocmd edits the source", function()
    local dir = util.reset("refile_optionset_src")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    with_group("TinoOptionSetSrc", function(group)
      vim.api.nvim_create_autocmd("OptionSet", {
        group = group,
        pattern = "buflisted",
        callback = function()
          vim.api.nvim_buf_set_lines(src, 0, 1, false, { "- [ ] TODO tampered" })
        end,
      })
      local ok, reason = run_commit(dir, src, dir .. "/dest.md")
      H.assert(not ok, "must refuse")
      H.assert(reason, "reason present")
    end)
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO tampered")
    cleanup(src)
  end)

  H.it("refuses when a scratch BufWipeout autocmd edits the destination", function()
    local dir = util.reset("refile_scratch_wipe_dest")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    with_group("TinoScratchWipeDest", function(group)
      vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        pattern = "*",
        callback = function()
          local db = vim.fn.bufnr(dir .. "/dest.md")
          if db and db ~= -1 and vim.api.nvim_buf_is_valid(db) then
            vim.api.nvim_buf_set_lines(db, -1, -1, false, { "injected" })
          end
        end,
      })
      local ok, reason = run_commit(dir, src, dir .. "/dest.md")
      H.assert(not ok, "must refuse")
      H.assert(reason, "reason present")
    end)
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    cleanup(src)
  end)

  H.it("refuses when an OptionSet(buflisted) autocmd edits the destination", function()
    local dir = util.reset("refile_optionset_dest")
    set_config({ dir })
    local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
    util.write(dir .. "/dest.md", "d\n")
    with_group("TinoOptionSetDest", function(group)
      vim.api.nvim_create_autocmd("OptionSet", {
        group = group,
        pattern = "buflisted",
        callback = function()
          local db = vim.fn.bufnr(dir .. "/dest.md")
          if db and db ~= -1 and vim.api.nvim_buf_is_valid(db) then
            vim.api.nvim_buf_set_lines(db, -1, -1, false, { "injected" })
          end
        end,
      })
      local ok, reason = run_commit(dir, src, dir .. "/dest.md")
      H.assert(not ok, "must refuse")
      H.assert(reason, "reason present")
    end)
    H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
    cleanup(src)
  end)

  local function dest_bufread_case(name, setup)
    H.it(name, function()
      local dir = util.reset(name:gsub("[^%w]", "_"))
      set_config({ dir })
      local src = load_file(dir .. "/src.md", "- [ ] TODO a\n")
      util.write(dir .. "/dest.md", "d\n")
      with_group("TinoDestRead" .. name:gsub("[^%w]", ""), function(group)
        vim.api.nvim_create_autocmd("BufRead", {
          group = group,
          pattern = dir .. "/dest.md",
          callback = function()
            setup(dir, src)
          end,
        })
        local ok, reason = run_commit(dir, src, dir .. "/dest.md")
        H.assert(not ok, "must refuse")
        H.assert(reason, "reason present")
      end)
      H.eq(table.concat(buflines(src), "\n"), "- [ ] TODO a")
      cleanup(src)
    end)
  end

  dest_bufread_case("refuses a destination whose BufRead edits its contents", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "d", "injected" })
  end)

  dest_bufread_case("refuses a destination whose BufRead makes it readonly", function()
    vim.bo[0].readonly = true
  end)

  dest_bufread_case("refuses a destination whose BufRead renames the buffer", function(dir)
    vim.api.nvim_buf_set_name(0, dir .. "/renamed.md")
  end)

  dest_bufread_case("refuses a destination whose BufRead retargets it to the source", function(dir)
    uv.fs_unlink(dir .. "/dest.md")
    uv.fs_symlink(dir .. "/src.md", dir .. "/dest.md")
  end)
end)

H.describe("refile rollback and alias regressions", function()
  local function prepare(name, content, row, unsaved)
    local dir = util.reset("refile_targeted_" .. name)
    set_config({ dir })
    local src = load_file(dir .. "/src.md", content)
    local dest = load_file(dir .. "/dest.md", "# Destination\n\nKeep this.\n")
    if unsaved then
      vim.api.nvim_buf_set_lines(src, 0, 1, false, { "# Unsaved source — 保留" })
      vim.api.nvim_buf_set_lines(dest, -1, -1, false, { "Unsaved destination — 保留" })
    end
    local lines = buflines(src)
    local task = parser.parse(lines[row + 1])
    local item, first, last = refile.locate(src, lines, row, task.spans.checkbox[1], task.spans.checkbox[2])
    H.assert(item, first)
    return {
      dir = dir, src = src, dest = dest, row = row, first = first, last = last,
      taskline = lines[row + 1], snap = snapshot(src, row, first, last, dir .. "/dest.md"),
      src_lines = lines, dest_lines = buflines(dest),
      src_modified = vim.bo[src].modified, dest_modified = vim.bo[dest].modified,
    }
  end

  local function commit(p)
    return refile.commit(p.src, p.row, p.taskline, p.first, p.last, p.snap, p.dir .. "/dest.md")
  end

  local function failed_edit(p, fail_at, touch_dest, block_rollback)
    local original = vim.api.nvim_buf_set_lines
    local injected = false
    vim.api.nvim_buf_set_lines = function(buf, s, e, strict, replacement)
      if not injected and buf == fail_at then
        injected = true
        if buf == p.src then
          original(buf, s, s + 1, strict, {}) -- Only part of the source operation completes.
        else
          original(buf, 0, 1, strict, { "partial destination edit" })
        end
        if touch_dest then
          original(p.dest, -1, -1, false, { "changed by the failing source operation" })
        end
        error("injected partial edit failure")
      end
      if injected and block_rollback and buf == p.src and s == 0 and e == -1 then
        error("injected source rollback failure")
      end
      return original(buf, s, e, strict, replacement)
    end
    local ran, ok, reason = pcall(commit, p)
    vim.api.nvim_buf_set_lines = original
    local result = {
      ran = ran, ok = ok, reason = reason, injected = injected,
      src_lines = buflines(p.src), dest_lines = buflines(p.dest),
      src_modified = vim.bo[p.src].modified, dest_modified = vim.bo[p.dest].modified,
    }
    cleanup(p.src, p.dest)
    return result
  end

  local function assert_restored(p, result)
    H.assert(result.ran, result.ok)
    H.assert(result.injected, "failure path must execute")
    H.assert(not result.ok, "failed edit must not report success")
    H.assert(result.reason:match("restored"), result.reason)
    H.assert(vim.deep_equal(result.src_lines, p.src_lines), "exact source contents restored")
    H.assert(vim.deep_equal(result.dest_lines, p.dest_lines), "exact destination contents restored")
    H.eq(result.src_modified, p.src_modified, "source dirty flag restored")
    H.eq(result.dest_modified, p.dest_modified, "destination dirty flag restored")
  end

  H.it("restores a whole-task source after a partial source-edit failure", function()
    local p = prepare("whole_source_failure", "- [ ] TODO sole task\n", 0, false)
    assert_restored(p, failed_edit(p, p.src, false, false))
  end)

  H.it("restores nested content and unrelated unsaved notes after a partial source-edit failure", function()
    local p = prepare("unsaved_source_failure", "# Source\n\n- [ ] TODO parent\n  Child notes.\n\nAfter the task.\n", 2, true)
    assert_restored(p, failed_edit(p, p.src, false, false))
  end)

  H.it("restores both buffers when the failing source operation also changes the destination", function()
    local p = prepare("both_source_failure", "# Source\n\n- [ ] TODO parent\n  Child notes.\n\nAfter the task.\n", 2, true)
    assert_restored(p, failed_edit(p, p.src, true, false))
  end)

  H.it("reports a refused source rollback without claiming restoration", function()
    local p = prepare("source_rollback_failure", "- [ ] TODO sole task\n", 0, false)
    local result = failed_edit(p, p.src, false, true)
    H.assert(result.ran, result.ok)
    H.assert(result.injected)
    H.assert(not result.ok)
    H.assert(result.reason:match("source edit failed"), result.reason)
    H.assert(result.reason:match("ROLLBACK FAILED for source"), result.reason)
    H.assert(not vim.deep_equal(result.src_lines, p.src_lines), "injected rollback refusal really leaves source unrestored")
    H.assert(vim.deep_equal(result.dest_lines, p.dest_lines), "destination still restored")
    H.eq(result.dest_modified, p.dest_modified)
  end)

  H.it("restores pre-operation dirty flags after a partial destination-edit failure", function()
    local p = prepare("destination_dirty_flags", "- [ ] TODO sole task\n", 0, false)
    assert_restored(p, failed_edit(p, p.dest, false, false))
  end)

  for _, target in ipairs({ "source", "destination" }) do
    for _, timing in ipairs({ "selection", "scratch cleanup" }) do
      H.it("refuses a divergent " .. target .. " hardlink alias introduced during " .. timing, function()
        local p = prepare(target .. "_alias_" .. timing:gsub(" ", "_"), "- [ ] TODO move me\n", 0, false)
        local aliaspath = p.dir .. "/alias.md"
        local alias = load_file(aliaspath, "# Separate file\n")
        vim.api.nvim_buf_set_lines(alias, 0, -1, false, { "Unrelated unsaved alias — 保留" })
        local alias_lines = buflines(alias)
        local targetpath = p.dir .. (target == "source" and "/src.md" or "/dest.md")
        local files = require("tino.files")
        local created, alias_error = false, nil
        local function introduce_alias()
          if created then
            return
          end
          -- Load separate files first, then replace one path with a real hardlink.
          -- This keeps distinct loaded buffers without mocking filesystem identity.
          H.assert(uv.fs_rename(aliaspath, aliaspath .. ".original"))
          H.assert(uv.fs_link(targetpath, aliaspath))
          created = true
          H.assert(files.same_physical(targetpath, aliaspath), "real hardlink identity")
          local _, err = files.buffer_for(targetpath)
          alias_error = err
        end
        local original_select, original_notify = vim.ui.select, vim.notify
        local messages, callback, group = {}, nil, nil
        vim.notify = function(message)
          messages[#messages + 1] = message
        end
        vim.ui.select = function(_, _, cb)
          callback = cb
        end
        local ran, err = pcall(function()
          vim.api.nvim_set_current_buf(p.src)
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          H.assert(refile.run(), "selection must start")
          H.assert(callback, "selection callback captured")
          if timing == "selection" then
            introduce_alias()
          else
            group = vim.api.nvim_create_augroup("TinoTargetedAlias", { clear = true })
            vim.api.nvim_create_autocmd("BufWipeout", {
              group = group,
              callback = function(ev)
                if ev.buf ~= p.src and ev.buf ~= p.dest and ev.buf ~= alias then
                  introduce_alias()
                end
              end,
            })
          end
          callback(p.dir .. "/dest.md")
        end)
        vim.ui.select, vim.notify = original_select, original_notify
        if group then
          vim.api.nvim_del_augroup_by_id(group)
        end
        local source_after, dest_after, alias_after = buflines(p.src), buflines(p.dest), buflines(alias)
        local src_modified, dest_modified, alias_modified = vim.bo[p.src].modified, vim.bo[p.dest].modified, vim.bo[alias].modified
        cleanup(p.src, p.dest, alias)
        H.assert(ran, err)
        H.assert(created, "late alias must be introduced")
        H.assert(alias_error and alias_error:match("ambiguous"), "distinct loaded aliases really diverge")
        H.assert(vim.deep_equal(source_after, p.src_lines), "source must not be edited")
        H.assert(vim.deep_equal(dest_after, p.dest_lines), "destination must not be edited")
        H.assert(vim.deep_equal(alias_after, alias_lines), "unrelated unsaved alias must not be edited")
        H.eq(src_modified, p.src_modified)
        H.eq(dest_modified, p.dest_modified)
        H.eq(alias_modified, true)
        H.assert(table.concat(messages, "\n"):match("ambiguous"), "ambiguity must be reported")
      end)
    end
  end
end)

return H
