-- Official Gancao channel; full SHA-256 verification of the stored package.
local M={MAX_BYTES=1048576,CHANNEL='gancao',MIN_API='2.26'}
function M.manifest(current, doc)
  if type(doc)~='table' or doc.app~='ybx-xtapp' or doc.channel~='gancao' or doc.min_api~='2.26' then return nil end
  local function parts(v)
    if type(v)~='string' or #v>32 then return nil end
    local a,b,c=v:match('^(%d+)%.(%d+)%.(%d+)$')
    if not a then return nil end
    a,b,c=tonumber(a),tonumber(b),tonumber(c)
    if a>9999 or b>9999 or c>9999 then return nil end
    return {a,b,c}
  end
  local a,b=parts(current),parts(doc.version)
  if not a or not b then return nil end
  local newer=false
  for i=1,3 do if b[i]~=a[i] then newer=b[i]>a[i];break end end
  if not newer or doc.url~='/xtapp/YBX-'..doc.version..'.xtapp' then return nil end
  if type(doc.size)~='number' or doc.size%1~=0 or doc.size<128 or doc.size>M.MAX_BYTES then return nil end
  if type(doc.sha256)~='string' or #doc.sha256~=64 or not doc.sha256:match('^[0-9a-f]+$') then return nil end
  return {version=doc.version,url=doc.url,size=doc.size,sha256=doc.sha256,notes=type(doc.notes)=='string' and doc.notes or ''}
end
function M.verify(ctx,store,name,size,expected)
  if type(size)~='number' or size%1~=0 or size<128 or size>M.MAX_BYTES
      or type(expected)~='string' or #expected~=64 or not expected:match('^[0-9a-f]+$') then return false end
  local ok,valid=pcall(function()
    ctx.budget:extend()
    if store:size(name)~=size then return false end
    local parts={}
    for offset=0,size-1,65536 do
      local length=math.min(65536,size-offset)
      local chunk=store:read(name,offset,length)
      if type(chunk)~='string' or #chunk~=length then return false end
      parts[#parts+1]=chunk
    end
    local bytes=table.concat(parts)
    if bytes:sub(1,4)~='XTAP' then return false end
    local digest=ctx.hash:sha256(bytes)
    return type(digest)=='string' and ctx.hex:encode(digest)==expected
  end)
  return ok and valid==true
end
return M
