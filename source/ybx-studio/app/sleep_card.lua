-- Shared by the foreground app and the future lock-screen entry.
local S={size=48062,width=480,height=800}
local function uint(bytes,at,n)
  local value=0
  for i=n-1,0,-1 do value=value*256+bytes:byte(at+i) end
  return value
end
function S.valid(bytes)
  if type(bytes)~='string' or #bytes~=S.size or bytes:sub(1,2)~='BM' or bytes:sub(7,10)~='YBX1' then return false end
  local height=uint(bytes,23,4)
  if height>=0x80000000 then height=height-0x100000000 end
  if uint(bytes,3,4)~=#bytes or uint(bytes,11,4)~=62 or uint(bytes,15,4)~=40
    or uint(bytes,19,4)~=S.width or math.abs(height)~=S.height or uint(bytes,27,2)~=1
    or uint(bytes,29,2)~=1 or uint(bytes,31,4)~=0 then return false end
  local a,b=bytes:sub(55,57),bytes:sub(59,61)
  return (a=='\0\0\0' and b=='\255\255\255') or (b=='\0\0\0' and a=='\255\255\255')
end
local function slot(storage,json,name)
  local ok,meta,bytes=pcall(function()
    local raw=storage:read('ybx-sleep-'..name..'.json')
    if type(raw)~='string' or #raw>256 then error('metadata read') end
    local record=json:decode(raw)
    if type(record)~='table' or type(record.revision)~='number' or record.revision%1~=0
      or record.revision<0 or record.revision>=2147483647 then error('metadata format') end
    if record.revision==0 and record.size==0 then return nil end
    if record.size~=S.size then error('metadata size') end
    local data=storage:read('ybx-sleep-'..name..'.bmp')
    if not S.valid(data) then error('image read') end
    return record,data
  end)
  if not ok then return nil,'Cannot read sleep cache.' end
  if meta then return {name=name,revision=meta.revision,bytes=bytes} end
end
function S.initialize(storage,json)
  local ok,ready=pcall(function()
    local a=storage:read('ybx-sleep-a.json')
    local b=storage:read('ybx-sleep-b.json')
    -- Repair only a demonstrably unfinished initialization, never a committed cache.
    if type(a)=='string' and type(b)=='string' then return true end
    local survivor=type(a)=='string' and a or type(b)=='string' and b
    if survivor then
      local record=json:decode(survivor)
      if type(record)~='table' or record.revision~=0 or record.size~=0 then return false end
      local missing=type(a)=='string' and 'b' or 'a'
      if storage:size('ybx-sleep-'..missing..'.json') or storage:size('ybx-sleep-'..missing..'.bmp') then return false end
      return storage:write('ybx-sleep-'..missing..'.json',json:encode({revision=0,size=0}))
    end
    if storage:size('ybx-sleep-a.json') or storage:size('ybx-sleep-b.json') then return false end
    local empty=json:encode({revision=0,size=0})
    return storage:write('ybx-sleep-a.json',empty) and storage:write('ybx-sleep-b.json',empty)
  end)
  return ok and ready
end
function S.current(storage,json)
  local a,ae=slot(storage,json,'a')
  local b,be=slot(storage,json,'b')
  local active=not a and b or not b and a or a and b and (a.revision>=b.revision and a or b)
  return active,ae or be
end
function S.save(storage,json,bytes)
  if not S.valid(bytes) then return false,'Invalid YBX sleep card.' end
  local ok,saved,reason=pcall(function()
    local active,error=S.current(storage,json)
    if error then return false,error end
    local name=active and active.name=='a' and 'b' or 'a'
    local revision=active and active.revision+1 or 1
    if revision>=2147483647 then return false,'Sleep cache revision limit reached.' end
    local image='ybx-sleep-'..name..'.bmp'
    local metadata='ybx-sleep-'..name..'.json'
    if not storage:write(image,bytes) or storage:read(image)~=bytes then return false,'Cannot save sleep image.' end
    local encoded=json:encode({revision=revision,size=S.size})
    if not storage:write(metadata,encoded) or storage:read(metadata)~=encoded then return false,'Cannot commit sleep image.' end
    return true
  end)
  return ok and saved or false,ok and reason or 'Sleep cache storage error.'
end
return S
