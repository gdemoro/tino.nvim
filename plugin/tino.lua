-- tino plugin bootstrap. Commands are registered eagerly so they exist
-- even before the user calls require("tino").setup().
if vim.g.loaded_tino == 1 then
  return
end
vim.g.loaded_tino = 1

require("tino")._register_commands()
