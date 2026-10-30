-- SPDX-License-Identifier: MIT
local U = require("./util.luau")
local M = {}
function M.flatten(value, prefix, result)
  result = result or {}
  for key, v in pairs(value) do
    assert(
      not key:find(".", 1, true),
      noctalia.tr("graph.quoted_dotted_setting_key_is_not_a_nested_table")
    )
    if type(v) == "table" and #v == 0 then
      M.flatten(v, prefix .. "." .. key, result)
    else
      result[prefix .. "." .. key] = v
    end
  end
  return result
end
function M.read(base)
  local graph = { files = {}, settings = {}, presets = {}, drm = false }
  local visited, count = {}, 0
  local function visit(path, optional, depth)
    count += 1
    assert(depth < 32 and count <= 256, noctalia.tr("graph.configuration_graph_exceeds_limits"))
    path = U.normalize(path)
    if optional and not U.exists(path) then
      graph.files[path] = "missing"
      return
    end
    assert(not visited[path], noctalia.tr("graph.duplicate_or_cyclic_configuration_include"))
    visited[path] = true
    local raw = U.read(path)
    graph.files[path] = U.hash(path .. "\n" .. raw)
    local data = U.toml(raw)
    local include = data.include or {}
    for _, entry in ipairs(include.files or {}) do
      visit(U.expand(entry, U.parent(path)), false, depth + 1)
    end
    for _, entry in ipairs(include.optional and include.optional.files or {}) do
      visit(U.expand(entry, U.parent(path)), true, depth + 1)
    end
    graph.drm = graph.drm or data.drm ~= nil
    local effects = data.effects or {}
    for _, kind in ipairs({ "cursor", "border", "window", "screen" }) do
      if effects[kind] ~= nil then
        graph.settings["effects." .. kind] = effects[kind]
      end
    end
    if data.animation then
      M.flatten(data.animation, "animation", graph.settings)
    end
    for name, preset in pairs(effects.preset or {}) do
      assert(
        not graph.presets[name] and not name:match("^umbriel%-.*generation%-"),
        noctalia.tr("graph.conflicting_or_managed_preset_in_original_configuration")
      )
      local definition = U.copy(preset)
      if preset.shader then
        definition.shader = U.expand(preset.shader, U.parent(path))
        graph.files[definition.shader] = U.fingerprint(definition.shader)
      end
      graph.presets[name] = definition
    end
    for name in pairs(effects.pool or {}) do
      assert(not graph.presets[name], noctalia.tr("graph.pool_and_preset_name_collision"))
      graph.presets[name] = { kind = "pool" }
    end
  end
  visit(base, false, 0)
  return graph
end
return M
