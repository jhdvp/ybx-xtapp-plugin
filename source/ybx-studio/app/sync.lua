-- YBX reading sync, following docs/XTApp-YBX-progress-sync-guide.md.
--
-- Three things are kept apart on purpose, because the guide shows they are three
-- different problems:
--
--   1. Identity. The server matches a book by the KOReader partial MD5 of the
--      EPUB bytes (section 3), not by title, author, or ctx.reader's id.
--   2. Position. A real position goes to PUT /kosync/syncs/progress as
--      {document, progress, percentage, device, device_id} (section 4). The
--      server turns a declared percentage into an approximate CFI itself.
--   3. Delivery status. HTTP 200 proves only that a route accepted the report.
--      "Saved", "accepted by YBX", "waiting for Yandex" and "confirmed in Yandex"
--      are different states and are not collapsed (sections 1, 7).
--
-- What is not claimed: exact page coordinates (the firmware gives a percentage,
-- not an xpointer, and inventing one is forbidden), and minute accounting, which
-- goes through a separate route with its own fields and its own authorisation
-- (section 5).

local M = {}

-- Up to 1024 bytes at offsets 0 and 1024*4^i for i = 0..10, fed to MD5 in order.
local OFFSET_COUNT = 12
local BLOCK = 1024

local function epoch_of(ctx)
  local ok, t = pcall(function() return ctx.clock:now() end)
  local value = ok and type(t) == 'table' and math.tointeger(t.epoch_sec)
  return value and value >= 0 and value <= 4102444800 and value or 0
end

local function today(ctx)
  local ok, t = pcall(function() return ctx.clock:now() end)
  if not ok or type(t) ~= 'table' then return nil end
  local y, m, d = tonumber(t.year), tonumber(t.month), tonumber(t.day)
  if not (y and m and d) then return nil end
  if y < 2000 or y > 2100 or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
  return string.format('%04d-%02d-%02d', y, m, d)
end

-- ---------------------------------------------------------------- identity

-- Reading a file in parts: a whole EPUB does not fit in one Lua string on the
-- device, and the hash needs only 12 * 1024 bytes anyway.
local function read_at(store, name, offset, length)
  local ok, data = pcall(function() return store:read(name, offset, length) end)
  if not ok or type(data) ~= 'string' or #data == 0 then return nil end
  return data
end

