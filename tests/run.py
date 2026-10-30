#!/usr/bin/env python3
"""Bundle the actual plugin modules and execute their host-fixture tests in Luau."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / 'umbriel-shaders'

def bundle(entry):
    loaders = []
    for path in sorted(PLUGIN.rglob('*.luau')):
        name = path.relative_to(PLUGIN).as_posix()
        def dependency(match):
            target = (path.parent / match.group(1)).resolve().relative_to(PLUGIN).as_posix()
            return f'require({target!r})'
        source = re.sub(r'require\("([^\"]+)"\)', dependency, path.read_text())
        loaders.append(f'loaders[{name!r}] = function()\n{source}\nend\n')
    return ('local loaders, modules = {}, {}\nlocal require\n'
            'require = function(name)\n if modules[name] == nil then modules[name] = assert(loaders[name], name)() end\n return modules[name]\nend\n'
            + '\n'.join(loaders) + '\n' + entry)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('runner', help='Luau CLI or tests/luau_runner.cpp executable')
    args = parser.parse_args()
    for test in sorted((ROOT / 'tests/luau').glob('*.luau')):
        with tempfile.TemporaryDirectory(prefix='shaders-luau-test-') as temp:
            script = Path(temp) / test.name
            script.write_text(bundle((ROOT / 'tests/fixtures/host.luau').read_text() + '\n' + test.read_text()))
            subprocess.run([args.runner, str(script)], check=True, timeout=120)
