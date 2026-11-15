-- Lock screen: draw the card the server generated.
--
-- The picture is composed on the server (/sleep-image?w=480&h=800) and stored as
-- a 1-bit BMP: 480x800, 62-byte header, 60 bytes per row, pixel data at 62.
--
-- ctx.image:decode is not relied on: image_decode is an optional capability and
-- a lock session may run without it, which is exactly how the card failed to
-- appear. The stored rows go into a layer through set_bits instead: required,
-- no capability, available in a lock session (section 11, 2.21). The BMP is
-- already the screen size, so nothing is scaled.
--
-- BMP bit and palette order are honoured: a row stored bottom-up is turned over,
-- and a palette whose entry 0 is black means a 0 bit is ink, drawn inverted.
local SleepCard = require('app.sleep_card')
local card          -- { image = layer, invert = boolean, decoded = boolean }
local note

local function release_card()
  if card and card.image then pcall(function() card.image:release() end) end
  card = nil
end

-- The stored rows, top row first, ready for set_bits.
local function pixel_rows(bytes)
  local width, height = SleepCard.width, SleepCard.height
  local row_bytes = (width + 7) // 8
  local total = row_bytes * height
  local pixels = bytes:sub(63, 63 + total - 1)
  if #pixels ~= total then return nil end

  -- A negative height means the rows are already top-down.
  if bytes:byte(26) < 128 then
    local rows = {}
    for y = total - row_bytes + 1, 1, -row_bytes do
      rows[#rows + 1] = pixels:sub(y, y + row_bytes - 1)
    end
    pixels = table.concat(rows)
  end
  return pixels, bytes:byte(55) == 0
end

local function build_from_bits(ctx, bytes)
  if type(ctx.layers) ~= 'table' then return nil end
  local pixels, black_is_zero = pixel_rows(bytes)
  if not pixels then return nil end
  local created = ctx.layers:create(SleepCard.width, SleepCard.height)
  if not created then return nil end
  if type(created.set_bits) ~= 'function' then
    pcall(function() created:release() end)
    return nil
  end
  local ok, written = pcall(function() return created:set_bits(pixels, 0) end)
  if not ok or not written then
    pcall(function() created:release() end)
    return nil
  end
  return { image = created, invert = black_is_zero }
end

local function build_from_decode(ctx, bytes)
  if not (ctx.capabilities and ctx.capabilities.image_decode) then return nil end
  if type(ctx.image) ~= 'table' or type(ctx.image.decode) ~= 'function' then return nil end
  local ok, decoded = pcall(function()
    return ctx.image:decode(bytes, { max_w = SleepCard.width, max_h = SleepCard.height })
  end)
  if not ok or not decoded then return nil end
  return { image = decoded, invert = false, decoded = true }
end

-- Draw the card; returns true when something reached the screen.
-- g:image returns nothing on success and nil, "code" on failure, so both
-- returns are checked instead of one.
local function draw_card(g)
  if not card then return false end
  local opts = card.invert and { invert = true } or nil
  local ok, err = pcall(function()
    local _, failure = g:image(card.image, 0, 0, opts)
    return failure
  end)
  if not ok or err then return false end
  return true
end

local function load_card(ctx)
  release_card()
  local ok, current = pcall(function() return SleepCard.current(ctx.storage, ctx.json) end)
  if not ok or type(current) ~= 'table' or type(current.bytes) ~= 'string' then
    note = 'Open YBX and refresh the sleep card.'
    return
  end
  card = build_from_bits(ctx, current.bytes) or build_from_decode(ctx, current.bytes)
  if not card then note = 'The stored card could not be drawn.' end
end

function on_load(ctx)
  load_card(ctx)
end

function on_tick() end
function on_input() return false end

function on_draw(ctx, g)
  g:clear(0)
  if draw_card(g) then return end

  -- The invert option needs the image_transform capability; when it is missing,
  -- draw the same layer through the decoder instead, which applies no transform.
  if card and card.invert and not card.decoded then
    local ok, current = pcall(function() return SleepCard.current(ctx.storage, ctx.json) end)
    if ok and type(current) == 'table' and type(current.bytes) == 'string' then
      local swapped = build_from_decode(ctx, current.bytes)
      if swapped then
        release_card()
        card = swapped
        if draw_card(g) then return end
      end
    end
    note = 'The card could not be drawn.'
  end

  local font = ctx.fonts.medium
  local mark=ctx.package:image('ybx_brand_88')
  if mark then g:image(mark,20,264,{w=48,h=48}) end
  g:text(20, 330, 'YBX.app', { font = font })
  g:text_box(20, 372, ctx.screen.width - 40, 120,
    note or 'Open YBX and refresh the sleep card.', { font = font, wrap = 'word' })
end
