# Umbriel Shaders — simplified redesign

Date: 2026-11-20. Status: approved design, pending implementation plan.

## Goal

Replace the 0.6.0 plugin (~7k lines in the official-plugins PR) with a plugin that
does the same core job in under ~1,800 lines including translations, with tests
around 300 lines. The plugin lets a user browse the community shader catalogue,
assign shaders to Umbriel effect/animation slots, assign shaders per application,
import their own GLSL, adjust animation timing, apply families, clear and undo.

## Key mechanism

Umbriel already provides what the old wrapper-config machinery emulated:

- `[include.optional] files = [...]` ignores a missing file and watches it;
  creating or changing it reloads the configuration automatically.
- Included files are applied before the including file, so anything the user
  writes in their own `config.toml` wins over the generated file. Rule lists such
  as `[[window_rule]]` collect entries across files.
- The published `catalogue.json` (`catalogue` branch of
  `noctalia-dev/community-umbriel-shaders`) gives every effect its `preset`,
  `uses` (slots), `dependencies`, `install_files`, `preview` and
  `activation.{include,settings}`. An effect's preset name is the same whether it
  is applied alone or through a family.

The plugin therefore owns exactly one generated file,
`~/.config/umbriel/noctalia-shaders.toml`, plus downloaded shader files under
`~/.config/umbriel/noctalia-shaders/`. It never calls `config-replace` and never
rewrites the user's configuration except for the one-time, user-initiated include
append described below.

## Kept and dropped

Kept: catalogue browse/search/filter with previews; apply an effect to any of the
13 slots found in the catalogue (`effects.{cursor,border,window,screen}` and
`animation.{windows_in,windows_out,windows_move,workspaces,overview,border,dim_unfocused,layers,scratchpad}`);
apply a family; clear a slot; clear all; one-level undo; per-application
border/window assignments; GLSL import; animation duration/curve overrides.

Dropped: wrapper configuration and `config-replace`; the "original Umbriel
configuration" setting; local-checkout and snapshot source modes and all source
settings; recovery, journals, pending/operation files; session/peer tracking;
diagnostics report; vendored TOML parser, custom JSON encoder/decoder and SHA-256
(files are fetched from the commit-pinned URL recorded in the catalogue, the same
trust root as before); revision-safe undo of shader file contents; the
Default/No effect/Inherit distinction (now just *None* or a shader); extra import
knobs (cursor radius, border padding/speed/animated, palette, dim amount);
callback/performance budget suites and the C++ test runner.

Migration: none in code. The ~5 existing users run **Restore original** in 0.6.0
before upgrading; the author will notify them. The new plugin ignores `luau-v1`.

## Structure

```
umbriel-shaders/
  plugin.toml, widget.luau, shortcut.luau, thumbnail.webp, LICENSE, README.md
  translations/en.json
  panel.luau          UI only: header, setup banner, Slots / Browse / Families tabs
  lib/catalogue.luau  fetch + cache catalogue.json, search/filter, preview cache
  lib/selection.luau  load/save selection.json, apply effect/family, clear, undo
  lib/config.luau     render selection to TOML; detect/append the include
  lib/files.luau      download install files at the pinned revision; import GLSL
```

No service entry unless the spike (below) shows the catalogue cannot be decoded
within the panel's callback budget; in that case a minimal service decodes once
and publishes a trimmed effect list through `noctalia.state`.

Plugin settings: none.

## Data

`<pluginDataDir>/selection.json`:

```
{
  slots   = { ["effects.border"] = { id, preset, include = {abs paths}, settings = {dotted key -> value} }, ... },
  apps    = { { app_id, slot = "effects.border" | "effects.window", id, preset, include }, ... },
  timing  = { ["animation.windows_in"] = { duration_ms, curve }, ... },
  imports = { { id, name, kind, slot, path }, ... },
  previous = <snapshot of slots/apps/timing before the last change>
}
```

Each slot stores its resolved activation, so rendering, undo and clear work
without the catalogue and survive an effect being removed from the catalogue.

`<pluginDataDir>/catalogue.json` caches the last fetched catalogue. Previews cache
under `<pluginDataDir>/previews/<revision>/`.

Shader files: `~/.config/umbriel/noctalia-shaders/<revision>/<path>` for catalogue
files, `~/.config/umbriel/noctalia-shaders/imports/<id>/{shader.glsl,effect.toml}`
for imports. Keeping them next to the generated file makes the active set
self-contained even if plugin data is deleted.

## Flows

