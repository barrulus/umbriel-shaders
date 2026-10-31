local F=fixture
local U=require('lib/util.luau')
for _,kind in ipairs({'cursor','border','window','screen','animation'}) do F.effect(kind,kind..'-fixture') end
F.effect('cursor','second')
F.write('/assets/families.toml', [[
[families.coordinated]
name="Coordinated"
description="Fixture family"
members=["cursor/cursor-fixture","border/border-fixture","window/window-fixture","screen/screen-fixture","animation/animation-fixture"]
[families.coordinated.defaults]
"effects.cursor"="cursor/cursor-fixture"
"animation.windows_in"="animation/animation-fixture"
]])
F.session=1.0009999
local base=F.files['/base.toml']
local catalogue=F.call('catalogue')
F.check(#catalogue.catalogue.effects==6 and #catalogue.catalogue.families==1,'Local catalogue generation')
local plan=F.call('prepare',{effect='cursor/cursor-fixture',slot='effects.cursor'})
F.check(plan.effect_id=='cursor/cursor-fixture' and plan.slot=='effects.cursor','Review lost its effect and destination')
F.check(not plan.managed and #plan.changes==1,'Review changed live selection')
local applied=F.call('apply',{token=plan.plan_token})
F.session=1.0010001
F.check(F.call('status').managed,'Timestamp jitter crossing a millisecond lost ownership')
F.check(applied.managed and applied.can_undo and applied.cursor=='cursor-fixture','Apply failed')
F.check(not F.call('undo').managed and F.active=='/base.toml','Undo initial application')
F.call('choose',{effect='cursor/cursor-fixture',slot='effects.cursor'})
F.call('choose',{effect='cursor/second',slot='effects.cursor'})
F.check(F.call('undo').cursor=='cursor-fixture','Undo prior generation')
F.check(not F.call('restore').managed,'Restore original')
local choices={['effects.cursor']='cursor/cursor-fixture',['effects.border']='border/border-fixture',['effects.window']='window/window-fixture',['effects.screen']='screen/screen-fixture',['animation.windows_in']='animation/animation-fixture'}
local family=F.call('choose-family',{family='coordinated',choices=choices})
F.check(#U.keys(family.selections)==5,'Family selection lost destinations')
F.check(F.call('remove',{slot='effects.border'}).selections['effects.border']==nil,'Remove individual slot')
F.check(F.call('undo').selections['effects.border']=='border/border-fixture','Undo removal')
F.runtime['window:42']={source='runtime',pool='',name='external',suppressed=false}
F.call('restore')
F.check(F.runtime['window:42'].name=='external','Restore overwrote external selection')
F.runtime={}
plan=F.call('prepare',{effect='cursor/cursor-fixture',slot='effects.cursor'})
F.write('/base.toml',base..'\n# changed after review\n')
F.call('apply',{token=plan.plan_token},false)
F.check(F.active=='/base.toml','Stale review changed compositor')
F.write('/base.toml',base)
F.fail.compile='cursor-fixture'
local failed=F.call('choose',{effect='cursor/cursor-fixture',slot='effects.cursor'},false)
F.check(not failed.pending and F.active=='/base.toml','Compile failure did not rollback')
F.fail={}
F.fail.replace=true
F.call('choose',{effect='cursor/cursor-fixture',slot='effects.cursor'},false)
F.check(F.active=='/base.toml','Rejected replace changed compositor')
F.fail={compile='cursor-fixture',rollback=true}
failed=F.call('choose',{effect='cursor/cursor-fixture',slot='effects.cursor'},false)
F.check(failed.pending,'Failed rollback lost recovery journal')
F.fail={}; F.time+=8000
F.check(not F.call('recover').pending and F.active=='/base.toml','Recover failed rollback')
-- An unloaded VM cannot execute the callback after a command already reached Umbriel.
F.interrupt=true
F.backend.run({action='choose',request={effect='cursor/cursor-fixture',slot='effects.cursor'}},function() error('Interrupted operation completed') end)
for _=1,10000 do if F.interrupted then break end; F.pump() end
F.check(F.interrupted and F.files['/state/pending.json']~=nil,'Interrupted command lost journal')
F.backend=require('lib/backend.luau').new('/state')
F.call('recover',nil,false)
F.time+=8000
F.check(not F.call('recover').managed,'Recover interrupted callback')
local reused=F.call('choose',{effect='cursor/cursor-fixture',slot='effects.cursor'})
F.check(not reused.used_local_copy,'Local selection reused a stale installed copy')
local active=F.active
F.session+=0.0000002
F.backend=require('lib/backend.luau').new('/state')
F.check(F.call('status').managed and F.active==active,'Reload did not preserve active selections')
-- Restore has no dependency on the catalogue or its source checkout.
for path in pairs(F.files) do if path:sub(1,8)=='/assets/' then F.files[path]=nil end end
F.check(not F.call('restore').managed,'Restore required source catalogue')
F.check(F.files['/base.toml']==base,'Original config was modified')
local diagnostics=F.call('diagnostics').diagnostics
F.check(diagnostics.report_text and not diagnostics.report_text:find('external',1,true),'Diagnostics exposed stale target state')
print('PASS workflows: '..F.checks..' checks (all kinds, family, review, undo, removal, external overrides, rollback, interruption, persistence, offline restore)')
