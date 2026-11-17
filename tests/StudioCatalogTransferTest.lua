-- Exercise the real app through host callbacks and ordinary touch actions.
local function fixture(persisted)
  local h={files=persisted or {},pending={},cancelled=0,time=0,objects={},serial=0,text={}}
  local function copy(v) if type(v)~='table' then return v end;local out={};for k,x in pairs(v)do out[k]=copy(x)end;return out end
  local function font(size)return {measure=function(_,s)return #s*size/2 end}end
  local store={read=function(_,n,o,l)local s=h.files[n];return s and l and s:sub((o or 0)+1,(o or 0)+l) or s end,
    size=function(_,n)return h.files[n] and #h.files[n]end,write=function(_,n,s)h.files[n]=s;return true end,
    remove=function(_,n)h.files[n]=nil;return true end,list=function()return {}end}
  local ctx={state={lang='en',token='synthetic-token',event_owner=string.rep('a',32)},storage=store,files=store,
    clock={millis=function()return h.time end,now=function()return {epoch_sec=0}end},
    fonts={small=font(20),medium=font(24),large=font(30)},budget={extend=function()end},
    package={image=function()return {width=88,height=88}end},set_tick=function()end,invalidate=function()end,save_state=function()end,
    json={encode=function(_,v)h.serial=h.serial+1;local k='object:'..h.serial;h.objects[k]=copy(v);return k end,decode=function(_,s)return copy(h.objects[s])end},
    net={keep_wifi=function()end,request=function(_,opts,fn)local job={opts=opts,fn=fn};h.pending[#h.pending+1]=job;job.cancel=function()job.cancelled=true;h.cancelled=h.cancelled+1 end;return job end}}
  local env=setmetatable({},{__index=_G});assert(load(appSource,'YBX','t',env))()
  local g={clear=function()h.text={}end,line=function()end,rect=function()end,image=function()end,text=function(_,x,y,s)h.text[#h.text+1]=s end}
  h.ctx=ctx;h.env=env
  function h:draw()env.on_draw(ctx,g)end
  function h:tick(ms)self.time=self.time+(ms or 0);env.on_tick(ctx)end
  function h:tap(x,y)self:draw();env.on_input(ctx,{type='pointer',phase='up',gesture='tap',x=x,y=y});self:draw()end
  function h:reply(data,extra)
    local job=assert(table.remove(self.pending,1),'request expected');assert(not job.cancelled)
    local response={status=200,ok=true,headers={},body=ctx.json:encode(data)}
    for k,v in pairs(extra or {})do response[k]=v end
    job.fn(ctx,response);self:draw();return job
  end
  function h:contains(text)for _,s in ipairs(self.text)do if s:find(text,1,true)then return true end end;return false end
  env.on_load(ctx);h:draw();return h
end
local book={id='book-one',title='A book',author='Author'}
local h=fixture();h:tick();h:reply({items={book},warnings={yandex_books='slow'}})
assert(not h.files['ybx-cache.json'],'partial foreground must not persist a page')
assert(h:contains('sources'),'partial foreground must be explained on screen')
h:tap(370,30);assert(#h.pending==1,'partial page can immediately be retried')
h:reply({items={book},warnings={}})
local saved=h.ctx.json:decode(h.files['ybx-cache.json']);assert(saved.schema==2 and #saved.pages['reading|1']==1)
print('PASS: partial foreground is visible but uncached; complete retry is persisted')
-- A cached complete page must survive a partial background refresh unchanged.
h.env.on_leave();h.env.on_load(h.ctx);h:tick()
assert(#h.pending==1,'cached page must revalidate in background')
h:reply({items={},warnings={'regional outage'}})
saved=h.ctx.json:decode(h.files['ybx-cache.json']);assert(#saved.pages['reading|1']==1)
assert(h:contains('A book'),'background partial must keep the last complete page')
assert(h:contains('sources'))
print('PASS: partial background refresh keeps the complete cache and visible page')
-- Old caches have no evidence that source warnings were checked.
h.files['ybx-cache.json']=h.ctx.json:encode({owner=h.ctx.state.event_owner,pages={['reading|1']={book}},order={'reading|1'}})
h.env.on_leave();h.env.on_load(h.ctx);h:draw();assert(not h:contains('A book'),'legacy cache must be invalidated')
h:tick();h:reply({items={book}})
-- Start a native save using the actual catalogue row and Download button.
h:tap(100,250);h:tap(100,730)
local download=assert(h.pending[1]);assert(download.opts.save and download.opts.timeout_ms==60000)
h:tick(45000);assert(not download.cancelled,'60-second save must survive 35 seconds without visible growth')
local filename=download.opts.save.name;h.files[filename]='PK\3\4'
h:reply({}, {body='',saved=true,bytes=4,headers={['content-length']='4'}})
assert(#h.ctx.state.downloads==1,'late successful save must be accepted')
print('PASS: atomic native save completes after 45 seconds with no visible file growth')
-- A lost completion still cancels after the host deadline plus callback grace.
h=fixture();h:tick();h:reply({items={book}});h:tap(100,250);h:tap(100,730)
download=assert(h.pending[1]);h:tick(64999);assert(not download.cancelled)
h:tick(1);assert(download.cancelled and h.ctx.state.pending==nil)
local late=download.fn;late(h.ctx,{status=200,saved=true,headers={},body=''})
assert(#h.ctx.state.downloads==0,'completion after cancellation must be ignored')
print('PASS: lost completion times out at 65 seconds, clears pending state and ignores late callbacks')
-- An explicit user Cancel on the loader must stop the save and clear pending state.
h=fixture();h:tick();h:reply({items={book}});h:tap(100,250);h:tap(100,730)
download=assert(h.pending[1])
h:tap(240,728)
assert(download.cancelled,'user cancel must stop the request')
assert(h.ctx.state.pending==nil and #h.ctx.state.downloads==0,'user cancel must clear the pending file')
late=download.fn;late(h.ctx,{status=200,saved=true,headers={},body=''})
assert(#h.ctx.state.downloads==0,'a completion after user cancel must be ignored')
-- Leaving the app during a native save is equally safe.
h=fixture();h:tick();h:reply({items={book}});h:tap(100,250);h:tap(100,730)
download=assert(h.pending[1]);h.env.on_leave()
assert(download.cancelled and h.ctx.state.pending==nil,'leave must cancel and clear pending')
late=download.fn;late(h.ctx,{status=200,saved=true,headers={},body=''})
assert(#h.ctx.state.downloads==0,'a completion after leave must be ignored')
print('PASS: user cancel and leave stop a native save, clear pending state and ignore late callbacks')
