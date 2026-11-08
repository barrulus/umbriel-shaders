# Umbriel Shaders

Browse community shaders and apply individual effects or coordinated families to
Umbriel. Review changes, undo a selection, or restore your original configuration.

## Plugin

Manifest ID: `barrulus/umbriel-shaders`.

- `shaders-bar` — bar widget that opens the shader browser.
- `open` — control-center shortcut to the browser.
- `shaders` — panel for browsing, applying, reviewing and restoring selections.
- `manager` — service that downloads verified assets and talks to Umbriel.

Open or close the panel from a terminal:

```sh
noctalia msg panel-toggle barrulus/umbriel-shaders:shaders
```

## Requirements

- Noctalia with plugin API 43 or later.
- `umbriel` on Noctalia's PATH, in a running Umbriel session, with `effects --json`,
  `config validate`, `config-replace`, and word-based effect actions with explicit
  targets (`umbriel msg effect-window-set NAME --window ID`).

The plugin is entirely Luau. Fedora and NixOS use the same files; Python, a compiler
and additional helper executables are not runtime dependencies.

## Usage

Add the bar widget or control-center shortcut, then open **Effect slots**.

- Each collapsed card shows its slot name, current default allocation and saved
  application-rule count. Expand a card to edit it; opening another card closes
  the previous one. Bold headings, accent allocations, bordered cards and dividers
  distinguish the slot, its defaults and its application rules. Expanded cards
  explain what the slot affects and link to the relevant Umbriel documentation.
- Inside an expanded card, choose a shader to browse compatible effects, or select
  **Default**, **No effect** or **Inherit**. Default clears the shader; for animation
  slots it enables the native animation and animation master switch, using timing
  from the original configuration unless you override it. It does not reset the
  original configuration's native style or other animation parameters. No effect
  disables the animation event. Inherit removes the plugin's contribution and
  returns to the original configuration.
- Overview, Scratchpad, Border animation, Unfocused dimming and Layer animations
  each include a catalogue-backed **Try example** choice. These are real shaders managed
  with the same apply, timing, Undo and Restore behavior as community selections:
  overview glow, scratchpad fade, focus-ring pulse, focus desaturation and panel
  glide. Their canonical sources live under `animation/` in
  `community-umbriel-shaders`; the plugin carries no duplicate shader code.
  Refresh an updated local checkout to select them immediately. Online selection
  requires a published catalogue containing these entries. The example button is
  disabled when its entry is absent from the loaded catalogue. Already installed
  examples remain manageable without the source checkout.
- Border and window-surface cards have a nested **Window rules** section. Use
  **+ Add application**, choose from open applications, then **Add**. Add more rows
  to assign different effects to multiple applications. Choose a shader or
  **No effect** for each row to save its assignment; an unconfigured new row is a
  draft. **Remove** deletes just that application's assignment for this slot.
- Application assignments use exact app IDs and cover all windows of that
  application, including future windows. Saved assignments remain visible when
  the application is closed. Duplicate applications are omitted from the Add picker.
- Each assignment shows a live example from its first matching open window,
  including its selected shader, source and suppression. **Refresh windows**
  updates this snapshot. Umbriel identifies a window-rule source but does not
  expose which rule supplied it.
- Handwritten window rules take precedence over application preferences, field by
  field. Runtime overrides and suppression remain active when applying selections.
  Removing an assignment can expose another matching rule rather than the global
  default. Application **No effect** is also subject to later handwritten rules.
- Global animation slots offer duration and curve overrides after a shader is
  selected. Press **Apply** to save both. Spring curves set their own duration, so
  fixed-duration overrides use an easing curve. Initial suggestions are 200 ms
  and ease-out cubic when the selection has no explicit duration or compatible
  curve; they are saved only when you apply a timing change. Per-application
  opening, closing and movement animations/timing require additional Umbriel support.
- **All shaders** opens the complete catalogue, including coordinated families.
  Use **Next page** and **Previous page** to move through the results.
- Search or filter shaders by type and tag. Choose a shader and destination, then
  **Apply**. Open **Details** to review the proposed changes before applying.
- Choose a family to apply coordinated shaders together. **Keep current** leaves
  a destination unchanged; **Review** prepares the combined changes.
- Return to **Effect slots** to inspect or change an individual assignment.
- **Undo** reverses the last change. **Restore original** returns to your original
  configuration while preserving unrelated runtime selections where possible.

The plugin creates a separate configuration that includes generated application
preferences first and your original file afterwards;
it does not rewrite that file. Presets defined in your original configuration take
precedence. Online and snapshot modes preserve installed shader edits.

In local-checkout mode, **Refresh** also updates active shaders from the checkout,
including their preset definitions and dependencies. It keeps your selected slots,
application assignments and activation settings, such as animation timing. Updated
shaders must pass
configuration validation; reached shaders must also pass GPU compilation. Unused
shaders compile when first needed. A failed update restores the previous
revision. **Undo** restores the previous shader files as well as the selection.
Refreshing without active shader changes keeps the existing Undo history.

**Selections remain active when you close, disable or uninstall the plugin.**
Generated configurations and shader files remain in Noctalia's plugin data
directory. Use **Restore original** before deleting that data, or re-enable the
same plugin ID to restore later. Restore and recovery do not need the catalogue.

## Settings

- **Catalogue source** — online community catalogue, local shader checkout, or
  saved snapshot. Online mode reuses the saved index; **Refresh** checks for
  updates. Downloaded shader assets are checked against their SHA-256 hashes.
- **Community shader checkout** — source directory for local authoring metadata
  and experiments, shown in local mode. Previews load directly from the checkout.
  Use **Refresh** after authoring edits to reload previews and update active shaders.
  Applying a selection also uses the current checkout files.
- **Saved catalogue** and **Shader asset snapshot** — matching published index
  and assets directory, shown in snapshot mode.
- **Original Umbriel configuration** — defaults to
  `$XDG_CONFIG_HOME/umbriel/config.toml` or `~/.config/umbriel/config.toml`.
  Set this before applying if Umbriel was launched with a different `-c` path.
  Restore active selections before changing it.

## Troubleshooting

Use **Recover** after an interrupted operation. After a reload, recovery may ask
you to wait a few seconds for an already-launched Umbriel command to finish.

**Troubleshooting** displays a diagnostic report and saves `diagnostics.txt` under
the plugin's `luau-v1` data directory. Reports contain local paths and shader names,
but omit original configuration contents, application identities, window IDs and
environment values.
Technical reports and external command errors retain their original language.

State files are replaced atomically. Recovery covers interrupted plugin operations;
the host API does not guarantee filesystem synchronization during sudden power loss.
