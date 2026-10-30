-- SPDX-License-Identifier: MIT
local U = require("./util.luau")
local M = {}
M.kinds={cursor=true,border=true,window=true,screen=true,animation=true}
M.events={windows_in=true,windows_out=true,windows_move=true,workspaces=true,overview=true,scratchpad=true,border=true,dim_unfocused=true,layers=true}
local curves={}
for word in ("linear ease easein easeout easeinout snappy default overshoot quad cubic quart quint expo circ back elastic bounce defaultspring bouncy smooth stiff"):gmatch("%S+") do curves[word]=true end
for _,direction in ipairs({"in","out","inout"}) do
  for shape in ("sine quad cubic quart quint expo circ back elastic bounce"):gmatch("%S+") do curves["ease"..direction..shape]=true end
end
function M.slot(slot)
  return type(slot)=="string" and (slot:match("^effects%.") and M.kinds[slot:sub(9)] and slot~="effects.animation" or slot:match("^animation%.") and M.events[slot:sub(11)]) or false
end
function M.scope(key)
  if key=="animation.enabled" then return "" end
  return key:match("^effects%.") and key or key:match("^[^.]+%.[^.]+") or key
end
local function number(v,low,high,integer)
  assert(type(v)=="number" and v==v and v>=low and v<=high and (not integer or v%1==0),"Invalid numeric effect setting")
end
function M.setting(key,v)
  local function selector() assert(type(v)=="string" and #v>0 and #v<=128 and not v:find("%z"),"Invalid effect selector") end
  if key:match("^effects%.") and M.slot(key) then selector(); return end
  if key=="animation.enabled" then assert(type(v)=="boolean","Expected animation flag"); return end
  local slot=M.scope(key)
  assert(M.slot(slot) and slot:match("^animation%."),"Unapproved activation setting: "..key)
  local field,event=key:sub(#slot+2),slot:sub(11)
  if field=="enabled" then assert(type(v)=="boolean","Expected animation flag")
  elseif field=="effect" then selector()
  elseif field=="duration_ms" then number(v,1,10000,true)
  elseif field=="scale" and (event=="windows_in" or event=="windows_out" or event=="scratchpad") then number(v,event=="scratchpad" and 0 or .1,1)
  elseif field=="curve" then assert(curves[v],"Unsupported animation curve")
  elseif field=="style" then
    local styles={windows_in={popin=true,zoom=true,slide=true,fade=true,none=true},windows_out={fade=true,slide=true,popin=true,zoom=true},workspaces={slide=true,reveal=true}}
    assert(styles[event] and styles[event][v],"Unsupported animation style")
  else error("Unapproved activation setting: "..key) end
end
function M.definition(d,kind)
  assert(M.kinds[kind] and type(d)=="table" and d.kind==kind and type(d.shader)=="string","Preset kind or shader mismatch")
  local allowed={kind=true,shader=true,palette=true}
  if kind=="cursor" then allowed.radius=true end
  if kind=="border" then for _,key in ipairs({"padding","speed","animated","overlay","light"}) do allowed[key]=true end end
  for key in pairs(d) do assert(allowed[key],"Unexpected preset field: "..key) end
  for _,key in ipairs({"palette","animated"}) do if d[key]~=nil then assert(type(d[key])=="boolean","Invalid preset flag") end end
  if d.radius then number(d.radius,0,4096,true) end
  if d.padding then number(d.padding,0,1024,true) end
  if d.speed then number(d.speed,0,10) end
  if d.overlay then assert(type(d.overlay)=="string","Invalid overlay") end
  if d.light then
    for k,v in pairs(d.light) do
      if k=="spread" then number(v,1,256,true) elseif k=="intensity" then number(v,0,4) elseif k=="threshold" then number(v,0,1) else error("Invalid light field") end
    end
  end
end
function M.find(records,id)
  for _,r in ipairs(records) do if r.id==id then return r end end
  error("Unknown catalogue entry: "..tostring(id))
end
function M.binding(registry,id,slot,family)
  assert(M.slot(slot),"Unsupported selection slot")
  local effect=M.find(registry.effects,id)
  assert(effect.role=="effect" and table.find(effect.uses,slot),"Effect does not support this use")
  local selector=slot:match("^animation%.") and slot..".effect" or slot
  local recipe=effect.activation
  if family and family~="" then
    local group=M.find(registry.families,family)
    assert(table.find(group.members,id),"Effect is not in this family")
    if group.activation and group.activation.settings[selector]==effect.preset then recipe=group.activation end
  end
  assert(recipe and recipe.settings[selector]==effect.preset,"This effect requires manual configuration")
  local result={id=id,name=effect.preset,kind=effect.kind,settings={},required={},features={}}
  for k,v in pairs(recipe.settings) do
    M.setting(k,v)
    if M.scope(k)==slot or k=="animation.enabled" and slot:match("^animation%.") then result.settings[k]=v end
  end
  local visiting,visited,features={},{},{}
  local function visit(selected,depth)
    assert(not visiting[selected] and depth<64,"Cyclic or excessive dependencies")
    if visited[selected] then return end
    visiting[selected]=true
    local record=M.find(registry.effects,selected)
    for _,dep in ipairs(record.dependencies) do visit(dep,depth+1) end
    for k,v in pairs(record.required_settings) do
      M.setting(k,v)
      assert(not k:match("^effects%.") and not k:match("%.effect$"),"Requirements cannot select effects")
      assert(result.required[k]==nil or U.equal(result.required[k],v),"Conflicting requirements")
      result.required[k]=v
    end
    for _,feature in ipairs(record.requirements and record.requirements.features or {"preset-effects"}) do features[feature]=true end
    visiting[selected]=nil; visited[selected]=true
  end
  visit(id,0); result.features=U.keys(features)
  return result
end
function M.familyChoices(registry,id,choices)
  local family=M.find(registry.families,id)
  local groups={}
  for _,member in ipairs(family.members) do
    local effect=M.find(registry.effects,member)
    if effect.role=="effect" then
      for _,slot in ipairs(effect.uses) do groups[slot]=groups[slot] or {}; groups[slot][member]=true end
    end
  end
  assert(type(choices)=="table" and U.equal(U.keys(groups),U.keys(choices)),"Choose an effect or Keep current for every family use")
  local requested={}
  for slot,selected in pairs(choices) do
    assert(type(selected)=="string","Missing family choice")
    if selected~="" then assert(groups[slot][selected],"Invalid family choice"); requested[slot]=selected end
  end
  assert(next(requested),"Choose at least one family effect")
  return requested
end
return M
