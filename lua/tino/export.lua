-- tino: standalone HTML export of the current Markdown buffer via Pandoc.
--
-- The source buffer is only read: unsaved edits are exported without saving
-- and the buffer is never modified. Pandoc is an optional, command-specific
-- dependency; when it is missing or fails the command refuses cleanly and
-- writes nothing. The result is a single self-contained HTML file next to the
-- source (built-in inline CSS, embedded local resources, no external files).
--
-- Markdown is parsed by Pandoc itself, not by hand. Task markers are
-- transformed on the Pandoc JSON AST (never with line regexes), so examples
-- inside code blocks and inline code are left untouched.

local M = {}

local uv = vim.uv or vim.loop

-- Overridable for tests (point at a nonexistent binary to exercise failure).
M.pandoc = "pandoc"

local DEFAULT_STATES = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" }

-- Checkbox marker (used only when no explicit state token follows) -> state.
local CHECKBOX_STATE = {
  [" "] = "TODO",
  ["/"] = "DOING",
  ["~"] = "WAITING",
  ["x"] = "DONE",
  ["X"] = "DONE",
  ["-"] = "CANCELLED",
}

local STATE_ICON = {
  TODO = "\u{2610}",
  DOING = "\u{25B6}",
  WAITING = "\u{23F3}",
  DONE = "\u{2714}",
  CANCELLED = "\u{2717}",
}

local STATE_CLASS = {
  TODO = "tino-state-todo",
  DOING = "tino-state-doing",
  WAITING = "tino-state-waiting",
  DONE = "tino-state-done",
  CANCELLED = "tino-state-cancelled",
}

M.css = table.concat({
  "body{font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Helvetica,Arial,sans-serif;line-height:1.55;max-width:52rem;margin:2rem auto;padding:0 1rem;color:#1f2328}",
  "h1,h2,h3,h4{line-height:1.25}",
  "a{color:#0969da}",
  "code{background:#f0f1f3;padding:.1em .3em;border-radius:4px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.92em}",
  "pre{background:#f6f8fa;padding:.8rem 1rem;border-radius:6px;overflow:auto}",
  "pre code{background:none;padding:0}",
  "table{border-collapse:collapse;margin:1rem 0}",
  "th,td{border:1px solid #d0d7de;padding:.35rem .6rem}",
  "blockquote{border-left:4px solid #d0d7de;margin:1rem 0;padding:0 1rem;color:#57606a}",
  ".tino-state{display:inline-block;font-size:.78em;font-weight:600;letter-spacing:.02em;padding:.05em .5em;margin-right:.35em;border-radius:1em;border:1px solid currentColor;vertical-align:baseline}",
  ".tino-state-todo{color:#57606a;background:#eaeef2}",
  ".tino-state-doing{color:#0550ae;background:#ddf4ff}",
  ".tino-state-waiting{color:#9a6700;background:#fff8c5}",
  ".tino-state-done{color:#1a7f37;background:#dafbe1}",
  ".tino-state-cancelled{color:#cf222e;background:#ffebe9;text-decoration:line-through}",
  ".tino-state-other{color:#57606a;background:#eaeef2}",
  "",
}, "\n")

