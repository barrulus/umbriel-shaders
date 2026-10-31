local F=fixture
local rawUtil=require('lib/util.luau')
local U={}
for _,name in ipairs({'load','save','hash','equal','json','fingerprint'}) do
  U[name]=function(...)
    local args={...}
    return F.run(function() return rawUtil[name](unpack(args)) end)
  end
end
local Source=require('lib/source.luau')
local function state() return U.load('/state/state.json') end
local function shader(g,id) return (g.library or '/state/library')..'/'..id..'/shader.glsl' end
F.effect('cursor','glow')
F.effect('animation','roll')
F.write('/assets/animation/roll/config.toml','animation.windows_in.duration_ms=2600\n'..F.files['/assets/animation/roll/config.toml'])
F.write('/assets/families.toml', [[
[families.coordinated]
name="Coordinated"
description="Fixture family"
members=["cursor/glow","animation/roll"]
[families.coordinated.defaults]
"animation.windows_in"="animation/roll"
"effects.cursor"="cursor/glow"
]])
local initial=F.call('refresh')
F.check(not initial.managed and F.active=='/base.toml','Browse-only Refresh installed a shader')
F.call('choose-family',{family='coordinated',choices={['effects.cursor']='cursor/glow',['animation.windows_in']='animation/roll'}})
local first=state().current
local v1=F.files[shader(first,'cursor/glow')]
local v2=v1..'// revised shader\n'
F.write('/assets/cursor/glow/shader.glsl',v2)
F.write('/assets/cursor/glow/effect.toml',F.files['/assets/cursor/glow/effect.toml']..'radius=42\n')
F.write('/assets/animation/roll/config.toml',F.files['/assets/animation/roll/config.toml']:gsub('duration_ms=2600','duration_ms=900'))
F.runtime['window:42']={source='runtime',pool='',name='external',suppressed=false}
F.call('refresh')
local second=state().current
F.check(second.token~=first.token and F.files[shader(second,'cursor/glow')]==v2,'Refresh did not install edited source')
F.check(F.files[shader(first,'cursor/glow')]==v1 and state().previous.token==first.token,'Refresh overwrote the Undo revision')
F.check(U.load(second.library..'/cursor/glow/preset.json').definition.radius==42,'Refresh ignored edited preset definition')
F.check(U.equal(second.bindings,first.bindings) and U.equal(second.settings,first.settings),'Refresh changed activation choices or timing')
F.check(second.settings['animation.windows_in.duration_ms']==2600,'Family timing was not retained')
F.check(F.runtime['window:42'].name=='external','Refresh overwrote unrelated runtime selection')
F.call('refresh')
F.check(state().current.token==second.token and state().previous.token==first.token,'Unchanged Refresh discarded Undo')
F.call('undo')
F.check(state().current.token==first.token and F.files[shader(first,'cursor/glow')]==v1,'Undo did not restore original shader revision')
F.check(not F.files[shader(second,'cursor/glow')],'Retired generation assets were not collected')
-- Preparation must never change live files; late edits invalidate its baseline.
local review=F.call('prepare',{effect='cursor/glow',slot='effects.cursor'})
F.check(F.active==first.config and F.files[shader(first,'cursor/glow')]==v1,'Review changed live shader bytes')
F.write(shader(first,'cursor/glow'),v1..'// manually patched\n')
F.call('apply',{token=review.plan_token},false)
F.check(F.active==first.config,'An edit after review was silently adopted')
-- Model a pre-upgrade installation with mutable shared-library assets.
local legacy=state()
local moved={}
for path,hash in pairs(legacy.current.files) do
  if path:sub(1,#first.library+1)==first.library..'/' then
    local target='/state/library'..path:sub(#first.library+1)
    F.write(target,F.files[path]); moved[target]=U.hash(target.."\n"..v1) -- overwritten below except the intentionally stale shader hash
    if path~=shader(first,'cursor/glow') then moved[target]=U.fingerprint(target) end
  else moved[path]=hash end
end
local config=F.files[first.config]:gsub(first.library,'/state/library')
F.write(first.config,config); moved[first.config]=U.fingerprint(first.config)
legacy.current.files=moved; legacy.current.library=nil
U.save('/state/state.json',legacy)
local patched=F.files['/state/library/cursor/glow/shader.glsl']
F.call('refresh')
local refreshed=state()
F.check(F.files[shader(refreshed.current,'cursor/glow')]==v2,'Legacy installation did not refresh')
F.check(F.files['/state/library/cursor/glow/shader.glsl']==patched,'Refresh overwrote the manually patched Undo copy')
F.check(refreshed.previous.files['/state/library/cursor/glow/shader.glsl']==U.fingerprint('/state/library/cursor/glow/shader.glsl'),'Legacy rollback fingerprint was not repaired')
F.call('undo')
F.check(F.active==first.config and F.files['/state/library/cursor/glow/shader.glsl']==patched,'Legacy Undo failed')
-- Failed new GLSL must roll back to independently retained old GLSL.
F.write('/assets/cursor/glow/shader.glsl',v2..'BROKEN\n')
F.fail.shader='BROKEN'
local failed=F.call('refresh',nil,false)
F.check(not failed.pending and F.active==first.config,'Failed Refresh did not roll back')
F.check(U.load('/state/operation.json').outcome=='failed','Failed Refresh was not recorded')
F.fail={}
F.write('/assets/cursor/glow/shader.glsl',v2)
-- Wrapper edits cannot be silently adopted as customized shader assets.
F.write(first.config,config..'\n# foreign wrapper change\n')
F.call('refresh',nil,false)
F.check(F.active==first.config,'Refresh accepted a modified generated wrapper')
F.write(first.config,config)
F.call('refresh')
local current=state().current
F.call('choose',{effect='cursor/glow',slot='effects.cursor'})
F.check(F.files[shader(current,'cursor/glow')]==v2,'Previous revision was collected prematurely')
-- Online Refresh only updates metadata; online Apply retains installed edits.
local published=F.run(function() return Source.open('/published',true).registry end)
published.draft=false; published.source.revision=string.rep('a',40)
local origin='https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/'
F.http[origin..'catalogue/catalogue.json']=U.json(published)
for name in pairs(published.files) do F.http[origin..published.source.revision..'/'..name]=F.files['/assets/'..name] end
local beforeOnline=state().current
F.write(shader(beforeOnline,'cursor/glow'),v2..'// installed edit\n')
F.config.source_mode='online'
F.call('refresh')
F.check(state().current.token==beforeOnline.token,'Online Refresh unexpectedly applied shaders')
local reused=F.call('choose',{effect='cursor/glow',slot='effects.cursor'})
F.check(reused.used_local_copy and F.files[shader(state().current,'cursor/glow')]==v2..'// installed edit\n','Online selection discarded an installed edit')
-- Removal and Restore remain usable after the checkout disappears.
for path in pairs(F.files) do if path:sub(1,8)=='/assets/' then F.files[path]=nil end end
F.http={}
F.call('remove',{slot='animation.windows_in'})
F.check(F.files[shader(state().current,'cursor/glow')]==v2..'// installed edit\n','Offline removal lost retained shader revision')
F.check(not F.call('restore').managed,'Restore required the source checkout')
F.check(F.files['/state/library/cursor/glow/shader.glsl']==v2..'// installed edit\n','Restore lost the cached installed customization')
F.call('choose',{effect='cursor/glow',slot='effects.cursor'})
F.check(F.files[shader(state().current,'cursor/glow')]==v2..'// installed edit\n','Reapplying after Restore lost the installed customization')
print('PASS local refresh: '..F.checks..' checks (revisions, timing, Undo, legacy edits, rollback, cleanup, online and offline behavior)')
