#!/usr/bin/env python3
"""Exercise local indexing against an actual checkout, substituting tiny preview bytes."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
from run import bundle, ROOT

parser = argparse.ArgumentParser()
parser.add_argument('runner')
parser.add_argument('checkout', type=Path)
args = parser.parse_args()
lines = [(ROOT/'tests/fixtures/host.luau').read_text()]
count = 0
for path in sorted(args.checkout.rglob('*')):
    relative = path.relative_to(args.checkout)
    if not path.is_file() or any(p.startswith('.') for p in relative.parts):
        continue
    if path.suffix.lower() in {'.png', '.gif', '.mp4', '.webm', '.webp'}:
        content = 'fixture preview'
    else:
        try:
            content = path.read_text()
        except UnicodeDecodeError:
            continue
    delimiter = '='
    while f']{delimiter}]' in content:
        delimiter += '='
    # A leading newline is stripped by Luau long strings.
    literal = f'[{delimiter}[\n{content}]{delimiter}]'
    lines.append(f'fixture.write({json.dumps("/assets/" + relative.as_posix())}, {literal})')
    count += 1
lines.append('''
local value=fixture.call('catalogue')
assert(#value.catalogue.effects>20,'Real catalogue lost entries')
local source=fixture.run(function() return require('lib/source.luau').open('/state',false) end)
local S=require('lib/selection.luau')
local recipes=0
for _,effect in ipairs(source.registry.effects) do
  if effect.activation and effect.role=='effect' then
    for _,slot in ipairs(effect.uses) do
      fixture.run(function() S.binding(source.registry,effect.id,slot) end)
      recipes+=1
    end
  end
end
local prepared=fixture.call('prepare',{effect='border/diya-lights',slot='effects.border'})
assert(#prepared.dependencies==2,'Real border overlay dependency was not installed')
print('PASS real checkout: '..#source.registry.effects..' effects, '..#source.registry.families..' families, '..recipes..' activation bindings; border overlay review')
''')
with tempfile.TemporaryDirectory(prefix='shaders-checkout-') as temp:
    script=Path(temp)/'checkout.luau'
    script.write_text(bundle('\n'.join(lines)))
    subprocess.run([args.runner,str(script)],check=True,timeout=120)
