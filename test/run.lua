-- Headless test runner:  nvim --headless -u NONE -i NONE -l test/run.lua
local this = debug.getinfo(1, "S").source:sub(2)
local testdir = vim.fn.fnamemodify(this, ":p:h")
local root = vim.fn.fnamemodify(testdir, ":h")

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  testdir .. "/?.lua",
  package.path,
}, ";")

local H = require("harness")
require("parser_test")
require("task_test")
require("state_test")
require("due_test")
require("scan_test")
require("files_test")
require("capture_test")
require("agenda_test")
require("highlight_test")
require("refile_test")
require("picker_test")
require("init_test")
require("note_test")
local failed = H.summary()
os.exit(failed == 0 and 0 or 1)
