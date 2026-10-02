-- tino destination-file picker: a thin, isolated UI adapter for choosing one
-- existing Markdown destination path. It performs no root discovery, opens no
-- buffers and owns no configuration; callers pass already-validated candidate
-- path strings.
--
-- Prefers a Snacks file picker when a usable Snacks provider is present,
-- otherwise degrades to vim.ui.select with the same paths, options and
-- callback. The callback receives the chosen path string, or nil on cancel;
-- it is always invoked exactly once.

local M = {}

-- True for a provider exposing the public Snacks picker API we rely on.
local function usable(provider)
  return type(provider) == "table"
    and type(provider.picker) == "table"
    and type(provider.picker.pick) == "function"
end

-- Resolve an optional Snacks provider. Checks the global first, then an
-- optional require. Never installs or configures Snacks and never depends on
-- AstroVim; a missing or unusable provider returns nil.
local function picker_provider()
  local g = rawget(_G, "Snacks")
  if usable(g) then
    return g
  end
  local ok, mod = pcall(require, "snacks")
  if ok and usable(mod) then
    return mod
  end
  return nil
end

-- Select one path from `paths` (precomputed Markdown choices).
-- `opts` is passed through to the underlying UI (prompt/title are derived from
-- opts.prompt). `on_choice(path_or_nil)` is called exactly once after the UI
-- has closed.
function M.select_files(paths, opts, on_choice)
  if type(on_choice) ~= "function" then
    return
  end
  opts = opts or {}
  paths = type(paths) == "table" and paths or {}

  local provider = picker_provider()
  local completed = false

  -- Snacks path: deliver a terminal value at most once, deferred so the picker
  -- UI has closed and the source window is restored before the caller mutates
  -- state. The vim.ui.select fallback below does not use this guard and never
  -- schedules: it hands the backend's callback straight to on_choice.
  local function finish(value)
    if completed then
      return
    end
    completed = true
    vim.schedule(function()
      on_choice(value)
    end)
  end

  if provider then
    local items = {}
    for _, path in ipairs(paths) do
      items[#items + 1] = { file = path, text = path }
    end
    local ok = pcall(provider.picker.pick, {
      items = items,
      format = "file",
      preview = "file",
      title = opts.prompt or "Select file",
      actions = {
        confirm = function(picker, item)
          if item == nil or item.file == nil then
            return
          end
          -- Mark completed before closing so on_close does not also cancel.
          completed = true
          picker:close()
          vim.schedule(function()
            on_choice(item.file)
          end)
        end,
      },
      on_close = function()
        finish(nil)
      end,
    })
    if ok then
      return
    end
    -- Picker construction failed before any completed selection: fall back
    -- to vim.ui.select without having delivered a callback.
    completed = false
  end

  -- vim.ui.select already invokes this callback after its own UI has closed,
  -- so deliver directly (no extra scheduling) to preserve the caller's
  -- synchronous contract.
  vim.ui.select(paths, opts, function(choice)
    on_choice(choice)
  end)
end

return M
