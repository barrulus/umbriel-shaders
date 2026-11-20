-- SPDX-License-Identifier: MIT
local check = require("./check")
local Selection = require("../lib/selection")

local sel = Selection.empty()
local a = Selection.change(sel, function(n)
  n.slots["effects.screen"] = { id = "screen/v", preset = "v" }
end)
check.eq(sel.slots["effects.screen"], nil, "change does not mutate its input")
check.eq(a.slots["effects.screen"].preset, "v", "change applied")
check.truthy(a.previous, "previous state recorded")

local b = Selection.change(a, Selection.clearAll)
check.eq(next(b.slots), nil, "clear all")
local c = Selection.undo(b)
check.eq(c.slots["effects.screen"].preset, "v", "undo restores the previous state")
check.eq(next(Selection.undo(c).slots), nil, "undoing an undo redoes")
check.eq(Selection.undo(Selection.empty()), nil, "nothing to undo")

local d = Selection.change(sel, function(n)
  Selection.setApp(n, "mpv", "effects.window", nil)
  Selection.setApp(n, "mpv", "effects.window", { id = "window/s", preset = "s" })
  Selection.setApp(n, "mpv", "effects.border", nil)
end)
check.eq(#d.apps, 2, "one rule per application and slot")
check.eq(d.apps[1].entry.preset, "s", "rule updated in place")
local e = Selection.change(d, function(n)
  Selection.removeApp(n, "mpv", "effects.window")
end)
check.eq(#e.apps, 1, "rule removed")
check.eq(e.apps[1].slot, "effects.border", "other rule kept")

local t = Selection.parseTiming(" 450 ", " linear ")
check.eq(t.duration_ms, 450, "duration parsed")
check.eq(t.curve, "linear", "curve trimmed")
check.eq(next(Selection.parseTiming("", "")), nil, "empty fields mean no override")
local bad, err = Selection.parseTiming("fast", "")
check.eq(bad, nil, "non-numeric duration rejected")
check.eq(err, "error.duration", "error key")
check.eq(Selection.parseTiming("12.5", ""), nil, "fractional duration rejected")
check.eq(Selection.parseTiming("-1", ""), nil, "negative duration rejected")
-- An import used by a slot and an app rule, next to an ordinary slot.
local function withImport(n)
  n.imports = { { id = "import/x" } }
  n.slots["effects.cursor"] = { id = "import/x" }
  n.slots["effects.screen"] = { id = "screen/v", preset = "v" }
  n.apps = { { app_id = "a", slot = "effects.window", entry = { id = "import/x" } } }
end
local removed = Selection.change(Selection.change(sel, withImport), function(n)
  Selection.removeImport(n, "import/x")
end)
check.eq(#removed.imports, 0, "import removed")
check.eq(removed.slots["effects.cursor"], nil, "slot using the import cleared")
check.eq(#removed.apps, 0, "rule using the import removed")
check.eq(removed.slots["effects.screen"].preset, "v", "other slots kept")
local restored = Selection.undo(removed)
check.eq(restored.slots["effects.cursor"], nil, "undo does not restore a removed import slot")
check.eq(restored.slots["effects.screen"].preset, "v", "undo restores a non-import slot")
check.eq(#restored.apps, 0, "undo does not restore a rule using a removed import")
check.eq(#restored.imports, 0, "undo keeps the import removed")
check.done("selection")
