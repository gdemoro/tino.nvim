-- Shared deadline input normalization. Relative dates use the local calendar,
-- not elapsed 24-hour periods, so daylight-saving changes do not shift a day.
local parser = require("tino.parser")
local M = {}

local INVALID = "invalid due date: use YYYY-MM-DD, today, tomorrow, +Nd or +Nw"

-- Returns a canonical date, "" for no deadline, or nil plus an error.
-- `today` is an optional canonical base date for deterministic callers/tests.
function M.normalize(input, today)
  if type(input) ~= "string" then
    return nil, INVALID
  end
  input = input:gsub("^%s+", ""):gsub("%s+$", "")
  if input == "" or parser.valid_date(input) then
    return input
  end

  local days
  if input == "today" then
    days = 0
  elseif input == "tomorrow" then
    days = 1
  else
    local count, unit = input:match("^%+(%d+)([dw])$")
    if count then
      days = tonumber(count) * (unit == "w" and 7 or 1)
    end
  end
  -- No date in the supported four-digit Gregorian range is this far away.
  if not days or days > 3652058 then
    return nil, INVALID
  end
  today = today or os.date("%Y-%m-%d")
  if not parser.valid_date(today) then
    return nil, INVALID
  end
  if days == 0 then
    return today
  end
  local year, month, day = today:match("^(%d+)%-(%d+)%-(%d+)$")
  local ok, time = pcall(os.time, {
    year = tonumber(year), month = tonumber(month), day = tonumber(day) + days,
    hour = 12, min = 0, sec = 0,
  })
  if not ok or not time then
    return nil, INVALID
  end
  local formatted, date = pcall(os.date, "%Y-%m-%d", time)
  if not formatted or not parser.valid_date(date) then
    return nil, INVALID
  end
  return date
end

return M
