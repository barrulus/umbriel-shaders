#!/usr/bin/env python3
"""CLI error/protocol and offline browsing checks without a socket listener."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='native-cli-') as tmp:
    root=Path(tmp)
    index=root/'catalogue.json'
    registry=dict(schema_version=1,draft=False,source={'repository':'https://github.com/noctalia-dev/community-umbriel-shaders','revision':'a'*40},
                  files={},effects=[],families=[],feature_definitions={'preset-effects':'Presets'})
    index.write_text(json.dumps(registry))
    common=[binary,'--state-dir',root/'state','--socket',root/'absent.sock']
    def call(extra,ok):
        result=subprocess.run([*common,*extra],text=True,capture_output=True,timeout=10)
        value=json.loads(result.stdout)
        assert value['ok'] is ok and (result.returncode==0) is ok, result
        assert value['protocol_version']==1
        return value
    value=call(['--catalogue-index',index,'catalogue'],True)
    assert value['catalogue']['effects']==[] and 'live_error' in value
    assert not (root/'state').exists(), 'Offline browsing wrote transaction state'
    call(['--source-mode','snapshot','catalogue'],False)
    call(['--unknown','x','status'],False)
    call(['--slot','effects.invalid','choose'],False)
    assert 'report_text' in call(['diagnostics'],True)['diagnostics']
    registry['source']['revision']='main';index.write_text(json.dumps(registry))
    call(['--catalogue-index',index,'catalogue'],False)
    registry['source']['revision']='a'*40
    registry['files']['../escape.glsl']={'bytes':1,'sha256':hashlib.sha256(b'x').hexdigest()}
    index.write_text(json.dumps(registry))
    call(['--catalogue-index',index,'catalogue'],False)
print('PASS protocol errors, invalid requests, offline diagnostics/browsing without state writes, unpinned source and path traversal rejection')
