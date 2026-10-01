local H = require("harness")
local files = require("tino.files")
local util = require("util")
local uv = vim.uv or vim.loop

H.describe("files.collect", function()
  H.it("finds nested .md recursively and ignores non-markdown", function()
    local dir = util.reset("collect_basic")
    util.write(dir .. "/a.md", "- [ ] TODO a\n")
    util.write(dir .. "/notes.txt", "not markdown\n")
    util.mkdirp(dir .. "/sub/deep")
    util.write(dir .. "/sub/b.md", "- [ ] TODO b\n")
    util.write(dir .. "/sub/deep/c.md", "- [ ] TODO c\n")
    local found = files.collect({ dir })
    H.eq(#found, 3)
    for _, f in ipairs(found) do
      H.assert(f:match("%.md$"), "only .md: " .. f)
    end
  end)

  H.it("returns sorted normalized paths", function()
    local dir = util.reset("collect_sort")
    util.write(dir .. "/z.md", "x\n")
    util.write(dir .. "/a.md", "x\n")
    local found = files.collect({ dir })
    H.eq(#found, 2)
    H.assert(found[1] < found[2], "sorted")
    H.eq(found[1], uv.fs_realpath(dir .. "/a.md"))
  end)

  H.it("de-duplicates overlapping roots and repeated files", function()
    local dir = util.reset("collect_overlap")
    util.write(dir .. "/a.md", "x\n")
    util.mkdirp(dir .. "/sub")
    util.write(dir .. "/sub/b.md", "x\n")
    local found = files.collect({ dir, dir .. "/sub", dir })
    H.eq(#found, 2)
  end)

  H.it("does not recurse into directory symlinks", function()
    local dir = util.reset("collect_symlink")
    local outside = util.reset("collect_symlink_outside")
    util.write(outside .. "/hidden.md", "- [ ] TODO hidden\n")
    util.write(dir .. "/real.md", "- [ ] TODO real\n")
    uv.fs_symlink(outside, dir .. "/linkdir")
    local found = files.collect({ dir })
    H.eq(#found, 1)
    H.eq(found[1], uv.fs_realpath(dir .. "/real.md"))
  end)

  H.it("reports bad roots instead of returning a false complete list", function()
    local dir = util.reset("collect_badroot")
    util.write(dir .. "/a.md", "x\n")
    local found, errors = files.collect({ dir, dir .. "/missing" })
    H.eq(#found, 1)
    H.assert(#errors == 1, "one error recorded")
    H.assert(errors[1].path:match("missing"), "error names the bad root")
  end)

  H.it("handles paths containing spaces", function()
    local dir = util.reset("collect with spaces")
    util.write(dir .. "/a file.md", "- [ ] TODO spaced\n")
    local found = files.collect({ dir })
    H.eq(#found, 1)
    H.assert(found[1]:match("a file%.md"), "spaced file found")
  end)

  H.it("accepts a single .md file as a root", function()
    local dir = util.reset("collect_fileroot")
    local f = util.write(dir .. "/one.md", "x\n")
    local found = files.collect({ f })
    H.eq(#found, 1)
    H.eq(found[1], uv.fs_realpath(f))
  end)
end)

H.describe("files path normalization", function()
  local function with_home(home, fn)
    local orig = vim.env.HOME
    vim.env.HOME = home
    local ok, err = pcall(fn)
    vim.env.HOME = orig
    if not ok then
      error(err, 2)
    end
  end

  H.it("expands a literal ~/ prefix using the process HOME", function()
    local stub = util.reset("home_stub")
    with_home(stub, function()
      H.eq(files.normalize("~/notes"), stub .. "/notes")
      H.eq(files.normalize("~"), stub)
      H.eq(files.normalize(stub .. "/x"), stub .. "/x")
    end)
  end)

  H.it("returns nil for ~ when HOME is unset", function()
    local orig = vim.env.HOME
    vim.env.HOME = ""
    H.eq(files.normalize("~/notes"), nil)
    vim.env.HOME = orig
  end)

  H.it("never expands wildcards, %, # or buffer tokens", function()
    for _, p in ipairs({ "a b/100% done", "#notes.md", "%", "*" }) do
      H.eq(files.normalize(p), p, "literal: " .. p)
    end
  end)

  H.it("collects under a ~-rooted path", function()
    local stub = util.reset("home_collect")
    util.write(stub .. "/notes/a.md", "- [ ] TODO a\n")
    with_home(stub, function()
      local found = files.collect({ "~/notes" })
      H.eq(#found, 1)
      H.eq(found[1], util.realpath(stub .. "/notes/a.md"))
    end)
  end)

  H.it("handles roots containing spaces, % and #", function()
    local dir = util.reset("collect 100% #hash")
    util.write(dir .. "/a b.md", "- [ ] TODO x\n")
    local found = files.collect({ dir })
    H.eq(#found, 1, "spaced/%-/# root found")
  end)

  H.it("does not fall back to scanning when roots are empty", function()
    local found, errors = files.collect({})
    H.eq(#found, 0)
    H.eq(#errors, 0)
  end)
end)

H.describe("files.read_lines", function()
  H.it("reads a file from disk", function()
    local dir = util.reset("read_disk")
    util.write(dir .. "/a.md", "one\ntwo\n")
    local lines = files.read_lines(dir .. "/a.md")
    H.assert(vim.deep_equal(lines, { "one", "two" }))
  end)

  H.it("prefers loaded modified buffer contents", function()
    local dir = util.reset("read_buffer")
    local path = util.write(dir .. "/a.md", "disk line\n")
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "modified line" })
    local lines = files.read_lines(path)
    H.assert(vim.deep_equal(lines, { "modified line" }))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  H.it("returns nil and a reason for a missing file", function()
    local lines, err = files.read_lines("/no/such/path.md")
    H.eq(lines, nil)
    H.assert(type(err) == "string")
  end)
end)

H.describe("files physical identity", function()
  H.it("physically deduplicates hardlinked files with a deterministic representative", function()
    local dir = util.reset("collect_hardlink")
    local a = util.write(dir .. "/a.md", "x\n")
    uv.fs_link(a, dir .. "/b.md")
    local first = files.collect({ dir })
    local second = files.collect({ dir })
    H.eq(#first, 1, "one physical file")
    H.assert(vim.deep_equal(first, second), "deterministic across runs")
    H.eq(first[1], uv.fs_realpath(a), "lexicographically smallest representative")
  end)

  H.it("treats equal inode numbers on different devices as distinct files", function()
    local orig = uv.fs_stat
    uv.fs_stat = function(p)
      if p == "/dev/a" then
        return { dev = 1, ino = 7, type = "file" }
      end
      if p == "/dev/b" then
        return { dev = 2, ino = 7, type = "file" }
      end
      if p == "/dev/c" then
        return { dev = 1, ino = 7, type = "file" }
      end
      return orig(p)
    end
    local ok, res = pcall(function()
      return {
        ab = files.same_physical("/dev/a", "/dev/b"),
        ac = files.same_physical("/dev/a", "/dev/c"),
      }
    end)
    uv.fs_stat = orig
    H.assert(ok, res)
    H.eq(res.ab, false, "same inode on different devices is not the same file")
    H.eq(res.ac, true, "same device+inode+type is the same file")
  end)

  H.it("honors physical identity when looking up a loaded alias", function()
    local dir = util.reset("buffer_alias_same")
    local a = util.write(dir .. "/a.md", "same\n")
    local b = util.write(dir .. "/b.md", "same\n")
    local ba = vim.fn.bufadd(a)
    vim.fn.bufload(ba)
    local bb = vim.fn.bufadd(b)
    vim.fn.bufload(bb)
    -- Make the two distinct real files share a device+inode identity.
    local orig = uv.fs_stat
    uv.fs_stat = function(p)
      local rp = uv.fs_realpath(p) or p
      if rp == uv.fs_realpath(a) or rp == uv.fs_realpath(b) then
        return { dev = 9, ino = 99, type = "file" }
      end
      return orig(p)
    end
    local got = files.buffer_for(a)
    uv.fs_stat = orig
    H.assert(got == ba or got == bb, "returns one physical alias")
    vim.api.nvim_buf_delete(ba, { force = true })
    vim.api.nvim_buf_delete(bb, { force = true })
  end)

  H.it("refuses ambiguous divergent loaded aliases", function()
    local dir = util.reset("buffer_alias_divergent")
    local a = util.write(dir .. "/a.md", "one\n")
    local b = util.write(dir .. "/b.md", "two\n")
    local ba = vim.fn.bufadd(a)
    vim.fn.bufload(ba)
    local bb = vim.fn.bufadd(b)
    vim.fn.bufload(bb)
    vim.api.nvim_buf_set_lines(ba, 0, -1, false, { "alpha" })
    vim.api.nvim_buf_set_lines(bb, 0, -1, false, { "beta" })
    local orig = uv.fs_stat
    uv.fs_stat = function(p)
      local rp = uv.fs_realpath(p) or p
      if rp == uv.fs_realpath(a) or rp == uv.fs_realpath(b) then
        return { dev = 9, ino = 99, type = "file" }
      end
      return orig(p)
    end
    local got, err = files.buffer_for(a)
    local lines, rerr = files.read_lines(a)
    uv.fs_stat = orig
    vim.api.nvim_buf_delete(ba, { force = true })
    vim.api.nvim_buf_delete(bb, { force = true })
    H.eq(got, nil)
    H.assert(err and err:match("ambiguous"), tostring(err))
    H.eq(lines, nil)
    H.assert(rerr and rerr:match("ambiguous"), tostring(rerr))
  end)
end)