local function html_escape(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- Configured state tokens, falling back to the built-in five.
local function state_set()
  local ok, init = pcall(require, "tino")
  local list = DEFAULT_STATES
  if ok and type(init) == "table" and type(init.config) == "table"
    and type(init.config.states) == "table" then
    list = init.config.states
  end
  local set = {}
  for _, s in ipairs(list) do
    if type(s) == "string" then
      set[s] = true
    end
  end
  return set
end

-- Return the checkbox marker character and how many leading inlines it spans,
-- or nil when the inline run does not begin with a TINO checkbox. Pandoc is
-- read without the task_lists extension, so "[ ]" arrives as "[", space, "]".
local function detect_marker(inlines)
  local first = inlines[1]
  if not first or first.t ~= "Str" or type(first.c) ~= "string" then
    return nil
  end
  local s = first.c
  if s == "[/]" or s == "[x]" or s == "[X]" or s == "[~]" or s == "[-]" then
    return s:sub(2, 2), 1
  end
  if s == "[" and inlines[2] and inlines[2].t == "Space"
    and inlines[3] and inlines[3].t == "Str" and inlines[3].c == "]" then
    return " ", 3
  end
  return nil
end

local function badge(state)
  local icon = STATE_ICON[state] or "\u{2022}"
  local class = STATE_CLASS[state] or "tino-state-other"
  return ('<span class="tino-state %s" data-state="%s">%s %s</span>')
    :format(class, html_escape(state), icon, html_escape(state))
end

-- Replace a list item's leading checkbox (and explicit state token, which is
-- authoritative like in the parser) with a state badge. Returns true when the
-- item was a task. No regex preprocessing: only leading inlines are inspected.
local function transform_item(item, states)
  local first = item[1]
  if not first or (first.t ~= "Plain" and first.t ~= "Para") or type(first.c) ~= "table" then
    return false
  end
  local inlines = first.c
  local marker, consumed = detect_marker(inlines)
  if not marker then
    return false
  end

  local state
  local idx = consumed + 1
  if inlines[idx] and inlines[idx].t == "Space" then
    idx = idx + 1
  end
  local tok = inlines[idx]
  if tok and tok.t == "Str" and type(tok.c) == "string" and states[tok.c] then
    state = tok.c
    idx = idx + 1
    if inlines[idx] and inlines[idx].t == "Space" then
      idx = idx + 1
    end
  end
  state = state or CHECKBOX_STATE[marker]
  if not state then
    return false
  end

  local rest = {}
  for i = idx, #inlines do
    rest[#rest + 1] = inlines[i]
  end
  while rest[1] and rest[1].t == "Space" do
    table.remove(rest, 1)
  end

  local out = { { t = "RawInline", c = { "html", badge(state) } } }
  if #rest > 0 then
    out[#out + 1] = { t = "Space" }
    for _, node in ipairs(rest) do
      out[#out + 1] = node
    end
  end
  first.c = out
  return true
end

-- Walk the AST, transforming task list items and recursing into nested lists.
local function walk(value, states)
  if type(value) ~= "table" then
    return
  end
  local tag = value.t
  if tag == "BulletList" and type(value.c) == "table" then
    for _, item in ipairs(value.c) do
      transform_item(item, states)
      for _, blk in ipairs(item) do
        walk(blk, states)
      end
    end
    return
  end
  if tag == "OrderedList" and type(value.c) == "table" and type(value.c[2]) == "table" then
    for _, item in ipairs(value.c[2]) do
      transform_item(item, states)
      for _, blk in ipairs(item) do
        walk(blk, states)
      end
    end
    return
  end
  for _, child in pairs(value) do
    walk(child, states)
  end
end

-- Run one Pandoc pass synchronously. vim.system takes an argv list (no shell)
-- and reports a missing binary as a spawn error, which we surface cleanly.
local function run_pandoc(args, stdin, dir)
  local ok, res = pcall(function()
    return vim.system(args, { text = true, stdin = stdin, cwd = dir }):wait()
  end)
  if not ok then
    return nil, "pandoc is not available"
  end
  if res.code ~= 0 then
    local detail = (res.stderr or ""):gsub("%s+$", "")
    if detail == "" then
      detail = "pandoc exited with code " .. tostring(res.code)
    end
    return nil, detail
  end
  return res.stdout or ""
end

local function wrap(body, title)
  return table.concat({
    "<!DOCTYPE html>",
    '<html lang="en">',
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    "<title>" .. html_escape(title) .. "</title>",
    "<style>",
    M.css,
    "</style>",
    "</head>",
    "<body>",
    body,
    "</body>",
    "</html>",
    "",
  }, "\n")
end

local function write_all(fd, data)
  local written = 0
  local total = #data
  while written < total do
    local n, err = uv.fs_write(fd, data:sub(written + 1), written)
    if not n or n == 0 then
      return nil, err or "write made no progress"
    end
    written = written + n
  end
  return true
end

-- Exclusive creation: never overwrite an existing file (including a symlink),
-- falling back to basename-1.html, basename-2.html, ... on collisions.
local function write_exclusive(dir, base, html)
  local suffix = 0
  while true do
    local candidate = suffix == 0 and (dir .. "/" .. base .. ".html")
      or (dir .. "/" .. base .. "-" .. suffix .. ".html")
    local fd, err = uv.fs_open(candidate, "wx", 420)
    if fd then
      local ok, written, werr = pcall(write_all, fd, html)
      local closed, cerr = uv.fs_close(fd)
      if not ok or not written or not closed then
        uv.fs_unlink(candidate)
        return nil, "cannot write HTML output: " .. tostring(not ok and written or werr or cerr)
      end
      return candidate
    end
    if not (err and err:match("^EEXIST")) then
      return nil, "cannot create output file: " .. tostring(err)
    end
    suffix = suffix + 1
  end
end

-- Export `buf` (default: current). Returns the absolute output path or
-- (nil, message). Performs no notifications and never touches the buffer.
function M.export_buffer(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return nil, "buffer is not loaded"
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil, "buffer has no file to export"
  end
  if vim.bo[buf].buftype ~= "" then
    return nil, "not a normal file buffer"
  end
  local ext = (name:match("%.([%w]+)$") or ""):lower()
  if vim.bo[buf].filetype ~= "markdown" and ext ~= "md" and ext ~= "markdown" then
    return nil, "not a Markdown buffer"
  end

  local abs = name:sub(1, 1) == "/" and name
    or ((uv.cwd() or vim.fn.getcwd()) .. "/" .. name)
  local dir = abs:match("^(.*)/[^/]*$") or "."
  local file = abs:match("([^/]*)$") or abs
  local base = file:gsub("%.[Mm][Dd]$", ""):gsub("%.[Mm][Aa][Rr][Kk][Dd][Oo][Ww][Nn]$", "")
  if base == "" then
    return nil, "cannot derive an output name"
  end

  -- Read the live buffer so unsaved edits are exported; never write it back.
  local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

  local json, err = run_pandoc(
    { M.pandoc, "-f", "markdown-task_lists-citations", "-t", "json" }, content, dir)
  if not json then
    return nil, err
  end
  local ok, ast = pcall(vim.json.decode, json)
  if not ok or type(ast) ~= "table" or type(ast.blocks) ~= "table" then
    return nil, "cannot parse Markdown"
  end

  walk(ast.blocks, state_set())

  local fragment, ferr = run_pandoc(
    { M.pandoc, "-f", "json", "-t", "html", "--embed-resources", "--resource-path", dir },
    vim.json.encode(ast), dir)
  if not fragment then
    return nil, ferr
  end

  return write_exclusive(dir, base, wrap(fragment, base))
end

-- Command entry point: export the current buffer and report the result.
function M.run()
  local path, err = M.export_buffer(vim.api.nvim_get_current_buf())
  if not path then
    vim.notify("tino: " .. (err or "export failed"), vim.log.levels.ERROR)
    return nil
  end
  vim.notify("tino: exported " .. path, vim.log.levels.INFO)
  return path
end

return M
