local F = fixture
local U = require('lib/util.luau')
local A = require('lib/allocation.luau')
local function load(path) return F.run(function() return U.load(path) end) end
F.effect('border','global-border')
F.effect('border','app-border')
F.effect('window','surface')
F.effect('animation','opening')
local app = 'org.example.App+[test](one){two}^$|?*\\name'
F.app_id = app
local key = A.key('effects.border',app)
F.check(A.destination(key)=='effects.border', 'Application destination did not roundtrip')
local _, decoded = A.destination(key)
F.check(decoded==app and A.pattern(app)=='^org\\.example\\.App\\+\\[test\\]\\(one\\)\\{two\\}\\^\\$\\|\\?\\*\\\\name$', 'App-ID regex escaping is not exact')
F.check(not pcall(A.key,'animation.windows_in',app), 'Per-application animation was accepted')
F.check(not pcall(A.key,'effects.border','bad\napp'), 'Control characters accepted in application ID')
F.check(not pcall(A.destination,'application:effects.cursor:app'), 'Unsupported saved destination was accepted')
local original = F.files['/base.toml']
F.call('choose',{effect='@off',slot='effects.cursor'})
F.check(F.call('status').settings['effects.cursor']=='', 'Global No effect did not use an empty selector')
F.call('choose',{effect='border/global-border',slot='effects.border'})
F.check(F.report().owners[1].slots.border.source=='default' and not next(F.runtime), 'Global selection became a runtime override')
-- Persistent assignments need not have a matching live window to compile yet.
F.unreferenced={['app-border']=true}
local applied=F.call('choose',{effect='border/app-border',slot=key})
F.check(applied.selections[key]=='border/app-border' and applied.selections['effects.border']=='border/global-border', 'Application assignment replaced the global slot')
local diagnostic=F.call('diagnostics').diagnostics.report_text
F.check(not diagnostic:find('org.example.App',1,true), 'Diagnostics exposed saved application identity')
F.check(applied.windows[1].slots.border.name=='app-border' and applied.windows[1].slots.border.source=='rule','Application preference was not resolved as a rule')
local state=load('/state/state.json')
local directory=U.parent(state.current.config)
F.check(state.current.files[directory..'/applications.toml']~=nil, 'Application rules absent from generation fingerprints')
F.check(not state.current.settings['effects.window'] and state.current.settings['effects.border']=='global-border', 'Application activation leaked into global settings')
local config=F.run(function() return U.toml(F.files[state.current.config]) end)
F.check(config.include.files[1]==directory..'/applications.toml' and config.include.files[2]=='/base.toml','Handwritten rules are not loaded after application preferences')
F.unreferenced=nil
local base=original..'\n[[window_rule]]\nmatch.app_id=".*"\nopacity=0.8\n\n[[window_rule]]\nmatch.is_focused=true\nborder_effect="off"\n'
F.write('/base.toml',base)
F.check(F.call('status').windows[1].slots.border.name=='app-border','Unrelated handwritten fields replaced the shader')
F.focused=true
F.check(F.call('status').windows[1].slots.border.name=='','Handwritten focus rule did not override application assignment')
F.focused=false
F.call('choose',{effect='window/surface',slot=A.key('effects.window',app)})
F.check(F.report().owners[1].slots.window.name=='surface','Window-surface assignment failed')
F.app_id='another.application'
F.check(F.report().owners[1].slots.border.name=='global-border' and F.report().owners[1].slots.window.name=='','Application preference matched another app')
F.app_id=app
F.runtime['border:42']={source='runtime',name='external',pool='',suppressed=true}
F.call('choose',{effect='border/app-border',slot='effects.border'})
F.check(F.runtime['border:42'].name=='external' and F.runtime['border:42'].suppressed,'Applying a global default overwrote an external runtime override')
F.call('choose',{effect='@off',slot=key})
F.check(F.call('status').selections[key]=='@off' and F.runtime['border:42'].name=='external','No effect displaced runtime selection')
F.runtime={}
F.check(F.report().owners[1].slots.border.name=='','No effect was not persisted as an explicit off rule')
F.call('undo')
F.check(F.report().owners[1].slots.border.name=='app-border','Undo did not restore application rules')
F.call('remove',{slot=key})
F.check(F.report().owners[1].slots.border.name=='app-border' and F.report().owners[1].slots.border.source=='default','Inherit did not expose global default')
F.call('undo')
F.call('choose',{effect='animation/opening',slot='animation.windows_in'})
F.call('timing',{slot='animation.windows_in',duration_ms=680,curve='easeoutcubic'})
F.check(F.call('status').settings['animation.windows_in.duration_ms']==680,'Animation duration was not saved')
F.check(F.call('status').settings['animation.windows_in.curve']=='easeoutcubic', 'Duration override did not save a duration-based curve')
F.call('timing',{slot='animation.windows_in',duration_ms=680,curve='defaultspring'},false)
local active=F.active
F.call('timing',{slot='animation.windows_in',duration_ms=0},false)
F.call('choose',{effect='border/app-border',slot='application:animation.windows_in:app'},false)
F.check(F.active==active,'Invalid assignment or duration changed live config')
F.call('refresh')
F.check(F.call('status').selections[key]=='border/app-border' and F.call('status').settings['animation.windows_in.duration_ms']==680,'Local refresh lost application targets or timing')
F.call('choose',{effect='@off',slot='animation.windows_in'})
F.check(F.call('status').settings['animation.windows_in.enabled']==false,'Animation No effect did not disable its event')
F.call('undo')
F.check(F.call('status').settings['animation.windows_in.duration_ms']==680,'Undo lost custom timing')
-- A reviewed application's include is guarded just like its config and shaders.
local plan=F.call('prepare',{effect='border/app-border',slot=key})
local generated=load('/state/plan.json').generation
local rules=U.parent(generated.config)..'/applications.toml'
F.write(rules,F.files[rules]..'\n# changed after review\n')
active=F.active
F.call('apply',{token=plan.plan_token},false)
F.check(F.active==active,'Tampered application include was applied')
-- A failed application shader rolls back its complete generation.
F.effect('border','broken')
F.fail.compile='broken'
F.call('choose',{effect='border/broken',slot=key},false)
F.check(F.active==active and not F.call('status').pending,'Failed application shader did not roll back')
F.fail={}
-- Release legacy runtime overrides owned by the plugin, retaining Undo.
state=load('/state/state.json')
local id=F.run(function() return U.json({'border','42'}) end)
local legacy={kind='border',target='42',value={source='runtime',name='app-border',pool='',suppressed=false}}
state.owned[id]=legacy
state.original[id]={kind='border',target='42',value={source='rule',name='app-border',pool='',suppressed=false}}
F.run(function() U.save('/state/state.json',state) end)
F.runtime['border:42']=U.copy(legacy.value)
F.call('choose',{effect='border/global-border',slot='effects.border'})
F.check(F.runtime['border:42']==nil,'Legacy plugin override continued masking rules')
F.call('undo')
F.check(F.runtime['border:42'] and F.runtime['border:42'].name=='app-border','Undo did not restore legacy runtime ownership')
-- Removing assignments and restoring remain possible without the catalogue.
for path in pairs(F.files) do if path:sub(1,8)=='/assets/' then F.files[path]=nil end end
F.call('remove',{slot=key})
F.check(not F.call('restore').managed and F.files['/base.toml']==base,'Offline restore modified original rules')
print('PASS allocations: '..F.checks..' checks (rule ordering, exact matching, runtime overrides, timing, validation, rollback, migration, undo and offline restore)')
