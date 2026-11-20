# Umbriel Shaders Simplified Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ~7k-line plugin with a ~1.5k-line plugin that writes one Umbriel include file from the published community catalogue.

**Architecture:** A panel-only Noctalia plugin (no service). Pure Luau modules in `umbriel-shaders/lib/` hold all logic (slot table, TOML rendering, include setup, catalogue indexing, selection state, downloads); `lib/apply.luau` orchestrates download → write → validate → save; `panel.luau` is UI only. Umbriel picks up `~/.config/umbriel/noctalia-shaders.toml` through `[include.optional]` and reloads it on change.

**Tech Stack:** Luau (Noctalia plugin API 43), Noctalia `ui.*` declarative panel, `noctalia.http` / `noctalia.download` / `noctalia.runAsync`, `umbriel config validate --json`. Tests: stock `luau` CLI via `tests/run.py`.

**Spec:** `docs/superpowers/specs/2026-11-20-simplified-redesign-design.md`

## Facts established before planning (2026-11-20)

- `noctalia.json.decode` of the real 444 KB `catalogue.json` takes 3.7 ms in a panel HTTP callback (25 ms CPU budget per callback, 100 ms for the top-level load). **No service entry.**
- `noctalia.download(url, dest, cb)` does **not** create parent directories, and a 404 gives `cb(false)` with no file written.
- `umbriel config validate -c <path> --json` prints `{"diagnostics":[{file,line,column,message,severity}],"valid":bool}` and exits 0. It follows `[include.optional]`. **Any warning makes `valid` false**, including `include cycle or duplicate skipped: <path>` when one file is included twice.
- A border `effect.toml` includes its overlay through a relative path (`../../window/<overlay>/effect.toml`), so downloaded files must keep the repository layout, and the generated file must not include a companion whose parent is also selected.
- The author's own `config.toml` already has `[include.optional] files = ["scratch.toml", ...]`, so setup must insert into an existing `files = [` array.
- The stock `luau` CLI resolves `require("./x")` (no extension); Noctalia requires `require("./x.luau")`. `tests/run.py` rewrites the extension in a temp copy.
- `ui.select` reports a 0-based index as a string. Glyphs known to render: `refresh`, `x`, `trash`, `plus`.

## Global Constraints