-- The KOReader partial MD5: blocks at offsets 0 and 1024*4^i for i = 0..10, up to
-- 1024 bytes each, offsets past the end skipped, the surviving blocks fed to MD5
-- in order. This is not a hash of the whole file, and it must be computed over
-- the exact bytes the device reads: repacking the EPUB changes it.
function M.partial_md5(ctx, store, name)
  if type(ctx.hash) ~= 'table' or type(ctx.hash.md5) ~= 'function' then return nil, 'no_hash' end
  if not store then return nil, 'no_store' end
  local ok, size = pcall(function() return store:size(name) end)
  if not ok or type(size) ~= 'number' or size <= 0 then return nil, 'no_file' end

  if ctx.budget and type(ctx.budget.extend) == 'function' then ctx.budget:extend() end
  local hash = ctx.hash
  local pieces = {}
  local offset = 0
  for i = 0, OFFSET_COUNT - 1 do
    -- 0, then 1024*4^i for i = 0..10: 12 reads in total.
    if i > 0 then offset = BLOCK * 4 ^ (i - 1) end
    if offset < size then
      local length = math.min(BLOCK, size - offset)
      local block = read_at(store, name, offset, length)
      if not block or #block ~= length then return nil, 'read_failed' end
      pieces[#pieces + 1] = block
    end
  end
  if #pieces == 0 then return nil, 'no_bytes' end

  -- ctx.hash:md5 takes a byte string; feeding it the concatenated blocks is the
  -- same bytes the server hashes in sequence.
  local ok_hash, digest = pcall(function() return hash:md5(table.concat(pieces)) end)
  if not ok_hash or type(digest) ~= 'string' then return nil, 'hash_failed' end
  if type(ctx.hex) == 'table' and type(ctx.hex.encode) == 'function' then
    local ok_hex, text = pcall(function() return ctx.hex:encode(digest) end)
    if ok_hex and type(text) == 'string' and #text == 32 then return text:lower() end
  end
  if #digest == 32 and digest:match('^[0-9a-fA-F]+$') then return digest:lower() end
  return nil, 'hash_format'
end

-- The document id for a downloaded book, cached because hashing touches the card.
-- A cache entry is valid only while the file size is unchanged.
function M.document_for(ctx, record)
  if type(record) ~= 'table' or type(record.file) ~= 'string' then return nil, 'no_record' end
  local state = ctx.state
  if type(state) ~= 'table' then return nil, 'no_state' end
  local store = M.store(ctx)
  if not store then return nil, 'no_store' end
  local ok_size, size = pcall(function() return store:size(record.file) end)
  if not ok_size or type(size) ~= 'number' or size <= 0 then return nil, 'no_file' end

  state.doc_hashes = type(state.doc_hashes) == 'table' and state.doc_hashes or {}
  local cached = state.doc_hashes[record.file]
  if type(cached) == 'table' and cached.doc and cached.size == size then
    return cached.doc
  end

  local document, reason = M.partial_md5(ctx, store, record.file)
  if not document then return nil, reason end

  -- The cache is bounded: drop the oldest entries past 32.
  local count = 0
  for _ in pairs(state.doc_hashes) do count = count + 1 end
  if count >= 32 then
    local keys = {}
    for key in pairs(state.doc_hashes) do keys[#keys + 1] = key end
    table.sort(keys)
    for i = 1, count - 32 + 1 do state.doc_hashes[keys[i]] = nil end
  end
  state.doc_hashes[record.file] = { doc = document, size = size }
  return document
end

-- The file store holding downloaded books: the app folder when available.
function M.store(ctx)
  local ok, files = pcall(function() return ctx.files end)
  if ok and type(files) == 'table' and type(files.read) == 'function' then return files end
  local ok_storage, storage = pcall(function() return ctx.storage end)
  if ok_storage and type(storage) == 'table' then return storage end
  return nil
end

-- A stable identity for this reader, as section 4 asks (not a random value per
-- request). Created once and kept in state.
function M.device_id(ctx)
  local state = ctx.state
  if type(state) ~= 'table' then return 'crosspoint' end
  if type(state.device_id) ~= 'string' or state.device_id == '' then
    local made
    if type(ctx.random) == 'table' and type(ctx.random.uuid) == 'function' then
      local ok, value = pcall(function() return ctx.random:uuid() end)
      if ok and type(value) == 'string' and value ~= '' then made = value end
    end
    if not made and type(ctx.hash) == 'table' and type(ctx.hash.md5) == 'function' then
      local seed = table.concat({ tostring(epoch_of(ctx)), tostring(math.random(1, 2 ^ 30)),
        tostring(ctx.screen and ctx.screen.width or 0), tostring(ctx.screen and ctx.screen.height or 0) }, ':')
      local ok, digest = pcall(function() return ctx.hash:md5(seed) end)
      if ok and type(digest) == 'string' and type(ctx.hex) == 'table' then
        local encoded, text = pcall(function() return ctx.hex:encode(digest) end)
        if encoded and type(text) == 'string' then made = text end
      end
    end
    state.device_id = made or 'crosspoint'
  end
  return state.device_id
end

-- ---------------------------------------------------------------- position

-- "37.25" and 0.3725 for 37.25%. The server checks that the two agree within
-- 0.011 percentage points, and wants the string form even for a whole percent.
function M.progress_pair(percent)
  local value = tonumber(percent)
  if not value or value ~= value then return nil end
  if value < 0 then value = 0 end
  if value > 100 then value = 100 end
  local hundredths = math.floor(value * 100 + 0.5)
  local text = string.format('%d.%02d', hundredths // 100, hundredths % 100)
  return text, hundredths / 10000
end

-- Body for PUT /kosync/syncs/progress (section 4).
function M.position_body(ctx, document, percent)
  local progress, percentage = M.progress_pair(percent)
  if not progress then return nil end
  return {
    document = document,
    progress = progress,
    percentage = percentage,
    device = 'crosspoint',
    device_id = M.device_id(ctx),
  }
end

-- ---------------------------------------------------------------- queue
--
-- Section 7: an id is created once, the report is saved before sending, a retry
-- sends the same report with the same id, and accounts do not share a queue.

local QUEUE = 'ybx-sync-queue.json'
local QUEUE_LIMIT = 32

local function owner_key(ctx)
  local state = ctx.state
  local owner = type(state) == 'table' and state.event_owner or nil
  if type(owner) == 'string' and owner ~= '' then return owner end
  return 'default'
end

local function read_queue(ctx)
  local ok, raw = pcall(function() return ctx.storage:read(QUEUE) end)
  if not ok or type(raw) ~= 'string' or #raw > 16384 then return {} end
  local good, value = pcall(function() return ctx.json:decode(raw) end)
  if not good or type(value) ~= 'table' or value.owner ~= owner_key(ctx) then return {} end
  local out = {}
  for _, entry in ipairs(type(value.reports) == 'table' and value.reports or {}) do
    if type(entry) == 'table' and type(entry.id) == 'string' and type(entry.document) == 'string'
      and type(entry.progress) == 'string' then
      out[#out + 1] = entry
    end
  end
  return out
end

local function write_queue(ctx, reports)
  local ok, result = pcall(function()
    return ctx.storage:write(QUEUE, ctx.json:encode({ owner = owner_key(ctx), reports = reports }))
  end)
  return ok and result
end

-- Queue one report per book whose progress moved. The report gets its id here,
-- once, and keeps it across retries and restarts.
function M.collect(ctx, last_sent)
  local reader = M.reader(ctx)
  if not reader then return 0 end
  local ok, books = pcall(function() return reader:books() end)
  if not ok or type(books) ~= 'table' then return 0 end
  local state = ctx.state
  if type(state) ~= 'table' or type(state.downloads) ~= 'table' then return 0 end

  local reports = read_queue(ctx)
  local queued = {}
  for _, entry in ipairs(reports) do queued[entry.document] = true end
  local added = 0

  -- Only books this app downloaded have a known document id, and only those can
  -- be reported: the guide forbids inventing one for a foreign book.
  for _, book in ipairs(books) do
    if type(book) == 'table' then
      local percent = tonumber(book.percent)
      local document = M.document_for_reader_book(ctx, book)
      if document and percent then
        local progress, percentage = M.progress_pair(percent)
        local seen = type(last_sent) == 'table' and last_sent[document] or nil
        if progress and seen ~= progress and not queued[document] then
          local id
          if type(ctx.random) == 'table' and type(ctx.random.uuid) == 'function' then
            local ok_uuid, value = pcall(function() return ctx.random:uuid() end)
            if ok_uuid and type(value) == 'string' then id = value end
          end
          id = id or (tostring(epoch_of(ctx)) .. '-' .. tostring(math.random(1, 2 ^ 30)))
          reports[#reports + 1] = {
            id = id,
            document = document,
            progress = progress,
            percentage = percentage,
            at = epoch_of(ctx),
          }
          queued[document] = true
          added = added + 1
        end
      end
    end
  end

  while #reports > QUEUE_LIMIT do table.remove(reports, 1) end
  if added > 0 and not write_queue(ctx, reports) then return 0 end
  return added
end

-- Which downloaded file the reader is on. ctx.reader's id is the firmware's own
-- and says nothing about the server, so the file is found through the reading
-- position the app recorded when it handed the file over.
function M.document_for_reader_book(ctx, book)
  if type(book) ~= 'table' then return nil end
  local state = ctx.state
  local links = type(state) == 'table' and state.links or nil
  if type(links) ~= 'table' then return nil end
  local title = type(book.title) == 'string' and book.title:lower():match('^%s*(.-)%s*$') or nil
  local author = type(book.author) == 'string' and book.author:lower():match('^%s*(.-)%s*$') or nil
  if not title or title == '' then return nil end
  if author=='' then author=nil end
  local present={}
  for _,download in ipairs(state.downloads or {}) do if type(download)=='table' and type(download.file)=='string' then present[download.file]=true end end
  local matched
  for file, record in pairs(links) do
    if present[file] and type(record) == 'table' and type(record.title) == 'string' then
      local linked_title = record.title:lower():match('^%s*(.-)%s*$')
      local linked_author = type(record.author) == 'string' and record.author:lower():match('^%s*(.-)%s*$') or nil
      if linked_author=='' then linked_author=nil end
      if linked_title == title and (not author or not linked_author or linked_author == author) then
        if matched then return nil end -- ambiguous editions must not share counters
        matched=file
      end
    end
  end
  if matched then return M.document_for(ctx,{file=matched}) end
  return nil
end

-- Remember which file a YBX id was downloaded as, at the moment the app hands it
-- to the reader (the only moment the pair is known for certain).
function M.link_launch(ctx, file, record)
  if type(file) ~= 'string' or file == '' or type(record) ~= 'table' then return false end
  local state = ctx.state
  if type(state) ~= 'table' then return false end
  state.links = type(state.links) == 'table' and state.links or {}
  local count = 0
  for _ in pairs(state.links) do count = count + 1 end
  if count >= 32 then
    local keys = {}
    for key in pairs(state.links) do keys[#keys + 1] = key end
    table.sort(keys)
    for i = 1, count - 32 + 1 do state.links[keys[i]] = nil end
  end
  state.links[file] = {
    id = type(record.id) == 'string' and record.id or '',
    title = type(record.title) == 'string' and record.title or '',
    author = type(record.author) == 'string' and record.author or '',
  }
  return true
end

function M.reader(ctx)
  local ok, reader = pcall(function() return ctx.reader end)
  if not ok or type(reader) ~= 'table' then return nil end
  return reader
end

function M.kosync_key(ctx)
  local state = ctx.state
  local key = type(state) == 'table' and state.kosync_key or nil
  if type(key) == 'string' and key:match('^kosync_[%w_-]+$') and #key <= 256 then return key end
  return nil
end

function M.pending(ctx)
  return #read_queue(ctx)
end

-- Delivery is tracked separately from sending: a report that YBX accepted is not
-- the same as one Yandex has, so the status of the last accepted report is kept.
function M.mark_status(ctx, entry, status)
  if type(entry) ~= 'table' then return false end
  local state = ctx.state
  if type(state) ~= 'table' then return false end
  state.sync_status = { at = epoch_of(ctx), state = tostring(status),
    document = type(entry.document) == 'string' and entry.document or nil }
  return true
end

-- Last progress sent per document, so an unchanged position is not resent.
function M.sent(ctx)
  local ok, raw = pcall(function() return ctx.storage:read('ybx-sync-sent.json') end)
  if not ok or type(raw) ~= 'string' or #raw > 16384 then return {} end
  local good, value = pcall(function() return ctx.json:decode(raw) end)
  if not good or type(value) ~= 'table' or value.owner ~= owner_key(ctx) or type(value.positions) ~= 'table' then return {} end
  local out = {}
  for key, item in pairs(value.positions) do
    if type(key) == 'string' and type(item) == 'string' then out[key] = item end
  end
  return out
end

function M.remember_sent(ctx, document, progress)
  if type(document) ~= 'string' or type(progress) ~= 'string' then return false end
  local map = M.sent(ctx)
  map[document] = progress
  local count = 0
  for _ in pairs(map) do count = count + 1 end
  if count > 128 then
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    for i = 1, count - 128 do map[keys[i]] = nil end
  end
  local ok, result = pcall(function()
    return ctx.storage:write('ybx-sync-sent.json', ctx.json:encode({owner = owner_key(ctx), positions = map}))
  end)
  return ok and result ~= false
end

-- A report the server refused as unmappable is dropped: retrying cannot fix an
-- unknown document, and the guide says not to invent one.
function M.drop(ctx, entry)
  if type(entry) ~= 'table' or type(entry.id) ~= 'string' then return false end
  local reports = read_queue(ctx)
  for i, item in ipairs(reports) do
    if item.id == entry.id then
      table.remove(reports, i)
      return write_queue(ctx, reports) and true or false
    end
  end
  return false
end

function M.head(ctx)
  local reports = read_queue(ctx)
  return reports[1]
end

-- Remove a report only when its delivery was confirmed, never merely because a
-- route answered 200 (section 7).
function M.finish(ctx, entry)
  if type(entry) ~= 'table' or type(entry.id) ~= 'string' then return false end
  local reports = read_queue(ctx)
  for i, item in ipairs(reports) do
    if item.id == entry.id then
      table.remove(reports, i)
      return write_queue(ctx, reports) and true or false
    end
  end
  return false
end

return M
