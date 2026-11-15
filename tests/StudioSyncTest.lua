local Sync=require('app.sync')
local calls, hashcalls, budget= {},0,0
local bytes=string.rep('a',5000)
local expected=bytes:sub(1,1024)..bytes:sub(1025,2048)..bytes:sub(4097,5000)
local ctx={state={event_owner='account-a'},screen={},clock={now=function()return {epoch_sec=1}end},budget={extend=function()budget=budget+1 end}}
ctx.hash={md5=function(self,data)assert(self==ctx.hash);hashcalls=hashcalls+1;assert(data==expected);return string.rep('b',16)end}
ctx.hex={encode=function(self,data)assert(self==ctx.hex and #data==16);return string.rep('62',16)end}
ctx.random={uuid=function(self)assert(self==ctx.random);return '01234567-0123-4123-8123-0123456789ab'end}
ctx.files={size=function()return #bytes end,read=function(_,name,offset,length)calls[#calls+1]=offset;return bytes:sub(offset+1,offset+length)end}
assert(Sync.partial_md5(ctx,ctx.files,'book.epub')==string.rep('62',16))
assert(#calls==3 and calls[1]==0 and calls[2]==1024 and calls[3]==4096 and budget==1)
local read=ctx.files.read
ctx.files.read=function(_,name,offset,length)if offset==1024 then return nil,'io_error' end;return read(nil,name,offset,length)end
local doc,err=Sync.partial_md5(ctx,ctx.files,'book.epub');assert(not doc and err=='read_failed' and hashcalls==1)
ctx.files.read=function(_,name,offset,length)if offset==1024 then return 'x' end;return read(nil,name,offset,length)end
doc,err=Sync.partial_md5(ctx,ctx.files,'book.epub');assert(not doc and err=='read_failed' and hashcalls==1)
ctx.files.read=read
local id=Sync.device_id(ctx);assert(id=='01234567-0123-4123-8123-0123456789ab' and Sync.device_id(ctx)==id)
local p,f=Sync.progress_pair(37.25);assert(p=='37.25' and f==0.3725)
p,f=Sync.progress_pair(0);assert(p=='0.00' and f==0)
p,f=Sync.progress_pair(100);assert(p=='100.00' and f==1)
local objects,files={},{};local n=0
ctx.json={encode=function(_,v)n=n+1;local key=tostring(n);objects[key]=v;return key end,decode=function(_,s)return objects[s]end}
ctx.storage={read=function(_,k)return files[k]end,write=function(_,k,v)files[k]=v;return true end}
assert(Sync.remember_sent(ctx,'book','70.00'));assert(Sync.sent(ctx).book=='70.00')
assert(Sync.remember_sent(ctx,'book','30.00'));assert(Sync.sent(ctx).book=='30.00')
ctx.state.event_owner='account-b';assert(next(Sync.sent(ctx))==nil)
assert(Sync.remember_sent(ctx,'book','10.00'));assert(Sync.sent(ctx).book=='10.00')
ctx.state.event_owner='account-a';assert(next(Sync.sent(ctx))==nil)
print('PASS: partial MD5 offsets, colon APIs, failed/short reads, stable UUID, percentages, backward progress, account isolation')
ctx.state.downloads={{file='book.epub'}}
ctx.state.links={['book.epub']={title='A book',author='An author'}}
local percent=70
ctx.reader={books=function()return {{id='reader-id',title='A book',author='An author',percent=percent}}end}
assert(Sync.collect(ctx,{})==1)
local entry=assert(Sync.head(ctx));assert(entry.progress=='70.00' and entry.percentage==0.7)
assert(Sync.collect(ctx,{})==0,'retry must reuse queued entry')
assert(Sync.head(ctx).id==entry.id)
assert(Sync.finish(ctx,entry));assert(Sync.pending(ctx)==0)
percent=30
assert(Sync.collect(ctx,{[entry.document]='70.00'})==1)
assert(Sync.head(ctx).progress=='30.00','backward progress must be queued')
ctx.state.event_owner='different-account';assert(Sync.pending(ctx)==0)
print('PASS: document mapping, persistent queue retry, acknowledgment, backward progress and queue owner')
local wire=Sync.position_body(ctx,'document',37.25)
local expected_fields={document=true,progress=true,percentage=true,device=true,device_id=true}
for key in pairs(wire)do assert(expected_fields[key],'position wire must not upload reading time: '..key)end
for key in pairs(expected_fields)do assert(wire[key]~=nil)end
assert(wire.progress=='37.25' and wire.percentage==0.3725)
print('PASS: position-only wire contract; no client minutes or fabricated reading intervals')
