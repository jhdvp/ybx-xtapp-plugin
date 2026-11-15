-- Counter snapshots for comparison only. Never creates active reading sessions.
local Sync = require('app.sync')
local M = {}
local FILE = 'ybx-reader-diagnostics.json'
local LIMIT = 32
local function owner(ctx) return ctx.state.event_owner end
local function empty(ctx) return {owner=owner(ctx),queue={},last={}} end
local function read(ctx)
  local ok, value=pcall(function()
    local raw=ctx.storage:read(FILE)
    if type(raw)~='string' or #raw>32768 then return nil end
    return ctx.json:decode(raw)
  end)
  if not ok or type(value)~='table' or value.owner~=owner(ctx) or type(value.queue)~='table' or type(value.last)~='table' then return empty(ctx) end
  local out=empty(ctx)
  local clock_ok,clock=pcall(function()return ctx.clock:now()end)
  local stamp=clock_ok and type(clock)=='table' and tonumber(clock.epoch_sec)
  for i,s in ipairs(value.queue) do
    if i>LIMIT then break end
    if type(s)=='table' and type(s.sample_id)=='string' and type(s.document)=='string'
        and #s.sample_id==36 and #s.document==32 and s.document:match('^[0-9a-f]+$')
        and type(s.read_sec)=='number' and s.read_sec>=0 and s.read_sec<=2147483647 and s.read_sec%1==0
        and type(s.observed_at)=='number' and s.observed_at%1==0
        and (not stamp or (s.observed_at>=stamp-30*86400 and s.observed_at<=stamp+300)) then out.queue[#out.queue+1]=s end
  end
  local count=0
  for key,v in pairs(value.last) do
    if count>=LIMIT then break end
    if type(key)=='string' and type(v)=='number' then out.last[key]=v;count=count+1 end
  end
  return out
end
local function write(ctx,value)
  local ok,result=pcall(function()return ctx.storage:write(FILE,ctx.json:encode(value))end)
  return ok and result==true
end
local function counter(value)
  return type(value)=='number' and value==value and value>=0 and value<=2147483647 and value%1==0
end
function M.enabled(ctx) return ctx.state.reader_diagnostics_enabled~=false end
function M.set_enabled(ctx, enabled)
  ctx.state.reader_diagnostics_enabled=enabled==true
  if not enabled then return write(ctx,empty(ctx)) end
  return true
end
function M.collect(ctx)
  if ctx.budget and type(ctx.budget.extend)=='function' then ctx.budget:extend() end
  if not M.enabled(ctx) then return 0 end
  local reader=Sync.reader(ctx)
  if not reader then return 0 end
  local ok,books=pcall(function()return reader:books()end)
  local clock_ok,clock=pcall(function()return ctx.clock:now()end)
  local stamp=clock_ok and type(clock)=='table' and clock.epoch_sec
  if not ok or type(books)~='table' or not counter(stamp) or stamp<946684800 then return 0 end
  local value=read(ctx);local added=0
  for i,book in ipairs(books) do
    if i>18 then break end
    if type(book)=='table' and counter(book.read_sec) and counter(book.percent) and book.percent<=100 then
      local document=Sync.document_for_reader_book(ctx,book)
      if document and value.last[document]~=book.read_sec then
        local made,id=pcall(function()return ctx.random:uuid()end)
        if made and type(id)=='string' and #id==36 then
          value.queue[#value.queue+1]={sample_id=id,document=document,read_sec=math.tointeger(book.read_sec),observed_at=math.tointeger(stamp),percent=math.tointeger(book.percent)}
          value.last[document]=book.read_sec;added=added+1
        end
      end
    end
  end
  while #value.queue>LIMIT do table.remove(value.queue,1)end
  local keys={};for key in pairs(value.last)do keys[#keys+1]=key end;table.sort(keys)
  for i=1,#keys-LIMIT do value.last[keys[i]]=nil end
  if added>0 and not write(ctx,value) then return 0 end
  return added
end
function M.batch(ctx)
  if not M.enabled(ctx) then return {} end
  local out={};for i,s in ipairs(read(ctx).queue)do if i>18 then break end;out[#out+1]=s end
  return out
end
function M.ack(ctx,response)
  if type(response)~='table' then return false end
  local ids={}
  for _,field in ipairs({'accepted','duplicates'})do
    for _,id in ipairs(type(response[field])=='table' and response[field] or {})do if type(id)=='string' then ids[id]=true end end
  end
  local value=read(ctx);local queue={};local removed=0
  for _,sample in ipairs(value.queue)do if not ids[sample.sample_id] then queue[#queue+1]=sample else removed=removed+1 end end
  if removed==0 then return false end
  value.queue=queue
  return write(ctx,value)
end
return M
