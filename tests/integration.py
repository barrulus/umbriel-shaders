#!/usr/bin/env python3
"""Native CLI/IPC integration, private synthetic compositor; requires no GPU."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

helper, server = map(lambda p: Path(p).resolve(), sys.argv[1:3])

def wait_for(path, process):
    deadline = time.monotonic() + 10
    while not path.exists():
        if process.poll() == 77:
            print('SKIP: environment prohibits binding a private Unix socket')
            raise SystemExit(77)
        if process.poll() is not None or time.monotonic() >= deadline:
            raise RuntimeError(f'Process exited or timed out waiting for {path}')
        time.sleep(.01)

with tempfile.TemporaryDirectory(prefix='native-ipc-') as temporary:
    root = Path(temporary)
    base = root / 'base.toml'
    base.write_text('[effects]\ncursor = ""\n[general]\nautostart = []\n')
    original = base.read_bytes()
    assets = root / 'assets'
    files = {}
    effects = []
    for kind in ('cursor', 'border', 'window', 'screen', 'animation'):
        name = 'glow' if kind == 'cursor' else kind + '-fixture'
        identifier = kind + '/' + name
        contents = {
            identifier + '/effect.toml': f'[effects.preset.{name}]\nkind="{kind}"\nshader="shader.glsl"\n',
            identifier + '/shader.glsl': f'vec4 {kind}(vec2 uv) {{ return umbriel_sample(uv); }}\n',
            identifier + '/README.md': 'Synthetic MIT fixture\n',
        }
        for path, content in contents.items():
            destination = assets / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(content)
            files[path] = {'bytes': len(content.encode()), 'sha256': hashlib.sha256(content.encode()).hexdigest()}
        slot = 'animation.windows_in' if kind == 'animation' else 'effects.' + kind
        effects.append(dict(id=identifier, path=identifier, kind=kind, role='effect', preset=name, name=name,
                       description='Synthetic preset', author='Test', license='MIT', tags=[], families=['fixture'],
                       uses=[slot], dependencies=[], required_settings={}, notice_files=[identifier+'/README.md'],
                       install_files=list(contents), preview={'image':None,'animation':None},
                       activation={'settings':{slot + ('.effect' if kind == 'animation' else ''):name}}))
    family = dict(id='fixture', name='Fixture', members=[e['id'] for e in effects], activation={'settings':{}})
    index = root / 'catalogue.json'
    index.write_text(json.dumps(dict(schema_version=1, draft=False, source={'repository':'https://github.com/noctalia-dev/community-umbriel-shaders','revision':'a'*40},
                                    feature_definitions={'preset-effects':'Presets'},effects=effects,families=[family],files=files)))
    socket = root / 'umbriel.sock'
    state = root / 'state'
    process = subprocess.Popen([server,'-c',base,'--socket',socket],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    common = ['--state-dir',str(state),'--socket',str(socket),'--base-config',str(base),'--catalogue-index',str(index),'--source-root',str(assets)]
    def command(action, *extra, binary=helper, expect=True):
        result = subprocess.run([binary,*common,*extra,action],text=True,capture_output=True,timeout=15)
        value = json.loads(result.stdout)
        assert value['ok'] is expect, value
        assert (result.returncode == 0) is expect, result
        return value
    try:
        wait_for(socket,process)
        assert not command('status')['managed']
        assert len(command('catalogue')['catalogue']['effects'])==5
        plan=command('prepare','--effect','cursor/glow')
        assert not command('status')['managed']
        assert command('apply','--plan-token',plan['plan_token'])['managed']
        assert not command('undo')['managed']
        assert command('choose','--effect','cursor/glow')['managed']
        assert not command('restore')['managed']
        choices = {e['uses'][0]: e['id'] for e in effects}
        family_plan = command('prepare-family', '--family', 'fixture', '--choices', json.dumps(choices))
        applied = command('apply', '--plan-token', family_plan['plan_token'])
        assert len(applied['selections']) == 5
        assert len(command('remove', '--slot', 'effects.border')['selections']) == 4
        assert len(command('undo')['selections']) == 5
        assert not command('restore')['managed']
        # Kill only the helper after the compositor has accepted the switch.
        (root/'hold-switch').touch()
        child=subprocess.Popen([helper,*common,'--effect','cursor/glow','choose'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        wait_for(root/'switched',child)
        child.kill();child.communicate(timeout=5)
        assert (state/'pending.json').exists()
        (root/'hold-switch').unlink()
        assert command('status')['pending']
        # Recover with the preserved executable and no catalogue/assets supplied.
        recovery=state/'recovery'
        shutil.rmtree(assets);index.unlink()
        result=subprocess.run([recovery,'--state-dir',state,'--socket',socket,'recover'],text=True,capture_output=True,timeout=15)
        assert result.returncode==0,result.stdout+result.stderr
        assert not json.loads(result.stdout)['managed']
        assert not (state/'pending.json').exists()
        assert base.read_bytes()==original
        # Lock release on SIGKILL and complete standalone recovery were both exercised.
        print('PASS CLI all five kinds, family review/apply, explicit window/output targets, removal/undo, fragmented IPC, SIGKILL recovery without catalogue/assets')
    finally:
        process.terminate()
        try: process.communicate(timeout=5)
        except subprocess.TimeoutExpired: process.kill();process.communicate()