- Plugin ID stays `barrulus/umbriel-shaders`; `plugin_api = 43`; version `0.7.0`; manifest dependencies `["umbriel"]` only.
- The plugin never calls `config-replace` and writes the user's `config.toml` only from the **Add for me** setup button, after writing `config.toml.bak`.
- Generated file: `<umbriel config dir>/noctalia-shaders.toml`. Shader files: `<umbriel config dir>/noctalia-shaders/<revision>/<repo path>` and `<umbriel config dir>/noctalia-shaders/imports/<id>/`. Umbriel config dir = `$XDG_CONFIG_HOME/umbriel` or `~/.config/umbriel`.
- Plugin data dir holds only `selection.json`, `catalogue.json`, `previews/`.
- Catalogue URL: `https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/catalogue/catalogue.json`. Asset URLs: `https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/<revision>/<path>`.
- Size target: all text files under `umbriel-shaders/` < ~1,800 lines; tests ~300 lines.
- Formatting: `.stylua.toml` (2 spaces, width 100, `collapse_simple_statement = "Never"`). Always run `stylua umbriel-shaders tests` before committing; code blocks below may be compacted.
- Every Luau file starts with `-- SPDX-License-Identifier: MIT`.
- User-facing strings go through `noctalia.tr` with keys in `umbriel-shaders/translations/en.json` (written in full in Task 1).
- Commit messages: imperative subject, **no** `Co-Authored-By` line, no Claude attribution (user's global instruction).
- Work happens on branch `redesign/simplify` in `/home/barrulus/dev/umbriel-shaders`. Noctalia's `experimental` plugin source points at this working tree, so every save hot-reloads the live plugin.
- Run tests with: `nix-shell --run "python3 tests/run.py"` (Task 1 adds `luau` to `shell.nix`).

## File map

| File | Responsibility |
|---|---|
| `umbriel-shaders/plugin.toml` | Manifest: panel, shortcut, widget; no settings, no service |
| `umbriel-shaders/panel.luau` | UI only: header, setup banner, Slots / Browse / Families tabs |
| `umbriel-shaders/lib/slots.luau` | The 13 destinations, kind, translation key, selector settings, per-slot filtering |
| `umbriel-shaders/lib/config.luau` | Paths; TOML rendering; include detection/insertion; validate + diagnostic diff; setup |
| `umbriel-shaders/lib/catalogue.luau` | Fetch/cache catalogue, index, search, resolve effect → selection entry, family → slots |
| `umbriel-shaders/lib/selection.luau` | `selection.json` load/save; pure state changes; one-level undo; timing parsing |
| `umbriel-shaders/lib/files.luau` | Download jobs (bounded, `.part` + rename); GLSL import/removal |
| `umbriel-shaders/lib/apply.luau` | download → validate(before) → write → validate(after) → revert or save |
| `umbriel-shaders/widget.luau`, `shortcut.luau`, `thumbnail.webp`, `LICENSE` | Unchanged |
| `umbriel-shaders/translations/en.json` | All strings |
| `tests/run.py`, `tests/check.luau`, `tests/fixture.luau`, `tests/test_*.luau` | Unit tests for lib modules |

Deviation from spec structure: `lib/slots.luau` (shared slot table) and `lib/apply.luau` (I/O orchestration, keeps the panel UI-only) are added.

---

### Task 0: Restore the live configuration (user action, before Task 1)

The currently enabled 0.5.x plugin drives Umbriel through a wrapper configuration (`config-replace`). Task 1 deletes that code from the live plugin source.

- [ ] **Step 1:** Ask the user to open the current Umbriel Shaders panel and press **Restore original**, then confirm Umbriel runs their own `config.toml` again. Do not start Task 1 until the user confirms.

---

### Task 1: Remove the old implementation and scaffold tests, manifest, slots

**Files:**
- Delete: `umbriel-shaders/lib/` (all, including `vendor/`), `umbriel-shaders/service.luau`, `tests/` (all), `VALIDATION.md`
- Replace: `umbriel-shaders/panel.luau` (placeholder), `umbriel-shaders/plugin.toml`, `umbriel-shaders/translations/en.json`, `shell.nix`
- Create: `tests/run.py`, `tests/check.luau`, `tests/test_slots.luau`, `umbriel-shaders/lib/slots.luau`

**Interfaces:**
- Produces `lib/slots.luau`:
  - `Slots.list: {string}` — the 13 slots in display order
  - `Slots.appSlots: {[slot]: "border_effect"|"window_effect"}`
  - `Slots.kind(slot) -> "cursor"|"border"|"window"|"screen"|"animation"`
  - `Slots.key(slot) -> string` (dots → underscores, for `noctalia.tr("slot." .. key)`)
  - `Slots.isAnimation(slot) -> boolean`
  - `Slots.selector(slot, preset) -> {[dottedKey]: value}`
  - `Slots.filter(settings, slot) -> {[dottedKey]: value}`
- Produces `tests/check.luau`: `check.eq(actual, expected, label)`, `check.truthy(value, label)`, `check.done(name)`

- [ ] **Step 1: Delete the old implementation**

```bash
cd /home/barrulus/dev/umbriel-shaders
git rm -r -q umbriel-shaders/lib umbriel-shaders/service.luau tests VALIDATION.md
```

- [ ] **Step 2: Replace `shell.nix`**

```nix
# Development tools only. The installed plugin needs Noctalia and Umbriel.
{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  packages = with pkgs; [ python3 luau stylua ];
}
```

- [ ] **Step 3: Write `tests/run.py`**

```python
#!/usr/bin/env python3
"""Run the Luau unit tests in tests/test_*.luau against umbriel-shaders/lib.

Noctalia requires modules as require("./x.luau"); the stock luau CLI resolves
require("./x"). The lib modules are copied to a temporary tree with the
extension removed, next to a copy of the tests, so tests can require("../lib/x").
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRE = re.compile(r'require\("(\.{1,2}/[^"]+)\.luau"\)')


def main() -> int:
    luau = sys.argv[1] if len(sys.argv) > 1 else "luau"
    with tempfile.TemporaryDirectory(prefix="umbriel-shaders-tests-") as temp:
        tree = Path(temp)
        (tree / "lib").mkdir()
        for module in (ROOT / "umbriel-shaders" / "lib").glob("*.luau"):
            (tree / "lib" / module.name).write_text(REQUIRE.sub(r'require("\1")', module.read_text()))
        shutil.copytree(ROOT / "tests", tree / "tests", ignore=shutil.ignore_patterns("*.py", "__pycache__"))
        failures = 0
        for test in sorted((tree / "tests").glob("test_*.luau")):
            failures += subprocess.run([luau, str(test)]).returncode != 0
    if failures:
        print(f"{failures} test file(s) failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Write `tests/check.luau`**

```lua
-- SPDX-License-Identifier: MIT
-- Minimal assertions for the plugin's Luau unit tests.
local M = { count = 0 }

function M.eq(actual, expected, label)
  M.count += 1
  if actual ~= expected then
    error(string.format("%s\n  expected: %s\n  actual:   %s", label, tostring(expected), tostring(actual)), 2)
  end
end

function M.truthy(value, label)
  M.count += 1
  if not value then
    error(label .. ": expected a truthy value", 2)
  end
end

function M.done(name)
  print(string.format("PASS %s (%d checks)", name, M.count))
end

return M
```

- [ ] **Step 5: Write the failing test `tests/test_slots.luau`**

```lua
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
local border = Slots.filter({ ["animation.enabled"] = true, ["effects.border"] = "g" }, "effects.border")
check.eq(border["animation.enabled"], nil, "no master switch for effect slots")
check.eq(border["effects.border"], "g", "effect selector kept")
check.done("slots")
```

- [ ] **Step 6: Run it and confirm it fails**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: error mentioning `../lib/slots` cannot be found; final line `1 test file(s) failed`.

- [ ] **Step 7: Write `umbriel-shaders/lib/slots.luau`**

```lua
-- SPDX-License-Identifier: MIT
-- The Umbriel destinations a shader can be assigned to, in display order.
local M = {}

M.list = {
  "effects.cursor",
  "effects.border",
  "effects.window",
  "effects.screen",
  "animation.windows_in",
  "animation.windows_out",
  "animation.windows_move",
  "animation.workspaces",
  "animation.overview",
  "animation.scratchpad",
  "animation.layers",
  "animation.border",
  "animation.dim_unfocused",
}

-- Slots that can also be set per application, and their [[window_rule]] key.
M.appSlots = { ["effects.border"] = "border_effect", ["effects.window"] = "window_effect" }

function M.isAnimation(slot)
  return slot:sub(1, 10) == "animation."
end

function M.kind(slot)
  if M.isAnimation(slot) then
    return "animation"
  end
  return (slot:gsub("^effects%.", ""))
end

function M.key(slot)
  return (slot:gsub("%.", "_"))
end

-- Settings that turn `preset` on in `slot`.
function M.selector(slot, preset)
  if M.isAnimation(slot) then
    return {
      ["animation.enabled"] = true,
      [slot .. ".enabled"] = true,
      [slot .. ".effect"] = preset,
    }
  end
  return { [slot] = preset }
end

-- Only the settings that belong to `slot` (plus the animation master switch).
function M.filter(settings, slot)
  local out = {}
  local prefix = slot .. "."
  for key, value in pairs(settings) do
    if
      key == slot
      or key:sub(1, #prefix) == prefix
      or (key == "animation.enabled" and M.isAnimation(slot))
    then
      out[key] = value
    end
  end
  return out
end

return M
```

- [ ] **Step 8: Run the tests and confirm they pass**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `PASS slots (17 checks)` and exit code 0.

- [ ] **Step 9: Replace `umbriel-shaders/plugin.toml`**

```toml
id = "barrulus/umbriel-shaders"
name = "Umbriel Shaders"
version = "0.7.0"
plugin_api = 43
author = "Barrulus"
license = "MIT"
icon = "sparkles"
description = "Browse community shaders and apply them to Umbriel effect and animation slots."
dependencies = ["umbriel"]
tags = ["umbriel", "theming", "panel", "utility"]

[[panel]]
id = "shaders"
entry = "panel.luau"
width = 640
height = 740
placement = "floating"

[[shortcut]]
id = "open"
entry = "shortcut.luau"

[[widget]]
id = "shaders-bar"
entry = "widget.luau"
```

- [ ] **Step 10: Replace `umbriel-shaders/panel.luau` with a placeholder (Task 7 replaces it)**

```lua
-- SPDX-License-Identifier: MIT
function onOpen()
  panel.render(ui.label({ text = noctalia.tr("title") }))
end
```

- [ ] **Step 11: Replace `umbriel-shaders/translations/en.json` with the complete string table**

```json
{
  "title": "Umbriel Shaders",
  "tabs": { "slots": "Slots", "browse": "Browse", "families": "Families" },
  "header": { "undo": "Undo", "clear_all": "Clear all", "refresh": "Refresh catalogue", "close": "Close" },
  "slot": {
    "effects_cursor": "Cursor",
    "effects_border": "Border",
    "effects_window": "Window",
    "effects_screen": "Screen",
    "animation_windows_in": "Window open",
    "animation_windows_out": "Window close",
    "animation_windows_move": "Window move",
    "animation_workspaces": "Workspace switch",
    "animation_overview": "Overview",
    "animation_scratchpad": "Scratchpad",
    "animation_layers": "Layer surfaces",
    "animation_border": "Border animation",
    "animation_dim_unfocused": "Unfocused dimming"
  },
  "status": {
    "working": "Working…",
    "applied": "Applied.",
    "failed": "Not applied: {error}",
    "cleared": "All shaders cleared.",
    "undone": "Last change undone.",
    "family_applied": "Applied the {name} family.",
    "timing_saved": "Timing saved.",
    "imported": "Imported {name}. Apply it from its card in Browse.",
    "import_removed": "Import removed."
  },
  "setup": {
    "text": "Umbriel does not load this plugin's shaders yet. Add this include to {path}:",
    "add": "Add for me",
    "copy": "Copy snippet",
    "copied": "Snippet copied.",
    "check": "Check again",
    "done": "Include added. Your previous file is saved as config.toml.bak.",
    "failed": "Could not add the include: {error}"
  },
  "banner": {
    "no_umbriel": "The umbriel command was not found on PATH.",
    "offline": "Offline: showing the saved catalogue.",
    "loading": "Loading catalogue…",
    "catalogue_failed": "The catalogue could not be loaded. Use Refresh to retry.",
    "catalogue_error": "Catalogue unavailable: {error}"
  },
  "slots": { "none": "None", "change": "Change", "clear": "Clear", "details": "Details", "hide": "Hide" },
  "browse": {
    "search": "Search shaders",
    "all_slots": "All slots",
    "apply": "Apply",
    "by": "by {author}",
    "imported": "Imported",
    "picking": "Choose a shader for {slot}.",
    "picking_app": "Choose a {slot} shader for {app}.",
    "cancel": "Cancel",
    "previous": "Previous",
    "next": "Next",
    "page": "{page} / {pages}",
    "empty": "No shaders match."
  },
  "families": { "apply": "Apply family", "empty": "No families in the catalogue." },
  "timing": {
    "duration": "Duration (ms)",
    "duration_own": "{value} ms (shader default)",
    "curve": "Curve",
    "curve_own": "{value} (shader default)",
    "apply": "Save timing",
    "hint": "Leave empty to use the shader's own timing. Spring curves ignore the duration."
  },
  "apps": {
    "title": "Application rules",
    "add": "Add an open application…",
    "off": "No effect",
    "remove": "Remove",
    "loading": "Reading open windows…",
    "hint": "Window rules in your own config.toml take precedence."
  },
  "import": {
    "open": "Import GLSL",
    "title": "Import a GLSL file",
    "path": "Path to a .glsl file",
    "name": "Name (optional)",
    "hint": "The file must define the entry point for its slot: cursor(), border(), window(), screen() or animation().",
    "save": "Import",
    "failed": "Import failed: {error}",
    "remove": "Remove"
  },
  "error": {
    "duration": "Duration must be a whole number of milliseconds.",
    "download": "Download failed: {file}"
  }
}
```

- [ ] **Step 12: Format, lint and commit**

Run: `stylua umbriel-shaders tests && stylua --check umbriel-shaders tests && noctalia plugins lint umbriel-shaders`
Expected: no output from stylua check; lint reports zero errors.

```bash
git add -A shell.nix tests umbriel-shaders
git commit -m "Remove the 0.6 implementation and scaffold the simplified plugin"
```

---

### Task 2: Render the generated TOML file

**Files:**
- Create: `umbriel-shaders/lib/config.luau`
- Test: `tests/test_config.luau`

**Interfaces:**
- Consumes: `Slots.list`, `Slots.appSlots`, `Slots.isAnimation` (Task 1)
- Produces in `lib/config.luau`:
  - `Config.fileName = "noctalia-shaders.toml"`
  - `Config.snippet: string` — `[include.optional]\nfiles = ["noctalia-shaders.toml"]`
  - `Config.paths() -> { config = string, generated = string, shaders = string }`
  - `Config.string(s) -> string` (TOML basic string), `Config.value(v) -> string`
  - `Config.render(selection) -> string`
- A **selection entry** (produced by Task 4, consumed here) is `{ id, name, preset, include = {absPath}, deps = {effectId}, settings = {[dottedKey]=value}, revision?, files? = {repoPath} }`. A **selection** is `{ slots = {[slot]=entry}, apps = {{app_id, slot, entry?}}, timing = {[slot]={duration_ms?, curve?}}, imports = {...}, previous? }`.

- [ ] **Step 1: Write the failing test `tests/test_config.luau`**

```lua
-- SPDX-License-Identifier: MIT
local check = require("./check")
local Config = require("../lib/config")

check.eq(Config.value('a"b\\c\n'), '"a\\"b\\\\c\\n"', "string escaping")
check.eq(Config.value("\1"), '"\\u0001"', "control characters")
check.eq(Config.value(true), "true", "boolean")
check.eq(Config.value(1050), "1050", "integer")
check.eq(Config.value(0.2), "0.2", "float")

local HEADER = "# Generated by the Umbriel Shaders Noctalia plugin. Changes are overwritten."
local empty = { slots = {}, apps = {}, timing = {}, imports = {} }
check.eq(Config.render(empty), HEADER .. "\n", "empty selection renders only the header")

local glow = {
  id = "border/glow",
  name = "Glow",
  preset = "glow",
  deps = { "window/glow-overlay" },
  include = { "/s/r1/border/glow/effect.toml" },
  settings = { ["effects.border"] = "glow" },
}
local overlay = {
  id = "window/glow-overlay",
  name = "Overlay",
  preset = "glow-overlay",
  deps = {},
  include = { "/s/r1/window/glow-overlay/effect.toml" },
  settings = { ["effects.window"] = "glow-overlay" },
}
local fade = {
  id = "animation/fade",
  name = "Fade",
  preset = "fade",
  deps = {},
  include = { "/s/r1/animation/fade/effect.toml" },
  settings = {
    ["animation.enabled"] = true,
    ["animation.windows_in.effect"] = "fade",
    ["animation.windows_in.enabled"] = true,
    ["animation.windows_in.duration_ms"] = 300,
  },
}
local selection = {
  slots = { ["effects.border"] = glow, ["effects.window"] = overlay, ["animation.windows_in"] = fade },
  apps = {
    { app_id = "org.gnome.Nautilus", slot = "effects.border", entry = glow },
    { app_id = "mpv", slot = "effects.window" },
  },
  timing = {
    ["animation.windows_in"] = { duration_ms = 450, curve = "linear" },
    ["animation.workspaces"] = { duration_ms = 1 },
  },
  imports = {},
}
local expected = table.concat({
  HEADER,
  "",
  "[include]",
  "files = [",
  '  "/s/r1/animation/fade/effect.toml",',
  '  "/s/r1/border/glow/effect.toml",',
  "]",
  "",
  "[animation]",
  "enabled = true",
  "",
  "[animation.windows_in]",
  'curve = "linear"',
  "duration_ms = 450",
  'effect = "fade"',
  "enabled = true",
  "",
  "[effects]",
  'border = "glow"',
  'window = "glow-overlay"',
  "",
  "[[window_rule]]",
  'match.app_id = "^org\\\\.gnome\\\\.Nautilus$"',
  'border_effect = "glow"',
  "",
  "[[window_rule]]",
  'match.app_id = "^mpv$"',
  'window_effect = "off"',
  "",
}, "\n")
check.eq(
  Config.render(selection),
  expected,
  "companion include skipped, includes sorted, timing overrides applied, unset-slot timing ignored"
)
check.done("config render")
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `test_config.luau` fails because `../lib/config` is missing; `PASS slots` still printed.

- [ ] **Step 3: Write `umbriel-shaders/lib/config.luau`**

```lua
-- SPDX-License-Identifier: MIT
-- The generated Umbriel include file and the user's include of it.
local Slots = require("./slots.luau")

local M = {}

M.fileName = "noctalia-shaders.toml"
M.snippet = '[include.optional]\nfiles = ["' .. M.fileName .. '"]'
local HEADER = "# Generated by the Umbriel Shaders Noctalia plugin. Changes are overwritten."

function M.paths()
  local base = noctalia.getenv("XDG_CONFIG_HOME")
  if not base or base == "" then
    base = noctalia.expandPath("~/.config")
  end
  local dir = base .. "/umbriel"
  return {
    config = dir .. "/config.toml",
    generated = dir .. "/" .. M.fileName,
    shaders = dir .. "/noctalia-shaders",
  }
end

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }

function M.string(s)
  local escaped = s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04X", c:byte())
  end)
  return '"' .. escaped .. '"'
end

function M.value(v)
  local t = type(v)
  if t == "string" then
    return M.string(v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "number" then
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return string.format("%d", v)
    end
    return tostring(v)
  end
  error("unsupported TOML value type: " .. t)
end

-- Escape regex metacharacters so an app ID matches literally.
local function literal(s)
  return (s:gsub("[%.%^%$%*%+%?%(%)%[%]{}|\\]", "\\%0"))
end

local function sortedKeys(t)
  local keys = {}
  for key in pairs(t) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

function M.render(sel)
  local entries = {}
  for _, slot in ipairs(Slots.list) do
    if sel.slots[slot] then
      table.insert(entries, sel.slots[slot])
    end
  end
  for _, rule in ipairs(sel.apps) do
    if rule.entry then
      table.insert(entries, rule.entry)
    end
  end

  -- A selected parent's effect.toml already includes its companions; including
  -- them again is an Umbriel warning ("include cycle or duplicate skipped").
  local companion = {}
  for _, entry in ipairs(entries) do
    for _, dep in ipairs(entry.deps or {}) do
      companion[dep] = true
    end
  end
  local includeSet = {}
  for _, entry in ipairs(entries) do
    if not companion[entry.id] then
      for _, path in ipairs(entry.include) do
        includeSet[path] = true
      end
    end
  end

  local settings = {}
  for _, slot in ipairs(Slots.list) do
    local entry = sel.slots[slot]
    if entry then
      for key, value in pairs(entry.settings) do
        settings[key] = value
      end
      local timing = sel.timing[slot]
      if timing and Slots.isAnimation(slot) then
        if timing.duration_ms then
          settings[slot .. ".duration_ms"] = timing.duration_ms
        end
        if timing.curve then
          settings[slot .. ".curve"] = timing.curve
        end
      end
    end
  end
  local tables = {}
  for key, value in pairs(settings) do
    local name, leaf = key:match("^(.*)%.([^.]+)$")
    tables[name] = tables[name] or {}
    tables[name][leaf] = value
  end

  local out = { HEADER }
  local includes = sortedKeys(includeSet)
  if #includes > 0 then
    table.insert(out, "")
    table.insert(out, "[include]")
    table.insert(out, "files = [")
    for _, path in ipairs(includes) do
      table.insert(out, "  " .. M.string(path) .. ",")
    end
    table.insert(out, "]")
  end
  for _, name in ipairs(sortedKeys(tables)) do
    table.insert(out, "")
    table.insert(out, "[" .. name .. "]")
    for _, leaf in ipairs(sortedKeys(tables[name])) do
      table.insert(out, leaf .. " = " .. M.value(tables[name][leaf]))
    end
  end
  for _, rule in ipairs(sel.apps) do
    table.insert(out, "")
    table.insert(out, "[[window_rule]]")
    table.insert(out, "match.app_id = " .. M.string("^" .. literal(rule.app_id) .. "$"))
    local preset = rule.entry and rule.entry.preset or "off"
    table.insert(out, Slots.appSlots[rule.slot] .. " = " .. M.string(preset))
  end
  return table.concat(out, "\n") .. "\n"
end

return M
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `PASS config render (7 checks)` and `PASS slots (17 checks)`, exit 0.

- [ ] **Step 5: Format and commit**

```bash
stylua umbriel-shaders tests
git add umbriel-shaders/lib/config.luau tests/test_config.luau
git commit -m "Render the generated Umbriel include file"
```

---

### Task 3: Include setup and validation diffing

**Files:**
- Modify: `umbriel-shaders/lib/config.luau` (add functions before `return M`)
- Test: `tests/test_setup.luau`

**Interfaces:**
- Consumes: `Config.fileName`, `Config.string`, `Config.paths()` (Task 2)
- Produces:
  - `Config.addInclude(text) -> string | nil` — `text` with our file added to `[include.optional].files`, or `nil` when the layout needs a manual edit
  - `Config.includeState(text | nil) -> "present" | "insert" | "manual"`
  - `Config.introduced(beforeReport, afterReport) -> {string}` — diagnostics in `after` not in `before`, keyed by `file|message` (line numbers ignored)
  - `Config.validate(configPath, cb)` — `cb(report)` or `cb(nil, errorText)`; report is the decoded `umbriel config validate --json` output
  - `Config.setup(paths, cb)` — `cb(true)` or `cb(false, message)`; writes `config.toml.bak`, inserts the include, reverts if new diagnostics appear

- [ ] **Step 1: Write the failing test `tests/test_setup.luau`**

```lua
-- SPDX-License-Identifier: MIT
local check = require("./check")
local Config = require("../lib/config")

local LINE = 'files = ["noctalia-shaders.toml"]'
check.eq(Config.includeState(nil), "manual", "missing config file")
check.eq(Config.includeState("[include.optional]\n" .. LINE .. "\n"), "present", "already present")
check.eq(Config.includeState("[general]\n"), "insert", "can insert")
check.eq(Config.includeState("[include]\noptional = { files = [] }\n"), "manual", "inline table")

check.eq(
  Config.addInclude("[general]\nx = 1\n"),
  "[general]\nx = 1\n\n[include.optional]\n" .. LINE .. "\n",
  "append a new table"
)
check.eq(
  Config.addInclude("[general]\nx = 1"),
  "[general]\nx = 1\n\n[include.optional]\n" .. LINE .. "\n",
  "append when the file lacks a trailing newline"
)
check.eq(
  Config.addInclude('[include.optional]\nfiles = [\n    "scratch.toml",\n]\n'),
  '[include.optional]\nfiles = ["noctalia-shaders.toml", \n    "scratch.toml",\n]\n',
  "insert into a multi-line array"
)
check.eq(
  Config.addInclude("[include.optional] # extras\nfiles = []\n[general]\n"),
  '[include.optional] # extras\nfiles = ["noctalia-shaders.toml", ]\n[general]\n',
  "insert into an empty array"
)
check.eq(
  Config.addInclude("[include.optional]\nnote = 1\n[general]\n"),
  "[include.optional]\n" .. LINE .. "\nnote = 1\n[general]\n",
  "add a files key to an existing table"
)
check.eq(
  Config.addInclude("[include.optional]\n[general]\nfiles = []\n"),
  "[include.optional]\n" .. LINE .. "\n[general]\nfiles = []\n",
  "files in a later table is not ours"
)
check.eq(Config.addInclude("[include]\noptional = { files = [] }\n"), nil, "inline table")
check.eq(Config.addInclude("include.optional.files = []\n"), nil, "dotted key")

local before = { diagnostics = { { file = "/c.toml", line = 4, message = "unknown key a" } } }
local after = {
  diagnostics = {
    { file = "/c.toml", line = 5, message = "unknown key a" },
    { file = "/g.toml", line = 2, message = "ignoring effects.screen" },
    { message = "include cycle or duplicate skipped: /x" },
  },
}
local new = Config.introduced(before, after)
check.eq(#new, 2, "a shifted line is not a new diagnostic")
check.eq(new[1], "/g.toml:2: ignoring effects.screen", "file and line prefix")
check.eq(new[2], "include cycle or duplicate skipped: /x", "diagnostic without a file")
check.done("setup")
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `test_setup.luau` fails with `attempt to call a nil value (field 'includeState')`.

- [ ] **Step 3: Add to `umbriel-shaders/lib/config.luau`, immediately before `return M`**

```lua
-- `text` with our file added to [include.optional].files, or nil when the
-- table is written in a form we do not edit (inline table, dotted keys).
function M.addInclude(text)
  local lines = text:split("\n")
  local entry = M.string(M.fileName)
  local section, header = nil, nil
  for i, line in ipairs(lines) do
    local code = line:match("^([^#]*)"):match("^%s*(.-)%s*$")
    if code:match("^%[%[") then
      section = "array"
    elseif code:match("^%[") then
      section = code:match("^%[%s*(.-)%s*%]$")
      if section == "include.optional" then
        header = i
      end
    elseif
      (section == "include" and code:match("^optional%s*="))
      or code:match("^include%.optional")
    then
      return nil
    end
  end
  if not header then
    local separator = text:sub(-1) == "\n" and "" or "\n"
    return text .. separator .. "\n[include.optional]\nfiles = [" .. entry .. "]\n"
  end
  for i = header + 1, #lines do
    local code = lines[i]:match("^([^#]*)")
    if code:match("^%s*%[") then
      break
    end
    local prefix = code:match("^(%s*files%s*=%s*%[)")
    if prefix then
      lines[i] = prefix .. entry .. ", " .. lines[i]:sub(#prefix + 1)
      return table.concat(lines, "\n")
    end
  end
  table.insert(lines, header + 1, "files = [" .. entry .. "]")
  return table.concat(lines, "\n")
end

function M.includeState(text)
  if type(text) ~= "string" then
    return "manual"
  end
  if text:find(M.fileName, 1, true) then
    return "present"
  end
  return M.addInclude(text) and "insert" or "manual"
end

local function diagnosticKey(d)
  return (d.file or "") .. "|" .. tostring(d.message)
end

-- Diagnostics present in `after` but not `before`. Line numbers are ignored so
-- that inserting a line into config.toml does not make old warnings look new.
function M.introduced(before, after)
  local known = {}
  for _, d in ipairs(before.diagnostics) do
    known[diagnosticKey(d)] = true
  end
  local out = {}
  for _, d in ipairs(after.diagnostics) do
    if not known[diagnosticKey(d)] then
      local where = d.file and (d.file .. ":" .. tostring(d.line or "?") .. ": ") or ""
      table.insert(out, where .. tostring(d.message))
    end
  end
  return out
end

function M.validate(configPath, cb)
  local argv = { "umbriel", "config", "validate", "-c", configPath, "--json" }
  local started = noctalia.runAsync(argv, function(result)
    local report = noctalia.json.decode(result.stdout or "")
    if type(report) ~= "table" or type(report.diagnostics) ~= "table" then
      local stderr = result.stderr or ""
      cb(nil, stderr ~= "" and stderr or "umbriel config validate failed")
      return
    end
    cb(report)
  end)
  if not started then
    cb(nil, "could not run umbriel")
  end
end

-- Insert our include into the user's config, keeping config.toml.bak, and put
-- the original back if Umbriel reports anything new.
function M.setup(paths, cb)
  local text = noctalia.readFile(paths.config)
  local updated = type(text) == "string" and M.addInclude(text) or nil
  if not updated then
    cb(false, "add the snippet to " .. paths.config .. " by hand")
    return
  end
  M.validate(paths.config, function(before, err)
    if not before then
      cb(false, err)
      return
    end
    local ok, writeErr = noctalia.writeFile(paths.config .. ".bak", text)
    if ok then
      ok, writeErr = noctalia.writeFile(paths.config, updated)
    end
    if not ok then
      cb(false, writeErr)
      return
    end
    M.validate(paths.config, function(after, err2)
      local problems = after and M.introduced(before, after) or { err2 }
      if #problems > 0 then
        noctalia.writeFile(paths.config, text)
        cb(false, table.concat(problems, "\n"))
        return
      end
      cb(true)
    end)
  end)
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `PASS setup (15 checks)` plus the earlier passes; exit 0.

- [ ] **Step 5: Confirm Umbriel accepts the inserted forms**

The unit tests prove the text transformation; this proves Umbriel parses both inserted
shapes (`["x", ]` in a single-line array and `["x", ` opening a multi-line array):

```bash
t=$(mktemp -d)
printf '# Generated\n' > "$t/noctalia-shaders.toml"
printf '# other\n' > "$t/other.toml"
printf '[include.optional]\nfiles = ["noctalia-shaders.toml", ]\n' > "$t/a.toml"
printf '[include.optional]\nfiles = ["noctalia-shaders.toml", \n    "other.toml",\n]\n' > "$t/b.toml"
umbriel config validate -c "$t/a.toml"; echo "a exit=$?"
umbriel config validate -c "$t/b.toml"; echo "b exit=$?"; rm -r "$t"
```

Expected: `Config: ok (...)` twice, `a exit=0`, `b exit=0` (verified 2026-11-20).

- [ ] **Step 6: Format and commit**

```bash
stylua umbriel-shaders tests
git add umbriel-shaders/lib/config.luau tests/test_setup.luau
git commit -m "Add include setup and validation diffing"
```

---

### Task 4: Catalogue indexing, search and resolution

**Files:**
- Create: `umbriel-shaders/lib/catalogue.luau`
- Test: `tests/fixture.luau`, `tests/test_catalogue.luau`

**Interfaces:**
- Consumes: `Slots.list`, `Slots.filter`, `Slots.selector` (Task 1)
- Produces in `lib/catalogue.luau`:
  - `Catalogue.url: string`, `Catalogue.maxAgeSeconds = 86400`
  - `Catalogue.index(data) -> cat | nil, err` where `cat = { revision, effects = {effect} (role "effect", sorted by name), byId, byPreset, families = {family} (sorted by name) }`
  - `Catalogue.search(effects, query, slot?) -> {effect}`
  - `Catalogue.resolve(cat | nil, effect, slot, shadersDir) -> entry` (selection entry; see Task 2)
  - `Catalogue.familySlots(cat, family) -> {[slot]: effect}`
  - `Catalogue.readCache(dataDir) -> cat | nil`, `Catalogue.isStale(dataDir) -> boolean`, `Catalogue.fetch(dataDir, cb)` with `cb(cat)` or `cb(nil, err)`
- An **imported effect** (Task 6) has `imported = true`, `preset`, `uses = {slot}`, `include = {absPath}` and no `install_files`.

- [ ] **Step 1: Write `tests/fixture.luau`** (a trimmed catalogue in the published shape)

```lua
-- SPDX-License-Identifier: MIT
-- A trimmed catalogue.json in the published schema, already decoded.
return {
  schema_version = 1,
  source = { repository = "https://example.invalid/shaders", revision = "abc123" },
  effects = {
    {
      id = "border/glow",
      name = "Glow",
      description = "Soft ring",
      author = "A",
      tags = { "glow" },
      role = "effect",
      kind = "border",
      preset = "glow",
      uses = { "effects.border" },
      dependencies = { "window/glow-overlay" },
      install_files = { "LICENSES/A.txt", "border/glow/effect.toml", "border/glow/shader.glsl" },
      preview = { image = "border/glow/preview.png" },
      activation = { include = { "border/glow/effect.toml" }, settings = { ["effects.border"] = "glow" } },
    },
    {
      id = "window/glow-overlay",
      name = "Glow overlay",
      role = "companion",
      kind = "window",
      preset = "glow-overlay",
      uses = {},
      dependencies = {},
      install_files = { "LICENSES/A.txt", "window/glow-overlay/effect.toml", "window/glow-overlay/shader.glsl" },
      preview = {},
    },
    {
      id = "animation/fade",
      name = "Fade",
      description = "Fades windows",
      author = "B",
      tags = {},
      role = "effect",
      kind = "animation",
      preset = "fade",
      uses = { "animation.windows_in", "animation.windows_out" },
      dependencies = {},
      install_files = { "animation/fade/effect.toml", "animation/fade/shader.glsl" },
      preview = { image = "animation/fade/preview.png" },
      activation = {
        include = { "animation/fade/effect.toml" },
        settings = {
          ["animation.enabled"] = true,
          ["animation.windows_in.effect"] = "fade",
          ["animation.windows_in.enabled"] = true,
          ["animation.windows_in.duration_ms"] = 300,
          ["animation.windows_out.effect"] = "fade",
          ["animation.windows_out.enabled"] = true,
          ["animation.windows_out.duration_ms"] = 200,
        },
      },
    },
    {
      id = "cursor/evil",
      name = "Evil",
      role = "effect",
      kind = "cursor",
      preset = "evil",
      uses = { "effects.cursor" },
      dependencies = {},
      install_files = { "../../etc/passwd" },
      preview = {},
      activation = { include = { "cursor/evil/effect.toml" }, settings = { ["effects.cursor"] = "evil" } },
    },
  },
  families = {
    {
      id = "fam",
      name = "Fam",
      description = "Both",
      members = { "border/glow", "animation/fade" },
      activation = {
        include = {},
        settings = {
          ["animation.enabled"] = true,
          ["animation.windows_in.effect"] = "fade",
          ["animation.windows_in.duration_ms"] = 300,
          ["effects.border"] = "glow",
        },
      },
    },
  },
}
```

- [ ] **Step 2: Write the failing test `tests/test_catalogue.luau`**

```lua
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
check.eq(#Catalogue.search(cat.effects, "glow", "animation.windows_in"), 0, "query and slot combine")

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
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `test_catalogue.luau` fails because `../lib/catalogue` is missing.

- [ ] **Step 4: Write `umbriel-shaders/lib/catalogue.luau`**

```lua
-- SPDX-License-Identifier: MIT
-- The published community catalogue: fetch, cache, index, search, resolve.
local Slots = require("./slots.luau")

local M = {}

M.url = "https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/catalogue/catalogue.json"
M.maxAgeSeconds = 24 * 60 * 60

local function safe(path)
  return type(path) == "string"
    and path ~= ""
    and path:sub(1, 1) ~= "/"
    and not path:find("..", 1, true)
end

local function allSafe(paths)
  for _, path in ipairs(paths or {}) do
    if not safe(path) then
      return false
    end
  end
  return true
end

local function byName(a, b)
  return a.name:lower() < b.name:lower()
end

function M.index(data)
  if type(data) ~= "table" or data.schema_version ~= 1 or type(data.effects) ~= "table" then
    return nil, "unsupported catalogue"
  end
  local revision = type(data.source) == "table" and data.source.revision
  if type(revision) ~= "string" or not revision:match("^%x+$") then
    return nil, "unsupported catalogue revision"
  end
  local cat = { revision = revision, effects = {}, byId = {}, byPreset = {}, families = {} }
  for _, effect in ipairs(data.effects) do
    local image = type(effect.preview) == "table" and effect.preview.image or nil
    local usable = allSafe(effect.install_files)
      and allSafe(effect.activation and effect.activation.include)
      and (image == nil or safe(image))
    if usable then
      cat.byId[effect.id] = effect
      cat.byPreset[effect.preset] = effect
      if effect.role == "effect" and effect.activation then
        table.insert(cat.effects, effect)
      end
    end
  end
  table.sort(cat.effects, byName)
  for _, family in ipairs(data.families or {}) do
    if family.activation then
      table.insert(cat.families, family)
    end
  end
  table.sort(cat.families, byName)
  return cat
end

function M.search(effects, query, slot)
  local needle = (query or ""):lower()
  local out = {}
  for _, effect in ipairs(effects) do
    if slot == nil or table.find(effect.uses or {}, slot) then
      local haystack = table.concat({
        effect.name,
        effect.description or "",
        effect.author or "",
        table.concat(effect.tags or {}, " "),
      }, " "):lower()
      if needle == "" or haystack:find(needle, 1, true) then
        table.insert(out, effect)
      end
    end
  end
  return out
end

-- A self-contained selection entry: everything needed to render, download and
-- undo without the catalogue.
function M.resolve(cat, effect, slot, shadersDir)
  if effect.imported then
    return {
      id = effect.id,
      name = effect.name,
      preset = effect.preset,
      include = table.clone(effect.include),
      deps = {},
      files = {},
      settings = Slots.selector(slot, effect.preset),
    }
  end
  local files, seen, deps = {}, {}, {}
  local function addFiles(e)
    for _, path in ipairs(e.install_files or {}) do
      if not seen[path] then
        seen[path] = true
        table.insert(files, path)
      end
    end
  end
  addFiles(effect)
  for _, depId in ipairs(effect.dependencies or {}) do
    local dep = cat.byId[depId]
    if dep then
      addFiles(dep)
      table.insert(deps, depId)
    end
  end
  local base = shadersDir .. "/" .. cat.revision .. "/"
  local include = {}
  for _, path in ipairs(effect.activation.include) do
    table.insert(include, base .. path)
  end
  local settings = Slots.filter(effect.activation.settings, slot)
  for key, value in pairs(Slots.selector(slot, effect.preset)) do
    if settings[key] == nil then
      settings[key] = value
    end
  end
  return {
    id = effect.id,
    name = effect.name,
    preset = effect.preset,
    revision = cat.revision,
    files = files,
    include = include,
    deps = deps,
    settings = settings,
  }
end

-- The member effect a family selects for each slot, read from its activation.
function M.familySlots(cat, family)
  local out = {}
  for key, value in pairs(family.activation.settings) do
    local slot = key:match("^(effects%.[%w_]+)$") or key:match("^(animation%.[%w_]+)%.effect$")
    local effect = slot and type(value) == "string" and cat.byPreset[value]
    if effect and table.find(Slots.list, slot) then
      out[slot] = effect
    end
  end
  return out
end

local function cachePath(dataDir)
  return dataDir .. "/catalogue.json"
end

function M.readCache(dataDir)
  local raw = noctalia.readFile(cachePath(dataDir))
  if not raw then
    return nil
  end
  return (M.index(noctalia.json.decode(raw)))
end

function M.isStale(dataDir)
  local info = noctalia.fileInfo(cachePath(dataDir))
  return not info or os.time() - info.mtime > M.maxAgeSeconds
end

function M.fetch(dataDir, cb)
  local started = noctalia.http({ url = M.url }, function(response)
    if not response.ok or response.status ~= 200 then
      cb(nil, "HTTP " .. tostring(response.status))
      return
    end
    local cat, err = M.index(noctalia.json.decode(response.body))
    if not cat then
      cb(nil, err)
      return
    end
    noctalia.writeFile(cachePath(dataDir), response.body)
    cb(cat)
  end)
  if not started then
    cb(nil, "request not started")
  end
end

return M
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `PASS catalogue (31 checks)` plus earlier passes; exit 0.

- [ ] **Step 6: Format and commit**

```bash
stylua umbriel-shaders tests
git add umbriel-shaders/lib/catalogue.luau tests/fixture.luau tests/test_catalogue.luau
git commit -m "Index, search and resolve the community catalogue"
```

---

### Task 5: Selection state, undo and timing parsing

**Files:**
- Create: `umbriel-shaders/lib/selection.luau`
- Test: `tests/test_selection.luau`

**Interfaces:**
- Produces in `lib/selection.luau`:
  - `Selection.empty() -> selection` (`version = 1`)
  - `Selection.load(path) -> selection`, `Selection.save(path, selection) -> ok, err`
  - `Selection.copy(value) -> deep copy`
  - `Selection.change(selection, fn(next)) -> next` — deep copy, records `previous = {slots, apps, timing}`, applies `fn`
  - `Selection.undo(selection) -> next | nil`
  - `Selection.clearAll(next)`, `Selection.setApp(next, appId, slot, entry?)`, `Selection.removeApp(next, appId, slot)`, `Selection.removeImport(next, id)`
  - `Selection.parseTiming(durationText, curveText) -> timing | nil, errorKey` where `errorKey = "error.duration"`

- [ ] **Step 1: Write the failing test `tests/test_selection.luau`**

```lua
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

local f = Selection.change(sel, function(n)
  n.imports = { { id = "import/x" } }
  n.slots["effects.cursor"] = { id = "import/x" }
  n.apps = { { app_id = "a", slot = "effects.window", entry = { id = "import/x" } } }
  Selection.removeImport(n, "import/x")
end)
check.eq(#f.imports, 0, "import removed")
check.eq(f.slots["effects.cursor"], nil, "slot using the import cleared")
check.eq(#f.apps, 0, "rule using the import removed")

local t = Selection.parseTiming(" 450 ", " linear ")
check.eq(t.duration_ms, 450, "duration parsed")
check.eq(t.curve, "linear", "curve trimmed")
check.eq(next(Selection.parseTiming("", "")), nil, "empty fields mean no override")
local bad, err = Selection.parseTiming("fast", "")
check.eq(bad, nil, "non-numeric duration rejected")
check.eq(err, "error.duration", "error key")
check.eq(Selection.parseTiming("12.5", ""), nil, "fractional duration rejected")
check.eq(Selection.parseTiming("-1", ""), nil, "negative duration rejected")
check.done("selection")
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `test_selection.luau` fails because `../lib/selection` is missing.

- [ ] **Step 3: Write `umbriel-shaders/lib/selection.luau`**

```lua
-- SPDX-License-Identifier: MIT
-- What the user has chosen. Changes are pure: each returns a new selection
-- that remembers the previous slots, apps and timing for one-level undo.
local M = {}

function M.empty()
  return { version = 1, slots = {}, apps = {}, timing = {}, imports = {} }
end

function M.copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = M.copy(item)
  end
  return out
end

function M.load(path)
  local raw = noctalia.readFile(path)
  local data = raw and noctalia.json.decode(raw)
  if type(data) ~= "table" or data.version ~= 1 then
    return M.empty()
  end
  for _, key in ipairs({ "slots", "apps", "timing", "imports" }) do
    if type(data[key]) ~= "table" then
      data[key] = {}
    end
  end
  return data
end

function M.save(path, sel)
  local temp = path .. ".tmp"
  local ok, err = noctalia.writeFile(temp, noctalia.json.encode(sel, true))
  if ok then
    ok, err = noctalia.renameFile(temp, path)
  end
  return ok, err
end

function M.change(sel, fn)
  local nxt = M.copy(sel)
  nxt.previous = { slots = M.copy(sel.slots), apps = M.copy(sel.apps), timing = M.copy(sel.timing) }
  fn(nxt)
  return nxt
end

function M.undo(sel)
  local previous = sel.previous
  if not previous then
    return nil
  end
  return M.change(sel, function(n)
    n.slots = M.copy(previous.slots or {})
    n.apps = M.copy(previous.apps or {})
    n.timing = M.copy(previous.timing or {})
  end)
end

function M.clearAll(n)
  n.slots, n.apps, n.timing = {}, {}, {}
end

-- `entry` nil means "No effect" for that application.
function M.setApp(n, appId, slot, entry)
  for _, rule in ipairs(n.apps) do
    if rule.app_id == appId and rule.slot == slot then
      rule.entry = entry
      return
    end
  end
  table.insert(n.apps, { app_id = appId, slot = slot, entry = entry })
end

function M.removeApp(n, appId, slot)
  for i, rule in ipairs(n.apps) do
    if rule.app_id == appId and rule.slot == slot then
      table.remove(n.apps, i)
      return
    end
  end
end

function M.removeImport(n, id)
  for i, effect in ipairs(n.imports) do
    if effect.id == id then
      table.remove(n.imports, i)
      break
    end
  end
  for slot, entry in pairs(n.slots) do
    if entry.id == id then
      n.slots[slot] = nil
    end
  end
  for i = #n.apps, 1, -1 do
    local entry = n.apps[i].entry
    if entry and entry.id == id then
      table.remove(n.apps, i)
    end
  end
end

local function trim(s)
  return (s or ""):match("^%s*(.-)%s*$")
end

-- Empty fields mean "use the shader's own value".
function M.parseTiming(durationText, curveText)
  local timing = {}
  local duration = trim(durationText)
  if duration ~= "" then
    local n = tonumber(duration)
    if not n or n ~= math.floor(n) or n < 0 or n > 60000 then
      return nil, "error.duration"
    end
    timing.duration_ms = n
  end
  local curve = trim(curveText)
  if curve ~= "" then
    timing.curve = curve
  end
  return timing
end

return M
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `PASS selection (21 checks)` plus earlier passes; exit 0.

- [ ] **Step 5: Format and commit**

```bash
stylua umbriel-shaders tests
git add umbriel-shaders/lib/selection.luau tests/test_selection.luau
git commit -m "Add selection state with one-level undo"
```

---

### Task 6: Downloads, GLSL import and the apply pipeline

**Files:**
- Create: `umbriel-shaders/lib/files.luau`, `umbriel-shaders/lib/apply.luau`
- Test: `tests/test_files.luau`

**Interfaces:**
- Consumes: `Slots.list`, `Slots.kind` (Task 1); `Config.paths/render/validate/introduced` (Tasks 2–3); `Selection.save` (Task 5)
- Produces in `lib/files.luau`:
  - `Files.raw = "https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/"`
  - `Files.jobsFor(entries, shadersDir, exists) -> {{url, dest}}` — `exists(path) -> boolean` is injected (pass `noctalia.fileExists`)
  - `Files.download(jobs, cb)` — up to 4 at once; `cb(nil)` on success or `cb(failedUrl)`
  - `Files.slug(name) -> string`
  - `Files.import(shadersDir, path, name, slot, taken) -> importedEffect | nil, err`
  - `Files.removeImport(importedEffect)`
- Produces in `lib/apply.luau`:
  - `Apply.commit(env, nextSelection, cb)` with `env = { paths = Config.paths(), selectionPath = string }`; `cb(true)` or `cb(false, message)`

- [ ] **Step 1: Write the failing test `tests/test_files.luau`**

```lua
-- SPDX-License-Identifier: MIT
local check = require("./check")
local Files = require("../lib/files")

check.eq(Files.slug("My Cool Shader!"), "my-cool-shader", "slug")
check.eq(Files.slug("  ---  "), "shader", "empty slug falls back")

local existing = { ["/s/r1/LICENSES/A.txt"] = true }
local jobs = Files.jobsFor({
  { revision = "r1", files = { "LICENSES/A.txt", "border/glow/effect.toml" } },
  { revision = "r1", files = { "border/glow/effect.toml", "window/o/effect.toml" } },
  { files = {}, include = { "/s/imports/x/effect.toml" } },
}, "/s", function(path)
  return existing[path] == true
end)
check.eq(#jobs, 2, "existing and duplicate files are skipped")
check.eq(jobs[1].dest, "/s/r1/border/glow/effect.toml", "destination keeps the repository layout")
check.eq(jobs[1].url, Files.raw .. "r1/border/glow/effect.toml", "commit-pinned URL")
check.eq(jobs[2].dest, "/s/r1/window/o/effect.toml", "second file")
check.done("files")
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `test_files.luau` fails because `../lib/files` is missing.

- [ ] **Step 3: Write `umbriel-shaders/lib/files.luau`**

```lua
-- SPDX-License-Identifier: MIT
-- Shader files on disk: commit-pinned downloads and the personal import library.
local Slots = require("./slots.luau")

local M = {}

M.raw = "https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/"
M.maxImportBytes = 256 * 1024
local CONCURRENCY = 4

local function dirname(path)
  return path:match("^(.*)/[^/]*$")
end

function M.jobsFor(entries, shadersDir, exists)
  local jobs, seen = {}, {}
  for _, entry in ipairs(entries) do
    for _, path in ipairs(entry.files or {}) do
      local dest = shadersDir .. "/" .. entry.revision .. "/" .. path
      if not seen[dest] and not exists(dest) then
        table.insert(jobs, { url = M.raw .. entry.revision .. "/" .. path, dest = dest })
      end
      seen[dest] = true
    end
  end
  return jobs
end

-- Download into `<dest>.part` and rename, so a file on disk is always complete.
function M.download(jobs, cb)
  local nextJob, active, failed, finished = 1, 0, nil, false
  local pump
  pump = function()
    while failed == nil and active < CONCURRENCY and nextJob <= #jobs do
      local job = jobs[nextJob]
      nextJob += 1
      local part = job.dest .. ".part"
      noctalia.mkdirAll(dirname(job.dest))
      active += 1
      local started = noctalia.download(job.url, part, function(ok)
        active -= 1
        if ok then
          ok = noctalia.renameFile(part, job.dest)
        end
        if not ok then
          noctalia.removeFile(part)
          failed = failed or job.url
        end
        pump()
      end)
      if not started then
        active -= 1
        failed = failed or job.url
      end
    end
    if not finished and active == 0 and (failed ~= nil or nextJob > #jobs) then
      finished = true
      cb(failed)
    end
  end
  pump()
end

function M.slug(name)
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return slug ~= "" and slug or "shader"
end

-- Copy a standalone GLSL file into the import library with a generated preset.
-- `taken` is a set of existing import ids.
function M.import(shadersDir, path, name, slot, taken)
  if not table.find(Slots.list, slot) then
    return nil, "unknown slot"
  end
  local fullPath = noctalia.expandPath((path or ""):match("^%s*(.-)%s*$"))
  local source, readErr = noctalia.readFile(fullPath)
  if not source then
    return nil, readErr or ("cannot read " .. fullPath)
  end
  if #source > M.maxImportBytes then
    return nil, "file is larger than 256 KiB"
  end
  local display = (name or ""):match("^%s*(.-)%s*$")
  if display == "" then
    display = (fullPath:match("([^/]+)$") or "shader"):gsub("%.glsl$", "")
  end
  local base = M.slug(display)
  local id, n = base, 1
  while taken["import/" .. id] do
    n += 1
    id = base .. "-" .. n
  end
  local dir = shadersDir .. "/imports/" .. id
  local preset = "import." .. id
  noctalia.mkdirAll(dir)
  local ok, err = noctalia.writeFile(dir .. "/shader.glsl", source)
  if ok then
    local toml = string.format(
      '[effects.preset."%s"]\nkind = "%s"\nshader = "shader.glsl"\n',
      preset,
      Slots.kind(slot)
    )
    ok, err = noctalia.writeFile(dir .. "/effect.toml", toml)
  end
  if not ok then
    return nil, err
  end
  return {
    id = "import/" .. id,
    name = display,
    description = fullPath,
    author = "",
    tags = { "imported" },
    uses = { slot },
    preset = preset,
    imported = true,
    include = { dir .. "/effect.toml" },
  }
end

function M.removeImport(effect)
  local dir = effect.include[1]:match("^(.*)/effect%.toml$")
  if dir then
    noctalia.removeFile(dir .. "/shader.glsl")
    noctalia.removeFile(dir .. "/effect.toml")
  end
end

return M
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `nix-shell --run "python3 tests/run.py"`
Expected: `PASS files (6 checks)` plus earlier passes; exit 0.

- [ ] **Step 5: Write `umbriel-shaders/lib/apply.luau`**

```lua
-- SPDX-License-Identifier: MIT
-- Make a selection live: download its files, rewrite the generated include,
-- and keep the change only if Umbriel reports no new diagnostics.
local Config = require("./config.luau")
local Files = require("./files.luau")
local Selection = require("./selection.luau")

local M = {}

local function entriesOf(sel)
  local entries = {}
  for _, entry in pairs(sel.slots) do
    table.insert(entries, entry)
  end
  for _, rule in ipairs(sel.apps) do
    if rule.entry then
      table.insert(entries, rule.entry)
    end
  end
  return entries
end

function M.commit(env, nxt, cb)
  local paths = env.paths
  local jobs = Files.jobsFor(entriesOf(nxt), paths.shaders, noctalia.fileExists)
  Files.download(jobs, function(failed)
    if failed then
      cb(false, noctalia.tr("error.download", { file = failed }))
      return
    end
    Config.validate(paths.config, function(before, err)
      if not before then
        cb(false, err)
        return
      end
      local previous = noctalia.readFile(paths.generated)
      local ok, writeErr = noctalia.writeFile(paths.generated, Config.render(nxt))
      if not ok then
        cb(false, writeErr)
        return
      end
      Config.validate(paths.config, function(after, err2)
        local problems = after and Config.introduced(before, after) or { err2 }
        if #problems > 0 then
          if previous then
            noctalia.writeFile(paths.generated, previous)
          else
            noctalia.removeFile(paths.generated)
          end
          cb(false, table.concat(problems, "\n"))
          return
        end
        cb(Selection.save(env.selectionPath, nxt))
      end)
    end)
  end)
end

return M
```

- [ ] **Step 6: Format, lint and commit**

Run: `stylua umbriel-shaders tests && nix-shell --run "python3 tests/run.py" && noctalia plugins lint umbriel-shaders`
Expected: all six test files PASS; lint has no errors.

```bash
git add umbriel-shaders/lib/files.luau umbriel-shaders/lib/apply.luau tests/test_files.luau
git commit -m "Add commit-pinned downloads, GLSL import and the apply pipeline"
```

---

### Task 7: Panel — header, setup, Slots, Browse and Families

**Files:**
- Replace: `umbriel-shaders/panel.luau`

**Interfaces:**
- Consumes every lib function above. No new exports (panel globals: `onOpen`).
- Defines locals later tasks edit: `slotsTab()` (Task 8 replaces), `browseFooter()` (Task 9 replaces), helpers `nodes`, `slotLabel`, `say`, `canApply`, `commit`, `commitSelection`, `pick`, `render`.

- [ ] **Step 1: Replace `umbriel-shaders/panel.luau`**

```lua
-- SPDX-License-Identifier: MIT
local Apply = require("./lib/apply.luau")
local Catalogue = require("./lib/catalogue.luau")
local Config = require("./lib/config.luau")
local Files = require("./lib/files.luau")
local Selection = require("./lib/selection.luau")
local Slots = require("./lib/slots.luau")

local PAGE_SIZE = 8
local tr = noctalia.tr

local dataDir = assert(noctalia.pluginDataDir())
local env = { paths = Config.paths(), selectionPath = dataDir .. "/selection.json" }
local hasUmbriel = noctalia.commandExists("umbriel")

local sel = Selection.load(env.selectionPath)
local cat = Catalogue.readCache(dataDir)
local catState = cat and "ok" or "loading" -- ok | loading | offline | error
local fetching = false
local setupState = "present" -- present | insert | manual
local busy = false
local message, messageIsError = nil, false
local tab = "slots" -- slots | browse | families
local query, slotFilter, page = "", nil, 1
local picking = nil -- { slot = string, app_id = string? } while choosing a shader
local previews = {} -- destination path -> "pending" | "ok" | "failed"

local render

-- Child list without holes: nil/false arguments are skipped.
local function nodes(...)
  local out = {}
  for i = 1, select("#", ...) do
    local node = select(i, ...)
    if node then
      table.insert(out, node)
    end
  end
  return out
end

local function slotLabel(slot)
  return tr("slot." .. Slots.key(slot))
end

local function say(text, isError)
  message, messageIsError = text, isError == true
end

local function canApply()
  return hasUmbriel and setupState == "present" and not busy
end

local function commitSelection(nxt, okText, onOk)
  if busy then
    return
  end
  busy = true
  say(tr("status.working"))
  render()
  Apply.commit(env, nxt, function(ok, err)
    busy = false
    if ok then
      sel = nxt
      say(okText or tr("status.applied"))
      if onOk then
        onOk()
      end
    else
      say(tr("status.failed", { error = tostring(err) }), true)
    end
    render()
  end)
end

local function commit(change, okText, onOk)
  commitSelection(Selection.change(sel, change), okText, onOk)
end

local function refreshSetup()
  setupState = Config.includeState(noctalia.readFile(env.paths.config))
end

local function runSetup()
  if busy then
    return
  end
  busy = true
  say(tr("status.working"))
  render()
  Config.setup(env.paths, function(ok, err)
    busy = false
    refreshSetup()
    if ok then
      say(tr("setup.done"))
    else
      say(tr("setup.failed", { error = tostring(err) }), true)
    end
    render()
  end)
end

local function fetchCatalogue()
  if fetching then
    return
  end
  fetching = true
  if not cat then
    catState = "loading"
  end
  Catalogue.fetch(dataDir, function(fresh, err)
    fetching = false
    if fresh then
      cat, catState = fresh, "ok"
    elseif cat then
      catState = "offline"
    else
      catState = "error"
      say(tr("banner.catalogue_error", { error = tostring(err) }), true)
    end
    render()
  end)
end

local function previewFor(effect)
  local image = cat and not effect.imported and effect.preview and effect.preview.image
  if not image then
    return nil
  end
  local dest = dataDir .. "/previews/" .. cat.revision .. "/" .. image
  if previews[dest] == nil then
    if noctalia.fileExists(dest) then
      previews[dest] = "ok"
    else
      previews[dest] = "pending"
      local synchronous = true
      local job = { url = Files.raw .. cat.revision .. "/" .. image, dest = dest }
      Files.download({ job }, function(failed)
        previews[dest] = failed and "failed" or "ok"
        if not synchronous then
          render()
        end
      end)
      synchronous = false
    end
  end
  return previews[dest] == "ok" and dest or nil
end

local function pick(slot, appId)
  picking = { slot = slot, app_id = appId }
  tab, query, page = "browse", "", 1
  render()
end

local function applyEffect(effect, slot)
  local target = picking
  if target then
    picking, tab, query = nil, "slots", ""
  end
  local entry = Catalogue.resolve(cat, effect, slot, env.paths.shaders)
  if target and target.app_id then
    commit(function(n)
      Selection.setApp(n, target.app_id, slot, entry)
    end)
  else
    commit(function(n)
      n.slots[slot] = entry
    end)
  end
end

local function removeImport(effect)
  commit(function(n)
    Selection.removeImport(n, effect.id)
  end, tr("status.import_removed"), function()
    Files.removeImport(effect)
  end)
end

local function applyFamily(family)
  local entries = {}
  for slot, effect in pairs(Catalogue.familySlots(cat, family)) do
    entries[slot] = Catalogue.resolve(cat, effect, slot, env.paths.shaders)
  end
  commit(function(n)
    for slot, entry in pairs(entries) do
      n.slots[slot] = entry
    end
  end, tr("status.family_applied", { name = family.name }))
end

local function card(key, children)
  return ui.column({ key = key, gap = 6, padding = 10, radius = 8, fill = "surface_variant/0.5" }, children)
end

local function hint(text)
  return ui.label({ text = text, fontSize = 11, color = "on_surface_variant" })
end

local function slotsTab()
  local out = {}
  for _, slot in ipairs(Slots.list) do
    local entry = sel.slots[slot]
    table.insert(
      out,
      card(slot, {
        ui.row(
          { gap = 8, align = "center" },
          nodes(
            ui.column({ gap = 2, flexGrow = 1 }, {
              ui.label({ text = slotLabel(slot), fontWeight = "bold" }),
              ui.label({
                text = entry and entry.name or tr("slots.none"),
                color = entry and "primary" or "on_surface_variant",
                fontSize = 12,
              }),
            }),
            ui.button({
              text = tr("slots.change"),
              controlSize = "sm",
              enabled = canApply(),
              onClick = function()
                pick(slot, nil)
              end,
            }),
            entry and ui.button({
              text = tr("slots.clear"),
              controlSize = "sm",
              variant = "ghost",
              enabled = canApply(),
              onClick = function()
                commit(function(n)
                  n.slots[slot] = nil
                  n.timing[slot] = nil
                end)
              end,
            })
          )
        ),
      })
    )
  end
  return out
end

local function allEffects()
  local list = table.clone(sel.imports)
  for _, effect in ipairs(cat and cat.effects or {}) do
    table.insert(list, effect)
  end
  return list
end

local function effectCard(effect)
  local buttons = {}
  for _, slot in ipairs(picking and { picking.slot } or effect.uses) do
    table.insert(
      buttons,
      ui.button({
        key = effect.id .. ":" .. slot,
        text = picking and tr("browse.apply") or slotLabel(slot),
        controlSize = "sm",
        variant = "secondary",
        enabled = canApply(),
        onClick = function()
          applyEffect(effect, slot)
        end,
      })
    )
  end
  if effect.imported and not picking then
    table.insert(
      buttons,
      ui.button({
        key = effect.id .. ":remove",
        text = tr("import.remove"),
        controlSize = "sm",
        variant = "ghost",
        enabled = canApply(),
        onClick = function()
          removeImport(effect)
        end,
      })
    )
  end
  local image = previewFor(effect)
  return ui.row({ key = effect.id, gap = 12, padding = 10, radius = 8, fill = "surface_variant/0.5" }, {
    image and ui.image({ path = image, width = 144, height = 81, radius = 6, fit = "cover" })
      or ui.box({ width = 144, height = 81, radius = 6, fill = "surface_variant" }),
    ui.column({ gap = 4, flexGrow = 1 }, {
      ui.label({ text = effect.name, fontWeight = "bold" }),
      ui.label({
        text = effect.imported and tr("browse.imported") or tr("browse.by", { author = effect.author or "" }),
        fontSize = 12,
        color = "on_surface_variant",
      }),
      ui.label({ text = effect.description or "", fontSize = 12, maxLines = 2 }),
      ui.row({ gap = 6 }, buttons),
    }),
  })
end

-- Extra nodes at the end of Browse (Task 9 adds the import form here).
local function browseFooter()
  return {}
end

local function browseTab()
  local out = {}
  if picking then
    local target = picking
    local text = target.app_id
        and tr("browse.picking_app", { app = target.app_id, slot = slotLabel(target.slot) })
      or tr("browse.picking", { slot = slotLabel(target.slot) })
    table.insert(
      out,
      ui.row(
        { gap = 8, align = "center" },
        nodes(
          ui.label({ text = text, flexGrow = 1 }),
          target.app_id and ui.button({
            text = tr("apps.off"),
            controlSize = "sm",
            enabled = canApply(),
            onClick = function()
              picking, tab, query = nil, "slots", ""
              commit(function(n)
                Selection.setApp(n, target.app_id, target.slot, nil)
              end)
            end,
          }),
          ui.button({
            text = tr("browse.cancel"),
            controlSize = "sm",
            variant = "ghost",
            onClick = function()
              picking, tab, query = nil, "slots", ""
              render()
            end,
          })
        )
      )
    )
  end
  local options = { tr("browse.all_slots") }
  for _, slot in ipairs(Slots.list) do
    table.insert(options, slotLabel(slot))
  end
  table.insert(
    out,
    ui.row(
      { gap = 8 },
      nodes(
        ui.input({
          key = "search:" .. (picking and (picking.slot .. (picking.app_id or "")) or "all"),
          value = query,
          placeholder = tr("browse.search"),
          controlSize = "sm",
          flexGrow = 1,
          onChange = function(value)
            query, page = value, 1
            render()
          end,
        }),
        not picking and ui.select({
          key = "slot-filter",
          options = options,
          selectedIndex = slotFilter and table.find(Slots.list, slotFilter) or 0,
          controlSize = "sm",
          width = 200,
          onChange = function(value)
            local index = tonumber(value) or 0
            slotFilter, page = index > 0 and Slots.list[index] or nil, 1
            render()
          end,
        })
      )
    )
  )
  local effects = allEffects()
  if #effects == 0 then
    local key = catState == "error" and "banner.catalogue_failed" or "banner.loading"
    table.insert(out, ui.label({ text = tr(key), color = "on_surface_variant" }))
  else
    local results = Catalogue.search(effects, query, picking and picking.slot or slotFilter)
    local pages = math.max(1, math.ceil(#results / PAGE_SIZE))
    page = math.clamp(page, 1, pages)
    if #results == 0 then
      table.insert(out, ui.label({ text = tr("browse.empty"), color = "on_surface_variant" }))
    end
    for i = (page - 1) * PAGE_SIZE + 1, math.min(page * PAGE_SIZE, #results) do
      table.insert(out, effectCard(results[i]))
    end
    if pages > 1 then
      table.insert(
        out,
        ui.row({ gap = 8, align = "center", justify = "center" }, {
          ui.button({
            text = tr("browse.previous"),
            controlSize = "sm",
            enabled = page > 1,
            onClick = function()
              page -= 1
              render()
            end,
          }),
          ui.label({ text = tr("browse.page", { page = tostring(page), pages = tostring(pages) }) }),
          ui.button({
            text = tr("browse.next"),
            controlSize = "sm",
            enabled = page < pages,
            onClick = function()
              page += 1
              render()
            end,
          }),
        })
      )
    end
  end
  for _, node in ipairs(browseFooter()) do
    table.insert(out, node)
  end
  return out
end

local function familiesTab()
  if not cat then
    return { ui.label({ text = tr("banner.loading"), color = "on_surface_variant" }) }
  end
  if #cat.families == 0 then
    return { ui.label({ text = tr("families.empty"), color = "on_surface_variant" }) }
  end
  local out = {}
  for _, family in ipairs(cat.families) do
    local members = {}
    for slot, effect in pairs(Catalogue.familySlots(cat, family)) do
      table.insert(members, slotLabel(slot) .. ": " .. effect.name)
    end
    table.sort(members)
    table.insert(
      out,
      card(family.id, {
        ui.label({ text = family.name, fontWeight = "bold" }),
        ui.label({ text = family.description or "", fontSize = 12, maxLines = 3 }),
        hint(table.concat(members, " · ")),
        ui.row({ justify = "end" }, {
          ui.button({
            text = tr("families.apply"),
            variant = "primary",
            controlSize = "sm",
            enabled = canApply(),
            onClick = function()
              applyFamily(family)
            end,
          }),
        }),
      })
    )
  end
  return out
end

local function banner(text, actions)
  return ui.column({ gap = 8, padding = 10, radius = 8, border = "primary", borderWidth = 1 }, {
    ui.label({ text = text }),
    ui.row({ gap = 6, justify = "end" }, actions),
  })
end

local function banners()
  local out = {}
  if not hasUmbriel then
    table.insert(out, banner(tr("banner.no_umbriel"), {}))
  end
  if setupState ~= "present" then
    local actions = {}
    if setupState == "insert" then
      table.insert(
        actions,
        ui.button({
          text = tr("setup.add"),
          variant = "primary",
          controlSize = "sm",
          enabled = not busy,
          onClick = runSetup,
        })
      )
    end
    table.insert(
      actions,
      ui.button({
        text = tr("setup.copy"),
        controlSize = "sm",
        onClick = function()
          noctalia.copyToClipboard(Config.snippet)
          say(tr("setup.copied"))
          render()
        end,
      })
    )
    table.insert(
      actions,
      ui.button({
        text = tr("setup.check"),
        controlSize = "sm",
        variant = "ghost",
        onClick = function()
          refreshSetup()
          render()
        end,
      })
    )
    table.insert(out, banner(tr("setup.text", { path = env.paths.config }) .. "\n\n" .. Config.snippet, actions))
  end
  if catState == "offline" then
    table.insert(out, banner(tr("banner.offline"), {}))
  end
  return out
end

local function header()
  return ui.row({ gap = 6, align = "center" }, {
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
    ui.button({
      text = tr("header.undo"),
      controlSize = "sm",
      variant = "ghost",
      enabled = canApply() and sel.previous ~= nil,
      onClick = function()
        local nxt = Selection.undo(sel)
        if nxt then
          commitSelection(nxt, tr("status.undone"))
        end
      end,
    }),
    ui.button({
      text = tr("header.clear_all"),
      controlSize = "sm",
      variant = "ghost",
      enabled = canApply(),
      onClick = function()
        commit(Selection.clearAll, tr("status.cleared"))
      end,
    }),
    ui.button({
      glyph = "refresh",
      tooltip = tr("header.refresh"),
      controlSize = "sm",
      variant = "ghost",
      enabled = not fetching,
      onClick = function()
        fetchCatalogue()
        render()
      end,
    }),
    ui.button({
      glyph = "x",
      tooltip = tr("header.close"),
      controlSize = "sm",
      variant = "ghost",
      onClick = function()
        panel.close()
      end,
    }),
  })
end

local function tabs()
  local function tabButton(id)
    return ui.button({
      text = tr("tabs." .. id),
      controlSize = "sm",
      variant = tab == id and "primary" or "ghost",
      onClick = function()
        tab, picking, query = id, nil, ""
        render()
      end,
    })
  end
  return ui.row({ gap = 6 }, { tabButton("slots"), tabButton("browse"), tabButton("families") })
end

render = function()
  local body
  if tab == "browse" then
    body = browseTab()
  elseif tab == "families" then
    body = familiesTab()
  else
    body = slotsTab()
  end
  local children = { header(), tabs() }
  for _, node in ipairs(banners()) do
    table.insert(children, node)
  end
  if message then
    table.insert(
      children,
      ui.label({
        text = message,
        color = messageIsError and "error" or "on_surface_variant",
        fontSize = 12,
        maxLines = 4,
      })
    )
  end
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, body))
  panel.render(ui.column({ gap = 10, padding = 16 }, children))
end

function onOpen()
  sel = Selection.load(env.selectionPath)
  refreshSetup()
  if not cat or Catalogue.isStale(dataDir) then
    fetchCatalogue()
  end
  render()
end
```

- [ ] **Step 2: Format, test and lint**

Run: `stylua umbriel-shaders tests && nix-shell --run "python3 tests/run.py" && noctalia plugins lint umbriel-shaders`
Expected: all tests PASS; lint reports no errors.

- [ ] **Step 3: Live check (the plugin hot-reloads from this tree)**

Run: `noctalia msg panel-toggle barrulus/umbriel-shaders:shaders`, then `journalctl --user --since "2 min ago" | grep -i umbriel-shaders | tail -20`
Expected: no Luau errors in the log. Ask the user to confirm in the panel:
1. The setup banner shows **Add for me**; pressing it adds the include (check `grep noctalia-shaders ~/.config/umbriel/config.toml` and that `~/.config/umbriel/config.toml.bak` exists), and the banner disappears.
2. Browse lists shaders with previews appearing progressively; search and the slot filter work; paging works.
3. Applying a screen shader (e.g. Vignette) changes the screen; `cat ~/.config/umbriel/noctalia-shaders.toml` shows the include and `[effects] screen = ...`.
4. Slots → Screen → **Clear** removes it; **Undo** brings it back.
5. Families → **Apply family** sets several slots; `umbriel config validate` prints `Config: ok`.

- [ ] **Step 4: Commit**

```bash
git add umbriel-shaders/panel.luau
git commit -m "Add the shader panel: setup, slots, browse and families"
```

---

### Task 8: Panel — animation timing and per-application rules

**Files:**
- Modify: `umbriel-shaders/panel.luau` — insert a block above `local function slotsTab()`, and replace the whole `slotsTab` function.

**Interfaces:**
- Consumes: `Selection.parseTiming`, `Selection.setApp`, `Selection.removeApp`, `Slots.appSlots`, `Slots.isAnimation`, panel helpers `nodes`, `card`, `hint`, `pick`, `commit`, `say`, `canApply`, `render`.

- [ ] **Step 1: Insert immediately above `local function slotsTab()`**

```lua
local expanded = nil -- slot whose details are open
local timingDraft = {} -- slot -> { duration = string, curve = string }
local openApps = nil -- sorted app IDs of open windows, nil until read

local function loadOpenApps()
  noctalia.runAsync({ "umbriel", "windows", "--json" }, function(result)
    local windows = noctalia.json.decode(result.stdout or "")
    local seen, apps = {}, {}
    for _, window in ipairs(type(windows) == "table" and windows or {}) do
      local app = window.app_id
      if type(app) == "string" and app ~= "" and not seen[app] then
        seen[app] = true
        table.insert(apps, app)
      end
    end
    table.sort(apps)
    openApps = apps
    render()
  end)
end

local function toggleDetails(slot)
  expanded = expanded ~= slot and slot or nil
  if expanded and Slots.appSlots[slot] then
    openApps = nil
    loadOpenApps()
  end
  render()
end

local function applyTiming(slot)
  local draft = timingDraft[slot] or {}
  local timing, err = Selection.parseTiming(draft.duration, draft.curve)
  if not timing then
    say(tr(err), true)
    render()
    return
  end
  commit(function(n)
    n.timing[slot] = next(timing) and timing or nil
  end, tr("status.timing_saved"))
end

local function timingNodes(slot, entry)
  local draft = timingDraft[slot]
  if not draft then
    local saved = sel.timing[slot] or {}
    draft = {
      duration = saved.duration_ms and tostring(saved.duration_ms) or "",
      curve = saved.curve or "",
    }
    timingDraft[slot] = draft
  end
  local ownDuration = entry.settings[slot .. ".duration_ms"]
  local ownCurve = entry.settings[slot .. ".curve"]
  return {
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = slot .. ":duration",
        value = draft.duration,
        placeholder = ownDuration and tr("timing.duration_own", { value = tostring(ownDuration) })
          or tr("timing.duration"),
        controlSize = "sm",
        width = 190,
        onChange = function(value)
          draft.duration = value
        end,
      }),
      ui.input({
        key = slot .. ":curve",
        value = draft.curve,
        placeholder = ownCurve and tr("timing.curve_own", { value = tostring(ownCurve) }) or tr("timing.curve"),
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(value)
          draft.curve = value
        end,
      }),
      ui.button({
        text = tr("timing.apply"),
        controlSize = "sm",
        enabled = canApply(),
        onClick = function()
          applyTiming(slot)
        end,
      }),
    }),
    hint(tr("timing.hint")),
  }
end

local function appNodes(slot)
  local out = { ui.label({ text = tr("apps.title"), fontWeight = "bold", fontSize = 12 }) }
  local assigned = {}
  for _, rule in ipairs(sel.apps) do
    if rule.slot == slot then
      assigned[rule.app_id] = true
      table.insert(
        out,
        ui.row({ key = slot .. ":" .. rule.app_id, gap = 8, align = "center" }, {
          ui.label({ text = rule.app_id, flexGrow = 1 }),
          ui.label({ text = rule.entry and rule.entry.name or tr("apps.off"), color = "primary", fontSize = 12 }),
          ui.button({
            text = tr("slots.change"),
            controlSize = "sm",
            enabled = canApply(),
            onClick = function()
              pick(slot, rule.app_id)
            end,
          }),
          ui.button({
            text = tr("apps.remove"),
            controlSize = "sm",
            variant = "ghost",
            enabled = canApply(),
            onClick = function()
              commit(function(n)
                Selection.removeApp(n, rule.app_id, slot)
              end)
            end,
          }),
        })
      )
    end
  end
  if openApps == nil then
    table.insert(out, hint(tr("apps.loading")))
  else
    local choices = {}
    for _, app in ipairs(openApps) do
      if not assigned[app] then
        table.insert(choices, app)
      end
    end
    if #choices > 0 then
      local labels = { tr("apps.add") }
      for _, app in ipairs(choices) do
        table.insert(labels, app)
      end
      table.insert(
        out,
        ui.select({
          key = slot .. ":add",
          options = labels,
          selectedIndex = 0,
          controlSize = "sm",
          enabled = canApply(),
          onChange = function(value)
            local index = tonumber(value) or 0
            if index > 0 then
              pick(slot, choices[index])
            end
          end,
        })
      )
    end
  end
  table.insert(out, hint(tr("apps.hint")))
  return out
end
```

- [ ] **Step 2: Replace the whole `local function slotsTab() ... end` with**

```lua
local function slotsTab()
  local out = {}
  for _, slot in ipairs(Slots.list) do
    local entry = sel.slots[slot]
    local hasDetails = Slots.appSlots[slot] ~= nil or (entry ~= nil and Slots.isAnimation(slot))
    local children = {
      ui.row(
        { gap = 8, align = "center" },
        nodes(
          ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = slotLabel(slot), fontWeight = "bold" }),
            ui.label({
              text = entry and entry.name or tr("slots.none"),
              color = entry and "primary" or "on_surface_variant",
              fontSize = 12,
            }),
          }),
          ui.button({
            text = tr("slots.change"),
            controlSize = "sm",
            enabled = canApply(),
            onClick = function()
              pick(slot, nil)
            end,
          }),
          entry and ui.button({
            text = tr("slots.clear"),
            controlSize = "sm",
            variant = "ghost",
            enabled = canApply(),
            onClick = function()
              commit(function(n)
                n.slots[slot] = nil
                n.timing[slot] = nil
              end)
            end,
          }),
          hasDetails and ui.button({
            text = expanded == slot and tr("slots.hide") or tr("slots.details"),
            controlSize = "sm",
            variant = "ghost",
            onClick = function()
              toggleDetails(slot)
            end,
          })
        )
      ),
    }
    if expanded == slot then
      if entry and Slots.isAnimation(slot) then
        for _, node in ipairs(timingNodes(slot, entry)) do
          table.insert(children, node)
        end
      end
      if Slots.appSlots[slot] then
        for _, node in ipairs(appNodes(slot)) do
          table.insert(children, node)
        end
      end
    end
    table.insert(out, card(slot, children))
  end
  return out
end
```

- [ ] **Step 3: Format, test and lint**

Run: `stylua umbriel-shaders tests && nix-shell --run "python3 tests/run.py" && noctalia plugins lint umbriel-shaders`
Expected: all PASS; no lint errors.

- [ ] **Step 4: Live check with the user**

1. Apply a workspace animation; open **Details** on its slot; the inputs show the shader's own duration/curve as placeholders. Enter `600` and save; `grep -A6 'animation.workspaces' ~/.config/umbriel/noctalia-shaders.toml` shows `duration_ms = 600`.
2. Enter `fast` as duration → error "Duration must be a whole number…", nothing written.
3. Border → **Details** → **Add an open application…** lists open app IDs; picking one opens Browse filtered to Border; **Apply** adds a `[[window_rule]]` with `border_effect`. **No effect** writes `border_effect = "off"`. **Remove** deletes the rule.

- [ ] **Step 5: Commit**

```bash
git add umbriel-shaders/panel.luau
git commit -m "Add animation timing and per-application rules to the panel"
```

---

### Task 9: Panel — GLSL import form

**Files:**
- Modify: `umbriel-shaders/panel.luau` — replace the whole `browseFooter` function (and its comment line).

**Interfaces:**
- Consumes: `Files.import`, `Files.removeImport`, `Selection.copy`, `Selection.save`, `Slots.list`, panel helpers.

- [ ] **Step 1: Replace `-- Extra nodes at the end of Browse ...` and `local function browseFooter() return {} end` with**

```lua
local importOpen = false
local importForm = { path = "", name = "", slot = 1 }

local function importShader()
  if busy then
    return
  end
  local taken = {}
  for _, effect in ipairs(sel.imports) do
    taken[effect.id] = true
  end
  local slot = Slots.list[importForm.slot]
  local effect, err = Files.import(env.paths.shaders, importForm.path, importForm.name, slot, taken)
  if not effect then
    say(tr("import.failed", { error = tostring(err) }), true)
    render()
    return
  end
  local nxt = Selection.copy(sel)
  table.insert(nxt.imports, effect)
  local ok, saveErr = Selection.save(env.selectionPath, nxt)
  if ok then
    sel = nxt
    importOpen = false
    importForm = { path = "", name = "", slot = importForm.slot }
    say(tr("status.imported", { name = effect.name }))
  else
    Files.removeImport(effect)
    say(tr("import.failed", { error = tostring(saveErr) }), true)
  end
  render()
end

-- The GLSL import form at the end of Browse.
local function browseFooter()
  if picking then
    return {}
  end
  if not importOpen then
    return {
      ui.row({ justify = "end" }, {
        ui.button({
          text = tr("import.open"),
          glyph = "plus",
          variant = "outline",
          controlSize = "sm",
          onClick = function()
            importOpen = true
            render()
          end,
        }),
      }),
    }
  end
  local labels = {}
  for _, slot in ipairs(Slots.list) do
    table.insert(labels, slotLabel(slot))
  end
  return {
    card("import", {
      ui.label({ text = tr("import.title"), fontWeight = "bold" }),
      ui.input({
        key = "import:path",
        value = importForm.path,
        placeholder = tr("import.path"),
        controlSize = "sm",
        onChange = function(value)
          importForm.path = value
        end,
      }),
      ui.input({
        key = "import:name",
        value = importForm.name,
        placeholder = tr("import.name"),
        controlSize = "sm",
        onChange = function(value)
          importForm.name = value
        end,
      }),
      ui.select({
        key = "import:slot",
        options = labels,
        selectedIndex = importForm.slot - 1,
        controlSize = "sm",
        onChange = function(value)
          importForm.slot = (tonumber(value) or 0) + 1
          render()
        end,
      }),
      hint(tr("import.hint")),
      ui.row({ gap = 6, justify = "end" }, {
        ui.button({
          text = tr("browse.cancel"),
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            importOpen = false
            render()
          end,
        }),
        ui.button({
          text = tr("import.save"),
          variant = "primary",
          controlSize = "sm",
          enabled = not busy,
          onClick = importShader,
        }),
      }),
    }),
  }
end
```

- [ ] **Step 2: Format, test and lint**

Run: `stylua umbriel-shaders tests && nix-shell --run "python3 tests/run.py" && noctalia plugins lint umbriel-shaders`
Expected: all PASS; no lint errors.

- [ ] **Step 3: Live check with the user**

Prepare a test file:

```bash
cat > /tmp/tint.glsl <<'EOF'
vec4 screen(vec2 uv) {
  vec4 c = umbriel_sample(uv);
  return vec4(c.rgb * vec3(1.0, 0.9, 0.9), c.a);
}
EOF
```

1. Browse → **Import GLSL** → path `/tmp/tint.glsl`, name `Tint`, slot **Screen** → **Import**. A card "Tint" (Imported) appears first in Browse; `ls ~/.config/umbriel/noctalia-shaders/imports/tint/` shows `shader.glsl effect.toml`.
2. Its **Screen** button applies it; the screen tints.
3. **Remove** on the card clears the slot and deletes the two files.
4. Import a missing path → "Import failed: …".

- [ ] **Step 4: Commit**

```bash
git add umbriel-shaders/panel.luau
git commit -m "Add GLSL import to the panel"
```

---

### Task 10: Documentation, catalogue entry and final verification

**Files:**
- Replace: `README.md`, `umbriel-shaders/README.md`, `CONTRIBUTING.md`, `catalog.toml`

- [ ] **Step 1: Replace `catalog.toml`**

```toml
[[plugin]]
id = "barrulus/umbriel-shaders"
name = "Umbriel Shaders"
version = "0.7.0"
plugin_api = 43
author = "Barrulus"
license = "MIT"
description = "Browse community shaders and apply them to Umbriel effect and animation slots."
dependencies = ["umbriel"]
tags = ["umbriel", "theming", "panel", "utility"]
```

- [ ] **Step 2: Replace `umbriel-shaders/README.md`**

````markdown
# Umbriel Shaders

Browse the [community shader catalogue](https://github.com/noctalia-dev/community-umbriel-shaders)
and apply shaders to Umbriel's effect and animation slots from Noctalia.

## Plugin

Manifest ID: `barrulus/umbriel-shaders`.

- `shaders` — the panel.
- `shaders-bar` — bar widget that opens the panel.
- `open` — control-center shortcut to the panel.

```sh
noctalia msg panel-toggle barrulus/umbriel-shaders:shaders
```

## Requirements

- Noctalia with plugin API 43 or later.
- `umbriel` on Noctalia's `PATH`, with the preset effects API and `umbriel config validate --json`.

## Setup

The plugin writes one file, `~/.config/umbriel/noctalia-shaders.toml`, and keeps shader
files next to it in `~/.config/umbriel/noctalia-shaders/`. Umbriel loads it once your
configuration includes it:

```toml
[include.optional]
files = ["noctalia-shaders.toml"]
```

The panel offers **Add for me**, which saves `config.toml.bak`, adds the file to your
`[include.optional]` table (or creates the table), and keeps the change only if
`umbriel config validate` reports nothing new. If you start Umbriel with `-c`, or your
configuration is managed by Nix or home-manager, add the line yourself.

## Usage

- **Slots** lists every destination: cursor, border, window, screen and the animation
  events. **Change** opens Browse filtered to that slot; **Clear** removes the shader.
- **Details** on an animation slot overrides its duration and curve. Leave a field empty
  to use the shader's own value.
- **Details** on Border and Window adds per-application rules: pick an open application,
  then a shader or **No effect**. Rules match the exact app ID and cover all its windows.
- **Browse** searches the catalogue. Each card has one button per slot the shader supports.
- **Import GLSL** copies a standalone `.glsl` file (up to 256 KiB) into your library for one
  slot. The file must define that slot's entry point (`cursor`, `border`, `window`,
  `screen` or `animation`). Imported shaders appear first in Browse and work offline.
- **Families** applies a coordinated set of shaders in one step.
- **Undo** reverts the last change. **Clear all** empties the generated file.

Every change downloads any missing files, rewrites the generated file, and asks
`umbriel config validate` whether anything new is wrong. If so, the previous file is put
back and the message is shown. Umbriel reloads the file by itself.

Your own `config.toml` is applied after the generated file, so anything you set there —
an `[effects]` selector, animation timing, a window rule — takes precedence. If a slot
does not change, check your own configuration for the same key.

## Downloads and stored data

The catalogue is read from the `catalogue` branch of
`noctalia-dev/community-umbriel-shaders` and cached for a day; **Refresh** fetches it now.
Shader files and previews are downloaded from `raw.githubusercontent.com` at the
catalogue's pinned commit. Umbriel compiles and runs the downloaded GLSL when its effect
is used.

The plugin data directory holds `selection.json`, the cached catalogue and previews.

## Removing the plugin

Selections stay active after the plugin is disabled. Use **Clear all** first, or remove
the include line from your `config.toml`.
````

- [ ] **Step 3: Replace the root `README.md`**

````markdown
# Umbriel Shaders

A Noctalia plugin that applies community GLSL shaders to Umbriel. See the
[plugin guide](umbriel-shaders/README.md) for setup and usage, and
[CONTRIBUTING.md](CONTRIBUTING.md) for development.

## Install for testing

```sh
noctalia msg plugins source add umbriel-shaders git https://github.com/barrulus/umbriel-shaders
noctalia msg plugins enable barrulus/umbriel-shaders
noctalia msg panel-toggle barrulus/umbriel-shaders:shaders
```

For a local checkout, replace the source-add command with:

```sh
noctalia msg plugins source add umbriel-shaders path "$HOME/dev/umbriel-shaders"
```

Upgrading from 0.6 or earlier: press **Restore original** in the old version before
updating. 0.7 no longer uses a wrapper configuration.
````

- [ ] **Step 4: Replace `CONTRIBUTING.md`**

````markdown
# Development

The installable plugin is `umbriel-shaders/`. `panel.luau` is the UI; `lib/` holds the
logic and is covered by unit tests in `tests/`.

## Checks

```sh
nix-shell --run "python3 tests/run.py"   # or: python3 tests/run.py /path/to/luau
stylua --check umbriel-shaders tests
noctalia plugins lint umbriel-shaders
```

The tests run the real `lib/` modules with the stock `luau` CLI. They do not exercise
the panel, Umbriel or the network; check those live with a local `path` source.

## Translations and artwork

Edit only `umbriel-shaders/translations/en.json`, using nested lowercase keys and
`noctalia.tr()` with named substitutions. `python3 tools/thumbnail.py` regenerates the
illustrative card artwork (needs FFmpeg).

## Official repository submission

Copy only `umbriel-shaders/` into `noctalia-dev/official-plugins`, keep the ID
`barrulus/umbriel-shaders` unless maintainers ask otherwise, and run upstream's validator
and `noctalia plugins lint`. Do not copy this repository's root files or edit upstream's
generated `catalog.toml`.
````

- [ ] **Step 5: Full verification**

Run:

```bash
nix-shell --run "python3 tests/run.py"
stylua --check umbriel-shaders tests
noctalia plugins lint umbriel-shaders
git ls-files umbriel-shaders | grep -v '\.webp$' | xargs wc -l | tail -1
git ls-files tests | xargs wc -l | tail -1
```

Expected: six `PASS` lines; stylua silent; lint with zero errors; plugin total under ~1,800 lines; tests around 300–400 lines. Report the actual numbers to the user.

- [ ] **Step 6: Final live pass with the user**

Ask the user to run through: setup banner absent (already set up), apply one shader per kind (cursor, border, window, screen, an animation), apply a family, add an app rule, set timing, import + apply + remove a GLSL file, **Undo**, **Clear all** (generated file contains only the header line), close and reopen the panel (state persists), and confirm `umbriel config validate` prints `Config: ok`.

- [ ] **Step 7: Commit**

```bash
git add README.md CONTRIBUTING.md catalog.toml umbriel-shaders/README.md
git commit -m "Document the simplified plugin"
```
