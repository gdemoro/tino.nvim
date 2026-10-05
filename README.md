# tino.nvim

Everyone loves Org mode, right?

Apparently not. Markdown is still the format I end up using almost everywhere.

Plain Markdown is great for notes, but task management in Neovim often feels
either too minimal or too opinionated. There are already plenty of plugins for
Markdown checkboxes and TODOs, but none matched the workflow I wanted: simple
enough to stay out of the way, but complete enough to use for real work.

I wanted to create tasks quickly in the file I am already editing, give them
priorities and due dates, move them through TODO, DOING, WAITING, DONE and
CANCELLED, and keep track of when they were completed.

From Org mode I borrowed the parts I actually missed: quick capture, an
agenda-like overview, and easy refiling.

That is basically what **TINO** (**T**his **I**s **N**ot **O**rg-mode) is.

It does not try to turn Markdown into Org mode. Files remain ordinary Markdown;
TINO only adds the workflow layer I wanted on top.

## Installation

Requires Neovim **0.10+** (tested on **0.12.5**). No external plugins are
needed. Install with any plugin manager from
[`gdemoro/tino.nvim`](https://github.com/gdemoro/tino.nvim), for example:

```lua
-- lazy.nvim
{ "gdemoro/tino.nvim", opts = { roots = { "~/notes" } } }
```

```lua
-- packer.nvim
use({ "gdemoro/tino.nvim", config = function()
  require("tino").setup({ roots = { "~/notes" } })
end })
```

The same repository holds the source: <https://github.com/gdemoro/tino.nvim>.

## Philosophy

- Tasks are normal Markdown checkbox list items.
- Only the controlled tokens (state, optional priority, deadline, managed
  completion timestamp) are ever rewritten; everything else on the line is
  preserved byte-for-byte.
- Buffer edits are never saved to disk automatically. You decide when to
  `:write`.
- Scanning and refiling are read-only unless you explicitly ask for a move.

## Syntax

A task line is (after optional horizontal-whitespace indentation):

```
<marker><ws>+<checkbox><ws>+<STATE>[ [#P]]<ws>+<description>[<ws>+<metadata>]*<ws>*
```

- **marker** – `-`, `*`, `+`, or one to nine digits followed by `.` or `)`
  (ordered lists).
- **checkbox** – `[ ]`, `[x]`, or `[X]`.
- **STATE** – one configured uppercase token (`[A-Z][A-Z0-9_-]*`).
- **priority** – an optional single configured uppercase letter cookie `[#A]`.
- **description** – any non-empty text, including Unicode; embedded whitespace
  is preserved.
- **metadata** – an optional single `@due(YYYY-MM-DD)` deadline and/or single
  `@done(YYYY-MM-DD HH:MM)` completion timestamp, at the end of the description
  in either order. Gregorian dates (including leap years) and times are
  validated. Embedded metadata-like prose followed by more text stays prose.

Plain Markdown checkboxes that are not tasks (for example `- [ ] buy milk` with
no state token, or tasks inside fenced code blocks) are ignored. Lines are
matched byte-for-byte, so a terminal carriage return is preserved and never
rewritten. A repeated, unknown, or malformed leading `[#…]` cookie, or a
malformed, invalid, or duplicated trailing `@done(...)` / `@due(...)` metadata
(including a missing closing parenthesis), makes the line refuse to parse.

### Fence detection scope (lexical)

The scanner skips tasks inside fenced code blocks with a purely line-local rule:
a fence delimiter is a line with **0–3 literal leading spaces** followed by at
least three backticks or tildes. This is not a full CommonMark or Tree-sitter
fence model: it deliberately does **not** track indented-code containers, block
quotes, or nested/container fences, so a fence indented four or more spaces or
declared inside a container is out of scope. The plain-line parse is lexical
throughout; the real Tree-sitter Markdown parser is mandatory **only** for the
structural `TinoRefile` command.

## Requirements

- Neovim **0.10+** recommended (uses `vim.uv`, `vim.treesitter`, and standard
  buffer APIs). Tested on **Neovim 0.12.5**.
- A Tree-sitter **Markdown parser** is required **only for `TinoRefile`**.
  Neovim ships one in its runtime; no `nvim-treesitter` install is required.
  If the parser is missing, refile refuses with a clear message and does nothing
  else.
- [Pandoc](https://pandoc.org/) is required **only for `TinoExportHtml`**.

## Setup

```lua
require("tino").setup({
  roots = { "~/notes", "~/work" }, -- directories scanned for .md files
  inbox = "~/notes/inbox.md",      -- target of TinoCapture
  -- optional overrides:
  -- states = { "TODO", "DOING", "WAITING", "DONE", "CANCELLED" },
  -- priorities = { "A", "B", "C" },
  -- completed_states = { DONE = true, CANCELLED = true },
  -- done_timestamp = true,
  -- agenda = { include_completed = false },
})
```

- `states` – ordered cycle; the **first** state is the initial state used by
  capture. The cycle is `TODO -> DOING -> WAITING -> DONE -> CANCELLED -> TODO`.
- `priorities` – ordered priority list cycled by `TinoPriority`
  (`none -> A -> B -> C -> none`).
- `completed_states` – states that count as complete (checkbox synced, timestamp
  managed). Give a list of names, or a map of state-name to boolean; a `false`
  value means the state is *not* completed. Non-boolean map values are
  rejected.
- `done_timestamp` – whether completion timestamps are added/removed.
- `roots` – directories recursively scanned for `.md` files. Directory
  symlinks are never followed, and physically identical files (same resolved
  path, or same device+inode+type, covering symlink and hard-link aliases)
  collapse to one deterministic representative.
- `inbox` – file capture appends to.
- `agenda.include_completed` – show completed states in the agenda.

A leading literal `~/` in `roots` and `inbox` is expanded once using the
process `$HOME`; spaces, `%`, `#`, wildcards, and buffer tokens are kept
literally. `TinoCycle` and `TinoPriority` establish fence eligibility
through the same scan used by the agenda, so they ignore tasks inside fenced
code blocks (and after an unclosed fence).

There is **no fallback** to `$HOME` or any default root: without `roots`,
nothing is scanned.

## Optional rendering: render-markdown.nvim

[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
is optional, not a TINO dependency. It can display the extended task-state
markers recognized by TINO's HTML exporter:

```markdown
- [ ] TODO
- [/] DOING
- [~] WAITING
- [x] DONE
- [-] CANCELLED
```

Standard Markdown renderers may not recognize `[/]`, `[~]` or `[-]`
automatically. Add `checkbox.custom` to your render-markdown.nvim plugin options:

```lua
opts = {
  checkbox = {
    custom = {
      doing = {
        raw = "[/]",
        rendered = "◐ ",
        highlight = "DiagnosticInfo",
      },
      waiting = {
        raw = "[~]",
        rendered = "󰔟 ",
        highlight = "DiagnosticWarn",
      },
      todo = { -- CANCELLED: override the built-in [-] entry.
        raw = "[-]",
        rendered = "󰜺 ",
        highlight = "Comment",
      },
    },
  },
}
```

Replace the Nerd Font glyphs if needed. This only changes rendering; TINO's
editing commands still use `[ ]` / `[x]` plus an explicit state token.

## Commands

All ten commands are user commands. No mappings are created by default.

| Command | Description |
| --- | --- |
| `:TinoCycle` | Cycle the task under the cursor to the next state, syncing the checkbox and timestamp. |
| `:TinoPriority` | Cycle the task's priority cookie (`none -> A -> B -> C -> none`). |
| `:TinoDone` | Set the task to `DONE` directly (bypassing the cycle): the checkbox becomes `[x]` and a managed `@done(YYYY-MM-DD HH:MM)` timestamp is added when `done_timestamp = true`. |
| `:TinoTodo` | Set the task to `TODO` directly (bypassing the cycle): the checkbox becomes `[ ]` and any managed `@done(...)` timestamp is removed. |
| `:TinoState` | Show a floating box of shortcuts (`t` TODO, `d` DOING, `w` WAITING, `x` DONE, `c` CANCELLED) and set the task directly to the chosen state on that keypress; `Esc` cancels, no Enter. |
| `:TinoDue` | Prompt for a deadline on the current task; set/replace it, or remove it with empty input. |
| `:TinoCapture` | Prompt for text, optional priority, then optional deadline, and append a task to the inbox buffer. |
| `:TinoAgenda` | Open a read-only agenda of all tasks under `roots`, including due dates. |
| `:TinoRefile` | Structurally move the current top-level task item (with nested content) to another file. |
| `:TinoExportHtml` | Export the current Markdown buffer, including unsaved edits, to standalone HTML with TINO task badges. |

### HTML export: `:TinoExportHtml`

`:TinoExportHtml` uses Pandoc to render a named Markdown buffer with inline CSS
and distinct TODO, DOING, WAITING, DONE and CANCELLED badges. Priorities,
`@due(...)` and `@done(...)` remain readable. Linked resources are embedded so
the result is a single standalone HTML file.

The export is written beside the source: `notes.md` becomes `notes.html`, then
`notes-1.html`, `notes-2.html`, and so on if files already exist. The command
reports the generated path; it never overwrites an existing export or saves or
changes the Markdown buffer.

### Direct setters: `:TinoDone` and `:TinoTodo`

`:TinoDone` and `:TinoTodo` jump straight to a literal state, bypassing the
cycle order, and keep the checkbox and managed timestamp consistent with that
state:

- `:TinoDone` targets the literal `DONE` state. It sets the state token to
  `DONE`, sets the checkbox to `[x]`, and appends one canonical
  `@done(YYYY-MM-DD HH:MM)` timestamp if the task does not already have one and
  `done_timestamp = true`. An existing canonical timestamp is retained verbatim
  (never duplicated). Repeating the command is idempotent.
- `:TinoTodo` targets the literal `TODO` state. It sets the state token to
  `TODO`, sets the checkbox to `[ ]`, and removes the managed `@done(...)`
  timestamp if present.

Both commands use the literal tokens `DONE` and `TODO`; the configured
`states`/`completed_states` are never overridden. If the target token is not a
configured state, or if its configured completion role contradicts the command
(a `DONE` configured as active, or a `TODO` configured as completed), the
command refuses with a warning and does not modify the line. As with every
mutation command, non-task lines, keyword-only lines, lines whose checkbox does
not match the completion role, fenced code blocks, and read-only /
non-modifiable buffers are refused unchanged.

### State chooser: `:TinoState`

`:TinoState` opens a small floating box listing the available keys: `t` sets
`TODO`, `d` `DOING`, `w` `WAITING`, `x` `DONE`, and `c` `CANCELLED`. The
current task (or promoted plain text) is set directly to the chosen configured
state as soon as that key is pressed; the box closes immediately and no Enter
confirmation is required. `Esc`, an unrecognised key, or an interrupt closes
the box and changes nothing, and each key must map to a configured state
(unknown targets warn without editing).

### Deadlines: `:TinoDue` and capture

`:TinoDue` accepts `YYYY-MM-DD`, `today`, `tomorrow`, `+Nd` (N days from today),
or `+Nw` (N weeks from today). Relative inputs use the local calendar date.
Every accepted value is stored as `@due(YYYY-MM-DD)`; for example, `+2w`
means fourteen days from today. Empty input removes the deadline; cancelling
leaves the task unchanged. Invalid input warns without editing anything.
Existing description, priority and completion metadata are preserved. State
changes do not remove deadlines.

Capture asks **task text → priority → due date**, using the same date formats.
Empty due input creates a task without a deadline; cancelling aborts capture.
There are no new configuration options, dependencies, calendar pickers,
recurring tasks, scheduling or tags.

### Example mappings (optional, your choice)

```lua
vim.keymap.set("n", "<leader>td", "<cmd>TinoDone<cr>",     { desc = "tino: mark DONE" })
vim.keymap.set("n", "<leader>tt", "<cmd>TinoTodo<cr>",     { desc = "tino: mark TODO" })
vim.keymap.set("n", "<leader>t<Tab>", "<cmd>TinoCycle<cr>", { desc = "tino: cycle state" })
vim.keymap.set("n", "<leader>tc", "<cmd>TinoState<cr>",     { desc = "tino: choose state" })
vim.keymap.set("n", "<leader>tp", "<cmd>TinoPriority<cr>", { desc = "tino: cycle priority" })
vim.keymap.set("n", "<leader>ta", "<cmd>TinoAgenda<cr>",   { desc = "tino: agenda" })
vim.keymap.set("n", "<leader>tr", "<cmd>TinoRefile<cr>",   { desc = "tino: refile" })
vim.keymap.set("n", "<leader>ti", "<cmd>TinoCapture<cr>",  { desc = "tino: capture" })
vim.keymap.set("n", "<leader>tu", "<cmd>TinoDue<cr>",      { desc = "tino: set due date" })
```

## Timestamps

When a task enters a completed state, a canonical `@done(YYYY-MM-DD HH:MM)`
timestamp is appended if one is not already present and `done_timestamp = true`.
It is retained while moving between completed states (for example
`DONE -> CANCELLED`) and removed when the task returns to an active state.

**Every** valid trailing canonical `@done(...)` field is managed, regardless of
whether it was added by the plugin or typed by hand, and it stays managed after
a restart. Malformed, duplicated, or invalid date/time metadata makes the line
refuse to parse as a task (so the plugin will not touch it).

## Save policy

The plugin edits buffers only. It **never writes to disk automatically**.

- Capture opens the inbox buffer with the new task appended; press `:write`.
- State/priority/deadline/refile commands modify buffers in place; save with `:write` (or `:wall`
  to save every modified buffer).
- After a refile, **both** the source and destination buffers are modified and
  shown as edited; each keeps its own undo history and save state.

## Agenda

`:TinoAgenda` opens a read-only `nofile` buffer listing tasks grouped by
configured state order, showing state, priority, `file:line`, description and
`@due(YYYY-MM-DD)` when present. Completed states are hidden unless
`agenda.include_completed = true`.

- `<CR>` jumps to the verified original source line; a stale entry notifies
  instead of jumping.
- `r` refreshes the agenda (also simply re-run `:TinoAgenda`).
- Bad roots or unreadable files are reported rather than silently dropped, so an
  agenda is never a misleadingly "complete" list.

## Refile

`:TinoRefile` moves the **top-level** task item under the cursor, including
all of its nested lists, paragraphs, blank lines, and closed fenced code blocks,
to another `.md` file chosen with `vim.ui.select` from the configured `roots`.

It is the only command that requires Tree-sitter. It locates the `list_item`
whose direct task marker exactly matches the task's row and checkbox margin,
then moves whole original lines untouched. `TinoRefile`:

- uses the real Neovim Markdown parser (no `nvim-treesitter` dependency);
- snapshots every destination candidate *before* `vim.ui.select` (loaded
  buffers by id/name/tick/contents, unloaded files by on-disk identity and
  contents) and revalidates the source and the chosen destination (names,
  current resolved paths, physical identity (device/inode/type), ticks/contents,
  editability) immediately before editing, after destination loading has fired
  any autocmds;
- refuses nested or block-quoted sources (only top-level items can be refiled;
  nested content *inside* the moved item travels intact);
- refuses parse errors, missing nodes, and unterminated fenced code blocks;
- refuses an **unsafe destination** whose end context would swallow the task
  (for example an unclosed code fence), without touching either buffer;
- excludes every physical alias of the source file (same resolved path, or
  same device+inode+type, which also covers hard links and symlinks), and
  refuses a destination that is later renamed, deleted, replaced by an alias of
  the source, edited, or otherwise changed during the selection delay;
- on failure restores the exact full pre-edit contents of **both** buffers,
  including a partially modified destination, and reports rollback failure
  honestly;
- never saves automatically; both edited buffers are left visible for
  `:write`/`:wall`.

Known limitations: it will not attempt to refile a nested or block-quoted task,
and it will not insert an emergency Markdown boundary into an unsafe
destination; it refuses instead.

## Parser API

The pure-Lua parser is usable standalone:

```lua
local parser = require("tino.parser")

parser.parse(line, config)
-- -> nil  for non-tasks, malformed, or ambiguous lines
-- -> { state, checked, priority, text, due_date, done_timestamp, line,
--      spans = { checkbox, state, priority, due_date, done_timestamp, text } }
--    where spans are zero-based, exclusive byte ranges of controlled tokens.

parser.scan_lines(lines, config)
-- -> { { row, line, task }, ... } skipping fenced code blocks.

parser.valid_datetime("2024-05-01 09:30") -- -> true/false
parser.valid_date("2024-02-29")           -- -> true/false
```

`config` is optional; when omitted the active `require("tino").config` is
used (falling back to built-in defaults).

## Tests

The Lua test harness runs headless; HTML export tests also require Pandoc.
All generated fixtures live under the gitignored `test/tmp/`.

```sh
nvim --headless -u NONE -i NONE -l test/run.lua
```

The command prints the current pass/fail totals; treat that run output as
authoritative.

## Compatibility

- Neovim 0.10+ recommended; tested on 0.12.5.
- No external plugins or shell commands. Only HTML export invokes Pandoc;
  embedding remote resources may require network access.
- Purely Markdown: no folding, preview, adapters, databases, indexes, or
  background jobs. Despite the name, TINO does **not** implement Org-mode:
  no outline tree, no agenda clock, no properties drawer, just Markdown tasks.
