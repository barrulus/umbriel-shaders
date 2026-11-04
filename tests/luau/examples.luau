local F=fixture
local U=require('lib/util.luau')
local A=require('lib/allocation.luau')
local Source=require('lib/source.luau')
local events={'overview','scratchpad','border','dim_unfocused','layers'}
-- Source fixtures model community metadata; the plugin contains no shader copies.
for _,event in ipairs(events) do
  local slot='animation.'..event
  local id=A.example(slot)
  local slug=id:sub(11)
  F.effect('animation',slug)
  local path='/assets/'..id
  F.write(path..'/metadata.toml',F.files[path..'/metadata.toml']:gsub('uses=%[.-%]','uses=["'..slot..'"]'))
  F.write(path..'/config.toml','[include]\nfiles=["shaders/community/'..id..'/effect.toml"]\n[animation]\nenabled=true\n['..slot..']\nenabled=true\neffect="'..slug..'"\ncurve="easeoutcubic"\nduration_ms=300\n'..(event=='dim_unfocused' and 'dim=0.2\n' or ''))
end
local catalogue=F.call('catalogue').catalogue
F.check(#catalogue.effects==5,'Community examples were not discovered through metadata')
for _,event in ipairs(events) do
  local slot='animation.'..event
  local id=A.example(slot)
  local applied=F.call('choose',{slot=slot,effect=id})
  F.check(applied.selections[slot]==id and applied.settings[slot..'.enabled']==true,'Example did not activate its declared slot')
  local settings=F.call('choose',{slot=slot,effect='@default'}).settings
  F.check(settings[slot..'.effect']=='' and settings[slot..'.enabled']==true,'Default did not restore native animation')
  F.call('undo')
  F.check(F.call('status').selections[slot]==id,'Undo did not restore community example')
end
F.check(F.call('status').settings['animation.dim_unfocused.dim']==0.2,'Community dimming activation was lost')
local active=F.active
F.call('choose',{slot='animation.layers',effect=A.example('animation.overview')},false)
F.check(F.active==active,'Example was accepted for the wrong animation target')
-- Existing bundled generations remain ordinary installed assets after this move.
F.config.source_root='/missing'
F.call('timing',{slot='animation.overview',duration_ms=500,curve='linear'})
F.check(F.call('status').settings['animation.overview.duration_ms']==500,'Installed example timing needed the source checkout')
F.call('choose',{slot='animation.overview',effect='@default'})
F.check(F.call('status').settings['animation.overview.effect']=='','Default needed the source checkout')
F.call('restore')
F.check(not F.call('status').managed,'Restore left community assignments active')
print('PASS community examples: '..F.checks..' checks (metadata slots, native Default, dimming, Undo, compatibility, offline installed timing and Restore)')
