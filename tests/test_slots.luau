-- SPDX-License-Identifier: MIT
local check = require("./check")
local Slots = require("../lib/slots")

check.eq(#Slots.list, 13, "thirteen slots")
check.eq(Slots.kind("effects.border"), "border", "effects kind")
check.eq(Slots.kind("animation.windows_in"), "animation", "animation kind")
check.eq(Slots.key("animation.windows_in"), "animation_windows_in", "translation key")
check.eq(Slots.isAnimation("effects.cursor"), false, "cursor is not an animation")
check.eq(Slots.appSlots["effects.border"], "border_effect", "border window-rule key")

local selector = Slots.selector("animation.workspaces", "import.x")
check.eq(selector["animation.workspaces.effect"], "import.x", "animation selector")
check.eq(selector["animation.workspaces.enabled"], true, "event enabled")
check.eq(selector["animation.enabled"], true, "animation master switch")
check.eq(Slots.selector("effects.screen", "v")["effects.screen"], "v", "effects selector")

local filtered = Slots.filter({
  ["animation.enabled"] = true,
  ["animation.windows_in.effect"] = "fade",
  ["animation.windows_in.duration_ms"] = 300,
  ["animation.windows_out.effect"] = "fade",
  ["animation.windows_inx"] = 1,
}, "animation.windows_in")
check.eq(filtered["animation.windows_in.effect"], "fade", "keeps own effect")
check.eq(filtered["animation.windows_in.duration_ms"], 300, "keeps own timing")
check.eq(filtered["animation.enabled"], true, "keeps master switch")
check.eq(filtered["animation.windows_out.effect"], nil, "drops other slot")
check.eq(filtered["animation.windows_inx"], nil, "prefix must end at a dot")
local border =
  Slots.filter({ ["animation.enabled"] = true, ["effects.border"] = "g" }, "effects.border")
check.eq(border["animation.enabled"], nil, "no master switch for effect slots")
check.eq(border["effects.border"], "g", "effect selector kept")
check.done("slots")
