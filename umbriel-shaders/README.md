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

Add the bar widget or control-center shortcut, then open the browser.

- Search or filter shaders by type and tag. Choose a shader and destination, then
  **Apply**. Open **Details** to review the proposed changes before applying.
- Choose a family to apply coordinated shaders together. **Keep current** leaves
  a destination unchanged; **Review** prepares the combined changes.
- **Active selections** lets you remove one selection.
- **Undo** reverses the last change. **Restore original** returns to your original
  configuration while preserving unrelated runtime selections where possible.

The plugin creates a separate configuration that includes your original file;
it does not rewrite that file. Existing local presets take precedence, and
refreshing the catalogue does not overwrite installed shader edits.

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
  Use **Refresh** after authoring edits; preparing a selection rechecks the files.
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
but omit original configuration contents, window IDs and environment values.
Technical reports and external command errors retain their original language.

State files are replaced atomically. Recovery covers interrupted plugin operations;
the host API does not guarantee filesystem synchronization during sudden power loss.
