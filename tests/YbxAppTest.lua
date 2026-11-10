local files,objects,serial,pending,clock={},{},0,nil,0
local fail_append,throw_append=false,false
local wifi_keep
local append_max=0
local dialogs={}
local epoch_now=0
local function set_epoch(v) epoch_now=v end
local function encode(_,v) serial=serial+1;local key='json:'..serial;objects[key]=v;return key end
local function decode(_,s) return objects[s] end
local rendered,rectangles={},{}
local function font(size) return {size=size,measure=function(_,s)return (utf8.len(s) or #s)*(size*.5)end} end
local storage={read=function(_,n,offset,length)local data=files[n];return data and length and data:sub((offset or 0)+1,(offset or 0)+length) or data end,size=function(_,n)return files[n] and #files[n]end,
 write=function(_,n,s)files[n]=s;return true end,remove=function(_,n)files[n]=nil;return true end,
 list=function(_)local out={}for name,data in pairs(files)do out[#out+1]={name=name,size=#data}end;return out end,
 append=function(_,n,s)append_max=math.max(append_max,#s);assert(#s<=262144,'stock append cap');if throw_append then error('append is unavailable')end;if fail_append then return nil,'quota_exceeded'end;files[n]=(files[n] or '')..s;return true end}
local ctx={dialog={confirm=function(_,opts,fn)dialogs[#dialogs+1]={opts=opts,fn=fn}end},crosspoint_reader_events=false,state={lang='en'},fonts={small=font(20),medium=font(24),large=font(30)},clock={millis=function()return clock end,now=function()return {epoch_sec=epoch_now+clock//1000}end},json={encode=encode,decode=decode},storage=storage,
 set_tick=function()end,invalidate=function()end,save_state=function()end,quit=function()end,
 net={request=function(_,opts,fn)pending={opts=opts,fn=fn};return {cancel=function()end}end,keep_wifi=function(_,ms)wifi_keep=ms end},
 files=storage,
 input={text=function(_,opts,fn)fn(nil,'Тест & a')end}}
local g={clear=function()rendered={};rectangles={}end,line=function()end,image=function()end,
 rect=function(_,x,y,w,h)assert(x>=0 and y>=0 and x+w<=480 and y+h<=800,'rect outside screen');rectangles[#rectangles+1]={x,y,w,h}end,
 text=function(_,x,y,s,opts)assert(x>=0 and y>=0 and y<800,'text outside screen');rendered[#rendered+1]={x=x,y=y,s=s}end}
dofile(assert(arg[1]))
local function draw()on_draw(ctx,g)end
local function controls()
 for i=1,40 do local name,v=debug.getupvalue(on_input,i);if not name then break end;if name=='buttons'then return v end end
 error('buttons unavailable')
end
local function click(label)
 draw()
 for _,b in ipairs(controls())do if b.label==label then on_input(ctx,{type='pointer',phase='up',gesture='tap',x=b.x+b.w/2,y=b.y+b.h/2});return end end
 local t={}for _,b in ipairs(controls() or {})do t[#t+1]=tostring(b.label)end
 error('Missing control: '..label..' | have: '..table.concat(t,' '))
end
local function contains(s)draw();local a={};for _,r in ipairs(rendered)do a[#a+1]=r.s end;return table.concat(a,' '):find(s,1,true)~=nil end
local function answer(code,data,headers)local p=assert(pending);pending=nil;p.fn(ctx,{status=code,body=encode(nil,data),headers=headers or {}})end
local function items()return {items={{id='a',title='На Западном фронте без перемен',author='Эрих Мария Ремарк',description='A description from the catalog.'},{id='b',title='Book two',author='Author'},{id='c',title='Book three',author='Author'}}}end
on_load(ctx);assert(contains('All your books in one library'));click('Connect YBX')
assert(decode(nil,pending.opts.body).client_id=='crosspoint')
answer(200,{device_code='device',user_code='ABCD',expires_in=600,interval=5});assert(contains('ABCD'))
click('Check');answer(400,{error='authorization_pending'});click('Check');assert(not pending)
clock=6000;click('Check');answer(200,{access_token='cp_test'})
assert(ctx.state.token=='cp_test');click('Open library');assert(pending.opts.url:find('limit=3',1,true));answer(200,items())
assert(contains('На Западном фронте без перемен'));click('На Западном фронте без перемен');assert(contains('A description'))
click('Download');answer(302,{}, {Location='https://cdn.example.org/book.epub'})
assert(not pending.opts.headers.Authorization)
local data='PK\3\4'..string.rep('x',300000);pending.opts.on_data(ctx,data);assert(append_max<=262144)
answer(200,{}, {['content-length']=tostring(#data)})
assert(#ctx.state.downloads==1 and files[ctx.state.downloads[1].file]==data)
assert(append_max>=131072,'large downloads must batch appends to limit SD operations')
answer(503,{});assert(contains('Ready to read'));click('Back to library')
click('On device');click('На Западном фронте без перемен');assert(contains('Available offline'))
click('Book actions');click('Remove download');click('Keep book');click('Back')
click('All books');answer(200,items());click('Next page');assert(pending.opts.url:find('page=2',1,true));answer(200,items())
click('Book two');click('Back');click('Previous page');assert(not pending and contains('Book two'),'a page loaded this session must come from cache')
click('Book two');click('Download');local failed=pending;fail_append=true;failed.opts.on_data(ctx,'PK\3\4'..string.rep('x',131068));fail_append=false
assert(contains('Could not save this book'));click('Technical details');assert(contains('quota_exceeded'))
failed.opts.on_data(ctx,'late');assert(not ctx.state.pending)
click('Back');click('Try again');throw_append=true;pending.opts.on_data(ctx,'PK\3\4'..string.rep('x',131068));throw_append=false
click('Technical details');assert(contains('append is unavailable'));click('Back');click('Back');click('Back')
click('Search');click('Title or author');assert(contains('EN'),'keyboard must offer a layout switch')
click('EN')
assert(contains('й'),'Russian layout must be selectable')
click('т');click('е');click('с');click('т');click('Shift');click('т');click('OK')
assert(pending.opts.url:find('q=%%D1%%82%%D0%%B5%%D1%%81%%D1%%82%%D0%%A2',1),'Cyrillic query with shift must be URL encoded')
answer(200,{items={}});assert(contains('No matching books'))
click('Library');click('Settings');click('Reading sync');assert(contains('Not available on stock'));click('Back')
click('Help & diagnostics');click('Check device storage');click('Run storage check');assert(contains('Create, append, read and remove: OK'));click('Back');click('Back')
click('KOSync');click('Get setup details');answer(200,{kosync_key='kosync_secret'})
assert(contains('https://my.ybx.app') and contains('/api/v1/crosspoint/kosync'));assert(not contains('kosync_secret'));click('Reveal credentials');assert(contains('kosync_secret'));click('Hide credentials');assert(not contains('kosync_secret'));click('Back')
click('Back');click('Stats');answer(200,{today='2026-11-09',today_minutes={value=0},current_streak_days=3,week_minutes=24,week_days={{date='2026-11-09',minutes=24,sources={'reader'}}},year_goal={finished=2,goal=12}})
assert(contains('0 min'));click('Calendar');answer(200,{today='2026-11-09'});answer(200,{days={{date='2026-11-09',minutes=24}}});click('9');assert(contains('24 min'));click('Back');click('Back')
click('Achievements');answer(200,{yandex={received={{title='First book',description='Read a book'}},pending={{title='Next goal',progress=.5}}}});click('First book');assert(contains('Read a book'));click('Back');click('Back')
click('Settings');click('Account');click('Sign out on this reader');click('Cancel');assert(ctx.state.token=='cp_test')
click('Sign out on this reader');click('Sign out');assert(ctx.state.token=='');assert(#ctx.state.downloads==1)
-- Without a files service and without append there is nothing to write through.
local append=storage.append
local noappend={}
for k,v in pairs(storage) do noappend[k]=v end
noappend.append=nil
ctx.state.token='cp_alias';ctx.crosspoint_reader_events=false
ctx.storage=noappend;ctx.files=nil
on_load(ctx);on_tick();answer(200,items());click('Book two');click('Download')
assert(contains('Could not save this book'));click('Technical details');assert(contains('Append API unavailable'))
assert(#ctx.state.downloads==1)
ctx.storage=storage;ctx.files=storage;storage.append=append
-- Language is a setting; Kazakh layout is opt-in on the keyboard.
on_load(ctx);on_tick();answer(200,items())
click('Settings');click('Language');assert(contains('Настройки'),'Russian UI labels must render')
assert(contains('Язык'));click('Язык');assert(contains('Тіл'))
click('Тіл');assert(contains('Settings'),'third tap returns to English')
click('Kazakh layout');assert(ctx.state.kb_kk==true)
click('Back');click('Search');click('Title or author')
if contains('РУ') then click('РУ') else click('EN');click('РУ') end
assert(contains('ә'),'Kazakh layout must be reachable once enabled')
for _,ch in ipairs{'д','ә','с','т','ү','р'} do click(ch) end
click('OK')
assert(pending.opts.url:find('%%D3%%99',1),'Kazakh query must be URL encoded')
answer(200,{items={}})
ctx.state.kb_kk=false
print('PASS: 3-language UI and optional Kazakh keyboard')
print('PASS: approved navigation, real catalog descriptions, bounded downloads, storage exceptions/alias, stale callbacks, activity, calendar, credentials, account isolation')
-- Existing sleep/account ownership protections remain reachable through the redesign.
on_load(ctx);on_tick();answer(200,items())
click('Settings');click('Sleep screen');click('Refresh picture')
local card='BM'..string.pack('<I4',48062)..'YBX1'..string.pack('<I4',62)
 ..string.pack('<I4i4i4I2I2I4I4i4i4I4I4',40,480,800,1,1,0,48000,0,0,2,0)
 ..'\0\0\0\0\255\255\255\0'..string.rep('\0',48000)
pending.opts.on_data(ctx,card);answer(200,{}, {['content-length']='48062'})
assert(files['ybx-sleep-a.bmp']==card);on_tick();click('Back')
local chosen=false
ctx.lockscreen={is_default=function()return chosen end,set_default=function()chosen=true;return true end,clear_default=function()chosen=false;return true end}
click('Use YBX sleep screen');assert(chosen);click('Back');click('Auto refresh');click('Refresh before sleep')
assert(decode(nil,files['ybx-stock-sleep.json']).token=='cp_alias');click('Back');click('Refresh before sleep');assert(files['ybx-stock-sleep.json']=='')
click('Back');click('Restore usual sleep screen');assert(not chosen);click('Back');click('Back');click('Back')
local fail_clear=false;local original_write=storage.write
storage.write=function(self,n,s)if fail_clear and n=='ybx-stock-sleep.json'then return false end;return original_write(self,n,s)end
click('Account');click('Sign out on this reader');fail_clear=true;click('Sign out');assert(ctx.state.token=='cp_alias' and contains('account unchanged'))
fail_clear=false;click('Back');click('Cancel');click('Back')
ctx.crosspoint_sleep_image=function(bytes)return bytes==nil or bytes==card end
ctx.crosspoint_sleep_refresh=function(raw)files['sleep-request.json']=raw;return true end
click('Sleep screen');click('Auto refresh');click('Refresh before sleep');assert(decode(nil,files['sleep-request.json']).headers.Authorization=='Bearer cp_alias')
click('Back');click('Refresh before sleep');assert(not files['sleep-request.json']);click('Back');click('Back');click('Back')
local fail_reader_clear=false
ctx.crosspoint_reader_upload=function(raw)if not raw and fail_reader_clear then return false end;files['reader-upload.json']=raw;return true end
click('Reading sync');click('Sync before sleep');local config=decode(nil,files['reader-upload.json'])
assert(config.events['reader.session'].duration=='duration' and config.headers.Authorization=='Bearer cp_alias')
click('Back');click('Back');click('Account');click('Sign out on this reader');fail_reader_clear=true;click('Sign out')
assert(ctx.state.token=='cp_alias' and files['reader-upload.json']);fail_reader_clear=false;click('Back');click('Sign out');assert(ctx.state.token=='' and not files['reader-upload.json'])
-- Native session delivery retains queue on error and removes only an acknowledged head.
ctx.crosspoint_reader_events=true;ctx.state.token='cp_reader';on_load(ctx);on_tick();answer(200,items())
local owner=ctx.state.event_owner;local file=ctx.state.downloads[1].file
local record={event='reader.session',event_id='abcdef01-1',owner=owner,file=file,ts=1794222012,doc=string.rep('a',32),start=1794222000,duration=12,progress_bp=1200}
files['reader-events.jsonl']=encode(nil,record)..'\n';on_tick();assert(decode(nil,pending.opts.body).duration==12)
answer(503,{});assert(files['reader-events.jsonl']~='');click('Back');click('Settings');click('Reading sync');click('Sync now');assert(decode(nil,pending.opts.body).event_id=='abcdef01-1')
answer(204,{});assert(files['reader-events.jsonl']=='')
print('PASS: cached sleep card, stock/CrossPoint settings, failed credential cleanup and reader-event retry')
on_load(ctx);on_tick();answer(200,items())
click('Library');if pending then answer(200,items()) end
click('On device');click(ctx.state.downloads[1].title);click('Book actions');click('Remove download')
local old_remove=storage.remove;files[file..'.track']=owner
storage.remove=function(self,n)if n==file..'.track'then return false end;return old_remove(self,n)end
click('Remove download');assert(files[file] and contains('The book is kept'))
storage.remove=old_remove;click('Back');click('Book actions');click('Remove download');click('Remove download');assert(not files[file] and not files[file..'.track'])
print('PASS: deletion retains EPUB when reader metadata cleanup fails')

-- Explicit navigation before the startup tick must stay on the selected screen.
ctx.crosspoint_reader_events=nil;ctx.state.token='cp_reader';on_load(ctx);pending=nil
click('On device');on_tick();assert(not pending and contains('On device'))
on_load(ctx);pending=nil;click('Settings');on_tick()
assert(not pending and contains('Account'))
click('Back');answer(200,items());click('Stats');answer(200,{})
assert(contains('No reading stats yet'));click('Achievements');answer(200,{})
click('Back');click('Calendar');assert(pending)
print('PASS: startup navigation, complete KOSync endpoint and independent activity routes')

-- Stock firmware saves through the native target; the Lua streaming path is
-- paced by the host loop and cannot finish a book inside its 120 s window.
answer(200,{});if pending then answer(200,{})end
local saved_append=storage.append;storage.append=nil
ctx.crosspoint_reader_events=nil;ctx.state.token='cp_stock';on_load(ctx);on_tick();answer(200,items())
click('Book three');click('Download');assert(pending.opts.save.to=='files' and not pending.opts.on_data)
assert(wifi_keep and wifi_keep>=300000,'requests must hold Wi-Fi awake')
answer(302,{}, {Location='https://cdn.example.org/book.epub'})
assert(not pending.opts.headers.Authorization and pending.opts.save.name)
local name=pending.opts.save.name;files[name]='PK\3\4native';answer(200,{}, {['content-length']='10'})
local event_body=decode(nil,pending.opts.body)
assert(event_body.event=='book.downloaded' and event_body.event_id:match('^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-%d+$'),
  'book.downloaded event_id must match the YBX wire format')
answer(204,{});assert(contains('Ready to read'))
click('Back to library');click('На Западном фронте без перемен');click('Download')
local name=pending.opts.save.name;files[name]='PK\3\4'
clock=clock+30000;on_tick();assert(pending and files[name])
files[name]='PK\3\4short';clock=clock+30000;on_tick();assert(pending and files[name])
answer(200,{}, {['content-length']='100'})
click('Technical details');assert(contains('saved 9 of 100 bytes') and not files[name])
print('PASS: stock native-save redirects, no bearer leak, completed file and incomplete cleanup')

click('Back');click('Try again');local stalled=pending;local file=stalled.opts.save.name
clock=clock+35000;on_tick();assert(not files[file]);click('Technical details');assert(contains('timed out'))
stalled.fn(ctx,{status=200,headers={}});assert(not files[file])
print('PASS: native progress beyond 35 seconds, stalled timeout and stale completion')

-- Stock firmware reports a save overflow as err='limit_exceeded', not error=.
click('Back');click('Try again');local limited=pending
limited.fn(ctx,{status=0,err='limit_exceeded',headers={}})
assert(contains('Could not save this book'));click('Technical details')
assert(contains('8 MB firmware download limit') and not files[limited.opts.save.name])
print('PASS: stock limit_exceeded is reported as an 8 MiB firmware limit')


-- A save that reports success but leaves nothing readable names both counts.
local kept2={}
for _,book in ipairs(ctx.state.downloads) do if book.id=='a' then files[book.file]=nil else kept2[#kept2+1]=book end end
ctx.state.downloads=kept2
on_load(ctx);on_tick();answer(200,items())
click('На Западном фронте без перемен');click('Download')
local empty=pending
empty.fn(ctx,{status=200,headers={['content-length']='587091'},saved=587091})
assert(contains('Could not save this book'));click('Technical details')
assert(contains('file missing, firmware saved 587091 B') and contains('files:'),
  'missing native save must report the missing file, the firmware count and the listing')
print('PASS: missing native save reports firmware/app byte counts and listing')

-- A boolean saved=true must report the Content-Length count, not just 'file missing'.
click('Back');click('Try again');local boolsaved=pending
boolsaved.fn(ctx,{status=200,headers={['content-length']='587091'},saved=true})
assert(contains('Could not save this book'));click('Technical details')
assert(contains('file missing, firmware saved 587091 B'),'a boolean saved flag must report the Content-Length count')
print('PASS: boolean saved flag reports the firmware byte count')

-- Stock saves into ctx.files; a save left under another name in that service is
-- adopted by size, and a boolean 'saved' flag must not confuse the report.
storage.append=saved_append
local keptB={}
for _,book in ipairs(ctx.state.downloads) do if book.id=='b' then files[book.file]=nil else keptB[#keptB+1]=book end end
ctx.state.downloads=keptB
on_load(ctx);on_tick();answer(200,items())
click('Book two');click('Download');assert(pending.opts.save and pending.opts.save.to=='files' and not pending.opts.on_data)
local target=pending.opts.save.name
local adopted='PK\3\4'..string.rep('z',210000)
files['~xtapp.dl']=adopted
pending.fn(ctx,{status=200,headers={['content-length']=tostring(#adopted)},saved=true})
assert(files[target]==adopted,'same-size entry in ctx.files must be adopted')
answer(204,{})
print('PASS: stock save found under another name in ctx.files is adopted')

-- If the save leaves nothing readable, the app retries once through streaming.
local keptC={}
for _,book in ipairs(ctx.state.downloads) do if book.id=='a' then files[book.file]=nil else keptC[#keptC+1]=book end end
ctx.state.downloads=keptC
on_load(ctx);on_tick();answer(200,items())
click('На Западном фронте без перемен');click('Download');assert(pending.opts.save)
pending.fn(ctx,{status=200,headers={['content-length']='13'}})
assert(pending.opts.on_data and not pending.opts.save and pending.opts.timeout_ms==60000,'failed stock save must fall back to streaming')
assert(wifi_keep and wifi_keep>=300000,'streaming must hold Wi-Fi awake')
local streamed='PK\3\4fallback'
pending.opts.on_data(ctx,streamed)
answer(200,{}, {['content-length']=tostring(#streamed)});answer(204,{})
assert(files[ctx.state.downloads[#ctx.state.downloads].file]==streamed)
print('PASS: failed stock save falls back to streaming and holds Wi-Fi')

-- 0.8.3 and earlier queued 32-hex event ids that YBX answers with HTTP 400.
ctx.crosspoint_reader_events=nil;ctx.state.token='cp_legacy';ctx.state.event_owner=string.rep('a',32)
files['ybx-events.json']=encode(nil,{owner=ctx.state.event_owner,events={{event='book.downloaded',event_id=string.rep('b',32),ts=0}}})
on_load(ctx);on_tick();assert(pending.opts.url:find('catalog',1,true));answer(200,items())
local repaired=decode(nil,files['ybx-events.json'])
assert(#repaired.events==1 and repaired.events[1].event_id:match('^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-%d+$'),
  'legacy 32-hex queue ids must be re-minted as <8 hex>-<digits>')
click('Settings');click('Help & diagnostics');click('Resend reports')
assert(decode(nil,pending.opts.body).event_id==repaired.events[1].event_id)
answer(204,{});assert(#decode(nil,files['ybx-events.json']).events==0)
print('PASS: legacy event ids are repaired on load, persisted and accepted')
-- 0.11: Russian by default, cached library, quiet refresh and idle prefetch.
do
  local saved=ctx.state
  ctx.state={};on_load(ctx)
  assert(contains('Все ваши книги в одной библиотеке'),'a fresh install opens in Russian')
  ctx.state=saved
end
ctx.state.lang='en';ctx.state.token='cp_cache';ctx.crosspoint_reader_events=nil;files['ybx-cache.json']=nil;pending=nil
on_load(ctx);on_tick();assert(pending and contains('Connecting to YBX'),'an empty cache loads in the foreground')
answer(200,items());assert(contains('Book two'))
on_load(ctx);assert(contains('Book two') and not contains('Connecting to YBX'),'launch shows the cached shelf at once')
on_tick();assert(pending and pending.opts.url:find('kind=reading',1,true) and not contains('Connecting to YBX'),'the shown shelf refreshes quietly')
local changed=items();changed.items[3].title='Book four';answer(200,changed)
assert(contains('Book four'),'a changed shelf redraws after the quiet refresh')
clock=clock+5000;on_tick();assert(pending and pending.opts.url:find('kind=all',1,true),'idle time prefetches All books')
answer(200,items())
clock=clock+5000;on_tick();assert(pending and pending.opts.url:find('kind=reading',1,true) and pending.opts.url:find('page=2',1,true),'idle time prefetches the next page')
answer(200,items())
click('All books');assert(not pending and contains('Book three') and not contains('Connecting to YBX'),'prefetched shelves open without a request')
click('Reading');click('Next page');assert(not pending and contains('Book two'),'prefetched next page opens without a request')
clock=clock+5000;on_tick();assert(pending and pending.opts.url:find('page=3',1,true),'the page after the visible one comes first');answer(200,{items={}})
clock=clock+5000;on_tick();local background=assert(pending);assert(background.opts.url:find('summary',1,true),'idle time prefetches stats')
click('Stats');local foreground=assert(pending);assert(foreground~=background,'a foreground request replaces the background one')
background.fn(ctx,{status=200,body=encode(nil,{today='2000-01-01'}),headers={}})
answer(200,{today='2026-11-09',today_minutes=15,week_days={}});assert(contains('15 min'))
click('Library');click('Settings');click('Account');click('Sign out on this reader');click('Sign out')
assert(files['ybx-cache.json']=='','signing out wipes the library cache')
print('PASS: Russian default, cached launch, quiet refresh, prefetch, cancellation and sign-out wipe')
-- 0.12: plugin 1.6.15 parity.
ctx.state.lang='en';ctx.state.token='cp_parity';ctx.state.server=nil;files['ybx-cache.json']=nil;pending=nil
on_load(ctx);on_tick();assert(pending.opts.url:find('v=1.6.16',1,true),'requests carry the plugin version');answer(200,items())
-- Stats: books this year, goal pace, continue reading and the book card.
click('Stats');answer(200,{today='2026-11-09',today_minutes={value=20},books_finished_this_year={value=5},
  year_goal={finished=5,goal=12,delta=3},week_days={},currently_reading={{id='r1',title='Reading one',author='A',percent={value=42}}}})
assert(contains('Books in 2026') and contains('Ahead of plan by 3 books'),'books this year and goal pace')
click('Continue reading');assert(contains('Reading one'));click('Reading one')
assert(pending.opts.url:find('/reading/books/r1',1,true),'book card asks for per-book stats')
answer(200,{percent={value=42,sources={'ybx_reader'}},minutes={value=135},sessions={value=7},started_at=1767225600})
assert(contains('42%') and contains('2 h 15 min') and contains('7') and contains('January 1, 2026') and contains('Data: YBX'),'book card shows the stats')
click('Open book');assert(contains('Reading one') and contains('Download'),'book card opens the book page')
click('Back');click('Back');click('Back')
-- European mirror: an unreachable main host is retried once on the mirror, which then stays preferred.
click('Library');click('Refresh');assert(pending.opts.url:find('https://my.ybx.app/',1,true))
answer(0,{});assert(pending and pending.opts.url:find('https://emy.ybx.app/',1,true),'auto mode retries on the mirror')
answer(200,items());click('Refresh');assert(pending.opts.url:find('https://emy.ybx.app/',1,true),'the mirror stays preferred');answer(200,items())
clock=clock+6*60*1000;click('Refresh');assert(pending.opts.url:find('https://my.ybx.app/',1,true),'main is tried again after five minutes');answer(200,items())
click('Settings');click('Help & diagnostics');click('Server');click('Server');assert(ctx.state.server=='eu' and contains('Europe'))
click('Back');click('Back');click('Refresh');assert(pending.opts.url:find('https://emy.ybx.app/',1,true));answer(0,{})
assert(not pending and contains('No network'),'a fixed server is never swapped')
click('Back');click('Settings');click('Help & diagnostics');click('Server');assert(ctx.state.server==nil);click('Back');click('Back')
-- Clear messages for a removed device and a server outage; 403 signs out like 401.
click('Refresh');answer(404,{error='not_found'},{['X-YBX-Device-Removed']='true'});assert(contains('removed in your YBX account'));click('Back')
click('Refresh');answer(502,{});assert(contains('temporarily unavailable'));click('Back')
-- KOSync: HTTP sync address, key check over HTTPS, quotes key.
click('Settings');click('KOSync');click('Get setup details');answer(200,{kosync_key='kosync_secret'})
assert(contains('http://sync.ybx.app') and contains('https://my.ybx.app/api/v1/crosspoint/kosync'),'both KOSync addresses')
click('Check key');assert(pending.opts.url=='https://my.ybx.app/api/v1/crosspoint/kosync/users/auth' and pending.opts.headers.Authorization:sub(1,6)=='Basic ')
answer(200,{});assert(contains('accepts this key'));click('Back');click('Back');click('KOSync')
click('Quotes and notes');click('Get quotes key');assert(pending.opts.url:find('/auth/clippings-key',1,true))
local clip='kosync_'..string.rep('a',43)
answer(200,{kosync_key=clip,sync_url='https://my.ybx.app/api/v1/crosspoint/kosync',clippings_enabled=true});click('Reveal credentials');assert(contains(clip:sub(1,28)))
click('Revoke quotes key');assert(pending.opts.url:find('/auth/clippings-key/revoke',1,true));answer(204,{});assert(contains('Quotes key revoked'))
-- The clippings sync_url may be the main host or the EU mirror (both answer the
-- same store); any other host or path is refused.
click('Back');click('Get quotes key')
answer(200,{kosync_key=clip,sync_url='https://emy.ybx.app/api/v1/crosspoint/kosync',clippings_enabled=true})
assert(contains('emy.ybx.app'),'the EU mirror clippings URL is accepted for a blocked reader')
click('Revoke quotes key');answer(204,{})
click('Back');click('Get quotes key')
answer(200,{kosync_key=clip,sync_url='https://my.ybx.app/wrong-path',clippings_enabled=true})
assert(contains('unsuitable quotes key'),'a wrong clippings path must be rejected')
click('Back');click('Get quotes key')
answer(200,{kosync_key=clip,sync_url='https://evil.example/api/v1/crosspoint/kosync',clippings_enabled=true})
assert(contains('unsuitable quotes key'),'an untrusted clippings host must be rejected')
click('Back');click('Back');click('Back');click('Back')
click('Refresh');answer(403,{});assert(ctx.state.token=='' and contains('Sign in again'),'403 signs out like 401')
print('PASS: plugin 1.6.16 parity: stats, book card, mirror, error messages, KOSync check and quotes key')
-- 0.12.1: store shortcuts on the Library screen.
ctx.state.lang='en';ctx.state.token='cp_store';files['ybx-cache.json']=nil;pending=nil
on_load(ctx);on_tick();answer(200,items())
click('WB');assert(pending.opts.url:find('/wb/catalog?stock=1&page=1',1,true),'WB button opens the WB catalog');answer(200,items())
click('LitRes');assert(pending.opts.url:find('/litres/catalog?stock=1&page=1',1,true));answer(200,items())
click('Yandex');assert(pending.opts.url:find('/catalog?shelf=all&page=1',1,true));answer(200,items())
click('Yandex');assert(not pending or pending.opts.url:find('kind=all',1,true),'tapping the active store returns to All books')
if pending then answer(200,items()) end
click('WB');assert(not pending and contains('Book two'),'a store visited this session opens from cache')
ctx.state.lang='ru';on_load(ctx);assert(contains('ЛитРес'),'Russian spelling matches the plugin')
ctx.state.lang='en'
print('PASS: store shortcuts for Yandex, WB and LitRes')
-- 0.12.2: where to connect stores (QR + link to ybx.app).
do
  local encoded,released=nil,0
  ctx.qr={encode=function(_,url) encoded=url;return {release=function() released=released+1 end} end}
  ctx.state.lang='en';ctx.state.token='cp_stores';files['ybx-cache.json']=nil;pending=nil
  on_load(ctx);on_tick();answer(200,items())
  click('Connect stores');assert(encoded=='https://ybx.app' and contains('Scan the code') and contains('ybx.app'),'library info button opens the QR screen')
  click('Back');assert(released==1 and contains('Book two'),'leaving releases the QR and returns to the library')
  click('Settings');click('Help & diagnostics');click('Connect stores');assert(contains('Refresh library'))
  click('Back');assert(released==2 and contains('Check device storage'),'Help returns to Help');click('Back');click('Back')
  click('WB');answer(409,{error='books_consent_required'});assert(contains('not connected yet') and contains('How to connect'))
  click('How to connect');assert(contains('Scan the code'),'the not-connected message links to the QR screen')
  click('Refresh library');assert(released==3 and pending and pending.opts.url:find('/wb/catalog',1,true),'refresh reloads the store');answer(200,items())
  assert(contains('Book two'))
  ctx.qr=nil
end
print('PASS: store connection screen with QR, three entry points and QR release')
-- Holding Delete keeps deleting until the finger lifts.
ctx.state.lang='en';ctx.state.token='cp_hold';files['ybx-cache.json']=nil;pending=nil
on_load(ctx);on_tick();answer(200,items())
click('Search');click('Title or author')
if contains('EN') then click('EN') end
for _,ch in ipairs{'а','б','в','г','д','е'} do click(ch) end
local del;draw();for _,b in ipairs(controls()) do if b.label=='Del' then del=b end end
local function touch(phase,x,y) on_input(ctx,{type='pointer',phase=phase,x=x or del.x+5,y=y or del.y+5}) end
touch('down');assert(contains('абвгд') and not contains('абвгде'),'touching Delete removes one letter at once')
clock=clock+300;on_tick();assert(contains('абвгд'),'nothing more before the hold delay')
clock=clock+200;on_tick();assert(contains('абвг') and not contains('абвгд'),'holding starts repeating')
clock=clock+120;on_tick();clock=clock+120;on_tick();assert(contains('аб') and not contains('абв'),'and keeps repeating')
touch('up');clock=clock+1000;on_tick();assert(contains('аб'),'lifting the finger stops it, without an extra delete')
touch('down');touch('move',20,120);clock=clock+1000;on_tick();assert(contains('а') and not contains('аб'),'sliding off the key stops it')
touch('up');on_input(ctx,{type='key',phase='down',key='back'})
print('PASS: holding Delete repeats until release')
-- A 429 without Retry-After must not crash (a missing header returned no value).
ctx.state.lang='en';ctx.state.token='cp_429';files['ybx-cache.json']=nil;pending=nil
on_load(ctx);on_tick();answer(429,{})
assert(contains('Too many requests'),'429 without Retry-After shows the rate-limit message')
print('PASS: rate limit without Retry-After')
-- Book file names "<Author> - <Title>.epub"; the CrossPoint reading tracker's
-- "<name>.track" must fit ctx.storage too; old ybx-N.epub records still load.
do
  local saved_files = {}
  for k, v in pairs(files) do saved_files[k] = v end
  for k in pairs(saved_files) do if k:sub(-5)=='.epub' then files[k]=nil end end -- start without earlier test books
  ctx.state.lang='en';ctx.state.token='cp_names';ctx.state.downloads={{id='old',file='ybx-3.epub',title='Old book',author='A'}};files['ybx-3.epub']='PK\3\4old'
  files['ybx-cache.json']=nil;pending=nil;ctx.crosspoint_reader_events=nil
  clock=clock+120000 -- past the previous test's 429 pause
  on_load(ctx);on_tick();answer(200,items())
  assert(#ctx.state.downloads==1 and ctx.state.downloads[1].file=='ybx-3.epub','an old numbered download is kept')
  click('На Западном фронте без перемен');click('Download')
  local name=pending.opts.save and pending.opts.save.name or ctx.state.pending
  assert(name=='Эрих Мария Ремарк - На Западном фронте без перемен.epub','named after author and title, got '..tostring(name))
  click('Cancel');pending=nil;on_leave()
  -- CrossPoint: the tracker writes "<name>.track" to ctx.storage, which here refuses spaces
  ctx.crosspoint_reader_events=true
  local real=storage.write
  storage.write=function(self,n,v) if n:find('%.track$') and n:find(' ') then return nil,'invalid_argument' end;return real(self,n,v) end
  on_load(ctx);on_tick();if pending then answer(200,items()) end
  click('Book two');click('Download')
  local name2=ctx.state.pending
  assert(name2=='Author_-_Book_two.epub','the tracker sidecar forces the underscore variant, got '..tostring(name2))
  storage.write=real;click('Cancel');pending=nil;on_leave();ctx.crosspoint_reader_events=false
  for k in pairs(files) do files[k]=nil end
  for k, v in pairs(saved_files) do files[k]=v end
end
print('PASS: "<Author> - <Title>.epub" names, tracker-safe variant, old names kept')
-- Update check: strict manifest validation, dialog, throttle and snooze.
set_epoch(1767225600)
ctx.state.lang='en';ctx.state.token='cp_update';files['ybx-cache.json']=nil;pending=nil
ctx.state.update_checked_at=0;ctx.state.update_skip_version=nil;ctx.state.update_skip_until=nil
local function uv(name)
  for i=1,300 do local n,v=debug.getupvalue(on_load,i);if not n then break end;if n==name then return v end end
end
local cache=uv('cache');if cache then cache.pages={} end
local u=uv('ui');u.update_check_at=nil;u.library_cache=nil;u.auto_library=false
clock=clock+120000;pending=nil
on_load(ctx);on_tick()
assert(pending and not pending.opts.url:find('/xtapp/',1,true),'a fresh session loads the catalog first')
answer(200,items())
assert(pending and pending.opts.url:find('/xtapp/latest.json',1,true),'auto update check after the first catalog')
answer(200,{app='ybx-xtapp',version='1.6.17',url='/xtapp/YBX-1.6.17.xtapp',size=176924,sha256=string.rep('a',64),notes=''})
assert(#dialogs==1 and dialogs[1].opts.title:find('1.6.17',1,true),'dialog announces the new version')
dialogs[1].fn(ctx,true);draw();assert(contains('1.6.17') and contains('Later'),'confirming opens the update screen')
click('Later')
assert(ctx.state.update_skip_version=='1.6.17' and ctx.state.update_skip_until>0,'Later snoozes the version')
assert(not pending,'Later must not start a download')
set_epoch(0)
local function session()
  pending=nil;on_load(ctx);on_tick();if pending then answer(200,items()) end
end
local function open_about() click('Settings');click('Help & diagnostics');click('About') end
local function check_updates()
  if uv('message')~='' then click('Back') end
  click('Check for updates')
end
local function update_body(extra)
  local body={app='ybx-xtapp',version='1.6.17',url='/xtapp/YBX-1.6.17.xtapp',size=176924,sha256=string.rep('a',64),notes=''}
  for k,v in pairs(extra or {}) do body[k]=v end
  answer(200,body)
end
session();open_about();check_updates()
assert(pending and pending.opts.url:find('/xtapp/latest.json?v=1.6.16',1,true),'manual check asks the chosen host and sends the version')
update_body({url='https://evil.example/x.xtapp'})
assert(contains('You have the latest version'),'absolute URLs are rejected')
check_updates();update_body({size=0})
assert(contains('You have the latest version'),'zero size is rejected')
check_updates();update_body({app='other'})
assert(contains('You have the latest version'),'foreign app id is rejected')
check_updates();update_body({version='1.6.16',url='/xtapp/YBX-1.6.16.xtapp'})
assert(contains('You have the latest version'),'the same version is not an update')
check_updates();answer(500,{})
assert(contains('Could not check for updates'),'a failed request is reported on a manual check')
check_updates();update_body({})
assert(#dialogs==2,'manual check ignores the snooze')
dialogs[2].fn(ctx,false);assert(not pending)
print('PASS: update check, validation, throttle and snooze')
