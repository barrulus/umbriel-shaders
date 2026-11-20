-- SPDX-License-Identifier: MIT
local check = require("./check")
local Catalogue = require("../lib/catalogue")
local data = require("./fixture")

check.eq(Catalogue.index({ schema_version = 2, effects = {} }), nil, "unknown schema rejected")
check.eq(
  Catalogue.index({ schema_version = 1, effects = {}, source = { revision = "../x" } }),
  nil,
  "non-hex revision rejected"
)

local cat = Catalogue.index(data)
check.eq(cat.revision, "abc123", "revision")
check.eq(#cat.effects, 2, "companions and unsafe effects are not listed")
check.eq(cat.effects[1].id, "animation/fade", "sorted by name")
check.eq(cat.byId["cursor/evil"], nil, "effects with unsafe paths are dropped")
check.truthy(cat.byId["window/glow-overlay"], "companions are indexed by id")
check.eq(cat.byPreset["glow"].id, "border/glow", "indexed by preset")
check.eq(#cat.families, 1, "families")

check.eq(#Catalogue.search(cat.effects, "", nil), 2, "empty query matches all")
check.eq(#Catalogue.search(cat.effects, "SOFT", nil), 1, "case-insensitive description match")
check.eq(#Catalogue.search(cat.effects, "", "animation.windows_out"), 1, "slot filter")
check.eq(
  #Catalogue.search(cat.effects, "glow", "animation.windows_in"),
  0,
  "query and slot combine"
)

local entry = Catalogue.resolve(cat, cat.byId["border/glow"], "effects.border", "/s")
check.eq(entry.id, "border/glow", "id")
check.eq(entry.name, "Glow", "name")
check.eq(entry.preset, "glow", "preset")
check.eq(entry.revision, "abc123", "revision recorded")
check.eq(entry.include[1], "/s/abc123/border/glow/effect.toml", "absolute include path")
check.eq(#entry.files, 5, "own and companion files, licence once")
check.eq(entry.deps[1], "window/glow-overlay", "companion dependency")
check.eq(entry.settings["effects.border"], "glow", "selector")

local out = Catalogue.resolve(cat, cat.byId["animation/fade"], "animation.windows_out", "/s")
check.eq(out.settings["animation.windows_out.duration_ms"], 200, "own slot timing kept")
check.eq(out.settings["animation.windows_in.effect"], nil, "other slot dropped")
check.eq(out.settings["animation.windows_out.enabled"], true, "event enabled")
check.eq(out.settings["animation.enabled"], true, "master switch")

local imported = {
  id = "import/x",
  name = "X",
  preset = "import.x",
  imported = true,
  uses = { "effects.screen" },
  include = { "/s/imports/x/effect.toml" },
}
local ie = Catalogue.resolve(nil, imported, "effects.screen", "/s")
check.eq(ie.settings["effects.screen"], "import.x", "import selector")
check.eq(#ie.files, 0, "imports download nothing")
check.eq(ie.include[1], "/s/imports/x/effect.toml", "import include")

local slots = Catalogue.familySlots(cat, cat.families[1])
check.eq(slots["effects.border"].id, "border/glow", "family border member")
check.eq(slots["animation.windows_in"].id, "animation/fade", "family animation member")
check.eq(slots["animation.enabled"], nil, "non-selector keys ignored")

local function catalogueWith(effects, families)
  return { schema_version = 1, source = data.source, effects = effects, families = families or {} }
end

-- A well-formed listable effect, adjusted by `change`.
local function probe(change)
  local effect = {
    id = "x/probe",
    name = "Probe",
    preset = "probe",
    role = "effect",
    uses = { "effects.window" },
    install_files = {},
    activation = { include = {}, settings = { ["effects.window"] = "probe" } },
  }
  if change then
    change(effect)
  end
  return effect
end

local function listed(change)
  return #Catalogue.index(catalogueWith({ probe(change) })).effects
end

check.eq(listed(), 1, "a well-formed probe is listed")
-- Malformed network data is skipped, never raised.
for _, case in
  {
    {
      "missing name",
      function(e)
        e.name = nil
      end,
    },
    {
      "missing settings",
      function(e)
        e.activation.settings = nil
      end,
    },
    {
      "missing include",
      function(e)
        e.activation.include = nil
      end,
    },
    {
      "install_files not a list",
      function(e)
        e.install_files = "LICENSE"
      end,
    },
    {
      "unknown dependency",
      function(e)
        e.dependencies = { "nonexistent" }
      end,
    },
    {
      "table-valued setting",
      function(e)
        e.activation.settings["effects.x"] = { 1 }
      end,
    },
    {
      "non-table uses",
      function(e)
        e.uses = "effects.window"
      end,
    },
    {
      "setting key with a space",
      function(e)
        e.activation.settings["effects.bad key"] = "x"
      end,
    },
  }
do
  check.eq(listed(case[2]), 0, case[1] .. " is not listed")
end

local withEvilDep = table.clone(data.effects)
table.insert(
  withEvilDep,
  probe(function(e)
    e.dependencies = { "cursor/evil" }
  end)
)
check.eq(
  #Catalogue.index(catalogueWith(withEvilDep)).effects,
  2,
  "unsafe dependency hides the effect"
)

local junk = Catalogue.index(catalogueWith({ "not a table" }, {
  "not a family",
  { id = "noname", activation = { include = {}, settings = {} } },
}))
check.truthy(junk, "malformed entries do not reject the catalogue")
check.eq(#junk.effects, 0, "non-table entries are skipped")
check.eq(#junk.families, 0, "nameless and non-table families are dropped")
check.done("catalogue")
