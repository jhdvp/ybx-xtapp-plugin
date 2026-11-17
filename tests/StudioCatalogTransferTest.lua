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
-- Explicit pagination: page_size is the stride, limit stays the item count.
-- Every XTApp catalogue request must carry both; other endpoints keep the
-- server's legacy lookahead because they omit the marker.
local function assert_paged(url,kind)
  assert(type(url)=='string' and url:find('page_size=3',1,true) and url:find('limit=3',1,true),
    kind..' URL must carry explicit page_size=3 and limit=3: '..tostring(url))
end
local p=fixture();p:tick()
local catalogue=assert(p.pending[1],'catalogue must issue a request')
assert_paged(catalogue.opts.url,'catalogue')
assert(catalogue.opts.url:find('/catalog/all?kind=reading',1,true))
p:reply({items={book}})
-- Drive search through real UI callbacks: Search tab, search field, a letter, OK.
p:tap(240,760);p:tap(240,110);p:tap(30,540);p:tap(410,750)
local search_request=assert(p.pending[1],'search must issue a request')
assert_paged(search_request.opts.url,'search')
assert(search_request.opts.url:find('q=q',1,true),'search must keep its query')
-- Provider shelf through real UI callbacks: filter, provider, yandex, apply.
local provider=fixture();provider:tick();provider:reply({items={book}})
provider:tap(400,168);provider:tap(240,568);provider:tap(240,210);provider:tap(240,728)
local provider_request=assert(provider.pending[1],'provider shelf must issue a request')
assert_paged(provider_request.opts.url,'provider')
assert(provider_request.opts.url:find('/catalog?shelf=all',1,true))
print('PASS: catalogue, search and provider URLs carry page_size=3 and limit=3')
-- A partial Search page shows the same inline warning and must still have a
-- working header Refresh, preserving the query, shelf and page on retry.
p:reply({items={book},warnings={yandex_books='slow'}})
assert(p:contains('sources'),'partial search must show the inline warning')
p:tap(370,30)
local retry=assert(p.pending[1],'partial search needs a working header Refresh')
assert_paged(retry.opts.url,'search retry')
assert(retry.opts.url:find('q=q',1,true) and retry.opts.url:find('page=1',1,true),
  'search retry must preserve query, shelf and page')
p:reply({items={book},warnings={}})
assert(not p:contains('sources'),'complete retry clears the partial warning')
print('PASS: partial Search exposes a real header Refresh and retries with the query intact')
-- ui.catalog_partial belongs to the last shown page: restoring a complete
-- cached Reading page from the Library tab must clear a partial Search page's
-- stale warning while keeping the original complete book on screen.
local lib=fixture();lib:tick();lib:reply({items={book}})
assert(lib:contains('A book'),'complete Reading page must be on screen before navigating away')
lib:tap(240,760) -- Search tab
lib:tap(240,110) -- search field
lib:tap(30,540)  -- type a letter
lib:tap(410,750) -- OK -> search request
lib:reply({items={book},warnings={yandex_books='slow'}})
assert(lib:contains('sources'),'partial search must show the inline warning')
lib:tap(80,760) -- Library tab: fast-path restores the complete cached Reading page
assert(lib:contains('A book'),'restored Library must show the original complete book')
assert(not lib:contains('sources'),'restoring a complete cached page must clear the Search warning')
print('PASS: Library restores the complete cached Reading page without the stale Search warning')
-- A background recovery must not dismiss an unrelated modal error just because
-- the non-modal partial warning happens to be set.
local m=fixture()
m.files['ybx-cache.json']=m.ctx.json:encode({schema=2,owner=m.ctx.state.event_owner,pages={['reading|1']={book}},order={'reading|1'}})
m.env.on_leave();m.env.on_load(m.ctx);m:tick()
assert(#m.pending==1,'cached page must revalidate in background')
m:reply({items={book},warnings={'regional outage'}})
assert(m:contains('sources'),'partial background refresh must show the inline warning')
m:tap(370,30)
local failing=assert(m.pending[1]);m:reply({}, {status=500,body=''})
assert(m:contains('Server error'),'unrelated modal error must be visible')
m:tick(3000)
local background=assert(m.pending[1],'idle prefetch must revalidate the cached shelf')
assert_paged(background.opts.url,'background catalogue')
m:reply({items={book}})
assert(m:contains('Server error'),'background recovery must not clobber a modal error')
m:tap(240,728) -- dismiss the modal
assert(m:contains('sources'),'partial warning must survive until a real recovery')
m:tap(370,30)
m:reply({items={book},warnings={}})
assert(not m:contains('sources') and m:contains('A book'),'ordinary recovery clears the warning and keeps the page')
print('PASS: background recovery preserves modal errors and clears only the non-modal warning')
