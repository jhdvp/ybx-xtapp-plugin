local D=require('app.diagnostics');local Sync=require('app.sync')
local original=Sync.document_for_reader_book
Sync.document_for_reader_book=function(_,b)return b.test_doc end
local function clone(v)if type(v)~='table'then return v end;local out={};for k,x in pairs(v)do out[k]=clone(x)end;return out end
local objects,files,n,ids={},{},0,0
local stamp=1794770000;local seconds=120;local failed=false
local ctx={state={event_owner='a'},clock={now=function()return {epoch_sec=stamp}end}}
ctx.storage={read=function(_,k)return files[k]end,write=function(_,k,v)if failed then return nil,'io_error'end;files[k]=v;return true end}
ctx.json={encode=function(_,v)n=n+1;objects[tostring(n)]=clone(v);return tostring(n)end,decode=function(_,v)return clone(objects[v])end}
ctx.random={uuid=function()ids=ids+1;return string.format('00000000-0000-4000-8000-%012d',ids)end}
ctx.reader={books=function()return {{id='private-id',title='private title',test_doc=string.rep('a',32),read_sec=seconds,percent=40}}end}
assert(D.collect(ctx)==1);local batch=D.batch(ctx);assert(#batch==1 and batch[1].read_sec==120)
assert(batch[1].title==nil and batch[1].reader_id==nil and batch[1].active_ms==nil)
assert(not D.ack(ctx,{}),'a 200 response without sample acknowledgments must not count as success')
local first=batch[1].sample_id
assert(D.collect(ctx)==0 and D.batch(ctx)[1].sample_id==first,'retry stable')
assert(D.ack(ctx,{accepted={first}}));assert(#D.batch(ctx)==0)
seconds=180;stamp=stamp+10;assert(D.collect(ctx)==1)
seconds=5;stamp=stamp+10;assert(D.collect(ctx)==1,'counter reset retained for server classification')
assert(#D.batch(ctx)==2 and D.batch(ctx)[2].read_sec==5)
local second=D.batch(ctx)[1].sample_id
assert(D.ack(ctx,{duplicates={second}}));assert(#D.batch(ctx)==1)
ctx.state.event_owner='b';assert(#D.batch(ctx)==0);assert(D.collect(ctx)==1,'new account baseline')
D.set_enabled(ctx,false);assert(D.collect(ctx)==0 and #D.batch(ctx)==0)
D.set_enabled(ctx,true);failed=true;seconds=20;assert(D.collect(ctx)==0 and #D.batch(ctx)==0,'failed write cannot create phantom sent marker')
failed=false;assert(D.collect(ctx)==1)
stamp=stamp+31*86400;assert(#D.batch(ctx)==0,'stale samples cannot block new batches')
seconds=0/0;assert(D.collect(ctx)==0);seconds=-1;assert(D.collect(ctx)==0)
seconds=1.5;assert(D.collect(ctx)==0);seconds=math.huge;assert(D.collect(ctx)==0)
Sync.document_for_reader_book=original
print('PASS: diagnostic snapshots, no titles or active intervals, retry ids, reset, account switch, disable, write failure, expiry and invalid counters')
