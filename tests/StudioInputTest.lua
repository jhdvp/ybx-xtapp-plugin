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

ctx.package={image=function()return {width=88,height=88}end}
ctx.budget={extend=function()end}
assert(load(appSource))()
local function contains(s)for _,r in ipairs(rendered)do if r.s:find(s,1,true)then return true end end;return false end
on_load(ctx);on_draw(ctx,g)
assert(contains('All your books'))
assert(on_input(ctx,{type='key',key='ok',phase='down'})==true)
on_draw(ctx,g);assert(contains('All your books'),'keydown must not activate')
assert(on_input(ctx,{type='key',key='ok',phase='up'})==true)
on_draw(ctx,g);assert(contains('Account'),'keyup activates focused Settings')
assert(on_input(ctx,{type='key',key='back',phase='down'})==true)
on_draw(ctx,g);assert(contains('Account'),'back down must not navigate')
assert(on_input(ctx,{type='key',key='back',phase='up'})==true)
on_draw(ctx,g);assert(contains('All your books'))
assert(on_input(ctx,{type='key',key='back',phase='up'})==false,'root Back passes to host')
print('PASS: real app key-up activation, handled Back release, root exit and native branding draw')
