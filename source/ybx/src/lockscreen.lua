-- Stock lock entry. Optional networking depends on the firmware; always retain a cached card.
local picture, picture_key
local function release_picture()
  if picture then pcall(function() picture:release() end) end
  picture=nil;picture_key=nil
end
local generation,asked,job=0,false,nil
local function cancel_request()
  generation=generation+1
  if job then pcall(function() job:cancel() end) end
  job=nil
end
local function refresh_once(ctx)
  if asked then return end
  asked=true
  local ok,raw,token,host=pcall(function()
    local text=ctx.storage:read('ybx-stock-sleep.json')
    if type(text)~='string' or #text==0 or #text>8192 then return end
    local config=ctx.json:decode(text)
    if type(config)~='table' or type(config.token)~='string' or #config.token==0 or #config.token>4096 then return end
    local host=(config.host=='https://emy.ybx.app' or config.host=='https://pmy.ybx.app') and config.host or 'https://my.ybx.app'
    return text,config.token,host
  end)
  if not ok or not token then return end
  generation=generation+1
  local current=generation
  local data=''
  local pending=true
  local function abandon()
    pending=false;cancel_request();data=''
  end
  local started,handle=pcall(function()
    return ctx.net:request({url=host..'/api/v1/crosspoint/sleep-image?w=480&h=800&v=1.6.17',
      method='GET',headers={Authorization='Bearer '..token},timeout_ms=15000,
      on_data=function(_,chunk)
        if current~=generation or not pending then return end
        if type(chunk)~='string' or #chunk>SleepCard.size-#data then abandon();return end
        data=data..chunk
      end},function(_,response)
        if current~=generation or not pending then return end
        pending=false;job=nil
        pcall(function()
          if type(response)~='table' or response.status~=200 then return end
          if #data==0 and type(response.body)=='string' then data=response.body end
          if not SleepCard.valid(data) or ctx.storage:read('ybx-stock-sleep.json')~=raw then return end
          for name,value in pairs(type(response.headers)=='table' and response.headers or {}) do
            if tostring(name):lower()=='content-length' and tonumber(value)~=#data then return end
          end
          if SleepCard.save(ctx.storage,ctx.json,data) then ctx:invalidate() end
        end)
        data=''
      end)
  end)
  if not started then abandon();return end
  if handle and pending then job=handle
  elseif handle then pcall(function() handle:cancel() end) end
end
function on_load() cancel_request();asked=false;release_picture() end
function on_leave() cancel_request();release_picture() end
function on_unload() cancel_request();release_picture() end
function on_tick() end
function on_input() return false end
function on_draw(ctx,g)
  refresh_once(ctx)
  local current=SleepCard.current(ctx.storage,ctx.json)
  local note
  if current then
    local key=current.name..':'..current.revision
    if key~=picture_key then
      local ok,next_picture=pcall(function()
        return ctx.image:decode(current.bytes,{max_w=SleepCard.width,max_h=SleepCard.height})
      end)
      if ok and next_picture then
        release_picture();picture=next_picture;picture_key=key
      else note='New YBX card could not be decoded.' end
    end
  else note='Open YBX and refresh Sleep card.' end
  g:clear(0)
  if picture then
    local ok,result=pcall(function() return g:image(picture,0,0) end)
    if ok and result~=false then return end
    release_picture();note='YBX card could not be displayed.'
  end
  g:text(20,340,'YBX')
  g:text(20,380,note or 'Open YBX and refresh Sleep card.')
end
