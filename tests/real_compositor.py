#!/usr/bin/env python3
"""Exercise the native helper against a private headless Umbriel with real GPU compilation."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--helper',type=Path,required=True)
parser.add_argument('--umbriel',default=shutil.which('umbriel'))
parser.add_argument('--catalogue-index',type=Path,required=True)
parser.add_argument('--assets',type=Path,required=True)
parser.add_argument('--effect',default='cursor/glow')
parser.add_argument('--all-types',action='store_true',help='Exercise each effect kind, a family and per-slot removal')
args=parser.parse_args()
if not args.umbriel: parser.error('Umbriel is required')
helper=args.helper.resolve();index=args.catalogue_index.resolve();assets=args.assets.resolve()
with tempfile.TemporaryDirectory(prefix='native-gpu-') as tmp:
    root=Path(tmp);root.chmod(0o700)
    env=os.environ.copy()
    for key in ('DISPLAY','WAYLAND_DISPLAY','WAYLAND_SOCKET','UMBRIEL_SOCKET','NOCTALIA_SOCKET','DBUS_SESSION_BUS_ADDRESS','WLR_DRM_DEVICES','WLR_BACKENDS','WLR_HEADLESS_OUTPUTS'):
        env.pop(key,None)
    env.update(XDG_RUNTIME_DIR=str(root),WAYLAND_DISPLAY='wayland-0',UMBRIEL_SOCKET=str(root/'umbriel-wayland-0.sock'),
               XDG_CONFIG_HOME=str(root/'config'),XDG_STATE_HOME=str(root/'state'),XDG_CACHE_HOME=str(root/'cache'),
               WLR_BACKENDS='headless',WLR_HEADLESS_OUTPUTS='1',WLR_LIBINPUT_NO_DEVICES='1',WLR_RENDERER='gles2',LIBGL_ALWAYS_SOFTWARE='1')
    base=root/'base.toml'
    base.write_text('[general]\nautostart=[]\nxwayland=false\nshow_cheatsheet=false\n[effects]\ncursor=""\n[animation]\nenabled=false\n')
    original=base.read_bytes()
    with (root/'compositor.log').open('w') as log:
        process=subprocess.Popen([args.umbriel,'-c',base],env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=log)
        try:
            deadline=time.monotonic()+15
            while not Path(env['UMBRIEL_SOCKET']).is_socket():
                if process.poll() is not None or time.monotonic()>deadline:
                    raise RuntimeError('Private compositor unavailable:\n'+(root/'compositor.log').read_text()[-5000:])
                time.sleep(.05)
            def command(action,*extra):
                result=subprocess.run([helper,'--state-dir',root/'plugin','--socket',env['UMBRIEL_SOCKET'],'--base-config',base,
                                       '--catalogue-index',index,'--source-root',assets,*extra,action],env=env,capture_output=True,text=True,timeout=60)
                value=json.loads(result.stdout)
                if result.returncode or not value['ok']:raise RuntimeError(value.get('message',result.stderr))
                return value
            assert not command('status')['managed']
            plan=command('prepare','--effect',args.effect)
            assert not command('status')['managed']
            assert command('apply','--plan-token',plan['plan_token'])['managed']
            assert not command('undo')['managed']
            assert command('choose','--effect',args.effect)['managed']
            assert not command('restore')['managed']
            if args.all_types:
                registry=json.loads(index.read_text())
                selected={}
                for effect in registry['effects']:
                    if effect['role']=='effect' and effect['activation'] and effect['kind'] not in selected:
                        selected[effect['kind']]=effect
                for effect in selected.values():
                    slot=effect['uses'][0]
                    plan=command('prepare','--effect',effect['id'],'--slot',slot)
                    command('apply','--plan-token',plan['plan_token'])
                    print('PASS real compositor',effect['id'],slot,flush=True)
                assert len(command('status')['selections'])==5
                command('remove','--slot','effects.border')
                assert 'effects.border' not in command('status')['selections']
                command('undo')
                assert 'effects.border' in command('status')['selections']
                command('restore')
                family=next(f for f in registry['families'] if f['activation'])
                members={e['id']:e for e in registry['effects'] if e['id'] in family['members'] and e['role']=='effect'}
                choices={slot:'' for effect in members.values() for slot in effect['uses']}
                for slot in choices:
                    selector=slot+'.effect' if slot.startswith('animation.') else slot
                    preferred=family['activation']['settings'].get(selector)
                    choices[slot]=next((e['id'] for e in members.values() if slot in e['uses'] and e['preset']==preferred),'')
                command('choose-family','--family',family['id'],'--choices',json.dumps(choices))
                command('undo')
                assert not command('status')['managed']
                print('PASS real compositor family transaction and per-slot removal',flush=True)
            assert base.read_bytes()==original
            print('PASS native Review/Apply/Undo/Restore and real GPU compilation in a private compositor')
        finally:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
