-- Randomized "monkey" test for the YBX XTApp: random taps, keys, touch holds,
-- ticks, restarts and language switches on stock Licorice and CrossPoint
-- hosts, while every request gets a random answer shaped for its endpoint
-- (valid, missing fields, wrong types, failures). Any Lua error is reported
-- with the steps that led to it.
--   node tests/run-tests.js tests/YbxMonkeyTest.lua   (or: lua tests/YbxMonkeyTest.lua source/ybx/index.lua [seeds] [steps])
local APP = assert(arg[1])
local SEEDS = tonumber(arg[2]) or 200
local STEPS = tonumber(arg[3]) or 400

local files, objects, serial, pending, clock, history = {}, {}, 0, nil, 0, {}
local dialog_pending = nil
local stats = { views = {}, answers = {} }
local SERVER_HOST = { main = 'https://my.ybx.app', eu = 'https://emy.ybx.app', pt = 'https://pmy.ybx.app' }
-- Set by the net mock; the app wraps requests in pcall, so it is raised by the loop.
local violation = nil
local function log(s) history[#history + 1] = s; if #history > 40 then table.remove(history, 1) end end
local function copy(v) if type(v) ~= 'table' then return v end local t = {} for k, x in pairs(v) do t[k] = copy(x) end return t end
local function encode(_, v) serial = serial + 1; local k = 'json:' .. serial; objects[k] = copy(v); return k end
local function decode(_, s) if type(s) ~= 'string' then error('decode expects a string') end; local v = objects[s]; if v == nil then error('invalid json') end; return copy(v) end
local function font(size) return { size = size, measure = function(_, s) return (utf8.len(s) or #s) * (size * .5) end } end
local storage = {
  read = function(_, n, o, l) local d = files[n]; return d and l and d:sub((o or 0) + 1, (o or 0) + l) or d end,
  size = function(_, n) return files[n] and #files[n] end,
  write = function(_, n, s) files[n] = s; return true end,
  remove = function(_, n) files[n] = nil; return true end,
  list = function() local out = {} for k, v in pairs(files) do out[#out + 1] = { name = k, size = #v } end return out end,
  append = function(_, n, s) assert(#s <= 262144, 'append cap'); files[n] = (files[n] or '') .. s; return true end,
}
local g = {
  clear = function() end, line = function() end,
  image = function(_, img) assert(img ~= nil, 'image must exist') end,
  rect = function(_, x, y, w, h) assert(x >= -1 and y >= -1 and x + w <= 481 and y + h <= 801, ('rect outside screen %d,%d %dx%d'):format(x, y, w, h)) end,
  text = function(_, x, y, s) assert(type(s) == 'string', 'text must be a string'); assert(y < 800, 'text below screen') end,
}
local picture = { release = function() end }
local ctx
local function new_ctx(seed)
  local crosspoint = seed % 2 == 0
  dialog_pending = nil
  ctx = {
    state = { lang = ({ 'en', 'ru', 'kk' })[seed % 3 + 1] },
    fonts = { small = font(20), medium = font(24), large = font(30) },
    clock = { millis = function() return clock end, now = function() return { epoch_sec = 1767225600 + clock // 1000 } end },
    json = { encode = encode, decode = decode }, storage = storage, files = storage,
    set_tick = function() end, invalidate = function() end, save_state = function() end, quit = function() end,
    net = { request = function(_, opts, fn)
      -- A fixed server choice must never put an API call on another mirror.
      local want = ctx.state.server and SERVER_HOST[ctx.state.server]
      if want then
        local host = tostring(opts.url):match('^(https://[^/]+)/api/v1/crosspoint')
        if host and host ~= want then violation = violation or ('API call on %s while server=%s'):format(host, tostring(ctx.state.server)) end
      end
      local req = { opts = opts, fn = fn }; pending = req; return { cancel = function() if pending == req then pending = nil end end }
    end, keep_wifi = function() end },
    qr = { encode = function() return picture end }, image = { decode = function() return picture end },
    system = { open = function() return true end },
    dialog = { confirm = function(_, opts, fn) dialog_pending = { opts = opts, fn = fn } end },
    lockscreen = { is_default = function() return math.random() < .5 end, set_default = function() return true end, clear_default = function() return true end },
    input = { text = function(_, _, fn) fn(nil, 'тест') end },
  }
  if crosspoint then
    ctx.crosspoint_reader_events = seed % 4 == 0
    ctx.crosspoint_sleep_image = function() return math.random() < .9 end
    ctx.crosspoint_sleep_refresh = function() return math.random() < .9 end
    ctx.crosspoint_reader_upload = function() return math.random() < .9 end
  end
  if seed % 5 ~= 0 then ctx.state.token = 'cp_monkey' end
  -- Every third seed pins one mirror, so the random taps walk Main, Europe and
  -- Portugal; the rest stay on Auto and move on main -> Europe -> Portugal.
  if seed % 3 == 0 then ctx.state.server = ({ 'main', 'eu', 'pt' })[(seed // 3) % 3 + 1] end
end

local function controls()
  for i = 1, 90 do local n, v = debug.getupvalue(on_input, i); if not n then break end; if n == 'buttons' then return v end end
  return {}
end

-- ------------------------------------------------------- endpoint answers
local function any() -- a value of a random, often wrong, type
  return ({ 7, -3, 0, 1e15, 'text', '', true, {}, { value = 12 }, { value = 'x' }, { value = 5, sources = { 'ybx_reader', 7 } } })[math.random(11)]
end
local function maybe(v) return math.random() < .85 and v or any() end
local function item(i)
  return { id = maybe(math.random() < .9 and ('b' .. i) or i), title = maybe('Книга ' .. i), author = maybe('Автор ' .. i),
    description = maybe(string.rep('Описание ', i % 40)), percent = maybe(math.random(0, 100)) }
end
local function list(n, f) local t = {} for i = 1, n do t[i] = f(i) end return t end
local function day(i) return { date = maybe(('2026-11-%02d'):format(i)), minutes = maybe(math.random(0, 300)), sources = math.random() < .7 and { 'reader' } or any() } end
local function body_for(url)
  if url:find('/auth/device', 1, true) then return { device_code = maybe('dev'), user_code = maybe('ABCD-1234'), interval = maybe(5), expires_in = maybe(600),
    verification_uri_complete = maybe(({ 'https://my.ybx.app/pair?code=1', 'http://evil.example', 'https://emy.ybx.app/pair', 'https://pmy.ybx.app/pair' })[math.random(4)]) } end
  if url:find('/auth/token', 1, true) then
    return ({ { access_token = 'cp_new' }, { error = 'authorization_pending' }, { error = 'slow_down' }, { error = 'expired_token' }, { error = 'invalid_grant' }, { access_token = string.rep('x', 5000) } })[math.random(6)] end
  if url:find('/auth/kosync-key', 1, true) then return { kosync_key = maybe(math.random() < .7 and 'kosync_abcdef' or 'bad') } end
  -- The clippings base comes back per host, so every mirror answers its own.
  if url:find('/auth/clippings-key', 1, true) then return { kosync_key = maybe('kosync_' .. string.rep('a', 43)), sync_url = maybe(({ 'https://my.ybx.app/api/v1/crosspoint/kosync', 'https://emy.ybx.app/api/v1/crosspoint/kosync', 'https://pmy.ybx.app/api/v1/crosspoint/kosync' })[math.random(3)]), clippings_enabled = maybe(true) } end
  if url:find('/reading/summary', 1, true) then
    return { today = maybe('2026-11-09'), today_minutes = maybe({ value = 20 }), current_streak_days = maybe(3), week_minutes = maybe(140),
      books_finished_this_year = maybe({ value = 5 }), year_goal = maybe({ finished = maybe(5), goal = maybe(12), delta = maybe(math.random(-4, 4)) }),
      week_days = maybe(list(math.random(0, 9), day)),
      currently_reading = maybe(list(math.random(0, 6), function(i) return { id = maybe('r' .. i), title = maybe('Читаю ' .. i), author = maybe('A'), percent = maybe({ value = 42 }) } end)) } end
  if url:find('/reading/calendar', 1, true) then return { days = maybe(list(math.random(0, 35), day)) } end
  if url:find('/reading/books/', 1, true) then
    return { percent = maybe({ value = 42, sources = { 'ybx_reader' } }), minutes = maybe({ value = 135 }), sessions = maybe({ value = 7 }),
      started_at = maybe(1767225600), finished_at = maybe(math.random() < .5 and 1790000000 or -5), dates_source = maybe('yandex') } end
  if url:find('/achievements', 1, true) then
    local a = function(i) return { title = maybe('Награда ' .. i), description = maybe('Описание'), progress = maybe(math.random()) } end
    return { yandex = maybe({ received = maybe(list(math.random(0, 25), a)), pending = maybe(list(math.random(0, 5), a)) }) } end
  if url:find('catalog', 1, true) then return { items = maybe(list(math.random(0, 4), item)) } end
  if url:find('/xtapp/latest.json', 1, true) then
    local v = maybe(({ '1.6.18', '1.6.15', 'x', '1.6.18.1' })[math.random(4)])
    return { app = maybe('ybx-xtapp'), version = v, url = maybe('/xtapp/YBX-' .. tostring(v) .. '.xtapp'),
      size = maybe(math.random(1, 200000)), sha256 = maybe(string.rep('a', 64)), notes = maybe('notes') }
  end
  return {}
end
local function answer()
  local p = pending; pending = nil
  local url = tostring(p.opts.url)
  local r = math.random()
  if r < .06 then log('  -> no response ' .. url:sub(-50)); p.fn(ctx, nil); return end
  local status, headers = 200, {}
  if r < .12 then status = 0
  elseif r < .13 then status = 401
  elseif r < .19 then status = 403
  elseif r < .22 then status = 404; if math.random() < .5 then headers['X-YBX-Device-Removed'] = 'true' end
  elseif r < .25 then status = 429; if math.random() < .5 then headers['Retry-After'] = tostring(({ 1, 5, 30, 60, 9999 })[math.random(5)]) end
  elseif r < .28 then status = ({ 409, 500, 502, 503 })[math.random(4)]
  elseif r < .31 then status = 302; headers.Location = ({ 'https://cdn.example/b.epub', 'http://insecure/b', '/api/v1/crosspoint/x', 'https://my.ybx.app/y' })[math.random(4)]
  elseif url:find('/revoke', 1, true) or url:find('/events', 1, true) then status = ({ 200, 204, 400 })[math.random(3)] end
  local body
  if url:find('/sleep-image', 1, true) or url:find('/download', 1, true) or url:find('/xtapp/YBX-', 1, true) or url:find('cdn.example', 1, true) then
    -- binary: stream chunks or let the firmware save
    local data = math.random() < .6 and ('PK\3\4' .. string.rep('x', math.random(0, 400000))) or string.rep('z', math.random(0, 100))
    if p.opts.on_data then
      local at = 1
      while at <= #data and math.random() < .97 do local n = math.random(1, 140000); p.opts.on_data(ctx, data:sub(at, at + n - 1)); at = at + n end
    elseif p.opts.save then files[p.opts.save.name] = data end
    if math.random() < .7 then headers['content-length'] = tostring(#data + (math.random() < .8 and 0 or 7)) end
    body = ''
  else
    body = math.random() < .05 and 'not json' or encode(nil, body_for(url))
  end
  local ep = (url:gsub('https://[^/]+/api/v1/crosspoint', ''):match('^/[%a%-]+') or url:sub(1, 20))
  stats.answers[ep .. ' ' .. status] = (stats.answers[ep .. ' ' .. status] or 0) + 1
  log(('  -> %s %s'):format(status, url:gsub('https://[^/]+/api/v1/crosspoint', ''):sub(1, 60)))
  p.fn(ctx, { status = status, body = body, headers = headers, saved = math.random() < .3 and 123 or nil, err = math.random() < .1 and 'limit_exceeded' or nil })
end

-- ----------------------------------------------------------------- actions
local QUERIES = { 'ремарк', 'мастер и маргарита', 'абай жолы', '   ', 'x', string.rep('я', 200) }
local function find_upvalue(name)
  for _, f in ipairs { on_draw, on_input, on_tick, on_load } do
    for i = 1, 200 do
      local n, v = debug.getupvalue(f, i); if not n then break end
      if n == name then return v end
      if type(v) == 'function' then for j = 1, 80 do local m, w = debug.getupvalue(v, j); if not m then break end; if m == name then return w end end end
    end
  end
end
local function act()
  local r = math.random()
  local buttons = controls()
  if dialog_pending and r < .25 then
    local d = dialog_pending; dialog_pending = nil
    local yes = math.random() < .5
    log('update dialog ' .. tostring(yes)); d.fn(ctx, yes); return
  end
  if pending and r < .35 then answer(); return end
  if r < .70 and #buttons > 0 then
    local b = buttons[math.random(#buttons)]
    log('tap ' .. tostring(b.label))
    on_input(ctx, { type = 'pointer', phase = 'up', gesture = 'tap', x = b.x + 1, y = b.y + 1 })
  elseif r < .78 then
    local k = ({ 'back', 'ok', 'up', 'down', 'left', 'right' })[math.random(6)]
    log('key ' .. k); on_input(ctx, { type = 'key', phase = 'down', key = k })
  elseif r < .84 then
    local x, y = math.random(0, 479), math.random(0, 799)
    local ph = ({ 'down', 'move', 'hold', 'up' })[math.random(4)]
    log(('touch %s %d,%d'):format(ph, x, y)); on_input(ctx, { type = 'pointer', phase = ph, x = x, y = y, gesture = ph == 'up' and 'long' or nil })
  elseif r < .92 then
    clock = clock + math.random(50, 40000); log('tick'); on_tick()
  elseif r < .95 then
    if math.random() < .5 then log('resume'); pending = nil; on_leave(); on_load(ctx) else log('restart'); pending = nil; on_leave(); dofile(APP); on_load(ctx) end -- on_leave(); on_load(ctx)
  elseif r < .975 then
    -- damage saved data the way a bad SD write could, then restart
    local names = { 'ybx-cache.json', 'ybx-events.json', 'reader-events.jsonl', 'reader-books.json', 'ybx-sleep-a.json', 'ybx-sleep-b.bmp', 'ybx-stock-sleep.json', 'sleep-request.json' }
    local name = names[math.random(#names)]
    local junk = ({ '', 'garbage', string.rep('\0', 50), encode(nil, { owner = 'x', pages = 'oops', order = { 1, {}, 'a' } }), encode(nil, { 1, 2, 3 }), encode(nil, 'str') })[math.random(6)]
    files[name] = junk
    local keys = { 'downloads', 'recent', 'lang', 'kb_kk', 'token', 'next_file', 'pending', 'event_owner', 'server' }
    ctx.state[keys[math.random(#keys)]] = ({ 'x', 5, {}, { 1, 'a', { file = 7 } }, true, false, string.rep('y', 5000) })[math.random(7)]
    log('corrupt ' .. name); pending = nil; on_leave(); dofile(APP); on_load(ctx)
  elseif r < .98 then
    ctx.state.lang = ({ 'en', 'ru', 'kk', 'xx' })[math.random(4)]; log('lang ' .. ctx.state.lang)
  else
    local kb = find_upvalue('kb')
    for _, b in ipairs(buttons) do
      if b.label == 'OK' and kb then kb.text = QUERIES[math.random(#QUERIES)]; log('type "' .. kb.text:sub(1, 20) .. '" OK'); b.action(); break end
    end
  end
end

local failures = 0
for seed = 1, SEEDS do
  math.randomseed(seed)
  files, pending, history, clock, violation = {}, nil, {}, 1000, nil
  new_ctx(seed)
  dofile(APP)
  local ok, err = xpcall(function()
    on_load(ctx)
    local idle = 0
    for _ = 1, STEPS do
      act(); on_draw(ctx, g)
      if violation then error(violation) end
      local v = find_upvalue('view'); stats.views[tostring(v)] = (stats.views[tostring(v)] or 0) + 1
      if find_upvalue('busy') and not pending then idle = idle + 1 else idle = 0 end
      if idle >= 1 then error('stuck busy on "' .. tostring(v) .. '" with no request in flight') end
    end
  end, debug.traceback)
  if not ok then
    failures = failures + 1
    print(('FAIL seed %d: %s'):format(seed, tostring(err):match('^[^\n]*')))
    print('  last steps: ' .. table.concat(history, ' | '):sub(-700))
    if failures >= 6 then break end
  end
end
if os.getenv('MONKEY_STATS') then
  local function dump(t) local keys = {} for k in pairs(t) do keys[#keys + 1] = k end table.sort(keys); local out = {} for _, k in ipairs(keys) do out[#out + 1] = k .. '=' .. t[k] end return table.concat(out, '  ') end
  print('views: ' .. dump(stats.views)); print('answers: ' .. dump(stats.answers))
end
print(failures == 0 and ('PASS: YBX monkey test, %d seeds x %d steps'):format(SEEDS, STEPS) or ('FAILED: %d seeds'):format(failures))
-- The wasmoon runner treats any os.exit as a failure; raise instead.
if failures ~= 0 then error('YBX monkey test failed') end
