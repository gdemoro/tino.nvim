local H = require("harness")
local picker = require("tino.picker")
local CREATE = "Create new file..."

-- Run `fn` with deterministic stubs: scheduled callbacks fire synchronously,
-- the global Snacks provider is set to `snacks`, the `snacks` module is not
-- cached, and vim.ui.select is restored afterwards on every path.
local function with_env(snacks, fn)
  local orig_schedule = vim.schedule
  local orig_select = vim.ui.select
  local orig_snacks = rawget(_G, "Snacks")
  local orig_loaded = package.loaded["snacks"]

  vim.schedule = function(f)
    f()
  end
  _G.Snacks = snacks
  package.loaded["snacks"] = nil

  local ok, err = pcall(fn)

  vim.schedule = orig_schedule
  vim.ui.select = orig_select
  _G.Snacks = orig_snacks
  package.loaded["snacks"] = orig_loaded
  if not ok then
    error(err, 2)
  end
end

local function capture_ui_select()
  local cap = {}
  vim.ui.select = function(items, opts, cb)
    cap.items, cap.opts, cap.cb = items, opts, cb
  end
  return cap
end

H.describe("picker.select_files fallback", function()
  H.it("uses vim.ui.select when Snacks is unavailable, preserving choices", function()
    local paths = { "/a/one.md", "/a/two.md" }
    with_env(nil, function()
      -- The fallback hands the backend's callback straight through; it must not
      -- add scheduling around on_choice.
      vim.schedule = function()
        error("vim.ui.select fallback must not schedule on_choice")
      end
      local cap = capture_ui_select()
      local calls = { n = 0, last = false }
      picker.select_files(paths, { prompt = "Refile task to:" }, function(choice)
        calls.n = calls.n + 1
        calls.last = choice
      end)
      H.eq(cap.items, paths, "same choices")
      H.eq(cap.opts.prompt, "Refile task to:", "prompt preserved")
      cap.cb(paths[2])
      H.eq(calls.n, 1, "selected callback once")
      H.eq(calls.last, paths[2])

      calls.n, calls.last = 0, false
      cap.cb(nil)
      H.eq(calls.n, 1, "cancel callback once")
      H.eq(type(calls.last), "nil", "cancel delivers nil")
    end)
  end)

  H.it("falls back to vim.ui.select when the Snacks picker errors", function()
    local paths = { "/a/one.md" }
    with_env({ picker = { pick = function()
      error("picker boom")
    end } }, function()
      local cap = capture_ui_select()
      local got = { n = 0 }
      picker.select_files(paths, { prompt = "Refile task to:" }, function()
        got.n = got.n + 1
      end)
      H.assert(cap.cb, "ui.select used after picker failure")
      cap.cb(paths[1])
      H.eq(got.n, 1, "single callback after fallback")
    end)
  end)
end)

H.describe("picker.select_files snacks", function()
  H.it("uses a Snacks file picker and closes before the callback", function()
    local paths = { "/r/a.md", "/r/b.md" }
    with_env({}, function()
      local cap = nil
      _G.Snacks = { picker = { pick = function(o)
        cap = o
        return "picker"
      end } }
      vim.ui.select = function()
        error("vim.ui.select must not be used when Snacks is available")
      end

      local order, calls = {}, { n = 0, last = false }
      picker.select_files(paths, { prompt = "Refile task to:" }, function(choice)
        order[#order + 1] = "callback"
        calls.n = calls.n + 1
        calls.last = choice
      end)

      H.assert(cap, "snacks picker invoked")
      H.eq(#cap.items, 2, "one item per path")
      H.eq(cap.items[1].file, paths[1])
      H.eq(cap.items[1].text, paths[1])
      H.eq(cap.format, "file")
      H.eq(cap.preview, "file")
      H.eq(cap.title, "Refile task to:")

      local fake = { closed = false }
      function fake:close()
        self.closed = true
        order[#order + 1] = "close"
        cap.on_close()
      end
      cap.actions.confirm(fake, cap.items[1])

      H.eq(calls.n, 1, "confirm callback once")
      H.eq(calls.last, paths[1], "confirm returns item.file")
      H.assert(fake.closed, "picker closed")
      H.eq(order[1], "close", "close precedes callback")
      H.eq(order[2], "callback")
      H.eq(#order, 2, "no extra events")

      -- A late on_close after confirm must not re-fire.
      cap.on_close()
      H.eq(calls.n, 1, "no duplicate callback after confirm")
    end)
  end)

  H.it("exposes a synthetic Create item that confirms without a file", function()
    local paths = { "/r/a.md" }
    with_env({}, function()
      local cap = nil
      _G.Snacks = { picker = { pick = function(o)
        cap = o
      end } }
      vim.ui.select = function()
        error("vim.ui.select must not be used when Snacks is available")
      end

      local order, calls = {}, { n = 0, last = false }
      picker.select_files(paths, { prompt = "Refile task to:", create_new = true }, function(choice)
        order[#order + 1] = "callback"
        calls.n = calls.n + 1
        calls.last = choice
      end)

      H.eq(#cap.items, 2, "one item per path plus the Create action")
      local create = cap.items[2]
      H.eq(create.text, CREATE, "Create item carries the literal label")
      H.eq(create.file, nil, "Create item has no file")
      H.eq(create.create, true, "Create item is marked as create")
      H.eq(type(cap.format), "function", "custom formatter installed")
      local formatted = cap.format(create)
      H.eq(#formatted, 1, "Create item formats as a single chunk")
      H.eq(formatted[1][1], CREATE, "Create item text is its label")
      H.eq(formatted[1][2], "Special", "Create item uses the Special highlight")
      local filefmt = cap.format(cap.items[1])
      H.eq(#filefmt, 1, "file item formats as a single chunk")
      H.eq(filefmt[1][1], paths[1], "file item falls back to plain file text")

      local fake = { closed = false }
      function fake:close()
        self.closed = true
        order[#order + 1] = "close"
        cap.on_close()
      end
      cap.actions.confirm(fake, create)

      H.assert(fake.closed, "picker closed")
      H.eq(order[1], "close", "close precedes callback")
      H.eq(order[2], "callback")
      H.eq(calls.n, 1, "confirm callback once")
      H.eq(calls.last, CREATE, "confirm emits the Create label")
      cap.on_close()
      H.eq(calls.n, 1, "no duplicate callback after confirm")
    end)
  end)

  H.it("delivers nil exactly once on Snacks cancellation", function()
    local paths = { "/r/a.md" }
    with_env({}, function()
      local cap = nil
      _G.Snacks = { picker = { pick = function(o)
        cap = o
      end } }
      vim.ui.select = function()
        error("vim.ui.select must not be used when Snacks is available")
      end

      local calls = { n = 0, last = false }
      picker.select_files(paths, { prompt = "Refile task to:" }, function(choice)
        calls.n = calls.n + 1
        calls.last = choice
      end)
      cap.on_close()
      H.eq(calls.n, 1, "cancel callback once")
      H.eq(type(calls.last), "nil", "cancel delivers nil")
      cap.on_close()
      H.eq(calls.n, 1, "no duplicate cancel callback")
    end)
  end)
end)
