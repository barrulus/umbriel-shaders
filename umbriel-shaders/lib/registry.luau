-- SPDX-License-Identifier: MIT
local U = require("./util.luau")
local S = require("./selection.luau")
local A = require("./async.luau")
local M = { repository="https://github.com/noctalia-dev/community-umbriel-shaders" }
local function text(v,limit) assert(type(v)=="string" and #v>0 and #v<=(limit or 2048) and not v:find("%z"),"Invalid catalogue string") end
local function list(values)
  assert(type(values)=="table" and #values<=64,"Invalid catalogue list")
  local seen={}
  for _,v in ipairs(values) do text(v,256); assert(not seen[v],"Duplicate list value"); seen[v]=true end
end
local function slug(s) return type(s)=="string" and #s<=128 and s:match("^[a-z0-9][a-z0-9%-]*$") and not s:find("--",1,true) and s:sub(-1)~="-" end
local function recipe(r)
  if r then
    assert(type(r)=="table" and type(r.settings)=="table","Invalid activation recipe")
    for k,v in pairs(r.settings) do S.setting(k,v) end
  end
end
function M.validate(r,localMode)
  assert(type(r)=="table" and r.schema_version==1 and type(r.draft)=="boolean" and (localMode or not r.draft),"A published schema-v1 catalogue is required")
  assert(r.source.repository==M.repository and (localMode or U.hex(r.source.revision,40)),"Catalogue needs the expected repository and a pinned revision")
  local total,count=0,0
  local media={png=true,webp=true,gif=true,mp4=true,webm=true}
  for name,record in pairs(r.files) do
    U.relative(name)
    local suffix=name:match("%.([^.]+)$")
    assert(media[suffix] or ({toml=true,glsl=true,md=true,txt=true})[suffix],"Invalid catalogue file type")
    assert(type(record.bytes)=="number" and record.bytes%1==0 and record.bytes>=0 and record.bytes<=(media[suffix] and 32*U.limit or 256*1024) and U.hex(record.sha256,64),"Invalid catalogue file metadata")
    total+=record.bytes; count+=1; A.checkpoint()
  end
  assert(count<=10000 and total<=512*U.limit,"Catalogue exceeds asset limits")
  assert(type(r.feature_definitions)=="table" and r.feature_definitions["preset-effects"] and #U.keys(r.feature_definitions)<=64,"Invalid feature definitions")
  for k,v in pairs(r.feature_definitions) do text(k,128); text(v) end
  assert(type(r.effects)=="table" and #r.effects<=512 and type(r.families)=="table" and #r.families<=64,"Too many catalogue records")
  local ids,names={},{}
  for _,e in ipairs(r.effects) do
    local kind,name=e.id:match("^([^/]+)/([^/]+)$")
    assert(S.kinds[kind] and slug(name) and not ids[e.id] and e.path==e.id and e.kind==kind,"Invalid effect identity")
    ids[e.id]=e
    assert(e.role=="effect" or e.role=="companion","Invalid catalogue role")
    for _,key in ipairs({"name","description","author","license","preset"}) do text(e[key]) end
    assert(#e.preset<=128 and not e.preset:find("/",1,true) and e.preset~="off" and not e.preset:match("^umbriel%-.*generation%-") and not names[e.preset],"Invalid preset name")
    names[e.preset]=true
    for _,key in ipairs({"tags","families","uses","dependencies","notice_files","install_files"}) do list(e[key]) end
    for _,slot in ipairs(e.uses) do assert(S.slot(slot) and (kind=="animation" and slot:match("^animation%.") or slot=="effects."..kind),"Invalid effect use") end
    assert(type(e.required_settings)=="table","Invalid required settings")
    for k,v in pairs(e.required_settings) do S.setting(k,v); assert(not k:match("^effects%.") and not k:match("%.effect$"),"Requirements cannot select effects") end
    if e.requirements then
      list(e.requirements.features)
      for _,feature in ipairs(e.requirements.features) do assert(r.feature_definitions[feature],"Unknown feature requirement") end
    end
    local shaders,install=0,{}
    for _,path in ipairs(e.install_files) do
      assert(r.files[path],"Missing installation asset")
      if path:match("%.glsl$") then shaders+=1; assert(path:sub(1,#e.id+1)==e.id.."/","Shader outside effect directory") end
      install[path]=true
    end
    assert(shaders==1 and install[e.id.."/effect.toml"] and #e.notice_files>0 and #e.install_files==#e.notice_files+2,"Invalid installation files")
    for _,path in ipairs(e.notice_files) do assert(install[path] and (path:match("%.md$") or path:match("%.txt$")),"Invalid attribution notice") end
    assert(type(e.preview)=="table","Invalid preview")
    for k,path in pairs(e.preview) do
      assert((k=="image" or k=="animation") and r.files[path],"Invalid preview path")
      local suffix=path:match("%.([^.]+)$")
      assert(k=="image" and (suffix=="png" or suffix=="webp") or k=="animation" and (suffix=="gif" or suffix=="mp4" or suffix=="webm"),"Invalid preview type")
    end
    recipe(e.activation); A.checkpoint()
  end
  local visiting,seen={},{}
  local function visit(id,depth)
    assert(ids[id] and not visiting[id] and depth<64,"Missing or cyclic dependency")
    if seen[id] then return end
    visiting[id]=true
    for _,dep in ipairs(ids[id].dependencies) do visit(dep,depth+1) end
    visiting[id]=nil; seen[id]=true
  end
  for id in pairs(ids) do visit(id,0) end
  seen={}
  for _,f in ipairs(r.families) do
    assert(slug(f.id) and not seen[f.id],"Invalid family identity"); seen[f.id]=true
    text(f.name); list(f.members)
    for _,member in ipairs(f.members) do assert(ids[member],"Missing family member") end
    for _,k in ipairs({"description","license"}) do if f[k] then text(f[k]) end end
    for _,k in ipairs({"authors","tags"}) do if f[k] then list(f[k]) end end
    recipe(f.activation)
  end
  return r
end
return M
