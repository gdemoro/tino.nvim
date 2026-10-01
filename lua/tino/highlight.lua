-- tino highlights: extmarks over the controlled state/priority/timestamp
-- byte spans using the shared parser. Highlight groups link to standard groups
-- with default=true so colorschemes may override them.

local parser = require("tino.parser")
local M = {}

M.namespace = vim.api.nvim_create_namespace("tino")

local attached = {} -- bufnr -> augroup id
local groups_set = false

local LINKS = {
  TinoState = "DiagnosticInfo",
  TinoPriority = "DiagnosticWarn",
  TinoDone = "Comment",
}

function M.define_groups()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  groups_set = true
end

local function setmark(bufnr, row, span, group)
  if not span or span[1] == span[2] then
    return
  end
  vim.api.nvim_buf_set_extmark(bufnr, M.namespace, row, span[1], {
    end_row = row,
    end_col = span[2],
    hl_group = group,
  })
end

function M.update(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
  if vim.bo[bufnr].filetype ~= "markdown" then
    return
  end
  local config = require("tino").config
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, item in ipairs(parser.scan_lines(lines, config)) do
    local t = item.task
    setmark(bufnr, item.row, t.spans.state, "TinoState")
    setmark(bufnr, item.row, t.spans.priority, "TinoPriority")
    setmark(bufnr, item.row, t.spans.done_timestamp, "TinoDone")
  end
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not attached[bufnr] then
    local group = vim.api.nvim_create_augroup("TinoHighlight" .. bufnr, { clear = true })
    attached[bufnr] = group
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
      group = group,
      buffer = bufnr,
      callback = function()
        M.update(bufnr)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = bufnr,
      callback = function()
        attached[bufnr] = nil
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end,
    })
  end
  M.update(bufnr)
end

function M.refresh_all()
  for bufnr in pairs(attached) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.update(bufnr)
    end
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "markdown" then
      M.attach(bufnr)
    end
  end
end

local augroup
function M.setup()
  if not groups_set then
    M.define_groups()
  end
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = vim.api.nvim_create_augroup("TinoHighlightGlobal", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = "markdown",
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
  -- Attach to any already-open Markdown buffers.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "markdown" then
      M.attach(bufnr)
    end
  end
end

return M
