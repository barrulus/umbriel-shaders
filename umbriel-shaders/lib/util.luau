-- SPDX-License-Identifier: MIT
local A = require("./async.luau")
local sha = require("./sha256.luau")
local toml = require("./vendor/tinytoml.luau")
local M = { hash = sha, limit = 1024*1024, marker = "umbriel-shaders-generation-" }
function M.keys(t)
  local result = {}
  for k in pairs(t or {}) do table.insert(result,k) end
  table.sort(result)
  return result
end
function M.copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k,v in pairs(t) do out[k] = M.copy(v) end
  return out
end
function M.equal(a,b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k,v in pairs(a) do if not M.equal(v,b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
function M.json(value, depth)
  depth = depth or 0
  assert(depth <= 32,"Document nesting exceeds limit")
  if type(value) ~= "table" then return (assert(noctalia.json.encode(value),"Cannot encode value")) end
  local out = {}
  if #value > 0 then
    for _,v in ipairs(value) do table.insert(out,M.json(v,depth+1)) end
    return "["..table.concat(out,",").."]"
  end
  for _,k in ipairs(M.keys(value)) do
    assert(type(k)=="string","Invalid document key")
    table.insert(out,M.json(k)..":"..M.json(value[k],depth+1))
  end
  return "{"..table.concat(out,",").."}"
end
function M.decode(raw)
  assert(type(raw)=="string" and #raw <= 4*M.limit,"Document exceeds limit")
  local depth, quoted, escaped = 0,false,false
  for i=1,#raw do
    local c=raw:sub(i,i)
    if quoted then
      if escaped then escaped=false elseif c=='\\' then escaped=true elseif c=='"' then quoted=false end
    elseif c=='"' then quoted=true
    elseif c=='{' or c=='[' then depth+=1; assert(depth<=32,"Document nesting exceeds limit")
    elseif c=='}' or c==']' then depth-=1 end
    if i%4096==0 then A.checkpoint() end
  end
  return (assert(noctalia.json.decode(raw),"Invalid JSON document"))
end
function M.token()
  return sha(tostring(noctalia.nowMs())..":"..tostring(math.random())..":"..tostring(math.random())):sub(1,32)
end
function M.hex(s,n) return type(s)=="string" and #s==n and s:match("^[0-9a-f]+$")~=nil end
function M.relative(s)
  assert(type(s)=="string" and s~="" and s:sub(1,1)~="/" and not s:find("[%z\1-\31\\$~:]") and not s:find("//",1,true),"Unsafe relative path")
  for part in s:gmatch("[^/]+") do assert(part~="." and part~="..","Unsafe path component") end
  assert(s:sub(-1)~="/","Unsafe path component")
  return s
end
function M.path(root,relative) return root.."/"..M.relative(relative) end
function M.normalize(s)
  assert(type(s)=="string" and s:sub(1,1)=="/" and not s:find("%z"),"An absolute path is required")
  local parts={}
  for part in s:gmatch("[^/]+") do
    if part==".." then table.remove(parts) elseif part~="." then table.insert(parts,part) end
  end
  return "/"..table.concat(parts,"/")
end
function M.parent(s) return s:match("^(.*)/[^/]+$") or "/" end
function M.reference(parent,ref)
  assert(type(ref)=="string" and ref:sub(1,1)~="/","Expected relative preset reference")
  local normalized=M.normalize("/"..parent.."/"..ref):sub(2)
  return M.relative(normalized)
end
function M.expand(s,parent)
  assert(type(s)=="string","Invalid configuration path")
  s=noctalia.expandPath(s)
  s=s:gsub("%${([^}]+)}",function(key) return noctalia.getenv(key) or "" end)
  s=s:gsub("%$([%a_][%w_]*)",function(key) return noctalia.getenv(key) or "" end)
  return M.normalize(s:sub(1,1)=="/" and s or parent.."/"..s)
end
function M.exists(path) return noctalia.fileExists(path) end
function M.read(path,limit)
  limit=limit or M.limit
  local info=noctalia.fileInfo(path)
  assert(info and not info.isDir and info.size<=limit,"Cannot read file within size limit: "..path)
  local raw,err
  -- procfs reports zero-sized files and can reject the host async reader's large read.
  if info.size>0 and info.size<=4*M.limit then
    raw,err=A.await(function(cb) return noctalia.readFileAsync(path,cb) end)
  else raw,err=noctalia.readFile(path) end
  assert(type(raw)=="string" and #raw<=limit,err or "File grew beyond size limit")
  return raw
end
function M.atomic(path,raw)
  assert(noctalia.mkdirAll(M.parent(path)),"Cannot create storage directory")
  local temp=path..".next-"..M.token()
  local ok,err=noctalia.writeFile(temp,raw)
  assert(ok,err or "Cannot write temporary file")
  ok,err=noctalia.renameFile(temp,path)
  if not ok then noctalia.removeFile(temp); error(err or "Cannot replace file") end
end
function M.save(path,value)
  local raw=M.json(value)
  assert(#raw<=M.limit,"Persistent document exceeds limit")
  M.atomic(path,raw)
end
function M.load(path) return M.decode(M.read(path)) end
function M.remove(path)
  if M.exists(path) then assert(noctalia.removeFile(path),"Cannot remove "..path) end
end
function M.fingerprint(path) return sha(path.."\n"..M.read(path)) end
function M.verify(files)
  for _,path in ipairs(M.keys(files)) do
    if files[path]=="missing" then assert(not M.exists(path),"Optional file appeared: "..path)
    else assert(M.fingerprint(path)==files[path],"File changed: "..path) end
  end
end
function M.toml(raw)
  assert(#raw<=M.limit,"TOML exceeds size limit")
  return toml.parse(raw,{load_from_string=true,max_nesting_depth=32,parse_datetime_as="string",checkpoint=A.checkpoint})
end
function M.value(value)
  if type(value)~="table" then return M.json(value) end
  local out={}
  if #value>0 then
    for _,v in ipairs(value) do table.insert(out,M.value(v)) end
    return "["..table.concat(out,",").."]"
  end
  for _,k in ipairs(M.keys(value)) do table.insert(out,M.json(k).." = "..M.value(value[k])) end
  return "{ "..table.concat(out,", ").." }"
end
function M.settingLines(settings)
  local lines={}
  for _,key in ipairs(M.keys(settings)) do
    local parts={}
    for part in key:gmatch("[^.]+") do table.insert(parts,M.json(part)) end
    table.insert(lines,table.concat(parts,".").." = "..M.value(settings[key]))
  end
  return lines
end
return M