**Apply effect to slot.** Resolve the effect and its `dependencies`; download any
missing `install_files` from
`https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/<revision>/<path>`;
filter `activation.settings` to keys under the chosen slot (plus
`animation.enabled` for animation slots); store the slot; snapshot `previous`;
write the file (see *Write*). Effects with several `uses` ask which slot.

**Apply family.** For each `(slot, member)` in the family defaults, run the
per-slot resolution above, then write once. One undo step.

**Clear slot / clear all.** Remove the slot (or slots, apps and timing) and write.
Clear all writes an empty generated file.

**Undo.** Swap current state with `previous` and write.

**Per-app assignment.** Only for `effects.border` and `effects.window`. Pick an
app from `umbriel windows --json` (unique `app_id`s, excluding ones already
assigned to that slot), then pick a shader of the matching kind or *None* (`off`).
Saved assignments persist when the app is closed.

**Timing.** Animation slots with a selection show duration (ms, text input) and
curve (select). Overrides replace the corresponding keys at render time.

**Import GLSL.** Form: file path, kind, name, and animation event when kind is
animation. Copy the file (≤256 KiB) to `imports/<id>/shader.glsl`, write a
generated `effect.toml` with preset `import.<id>`, record it in `imports`.
Imported effects appear in Browse tagged *imported* and can be removed; removal
also clears any slot or app using it.

**Write.** Render TOML from the selection; keep the current generated file's text
in memory; `writeFile` the new text; run
`umbriel config validate -c <user config>`. On failure write the previous text
back and show the validator's message. Umbriel reloads by itself.

**Setup.** On open, read the user config (`$XDG_CONFIG_HOME/umbriel/config.toml`
or `~/.config/umbriel/config.toml`) and check for `noctalia-shaders.toml`. If
absent, show a banner. **Add for me**: if the file has no `[include.optional]`
table, copy it to `config.toml.bak` and append
`[include.optional]\nfiles = ["noctalia-shaders.toml"]`; otherwise show the
snippet to add to the existing table, with **Copy**. **Check again** re-reads.

## Rendering

Deterministic: `[include]` first, then setting tables in alphabetical order, then
`[[window_rule]]` entries (`match.app_id = "^<regex-escaped>$"` and `border_effect` or
`window_effect`). A given effect id is included from one revision only.

Strings are TOML basic strings with `\`, `"` and control characters escaped.
Values are strings, integers, floats and booleans only.

## Panel

- Header: title, status line, **Undo**, **Clear all**, **Refresh catalogue**.
- Setup banner when the include is missing; banner when `umbriel` is missing
  (applying disabled); banner when offline and using the cached catalogue.
- **Slots** (default tab): one row per slot present in the catalogue, showing the
  current effect or *None*, **Change** (opens Browse filtered to that slot) and
  **Clear**. Animation rows show timing inputs. Border/window rows have an
  **Apps** expander.
- **Browse**: search, kind filter, pages of ~10 cards (preview, name, author,
  description, **Apply**), **Import GLSL** form.
- **Families**: name, description, members, **Apply family**.

## Errors

- Catalogue fetch failure: use the cached catalogue, show "offline".
  No cache: show the error and a retry button.
- Any download failure: abort before writing; show which file failed.
- Validation failure: restore the previous generated text; show the message.
- `umbriel` missing: banner; apply/validate disabled.

## Testing

`tests/run.py` runs plain Luau tests with a small host stub via the `luau` CLI:

- TOML rendering, escaping, ordering, app rules, timing overrides.
- Family → slot mapping; slot-filtered settings for multi-use effects.
- Include detection/append: no table, existing `[include.optional]`, already present.
- Catalogue search and kind filtering.
- Undo swap and clear.

Plus `noctalia plugins lint umbriel-shaders`, `stylua --check`, and a manual live
check: setup append, apply effect, apply family, app rule, import, timing, undo,
clear all.

## First step: decode spike

Before building the panel, time `noctalia.json.decode` of the real 438 KB
catalogue inside the plugin panel VM, against the 25 ms callback budget. Within
budget: no service. Over budget: add the minimal decoding service described in
*Structure*.

## Size target

All text files under `umbriel-shaders/` (everything except `thumbnail.webp`)
total under ~1,800 lines, including `translations/en.json`; tests ~300 lines.

## Recorded deviations

- The timing curve is free text: spring curves are free-form, so it is not validated.
- Slots lists all 13 slots.
- The Browse page size is 8.
- The status line is the message label under the tabs.
- The import entry point is at the top of Browse.
