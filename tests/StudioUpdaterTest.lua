local U=require('app.updater')
local sha=string.rep('a',64)
local doc={app='ybx-xtapp',channel='gancao',min_api='2.26',version='1.7.1',url='/xtapp/YBX-1.7.1.xtapp',size=128,sha256=sha}
assert(U.manifest('1.7.0',doc).sha256==sha)
assert(not U.manifest('1.7.1',doc));doc.channel='legacy';assert(not U.manifest('1.7.0',doc));doc.channel='gancao'
doc.url='https://untrusted.invalid/a.xtapp';assert(not U.manifest('1.7.0',doc));doc.url='/xtapp/YBX-1.7.1.xtapp'
doc.size=U.MAX_BYTES+1;assert(not U.manifest('1.7.0',doc));doc.size=128
local bytes='XTAP'..string.rep('x',124);local expected=bytes
local ctx={budget={extend=function()end},hash={sha256=function(_,s)return s==expected and string.rep('a',32) or string.rep('b',32)end},hex={encode=function(_,s)return s:sub(1,1)=='a' and sha or string.rep('b',64)end}}
local store={size=function()return #bytes end,read=function(_,_,offset,length)return bytes:sub(offset+1,offset+length)end}
assert(U.verify(ctx,store,'update',128,sha))
bytes=bytes:sub(1,127)..'z';assert(not U.verify(ctx,store,'update',128,sha),'same-size corruption rejected')
bytes=expected;assert(not U.verify(ctx,store,'update',129,sha))
store.read=function()return nil,'io_error'end;assert(not U.verify(ctx,store,'update',128,sha))
print('PASS: firmware channel, version and URL constraints, persisted package SHA-256, corruption/truncation/read-error rejection')
