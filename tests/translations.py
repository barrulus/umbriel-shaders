"""Use the shipped English catalogue in fixture hosts; reject missing keys."""
import json
from pathlib import Path


def translation_fixture():
    path = Path(__file__).resolve().parents[1] / 'umbriel-shaders/translations/en.json'
    flat = {}

    def flatten(value, prefix=''):
        for key, item in value.items():
            name = prefix + key
            if isinstance(item, dict):
                flatten(item, name + '.')
            else:
                flat[name] = item

    flatten(json.loads(path.read_text()))
    strings = ',\n'.join(
        f'[{json.dumps(key)}] = {json.dumps(value, ensure_ascii=False)}'
        for key, value in sorted(flat.items())
    )
    return 'local english = {\n' + strings + '''\n}
local translationOverrides = {}
local function fixtureTranslate(key, substitutions)
  local text = assert(translationOverrides[key] or english[key], "Missing translation: " .. key)
  return (text:gsub("{([^}]+)}", function(name)
    local value = (substitutions or {})[name]
    return value ~= nil and tostring(value) or "{" .. name .. "}"
  end))
end
local function fixturePlural(key, count, substitutions)
  local values = table.clone(substitutions or {})
  values.count = count
  return fixtureTranslate(key .. (count == 1 and ".one" or ".other"), values)
end
'''
