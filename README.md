# tino.nvim

**TINO** (**T**his **I**s **N**ot **O**rg-mode) is a small, dependency-free
Markdown-first task plugin for Neovim. The name is a nod to what it deliberately
is *not*: there is no Org-mode under the hood, no outlining engine, and no
proprietary file format. It is just Markdown, a checkbox, and a state token.

`tino` keeps tasks in **ordinary Markdown checklist lines**. It never owns a
separate database, index, or file format: a task is just a list item with a
checkbox and a state token, so your notes stay valid Markdown and remain usable
in any editor.

```markdown
- [ ] TODO write the parser
- [ ] DOING [#A] refile support
- [ ] TODO submit the report @due(2026-10-15)
- [x] DONE ship the README @done(2024-05-01 09:30)
```

The plugin is pure Lua built only on Neovim APIs. There are **no dependencies**,
**no default global mappings**, and no background jobs or daemons.

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
| `:TinoFiles` | Open a `.md` file discovered under the configured `roots` in the current window. |

### Opening files: `:TinoFiles`

`:TinoFiles` lists every `.md` file discovered under the configured `roots`
(nested files included, non-Markdown ignored) and opens the chosen one in the
current window using native `:hide edit`, so an unsaved current buffer is kept
(hidden, never discarded) and no split is created. It works from any buffer and
cursor position, parses no task, and needs no `roots` fallback: with no
configured roots, no files, or a cancelled picker it simply does nothing. The
chooser prefers a Snacks file picker when a usable Snacks provider is present
and otherwise falls back to `vim.ui.select` with the same candidates, exactly
like `:TinoRefile`.

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
to another `.md` file chosen from the recursively discovered `.md` candidates
under the configured `roots`. The chooser prefers a Snacks file picker when a
usable Snacks provider is present and otherwise falls back to `vim.ui.select`
with the same candidates; no Snacks or AstroNvim dependency is required.

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

The suite is dependency-free and runs headless. All generated fixtures live
under the gitignored `test/tmp/`.

```sh
nvim --headless -u NONE -i NONE -l test/run.lua
```

The command prints the current pass/fail totals; treat that run output as
authoritative.

## Compatibility

- Neovim 0.10+ recommended; tested on 0.12.5.
- No external plugins, no shelling out, no network access.
- Purely Markdown: no folding, preview, adapters, databases, indexes, or jobs.
  Despite the name, TINO does **not** implement Org-mode: no outline tree, no
  agenda clock, no properties drawer, no export engine, just Markdown tasks.
