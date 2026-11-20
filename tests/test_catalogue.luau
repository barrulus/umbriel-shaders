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
check.done("catalogue")
