local F=fixture
local U=require('lib/util.luau')
local S=require('lib/selection.luau')
local Reg=require('lib/registry.luau')
local Source=require('lib/source.luau')
F.effect('cursor','glow')
F.write('/assets/cursor/glow/preview.png','fixture image')
local localSource=F.run(function() return Source.open('/state',false) end)
local registry=U.copy(localSource.registry)
registry.draft=false; registry.source.revision=string.rep('a',40)
-- Published catalogues require checksums even for media; local display records do not.
for name,record in pairs(registry.files) do record.sha256=U.hash(F.files['/assets/'..name]) end
local origin='https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/'
F.http[origin..'catalogue/catalogue.json']=U.json(registry)
for name in pairs(registry.files) do F.http[origin..registry.source.revision..'/'..name]=F.files['/assets/'..name] end
F.config.source_mode='online'
local source=F.run(function() return Source.open('/online',false) end)
F.check(source.registry.effects[1].id=='cursor/glow','Online catalogue load')
F.check(not F.files[source:object('cursor/glow/shader.glsl')],'Browsing downloaded shader')
local previews=F.run(function() return source:previews({'cursor/glow'}) end)
F.check(previews['cursor/glow'].image~=nil,'Preview was not downloaded')
F.write(previews['cursor/glow'].image,'corrupt')
F.run(function() source:previews({'cursor/glow'}) end)
F.check(F.files[previews['cursor/glow'].image]=='fixture image','Corrupt preview was not repaired')
F.http[origin..'catalogue/catalogue.json']=nil
F.check(F.run(function() return Source.open('/online',true).offline end),'Offline refresh discarded cache')
F.http[origin..registry.source.revision..'/cursor/glow/shader.glsl']='corrupt shader'
local ok=pcall(function() F.run(function() source:bytes('cursor/glow/shader.glsl') end) end)
F.check(not ok,'Asset hash mismatch accepted')
local bad=U.copy(registry); bad.files['../escape.glsl']={bytes=1,sha256=string.rep('a',64)}
F.check(not pcall(Reg.validate,bad,false),'Catalogue traversal accepted')
bad=U.copy(registry); bad.source.revision='main'
F.check(not pcall(Reg.validate,bad,false),'Unpinned catalogue accepted')
bad=U.copy(registry); bad.effects[1].dependencies={'cursor/glow'}
F.check(not pcall(Reg.validate,bad,false),'Dependency cycle accepted')
F.check(not pcall(S.setting,'animation.windows_in.duration_ms',true),'Boolean accepted as duration')
F.check(not pcall(S.setting,'general.autostart',{'bad'}),'Unapproved setting accepted')
F.check(not pcall(U.decode,string.rep('[',40)..string.rep(']',40)),'Excessive JSON depth accepted')
local first=true
local value=F.run(function() return require('lib/async.luau').await(function(cb)
 if first then first=false; return false end
 table.insert(F.events,function() cb('accepted') end); return true
end) end)
F.check(value=='accepted','Host queue saturation was not retried')
print('PASS catalogue: '..F.checks..' checks (lazy assets, verified previews, repair, offline cache, hashes, traversal, dependencies, settings, queue limits)')
