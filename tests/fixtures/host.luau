-- A deterministic host/compositor fixture. Production modules run unchanged.
local F={files={},dirs={['/']=true},time=100000,session=1,events={},config={source_mode="local",source_root="/assets",base_config="/base.toml"},runtime={},commands={},http={},fail={},checks=0}
fixture=F
local function quote(s)
  return '"'..s:gsub('[%z\1-\31\\"]',function(c)
    return ({['"']='\\"',['\\']='\\\\',['\n']='\\n',['\r']='\\r',['\t']='\\t'})[c] or string.format('\\u%04x',string.byte(c))
  end)..'"'
end
local function encode(v)
  if v==nil then return "null" end
  if type(v)=="string" then return quote(v) end
  if type(v)~="table" then return tostring(v) end
  local out={}
  if #v>0 then for _,item in ipairs(v) do table.insert(out,encode(item)) end; return "["..table.concat(out,",").."]" end
  for key,item in pairs(v) do table.insert(out,quote(key)..":"..encode(item)) end
  table.sort(out); return "{"..table.concat(out,",").."}"
end
local function decode(s)
  local i=1
  local function space() local _,last=s:find('^[ \n\r\t]*',i); i=(last or i-1)+1 end
  local parse
  local function str()
    assert(s:sub(i,i)=='"'); i+=1
    local out={}
    while s:sub(i,i)~='"' do
      assert(i<=#s,"Unterminated fixture JSON string")
      local c=s:sub(i,i); i+=1
      if c=='\\' then
        c=s:sub(i,i); i+=1
        if c=='u' then c=utf8.char(assert(tonumber(s:sub(i,i+3),16))); i+=4
        else c=assert(({['"']='"',['\\']='\\',['/']='/',n='\n',r='\r',t='\t',b='\b',f='\f'})[c]) end
      end
      table.insert(out,c)
    end
    i+=1; return table.concat(out)
  end
  parse=function()
    space(); local c=s:sub(i,i)
    if c=='"' then return str() end
    if c=='{' or c=='[' then
      i+=1; space(); local out={}; local close=c=='{' and '}' or ']'
      if s:sub(i,i)==close then i+=1; return out end
      repeat
        local key
        if c=='{' then space(); key=str(); space(); assert(s:sub(i,i)==':'); i+=1 else key=#out+1 end
        out[key]=parse(); space()
        local separator=s:sub(i,i); i+=1
        if separator==close then break end
        assert(separator==',',"Invalid fixture JSON separator")
      until false
      return out
    end
    for word,value in pairs({['true']=true,['false']=false}) do if s:sub(i,i+#word-1)==word then i+=#word; return value end end
    if s:sub(i,i+3)=='null' then i+=4; return nil end
    local number=s:match('^%-?%d+%.?%d*[eE]?[+%-]?%d*',i); assert(number,"Invalid fixture JSON value")
    i+=#number; return assert(tonumber(number))
  end
  local out=parse(); space(); assert(i>#s,"Trailing fixture JSON"); return out
end
local function mkdir(path)
  F.dirs[path]=true
  for prefix in path:gmatch('()/') do if prefix>1 then F.dirs[path:sub(1,prefix-1)]=true end end
  return true
end
function F.write(path,raw) mkdir(path:match('^(.*)/[^/]+$') or '/'); F.files[path]=raw end
function F.check(v,message) F.checks+=1; assert(v,message) end
noctalia={
  tr=fixtureTranslate, trp=fixturePlural,
  setUpdateInterval=function() end,
  json={encode=encode,decode=decode},nowMs=function() return F.time end,
  getenv=function(key) return ({HOME='/home/test',XDG_RUNTIME_DIR='/run',WAYLAND_DISPLAY='test'})[key] end,
  expandPath=function(s) return s:gsub('^~','/home/test') end,
  commandExists=function() return true end,
  getConfig=function(key) return F.config[key] end,
  fileExists=function(path) return F.files[path]~=nil or F.dirs[path] or path=='/run/umbriel-test.sock' end,
  fileInfo=function(path)
    if path=='/run/umbriel-test.sock' then return {size=0,mtime=F.session,isDir=false} end
    if path=='/proc/sys/kernel/random/boot_id' then return {size=0,mtime=1,isDir=false} end
    if F.files[path] then return {size=#F.files[path],mtime=1,isDir=false} end
    if F.dirs[path] then return {size=0,mtime=1,isDir=true} end
  end,
  mkdirAll=mkdir,
  writeFile=function(path,raw) F.write(path,raw); return true end,
  readFile=function(path) return F.files[path] end,
  readFileAsync=function(path,cb) table.insert(F.events,function() cb(F.files[path],F.files[path] and nil or 'Missing file') end); return true end,
  renameFile=function(from,to) if not F.files[from] then return false end; F.files[to]=F.files[from]; F.files[from]=nil; return true end,
  removeFile=function(path) F.files[path]=nil; return true end,
  listDir=function(path)
    local found={}
    for name in pairs(F.files) do if name:sub(1,#path+1)==path..'/' then found[name:sub(#path+2):match('^[^/]+')]=true end end
    for name in pairs(F.dirs) do if name:sub(1,#path+1)==path..'/' then found[name:sub(#path+2):match('^[^/]+')]=true end end
    local out={}; for name in pairs(found) do table.insert(out,name) end; table.sort(out); return out
  end,
  http=function(request,cb)
    table.insert(F.events,function() cb({ok=F.http[request.url]~=nil,status=F.http[request.url] and 200 or 404,body=F.http[request.url] or ''}) end)
    return true
  end,
}
F.write('/proc/sys/kernel/random/boot_id','fixture-boot')
F.write('/base.toml','[general]\nautostart=[]\n[effects]\ncursor=""\n[animation]\nenabled=true\n')
F.active='/base.toml'
local toml=require('lib/vendor/tinytoml.luau')
local function config(path,depth)
  assert((depth or 0)<32,'Fixture config cycle')
  local data=toml.parse(assert(F.files[path],'Missing fixture config '..path),{load_from_string=true})
  local result={presets={},pools={},defaults={}}
  for _,include in ipairs(data.include and data.include.files or {}) do
    local parent=config(include,(depth or 0)+1)
    for k,v in pairs(parent.presets) do result.presets[k]=v end
    for k,v in pairs(parent.pools) do result.pools[k]=v end
    for k,v in pairs(parent.defaults) do result.defaults[k]=v end
  end
  for k,v in pairs(data.effects and data.effects.preset or {}) do result.presets[k]=v end
  for k,v in pairs(data.effects and data.effects.pool or {}) do result.pools[k]=v end
  for _,kind in ipairs({'cursor','border','window','screen'}) do if data.effects and data.effects[kind]~=nil then result.defaults[kind]=data.effects[kind] end end
  return result
end
local function key(kind,target) return kind..':'..target end
local targets={{kind='cursor',target=''}, {kind='window',target='42'}, {kind='border',target='42'}, {kind='screen',target='Display with/slash'}}
function F.report()
  local current=config(F.active)
  local presets,pools,owners={}, {}, {{type='window',id='42',slots={}},{type='output',name='Display with/slash',slots={}}}
  for name,d in pairs(current.presets) do table.insert(presets,{name=name,kind=d.kind,state=F.fail.compile==name and 'failed' or 'compiled'}) end
  for name,d in pairs(current.pools) do local members={}; for _,member in ipairs(d.choose) do table.insert(members,{name=member}) end; table.insert(pools,{name=name,members=members}) end
  local cursor
  for _,t in ipairs(targets) do
    local v=F.runtime[key(t.kind,t.target)] or {source='default',pool='',name='',suppressed=false}
    v=decode(encode(v))
    if v.source~='runtime' then v.name=current.defaults[t.kind] or '' end
    if t.kind=='cursor' then cursor=v elseif t.kind=='screen' then owners[2].slots.screen=v else owners[1].slots[t.kind]=v end
  end
  return {presets=presets,pools=pools,cursor=cursor,owners=owners}
end
noctalia.runAsync=function(args,cb)
  table.insert(F.commands,args)
  table.insert(F.events,function()
    local ok,value=pcall(function()
      if args[2]=='effects' then return encode(F.report()) end
      if args[2]=='config' then
        if F.fail.validate then error('Validation failed') end
        config(args[5]); return ''
      end
      if args[2]=='config-replace' then
        if F.fail.replace then F.fail.replace=false; error('Replace rejected') end
        if F.fail.rollback and args[3]=='/base.toml' then error('Rollback rejected') end
        config(args[3]); F.active=args[3]; return ''
      end
      assert(args[2]=='msg','Unexpected command')
      local kind,op=args[3]:match('^effect%-(%w+)%-(%w+)$')
      local target,selector='',nil
      if op=='set' or op=='cycle' then selector=args[4]; target=args[6] or '' else target=args[4] or '' end
      local id=key(kind,target)
      if op=='set' then
        local pool=config(F.active).pools[selector]
        F.runtime[id]={source='runtime',pool=pool and selector or '',name=pool and pool.choose[1] or selector,suppressed=false}
      elseif op=='reset' then F.runtime[id]=nil
      elseif op=='toggle' then
        local v=F.runtime[id] or {source='default',pool='',name='',suppressed=false}
        v.suppressed=not v.suppressed; F.runtime[id]=v
      elseif op=='cycle' then
        local pool=config(F.active).pools[selector]
        local v=assert(F.runtime[id]); local index=table.find(pool.choose,v.name) or 0
        v.name=pool.choose[index%#pool.choose+1]
      else error('Unknown action') end
      return ''
    end)
    if args[2]=='config-replace' and F.interrupt then F.interrupt=false; F.interrupted=true; return end
    cb({exitCode=ok and 0 or 1,stdout=ok and value or '',stderr=ok and '' or tostring(value),timedOut=false,stdoutTruncated=false})
  end)
  return true
end
function F.pump()
  F.time+=16
  local events=F.events; F.events={}
  for _,event in ipairs(events) do event() end
  require('lib/async.luau').update()
end
function F.run(fn)
  local done,ok,result=false,false,nil
  require('lib/async.luau').run(fn,function(success,value) done=true; ok=success; result=value end)
  for _=1,10000 do if done then break end; F.pump() end
  assert(done,'Fixture operation timed out'); assert(ok,result)
  return result
end
function F.call(action,request,expect)
  local done,result=false,nil
  F.backend=F.backend or require('lib/backend.luau').new('/state')
  F.backend.run({action=action,request=request},function(value) done=true; result=value end)
  for _=1,10000 do if done then break end; F.pump() end
  assert(done,'Fixture backend timed out')
  F.check(result.ok==(expect~=false),result.message or 'Wrong outcome')
  return result
end
function F.effect(kind,name,extra)
  local id=kind..'/'..name
  local slot=kind=='animation' and 'animation.windows_in' or 'effects.'..kind
  local selector=kind=='animation' and slot..'.effect' or slot
  F.write('/assets/'..id..'/metadata.toml','name="'..name..'"\ndescription="Fixture shader"\nauthor="Test"\nlicense="MIT"\nnotice_files=["'..id..'/README.md"]\n'..(kind=='animation' and 'uses=["'..slot..'"]\n' or '')..(extra or ''))
  F.write('/assets/'..id..'/effect.toml','[effects.preset.'..name..']\nkind="'..kind..'"\nshader="shader.glsl"\n')
  F.write('/assets/'..id..'/shader.glsl','vec4 '..kind..'(vec2 uv) { return umbriel_sample(uv); }\n')
  F.write('/assets/'..id..'/README.md','MIT fixture attribution')
  F.write('/assets/'..id..'/config.toml','[include]\nfiles=["shaders/community/'..id..'/effect.toml"]\n'..selector..'="'..name..'"\n')
  -- Settings must precede the include table; otherwise dotted keys belong to it.
  F.write('/assets/'..id..'/config.toml',selector..'="'..name..'"\n[include]\nfiles=["shaders/community/'..id..'/effect.toml"]\n')
end
