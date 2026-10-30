-- SPDX-License-Identifier: MIT
local A = require("./async.luau")
local U = require("./util.luau")
local S = require("./selection.luau")
local R = require("./runtime.luau")
local G = require("./graph.luau")
local Peer = require("./peer.luau")
local M = {}; local Controller={}; Controller.__index=Controller
local runtimeFields={"original","owned","undo_runtime","previous_original","previous_owned"}
local function empty(base,session)
  return {schema_version=4,base=base,session=U.copy(session),can_undo=false,original={},owned={},undo_runtime={},previous_original={},previous_owned={}}
end
local function prune(state,live) for _,key in ipairs(runtimeFields) do R.prune(state[key],live) end end
local function restored(live,owned,original)
  local desired=U.copy(live)
  for id,record in pairs(original) do if live[id] and U.equal(live[id],owned[id]) then desired[id]=U.copy(record) end end
  return desired
end
function M.new(root,peer,explicitBase)
  local base=peer.base
  if not explicitBase and U.exists(root.."/state.json") then base=U.load(root.."/state.json").base end
  return setmetatable({root=root,peer=peer,base=U.normalize(base),explicitBase=explicitBase},Controller)
end
function Controller:checkGeneration(g)
  assert(U.hex(g.token,32),"Invalid saved generation ID")
  local directory=U.path(self.root,"generations/"..g.token)
  assert(g.config==directory.."/config.toml" and g.files[g.config] and g.files[directory.."/marker.glsl"],"Incomplete managed generation")
  for path in pairs(g.files) do
    assert(path:sub(1,#self.root+1)==self.root.."/","Generation references foreign files")
    assert(U.path(self.root,path:sub(#self.root+2))==path,"Invalid managed asset path")
  end
  assert(#U.keys(g.bindings)<=13 and #g.presets<=512,"Oversized saved selection")
  for slot,b in pairs(g.bindings) do
    assert(S.slot(slot),"Invalid saved selection slot"); U.relative(b.id)
    for k,v in pairs(b.settings) do S.setting(k,v) end
    for k,v in pairs(b.required) do S.setting(k,v) end
  end
end
function Controller:decode(state)
  assert(state.schema_version==4 and type(state.session)=="table","Unsupported saved state")
  U.normalize(state.base)
  for _,key in ipairs(runtimeFields) do assert(type(state[key])=="table","Invalid saved runtime state") end
  for _,key in ipairs({"current","previous"}) do if state[key] then self:checkGeneration(state[key]) end end
  return state
end
function Controller:state()
  return U.exists(self.root.."/state.json") and self:decode(U.load(self.root.."/state.json")) or empty(self.base,self.peer.session)
end
function Controller:owned(state,report)
  return Peer.sameSession(state.session,self.peer.session) and state.current~=nil and U.equal(R.markers(report),{U.marker..state.current.token})
end
function Controller:target(state) return state.current and state.current.config or state.base end
function Controller:status()
  local state,report=self:state(),self.peer:effects()
  local managed=self:owned(state,report)
  local selections={}
  if state.current then for slot,b in pairs(state.current.bindings) do selections[slot]=b.id end end
  return {managed=managed,pending=U.exists(self.root.."/pending.json"),can_undo=managed and state.can_undo,can_restore=managed,
    base=self.base,selections=selections,cursor=report.cursor.name,message=managed and "Shader selections are active." or "Choose an effect to review and apply."}
end
function Controller:stateHash() return U.exists(self.root.."/state.json") and U.hash(U.read(self.root.."/state.json")) or false end
function Controller:cleanup(state)
  if U.exists(self.root.."/pending.json") then return end
  local keep={}
  if state.current then keep[state.current.token]=true end
  if state.previous then keep[state.previous.token]=true end
  if U.exists(self.root.."/plan.json") then
    local plan=U.load(self.root.."/plan.json")
    if noctalia.nowMs()-plan.created<900000 then keep[plan.generation.token]=true else U.remove(self.root.."/plan.json") end
  end
  local dir=self.root.."/generations"
  if not U.exists(dir) then return end
  for _,id in ipairs(noctalia.listDir(dir) or {}) do
    if U.hex(id,32) and not keep[id] then
      -- The host exposes file removal, not recursive directory deletion.
      for _,name in ipairs({"config.toml","marker.glsl"}) do U.remove(dir.."/"..id.."/"..name) end
    end
  end
end
function Controller:prepare(catalogue,requested,family,compare)
  assert(next(requested),"Choose at least one effect or slot to remove")
  assert(not U.exists(self.root.."/pending.json"),"Recover the interrupted operation first")
  local before,report=self:state(),self.peer:effects()
  assert(before.session.socket==self.peer.session.socket,"State belongs to another compositor socket")
  local managed=self:owned(before,report)
  local adopted=before.current and Peer.sameSession(before.session,self.peer.session) and not managed or false
  if adopted then
    assert(self.explicitBase and #R.markers(report)==0,"Another configuration replaced the managed wrapper; choose its original path explicitly and review again")
    before=empty(self.base,self.peer.session)
  elseif before.current and Peer.sameSession(before.session,self.peer.session) then assert(managed,"Another configuration replaced the wrapper")
  else assert(#R.markers(report)==0,"Another managed generation is active; restore it first") end
  assert(not managed or before.base==self.base,"Restore before changing the original configuration path")
  U.remove(self.root.."/plan.json"); self:cleanup(before)
  local graph=G.read(self.base)
  local bindings=before.current and U.copy(before.current.bindings) or {}
  for slot,id in pairs(requested) do
    assert(S.slot(slot),"Unsupported selection slot")
    if id=="" then bindings[slot]=nil else bindings[slot]=S.binding(catalogue.registry,id,slot,family) end
  end
  local settings,requirements,features={},{},{}
  for _,b in pairs(bindings) do
    for k,v in pairs(b.settings) do assert(settings[k]==nil or U.equal(settings[k],v),"Conflicting activation settings: "..k); settings[k]=v end
    for k,v in pairs(b.required) do assert(requirements[k]==nil or U.equal(requirements[k],v),"Conflicting shader requirements: "..k); requirements[k]=v end
    for _,feature in ipairs(b.features) do features[feature]=true end
  end
  for k,v in pairs(requirements) do
    assert(settings[k]==nil or U.equal(settings[k],v),"Requirement conflicts with selection: "..k)
    if k=="animation.enabled" or bindings[S.scope(k)] then settings[k]=v else assert(U.equal(graph.settings[k],v),"Resolve required original setting: "..k) end
  end
  local selected=catalogue:resolve(bindings,graph,self.root.."/library",compare)
  local id=U.token()
  local directory=self.root.."/generations/"..id
  assert(not U.exists(directory),"Generation identity collision; review again")
  local config,shader=directory.."/config.toml",directory.."/marker.glsl"
  local generation={token=id,config=config,files=selected.files,bindings=bindings,settings=settings,presets=selected.presets}
  U.atomic(shader,"vec4 cursor(vec2 uv) { return umbriel_sample(uv); }\n")
  local lines={"# Managed by Umbriel Shaders. Edit the original configuration."}
  for _,line in ipairs(U.settingLines(settings)) do table.insert(lines,line) end
  table.insert(lines,"[include]\nfiles = ["..U.json(self.base).."]")
  for _,name in ipairs(U.keys(selected.definitions)) do
    table.insert(lines,"[effects.preset."..U.json(name).."]")
    for _,key in ipairs(U.keys(selected.definitions[name])) do table.insert(lines,U.json(key).." = "..U.value(selected.definitions[name][key])) end
  end
  table.insert(lines,"[effects.preset."..U.json(U.marker..id).."]\nkind = \"cursor\"\nshader = \"marker.glsl\"\nradius = 1")
  if graph.drm then table.insert(lines,"[drm]") end
  U.atomic(config,table.concat(lines,"\n").."\n")
  self.peer:validate(config); U.verify(graph.files); U.verify(selected.files)
  generation.files[config]=U.fingerprint(config); generation.files[shader]=U.fingerprint(shader)
  U.save(self.root.."/plan.json",{schema_version=1,created=noctalia.nowMs(),base=self.base,session=self.peer.session,state_hash=self:stateHash(),
    generation=generation,base_files=graph.files,observed=R.stamp(report),requested=requested,adopted=adopted})
  local previous=U.copy(graph.settings)
  if before.current then for k,v in pairs(before.current.settings) do previous[k]=v end end
  local changes={}
  for _,k in ipairs(U.keys(settings)) do table.insert(changes,{key=k,before=previous[k],after=settings[k]}) end
  if before.current then for k,v in pairs(before.current.settings) do if settings[k]==nil then table.insert(changes,{key=k,before=v,after=graph.settings[k]}) end end end
  local unknown={}; for _,f in ipairs(U.keys(features)) do if f~="preset-effects" then table.insert(unknown,f) end end
  local result=self:status()
  result.plan_token=id; result.family_id=family; result.changes=changes; result.local_copies=selected.local_copies; result.dependencies=selected.presets
  result.compatibility={status=#unknown==0 and "compatible" or "unknown",unknown=unknown,incompatible={}}
  result.features=catalogue.registry.feature_definitions; result.message="Shader selection validated and ready."
  return result
end
function Controller:confirm(state)
  local deadline=noctalia.nowMs()+4000
  repeat
    local report=self.peer:effects()
    if not state.current then assert(#R.markers(report)==0,"Original configuration still has a managed generation"); return end
    assert(self:owned(state,report),"Active generation differs from requested configuration")
    local presets={}; for _,p in ipairs(report.presets) do presets[p.name]=p.state end
    local ready=true
    for _,name in ipairs(state.current.presets) do
      assert(presets[name],"Selected shader preset is not loaded: "..name)
      assert(presets[name]~="failed" and presets[name]~="error","Shader failed GPU compilation: "..name)
      ready=ready and presets[name]=="compiled"
    end
    if ready then return end
    A.pause()
  until noctalia.nowMs()>=deadline
  error("Shader compilation could not be verified")
end
function Controller:journalGuard(journal)
  -- A command already launched can outlive a reloaded VM. Recovery waits beyond its host timeout.
  journal.settle_after=noctalia.nowMs()+7000
  U.save(self.root.."/pending.json",journal)
end
function Controller:rollback(journal)
  local before,after=self:decode(journal.before),self:decode(journal.after)
  assert(Peer.sameSession(before.session,self.peer.session),"Compositor restarted; explicit recovery is required")
  local report=self.peer:effects()
  assert(self:owned(before,report) or self:owned(after,report) or (not before.current or not after.current) and #R.markers(report)==0,"A foreign managed configuration is active")
  if before.current then U.verify(before.current.files) end
  self.peer:validate(self:target(before))
  self:journalGuard(journal); self.peer:replace(self:target(before))
  R.restore(self.peer,journal.runtime_before or {},function() self:journalGuard(journal) end)
  self:confirm(before); prune(before,R.slots(self.peer:effects()))
  U.save(self.root.."/state.json",before); U.remove(self.root.."/pending.json")
end
function Controller:transact(before,after,desired,baseFiles,expected)
  if after.current then self:checkGeneration(after.current); U.verify(after.current.files) end
  self.peer:validate(self:target(after)); U.verify(baseFiles)
  local report=self.peer:effects()
  assert(before.current and self:owned(before,report) or not before.current and #R.markers(report)==0,"Configuration changed during validation")
  assert(U.equal(R.stamp(report),expected),"Live selections changed during validation; review again")
  local live=R.slots(report); prune(before,live); prune(after,live)
  local journal={schema_version=1,before=before,after=after,runtime_before=live}
  self:journalGuard(journal)
  local ok,err=pcall(function()
    self.peer:replace(self:target(after))
    R.restore(self.peer,desired,function() self:journalGuard(journal) end)
    self:confirm(after); U.verify(baseFiles); prune(after,R.slots(self.peer:effects()))
    U.save(self.root.."/state.json",after)
  end)
  if not ok then
    local recovered,recoveryError=pcall(function() self:rollback(journal) end)
    error(tostring(err)..(recovered and "; previous configuration restored" or "; recovery is pending: "..tostring(recoveryError)))
  end
  U.remove(self.root.."/pending.json")
  pcall(function() U.remove(self.root.."/plan.json"); self:cleanup(after) end)
end
function Controller:apply(id)
  assert(not U.exists(self.root.."/pending.json"),"Recover the interrupted operation first")
  assert(U.hex(id,32),"Invalid review token")
  local plan=U.load(self.root.."/plan.json")
  assert(plan.schema_version==1 and plan.generation.token==id,"Review is no longer current")
  assert(plan.base==self.base and Peer.sameSession(plan.session,self.peer.session),"Original configuration or compositor changed after review")
  local age=noctalia.nowMs()-plan.created
  assert(age>=0 and age<900000,"Review expired")
  assert(plan.state_hash==self:stateHash(),"Saved selections changed after review")
  local report=self.peer:effects()
  assert(U.equal(plan.observed,R.stamp(report)),"Live selections changed after review")
  U.verify(plan.base_files)
  local before=self:state()
  if not Peer.sameSession(before.session,self.peer.session) or plan.adopted then before=empty(self.base,self.peer.session) end
  if not before.current then before.base=self.base end
  local live=R.slots(report); prune(before,live)
  local after=U.copy(before)
  after.current=plan.generation; after.previous=before.current; after.can_undo=true
  after.previous_original=U.copy(before.original); after.previous_owned=U.copy(before.owned); after.undo_runtime={}
  local desired=U.copy(live)
  for key,record in pairs(live) do
    local slot="effects."..record.kind
    if plan.requested[slot]~=nil then
      after.undo_runtime[key]=U.copy(record)
      if after.current.bindings[slot] then
        after.original[key]=after.original[key] or U.copy(record)
        desired[key].value={name=after.current.bindings[slot].name,pool="",source="runtime",suppressed=false}
        after.owned[key]=U.copy(desired[key])
      else
        if before.original[key] and U.equal(record,before.owned[key]) then desired[key]=U.copy(before.original[key]) end
        after.original[key]=nil; after.owned[key]=nil
      end
    end
  end
  self:transact(before,after,desired,plan.base_files,R.stamp(report))
  local result=self:status(); result.message="Shader selections applied and GPU compilation verified."; return result
end
function Controller:undo()
  assert(not U.exists(self.root.."/pending.json"),"Recover the interrupted operation first")
  local before,report=self:state(),self.peer:effects()
  assert(self:owned(before,report) and before.can_undo,"No owned selection to undo")
  local after=U.copy(before)
  after.current=before.previous; after.previous=nil; after.can_undo=false
  after.original=U.copy(before.previous_original); after.owned=U.copy(before.previous_owned)
  after.undo_runtime={}; after.previous_original={}; after.previous_owned={}
  local live=R.slots(report)
  local desired=restored(live,before.owned,before.undo_runtime)
  for id,original in pairs(before.undo_runtime) do
    if not before.owned[id] and live[id] and before.previous_original[id] then
      local released,actual=before.previous_original[id].value,live[id].value
      if released.source=="runtime" and U.equal(actual,released) or released.source~="runtime" and actual.source~="runtime" and actual.suppressed==released.suppressed then desired[id]=U.copy(original) end
    end
  end
  self:transact(before,after,desired,G.read(before.base).files,R.stamp(report))
  local result=self:status(); result.message="Previous shader selections restored."; return result
end
function Controller:restore()
  assert(not U.exists(self.root.."/pending.json"),"Recover the interrupted operation first")
  local before,report=self:state(),self.peer:effects()
  if not self:owned(before,report) then return self:status() end
  self:transact(before,empty(before.base,self.peer.session),restored(R.slots(report),before.owned,before.original),G.read(before.base).files,R.stamp(report))
  local result=self:status(); result.message="Original configuration restored."; return result
end
function Controller:recover()
  assert(U.exists(self.root.."/pending.json"),"No interrupted operation to recover")
  local journal=U.load(self.root.."/pending.json")
  assert(journal.schema_version==1,"Unsupported recovery journal")
  assert(noctalia.nowMs()>=(journal.settle_after or 0),"The previous command may still be finishing. Retry recovery in a few seconds.")
  local before=self:decode(journal.before)
  assert(before.session.socket==self.peer.session.socket,"Recovery belongs to another compositor socket")
  if not Peer.sameSession(before.session,self.peer.session) then
    local report=self.peer:effects()
    local after=self:decode(journal.after)
    before.session=U.copy(self.peer.session); after.session=U.copy(self.peer.session)
    assert(#R.markers(report)==0 or self:owned(before,report) or self:owned(after,report),"Foreign managed configuration is active")
    local original=empty(before.base,self.peer.session)
    journal.before=original
    journal.after=self:owned(before,report) and before or self:owned(after,report) and after or original
    journal.runtime_before={}
  end
  self:rollback(journal)
  pcall(function() U.remove(self.root.."/plan.json"); self:cleanup(self:state()) end)
  local result=self:status(); result.message="Interrupted operation recovered."; return result
end
return M
