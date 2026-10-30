-- SPDX-License-Identifier: MIT
local U = require("./util.luau")
local S = require("./selection.luau")
local R = require("./registry.luau")
local G = require("./graph.luau")
local A = require("./async.luau")
local M = {}
function M.build(root, cache, refresh)
  root = U.normalize(root)
  local stamps, metadata, fallback = {}, {}, {}
  local count = 0
  local function scan(relative, depth)
    assert(depth <= 16, noctalia.tr("local_source.local_checkout_nesting_exceeds_limit"))
    local directory = relative == "" and root or U.path(root, relative)
    local entries = assert(
      noctalia.listDir(directory),
      noctalia.tr("local_source.cannot_read_local_shader_checkout")
    )
    for _, name in ipairs(entries) do
      if name:sub(1, 1) ~= "." then
        local path = relative == "" and name or relative .. "/" .. name
        local info = assert(
          noctalia.fileInfo(U.path(root, path)),
          noctalia.tr("local_source.local_file_disappeared")
        )
        count += 1
        assert(count <= 10000, noctalia.tr("local_source.too_many_local_files"))
        if info.isDir then
          scan(path, depth + 1)
        else
          stamps[path] = { info.size, info.mtime }
          local kind = path:match("^([^/]+)/[^/]+/metadata%.toml$")
          local overlay = path:match("^docs/catalogue%-examples/([^/]+)/[^/]+/metadata%.toml$")
          if S.kinds[kind] then
            table.insert(metadata, path)
          elseif S.kinds[overlay] then
            table.insert(fallback, path)
          end
        end
        A.checkpoint()
      end
    end
  end
  scan("", 0)
  local directory = U.path(cache, U.hash(root):sub(1, 16))
  local stampPath = directory .. "/stamps-v2.json"
  local function unchanged(previous)
    if
      type(previous) ~= "table"
      or type(previous.files) ~= "table"
      or not U.hex(previous.fingerprint, 32)
    then
      return false
    end
    for path, stamp in pairs(stamps) do
      local old = previous.files[path]
      -- Clock conversion jitter is not an edit. Exact timestamp hashes made
      -- otherwise unchanged checkouts miss their cache on every scan.
      if
        type(old) ~= "table"
        or type(old[2]) ~= "number"
        or old[1] ~= stamp[1]
        or math.abs(old[2] - stamp[2]) >= 0.001
      then
        return false
      end
      A.checkpoint()
    end
    for path in pairs(previous.files) do
      if not stamps[path] then
        return false
      end
    end
    return true
  end
  if not refresh and U.exists(stampPath) and U.exists(directory .. "/catalogue.json") then
    local ok, previous = pcall(U.load, stampPath)
    if ok and unchanged(previous) then
      return R.validate(U.decode(U.read(directory .. "/catalogue.json", 4 * U.limit)), true),
        previous.fingerprint
    end
  end
  local prefix = ""
  if #metadata == 0 then
    metadata = fallback
    prefix = "docs/catalogue-examples/"
  end
  assert(#metadata > 0, noctalia.tr("local_source.no_local_effect_metadata_found"))
  table.sort(metadata)
  local registry = {
    schema_version = 1,
    draft = true,
    source = { repository = R.repository },
    files = {},
    effects = {},
    families = {},
    feature_definitions = {
      ["preset-effects"] = "Umbriel named effect presets and selectors; the original preset API was introduced at 512e2fb3.",
      ["workspace-reveal-full-scene"] = "Full-scene workspace reveal: outgoing and incoming scene sampling, including umbriel_sample_incoming, with reveal mode. Older root-mask and scene-v1 interfaces are incompatible.",
      ["cursor-pointer-history"] = "Selection pointer history via umbriel_pointer_count and umbriel_pointer_path[64].",
    },
  }
  local files, effects, definitions = registry.files, {}, {}
  local total = 0
  local contents = {}
  local function read(name)
    if not contents[name] then
      contents[name] = U.read(U.path(root, name), 256 * 1024)
    end
    return contents[name]
  end
  local function file(name)
    if not files[name] then
      local media = name:match("%.(png)$")
        or name:match("%.(webp)$")
        or name:match("%.(gif)$")
        or name:match("%.(mp4)$")
        or name:match("%.(webm)$")
      if media then
        -- Display-only local media need no download checksum. Do not read whole
        -- GIFs and images merely to list their authoring metadata.
        local info = assert(
          noctalia.fileInfo(U.path(root, name)),
          noctalia.tr("local_source.local_file_disappeared")
        )
        assert(
          not info.isDir and info.size <= 32 * U.limit,
          noctalia.tr("local_source.local_assets_exceed_limit")
        )
        files[name] = { bytes = info.size, sha256 = false }
      else
        local raw = read(name)
        files[name] = { bytes = #raw, sha256 = U.hash(raw) }
      end
      total += files[name].bytes
      assert(total <= 512 * U.limit, noctalia.tr("local_source.local_assets_exceed_limit"))
    end
    return name
  end
  local function optional(name)
    if U.exists(U.path(root, name)) then
      return file(name)
    end
  end
  local function parse(name)
    return U.toml(read(name))
  end
  for _, path in ipairs(metadata) do
    local id = path:sub(#prefix + 1, -15)
    local kind = id:match("^([^/]+)/")
    local meta, data = parse(path), parse(id .. "/effect.toml")
    assert(
      data.effects and #U.keys(data.effects) == 1 and (not data.include or #U.keys(data) <= 2),
      noctalia.tr("local_source.unexpected_local_preset_sections")
    )
    local presets = data.effects.preset
    assert(
      type(presets) == "table" and #U.keys(presets) == 1,
      noctalia.tr("local_source.each_effect_must_define_one_preset")
    )
    local name, definition = next(presets)
    S.definition(definition, kind)
    definitions[id] = definition
    local shader = U.reference(id, definition.shader)
    assert(
      shader:sub(1, #id + 1) == id .. "/" and shader:match("%.glsl$"),
      noctalia.tr("local_source.invalid_shader_path")
    )
    local dependencies = {}
    for _, ref in ipairs(data.include and data.include.files or {}) do
      local dep = U.reference(id, ref)
      assert(dep:sub(-12) == "/effect.toml", noctalia.tr("local_source.invalid_dependency_include"))
      dependencies[dep:sub(1, -13)] = true
    end
    local features = U.copy(meta.requirements and meta.requirements.features or {})
    if not table.find(features, "preset-effects") then
      table.insert(features, 1, "preset-effects")
    end
    local role = meta.role or "effect"
    local install = { [id .. "/effect.toml"] = true, [shader] = true }
    for _, notice in ipairs(meta.notice_files) do
      install[notice] = true
    end
    for name in pairs(install) do
      file(name)
    end
    local animation
    for _, ext in ipairs({ "webm", "mp4", "gif" }) do
      animation = optional(id .. "/preview." .. ext)
      if animation then
        break
      end
    end
    local e = {
      id = id,
      path = id,
      kind = kind,
      role = role,
      preset = name,
      name = meta.name,
      description = meta.description,
      author = meta.author,
      license = meta.license,
      notice_files = meta.notice_files,
      tags = meta.tags or {},
      uses = meta.uses or (role == "companion" or kind == "animation") and {} or {
        "effects." .. kind,
      },
      dependencies = U.keys(dependencies),
      families = {},
      requirements = { features = features },
      required_settings = meta.required_settings or {},
      tested_on = meta.tested_on or {},
      install_files = U.keys(install),
      preview = { image = optional(id .. "/preview.png"), animation = animation },
      readme = optional(id .. "/README.md"),
      config_example = optional(id .. "/config.toml"),
    }
    effects[id] = e
    table.insert(registry.effects, e)
  end
  local function closure(ids)
    local found, visiting = {}, {}
    local function visit(id, depth)
      assert(
        effects[id] and not visiting[id] and depth < 64,
        noctalia.tr("local_source.missing_or_cyclic_local_dependency")
      )
      if found[id] then
        return
      end
      visiting[id] = true
      for _, dep in ipairs(effects[id].dependencies) do
        visit(dep, depth + 1)
      end
      visiting[id] = nil
      found[id] = true
    end
    for _, id in ipairs(ids) do
      visit(id, 0)
    end
    return found
  end
  local function roots(ids)
    local direct = {}
    for _, id in ipairs(ids) do
      direct[id] = true
    end
    for _, id in ipairs(ids) do
      for dep in pairs(closure(effects[id].dependencies)) do
        direct[dep] = nil
      end
    end
    local out = {}
    for _, id in ipairs(U.keys(direct)) do
      table.insert(out, id .. "/effect.toml")
    end
    return out
  end
  for _, e in ipairs(registry.effects) do
    local allowed = closure({ e.id })
    local overlay = definitions[e.id].overlay
    if overlay and overlay ~= "" then
      local found = false
      for id in pairs(allowed) do
        if effects[id].kind == "window" and effects[id].preset == overlay then
          found = true
        end
      end
      assert(found, noctalia.tr("local_source.overlay_is_not_an_included_window_dependency"))
    end
    if e.config_example and #e.uses > 0 then
      local data = parse(e.config_example)
      for k in pairs(data) do
        assert(
          k == "include" or k == "effects" or k == "animation",
          noctalia.tr("local_source.unexpected_activation_section")
        )
      end
      local includes = {}
      for _, ref in ipairs(data.include and data.include.files or {}) do
        assert(
          ref:sub(1, 18) == "shaders/community/" and ref:sub(-12) == "/effect.toml",
          noctalia.tr("local_source.invalid_example_include")
        )
        local id = U.relative(ref:sub(19, -13))
        assert(allowed[id], noctalia.tr("local_source.example_includes_unrelated_effect"))
        table.insert(includes, id)
      end
      local available = closure(includes)
      local settings, slots, manual = {}, {}, false
      if data.effects then
        G.flatten(data.effects, "effects", settings)
      end
      if data.animation then
        G.flatten(data.animation, "animation", settings)
      end
      for k, v in pairs(settings) do
        if k == "effects.max_fps" or k == "effects.in_capture" then
          manual = true
        else
          S.setting(k, v)
          if k:match("^effects%.") or k:match("%.effect$") then
            assert(
              v == e.preset and available[e.id] and table.find(e.uses, S.scope(k)),
              noctalia.tr("local_source.example_selects_unrelated_or_unsupported_effect")
            )
            slots[S.scope(k)] = true
          end
        end
      end
      assert(next(slots), noctalia.tr("local_source.example_has_no_effect_selection"))
      for k in pairs(settings) do
        if k ~= "effects.max_fps" and k ~= "effects.in_capture" then
          assert(
            S.scope(k) == "" or slots[S.scope(k)],
            noctalia.tr("local_source.example_changes_an_unselected_use")
          )
        end
      end
      for slot in pairs(slots) do
        local spring = ({ defaultspring = true, bouncy = true, smooth = true, stiff = true })[settings[slot .. ".curve"]]
        assert(
          not spring or not settings[slot .. ".duration_ms"],
          noctalia.tr("local_source.spring_duration_cannot_be_overridden")
        )
      end
      for id in pairs(allowed) do
        for k, v in pairs(effects[id].required_settings) do
          assert(
            settings[k] == nil or U.equal(settings[k], v),
            noctalia.tr("local_source.example_conflicts_with_requirements")
          )
        end
      end
      if not manual then
        e.activation = { include = roots(includes), settings = settings }
      end
    end
  end
  local familyFile = prefix .. "families.toml"
  local families = U.exists(U.path(root, familyFile)) and parse(familyFile).families or {}
  for _, id in ipairs(U.keys(families)) do
    local f = families[id]
    local authors, settings, required, selected = {}, {}, {}, {}
    for member in pairs(closure(f.members)) do
      authors[effects[member].author] = true
    end
    for slot, member in pairs(f.defaults or {}) do
      assert(
        table.find(f.members, member),
        noctalia.tr("local_source.family_default_is_not_a_member")
      )
      local b = S.binding(registry, member, slot)
      for k, v in pairs(b.settings) do
        assert(
          settings[k] == nil or U.equal(settings[k], v),
          noctalia.tr("local_source.conflicting_family_settings")
        )
        settings[k] = v
      end
      for k, v in pairs(b.required) do
        assert(
          required[k] == nil or U.equal(required[k], v),
          noctalia.tr("local_source.conflicting_family_requirements")
        )
        required[k] = v
      end
      table.insert(selected, member)
    end
    for k, v in pairs(required) do
      assert(
        settings[k] == nil or U.equal(settings[k], v),
        noctalia.tr("local_source.family_defaults_conflict_with_requirements")
      )
      if k == "animation.enabled" or (f.defaults or {})[S.scope(k)] then
        settings[k] = v
      end
    end
    for _, member in ipairs(f.members) do
      table.insert(effects[member].families, id)
    end
    table.insert(registry.families, {
      id = id,
      name = f.name,
      description = f.description,
      members = f.members,
      tags = f.tags or {},
      authors = U.keys(authors),
      preview = {},
      activation = #selected > 0 and { include = roots(selected), settings = settings } or nil,
    })
  end
  R.validate(registry, true)
  local raw = U.json(registry)
  assert(#raw <= 4 * U.limit, noctalia.tr("local_source.local_index_exceeds_limit"))
  U.atomic(directory .. "/catalogue.json", raw)
  local fingerprint = U.token()
  U.save(stampPath, { files = stamps, fingerprint = fingerprint })
  return registry, fingerprint
end
return M
