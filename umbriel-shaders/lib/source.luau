-- SPDX-License-Identifier: MIT
local A = require("./async.luau")
local U = require("./util.luau")
local R = require("./registry.luau")
local S = require("./selection.luau")
local Local = require("./local_source.luau")
local M = {}; local Source={}; Source.__index=Source
local origin="https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/"
local function download(url,limit)
  assert(url:sub(1,#origin)==origin and not url:find("[\r\n]"),"Unexpected download origin")
  local response=A.await(function(cb) return noctalia.http({url=url,follow_redirects=false},cb) end)
  assert(response.ok and response.status==200,"Catalogue download failed (HTTP "..tostring(response.status)..")")
  assert(type(response.body)=="string" and #response.body<=limit,"Download exceeds expected size")
  return response.body
end
function M.open(root,refresh)
  local mode=noctalia.getConfig("source_mode") or "online"
  local cache=U.path(root,"catalogue-cache/"..mode)
  local self=setmetatable({mode=mode,cache=cache,offline=false},Source)
  if mode=="online" then
    local path=cache.."/catalogue.json"
    if refresh or not U.exists(path) then
      local ok,raw=pcall(download,origin.."catalogue/catalogue.json",4*U.limit)
      if ok then self.registry=R.validate(U.decode(raw),false); U.atomic(path,raw)
      else assert(U.exists(path),raw); self.offline=true end
    end
    self.registry=self.registry or R.validate(U.decode(U.read(path,4*U.limit)),false)
  elseif mode=="local" then
    self.assets=U.normalize(noctalia.expandPath(noctalia.getConfig("source_root") or ""))
    self.registry=Local.build(self.assets,cache,refresh)
  else
    assert(mode=="snapshot","Invalid catalogue source mode")
    local index=noctalia.expandPath(noctalia.getConfig("catalogue_index") or "")
    self.assets=U.normalize(noctalia.expandPath(noctalia.getConfig("assets_root") or ""))
    self.registry=R.validate(U.decode(U.read(index,4*U.limit)),false)
  end
  return self
end
function Source:url(name)
  U.relative(name)
  local encoded=name:gsub("([^%w%-%._~/])",function(c) return string.format("%%%02X",string.byte(c)) end)
  return origin..self.registry.source.revision.."/"..encoded
end
function Source:object(name)
  return U.path(self.cache,"objects/"..self.registry.files[name].sha256..(name:match("%.[^.]+$") or ""))
end
function Source:bytes(name)
  local record=assert(self.registry.files[name],"Asset is absent from catalogue")
  local path=self.mode=="online" and self:object(name) or U.path(self.assets,name)
  local function matches(raw) return #raw==record.bytes and U.hash(raw)==record.sha256 end
  if U.exists(path) then
    local ok,raw=pcall(U.read,path,record.bytes)
    if ok and matches(raw) then return raw end
    assert(self.mode=="online","Local catalogue asset changed: "..name)
  else assert(self.mode=="online","Missing local catalogue asset: "..name) end
  local raw=download(self:url(name),record.bytes)
  assert(matches(raw),"Catalogue asset failed SHA-256 verification")
  U.atomic(path,raw)
  return raw
end
function Source:browse(offset)
  offset=offset or 0
  local r=self.registry
  local all={}
  for _,effect in ipairs(r.effects) do table.insert(all,{effect=true,record=effect}) end
  for _,family in ipairs(r.families) do table.insert(all,{record=family}) end
  assert(offset>=0 and offset<=#all,"Invalid catalogue offset")
  local result={mode=self.mode,offline=self.offline,effects={},families={},offset=offset,total_effects=#r.effects,total_families=#r.families,
    fingerprint=U.hash(U.json(r)),features=r.feature_definitions,revision=r.source.revision}
  local used,index=0,offset
  while index<#all do
    local item=all[index+1]
    local record=U.copy(item.record)
    if item.effect then
      record.local_preview={}
      for kind,name in pairs(record.preview) do
        local path=self.mode=="online" and self:object(name) or U.path(self.assets,name)
        if kind=="animation" and self.mode=="online" then record.local_preview[kind]=self:url(name)
        elseif U.exists(path) then record.local_preview[kind]=path end
      end
      for _,key in ipairs({"install_files","notice_files","tested_on","path"}) do record[key]=nil end
    end
    local size=#U.json(record)
    assert(size<128*1024,"Display record exceeds size limit")
    if used+size>512*1024 then break end
    table.insert(item.effect and result.effects or result.families,record)
    used+=size; index+=1; A.checkpoint()
  end
  if index<#all then result.next_offset=index end
  return result
end
function Source:previews(ids)
  assert(type(ids)=="table" and #ids<=24,"Too many preview requests")
  local results={}
  for _,id in ipairs(ids) do
    local record={}; results[id]=record
    local ok,err=pcall(function()
      local e=S.find(self.registry.effects,id)
      if e.preview.image then self:bytes(e.preview.image); record.image=self.mode=="online" and self:object(e.preview.image) or U.path(self.assets,e.preview.image) end
      if e.preview.animation then record.animation=self.mode=="online" and self:url(e.preview.animation) or U.path(self.assets,e.preview.animation) end
    end)
    if not ok then record.error=tostring(err) end
  end
  return results
end
function Source:collectCache()
  if self.mode~="online" then return end
  local directory=self.cache.."/objects"
  if not U.exists(directory) then return end
  local keep={}
  for name in pairs(self.registry.files) do keep[self:object(name)]=true end
  local stale,total={},0
  for _,name in ipairs(noctalia.listDir(directory) or {}) do
    local path=U.path(directory,name)
    local info=noctalia.fileInfo(path)
    if info and not info.isDir and not keep[path] then
      table.insert(stale,{path=path,mtime=info.mtime,size=info.size}); total+=info.size
    end
    A.checkpoint()
  end
  table.sort(stale,function(a,b) return a.mtime<b.mtime end)
  for _,record in ipairs(stale) do
    if total>64*U.limit or noctalia.nowMs()/1000-record.mtime>=7*86400 then
      U.remove(record.path); total-=record.size
    end
    A.checkpoint()
  end
end
function Source:resolve(bindings,base,library,compare)
  local result={files={},presets={},definitions={},local_copies={}}
  local effects,names,selected,visiting={},{},{},{}
  for _,e in ipairs(self.registry.effects) do effects[e.id]=e; names[e.preset]=e.id end
  for _,kind in ipairs({"cursor","border","window","screen","animation"}) do
    local dir=U.path(library,kind)
    if U.exists(dir) then
      local entries=assert(noctalia.listDir(dir)); assert(#entries<=512,"Too many installed effect records")
      for _,entry in ipairs(entries) do
        local id=kind.."/"..entry
        local path=U.path(library,id.."/preset.json")
        if U.exists(path) then local record=U.load(path); assert(record.id==id,"Installed effect identity mismatch"); names[record.name]=id end
      end
    end
  end
  local function localCopy(id,name,definition,shader,config)
    local copy={preset=name,config=config}
    if compare and effects[id] then
      local ok,value=pcall(function()
        local published=U.toml(self:bytes(id.."/effect.toml")).effects.preset[name]
        S.definition(published,definition.kind)
        local path=U.reference(id,published.shader)
        assert(path:sub(1,#id+1)==id.."/","Comparison shader is outside effect")
        local localDef=U.copy(definition); localDef.shader=nil; published.shader=nil
        return U.equal(localDef,published) and U.hash(U.read(shader))==self.registry.files[path].sha256
      end)
      if ok then copy.matches_catalogue=value else copy.comparison_error=tostring(value) end
    end
    table.insert(result.local_copies,copy)
  end
  local visit
  local function overlay(definition,depth)
    local name=definition.overlay
    if name and name~="" then
      assert(base.presets[name] or names[name],"Missing companion overlay: "..name)
      visit(names[name],name,"window",depth+1)
    end
  end
  visit=function(id,name,kind,depth)
    assert(not visiting[name] and depth<64,"Cyclic installed overlay")
    if selected[name] then return end
    visiting[name]=true
    if base.presets[name] then
      local definition=base.presets[name]
      S.definition(definition,kind); overlay(definition,depth)
      localCopy(id,name,definition,definition.shader,"Original configuration")
    else
      assert(id,"Missing installed identity")
      local directory=U.path(library,id)
      local recordPath=directory.."/preset.json"
      local definition,notices
      if U.exists(recordPath) then
        local record=U.load(recordPath)
        assert(record.id==id and record.name==name,"Installed preset identity changed")
        definition=record.definition; S.definition(definition,kind)
        assert(definition.shader=="shader.glsl","Installed shader path changed")
        notices=record.notices or {}
        overlay(definition,depth); localCopy(id,name,definition,directory.."/shader.glsl",recordPath)
      else
        local effect=assert(effects[id],"Withdrawn preset is not installed: "..id)
        assert(effect.preset==name and effect.kind==kind,"Catalogue identity changed")
        local presetPath=id.."/effect.toml"
        local data=U.toml(self:bytes(presetPath))
        assert(data.effects and #U.keys(data.effects)==1 and (#U.keys(data)==1 or #U.keys(data)==2 and data.include),"Unexpected preset sections")
        assert(#U.keys(data.effects.preset)==1 and data.effects.preset[name],"Downloaded preset identity mismatch")
        definition=data.effects.preset[name]; S.definition(definition,kind)
        local shaderPath=U.reference(id,definition.shader)
        assert(shaderPath:sub(1,#id+1)==id.."/" and shaderPath:match("%.glsl$"),"Invalid shader path")
        local dependencies={}
        local includes=data.include or {}
        assert(not next(includes) or #U.keys(includes)==1 and includes.files,"Unexpected include fields")
        for _,ref in ipairs(includes.files or {}) do
          local path=U.reference(id,ref); assert(path:sub(-12)=="/effect.toml","Invalid dependency include"); dependencies[path:sub(1,-13)]=true
        end
        local expectedDeps={}; for _,dep in ipairs(effect.dependencies) do expectedDeps[dep]=true end
        assert(U.equal(dependencies,expectedDeps),"Preset dependencies differ from catalogue")
        local shader=self:bytes(shaderPath)
        local expected={[presetPath]=true,[shaderPath]=true}
        local noticeBytes={}; notices=effect.notice_files
        for _,notice in ipairs(notices) do noticeBytes[notice]=self:bytes(notice); expected[notice]=true end
        local install={}; for _,path in ipairs(effect.install_files) do install[path]=true end
        assert(U.equal(expected,install),"Unexpected installation files")
        if definition.overlay and definition.overlay~="" then
          local found=base.presets[definition.overlay]~=nil
          for dep in pairs(dependencies) do if effects[dep].preset==definition.overlay then found=true end end
          assert(found,"Overlay is not a declared dependency"); overlay(definition,depth)
        end
        local path=directory.."/shader.glsl"
        assert(not U.exists(path) or U.read(path)==shader,"Unrecorded customised shader needs review")
        U.atomic(path,shader)
        for notice,raw in pairs(noticeBytes) do local dest=U.path(library.."/notices",notice); if not U.exists(dest) then U.atomic(dest,raw) end end
        definition.shader="shader.glsl"
        U.save(recordPath,{id=id,name=name,definition=definition,notices=notices})
      end
      definition=U.copy(definition); definition.shader=directory.."/shader.glsl"
      result.definitions[name]=definition
      result.files[recordPath]=U.fingerprint(recordPath)
      result.files[definition.shader]=U.fingerprint(definition.shader)
      for _,notice in ipairs(notices) do local path=U.path(library.."/notices",notice); result.files[path]=U.fingerprint(path) end
    end
    visiting[name]=nil; selected[name]=true
  end
  for _,slot in ipairs(U.keys(bindings)) do local b=bindings[slot]; visit(b.id,b.name,b.kind,0) end
  result.presets=U.keys(selected)
  return result
end
M.Source=Source
return M
