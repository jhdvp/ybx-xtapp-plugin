-- Local reading statistics and progress reporting.
--
-- Why this exists: the original client read CrossPoint's firmware APIs
-- (crosspoint_reader_events, the ".track" sidecar files) to learn how far the
-- reader had got. Plain XTApp has no such thing, but it does expose
-- ctx.reader (contract section 22): recent books, per-day seconds and totals,
-- readable from the main program and from a lock session. That is enough for
-- the sleep screen statistics and for progress reports, without the firmware.

local M = {}

local function now_ms(ctx)
  local ok,value = pcall(function() return ctx.clock:millis() end)
  return ok and tonumber(value) or 0
end

local function epoch_of(ctx)
  local ok,t = pcall(function() return ctx.clock:now() end)
  local value = ok and type(t) == 'table' and math.tointeger(t.epoch_sec)
  return value and value >= 0 and value <= 4102444800 and value or 0
end

local function today(ctx)
  local ok,t = pcall(function() return ctx.clock:now() end)
  if not ok or type(t) ~= 'table' then return nil end
  local y, m, d = tonumber(t.year), tonumber(t.month), tonumber(t.day)
  if not (y and m and d) then return nil end
  if y < 2000 or y > 2100 or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
  return string.format('%04d-%02d-%02d', y, m, d)
end

-- A readable subset of ctx.reader. Returns nil when the host or the user's
-- settings do not expose reading data.
function M.service(ctx)
  local ok, reader = pcall(function() return ctx.reader end)
  if not ok or type(reader) ~= 'table' then return nil end
  return reader
end

-- Totals for the statistics panel: nil fields where the host gives nothing.
function M.summary(ctx)
  local reader = M.service(ctx)
  if not reader then return nil end
  local ok, sum = pcall(function() return reader:summary() end)
  if not ok or type(sum) ~= 'table' then return nil end
  return {
    total_sec = tonumber(sum.total_sec),
    today_sec = tonumber(sum.today_sec),
    days_read = tonumber(sum.days_read),
    streak = tonumber(sum.streak_days),
    best_streak = tonumber(sum.best_streak_days),
    books_finished = tonumber(sum.books_finished),
    books_read = tonumber(sum.books_read),
  }
end

-- The most recent books, newest first, capped so the screen stays short.
function M.recent(ctx, limit)
  local reader = M.service(ctx)
  if not reader then return {} end
  local ok, books = pcall(function() return reader:books() end)
  if not ok or type(books) ~= 'table' then return {} end
  local out = {}
  for i, book in ipairs(books) do
    if i > (limit or 3) then break end
    if type(book) == 'table' then
      out[#out + 1] = {
        id = type(book.id) == 'string' and book.id or nil,
        title = type(book.title) == 'string' and book.title or '',
        author = type(book.author) == 'string' and book.author or '',
        percent = tonumber(book.percent),
        finished = book.finished == true,
      }
    end
  end
  return out
end

-- Seconds read on each of the last `count` days, oldest first, as {date, sec}.
function M.last_days(ctx, count)
  local reader = M.service(ctx)
  if not reader then return {} end
  local first = today(ctx)
  if not first then return {} end
  local y, m, d = first:match('^(%d+)-(%d+)-(%d+)$')
  local from_epoch = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
  if not from_epoch then return {} end
  local from = os.date('!%Y-%m-%d', from_epoch - (count - 1) * 86400)
  local ok, days = pcall(function() return reader:days(from, first) end)
  if not ok or type(days) ~= 'table' then return {} end
  local out = {}
  for _, item in ipairs(days) do
    if type(item) == 'table' and type(item.date) == 'string' then
      out[#out + 1] = { date = item.date, sec = tonumber(item.sec) or 0 }
    end
  end
  return out
end

return M
