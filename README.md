# Umbriel Shaders

A Noctalia plugin for browsing community shaders and applying them to Umbriel.
Choose individual effects or coordinated families, review changes, undo a
selection, or restore your original configuration.

The application is entirely Luau. It uses Noctalia's APIs and the existing
`umbriel` command; there is no helper to build or install.

## Requirements

- Noctalia with plugin API 24 or later.
- Umbriel on Noctalia's PATH, with `effects --json`, `config validate`,
  `config-replace`, and word-based effect actions with explicit targets
  (`umbriel msg effect-window-set NAME --window ID`).

These requirements are the same on Fedora and NixOS. Keep your existing Noctalia
and Umbriel installation; Python and a compiler are not runtime dependencies.

## Install

```sh
noctalia msg plugins source add umbriel-shaders git https://github.com/barrulus/umbriel-shaders
noctalia msg plugins enable barrulus/umbriel-shaders
```

Add the plugin's bar widget or use its control-center shortcut. To open it from a
terminal:

```sh
noctalia msg panel-open barrulus/umbriel-shaders:shaders
```

For a local checkout, use a path source instead:

```sh
noctalia msg plugins source add umbriel-shaders path "$HOME/dev/umbriel-shaders"
noctalia msg plugins enable barrulus/umbriel-shaders
```

The plugin ID is fixed in the manifest and interface. It does not depend on the
checkout directory or repository URL.

## Use

- Search or filter shaders by type and tag.
- Choose a shader and destination, then **Apply**. **Review** shows the proposed changes first.
- Choose a family to apply coordinated shaders together. **Keep current** leaves a destination unchanged.
- **Active selections** lets you remove one selection.
- **Undo** reverses the last change. **Restore original** returns to your original configuration.

The plugin writes a separate configuration that includes your original file.
It does not rewrite that original file. Existing local presets take precedence;
refreshing the catalogue does not overwrite installed shader edits.

**Selections remain active when you close, disable, or uninstall the plugin.**
Generated configurations and installed shader files remain in Noctalia's plugin
data directory. Use **Restore original** before deleting that data, or re-enable
the plugin to restore later. Restore and recovery do not need the catalogue.

## Catalogue sources

Choose a source in plugin settings:

- **Online community catalogue** uses a saved index after the first download.
  **Refresh** checks for updates; shader assets download when needed and are
  checked against the catalogue's SHA-256 hashes.
- **Local shader checkout** reads authoring metadata, including local experiments.
- **Saved snapshot** uses a published catalogue JSON file and matching asset directory.

The original configuration defaults to `$XDG_CONFIG_HOME/umbriel/config.toml`
(or `~/.config/umbriel/config.toml`). Set **Original Umbriel configuration** if
Umbriel was launched with a different `-c` path. Restore active selections before
changing it.

## Troubleshooting

If an operation is interrupted, use **Recover** before applying another selection.
After a reload you may need to wait a few seconds for an already-launched Umbriel
command to finish. Recovery uses a saved journal and verifies the resulting state.

Use **Troubleshooting** in the panel to inspect and copy a diagnostic report.
Generating it also saves `diagnostics.txt` under the plugin's `luau-v1` data
directory. Reports include local paths and shader names, but omit original
configuration contents, window IDs, and environment values.

State files are replaced atomically. Recovery covers interrupted plugin
operations; the host API does not provide filesystem synchronization guarantees
for a sudden power loss.

## Development

Application code lives in `umbriel-shaders/`: UI entry scripts and shared modules
in `lib/`. The bundled MIT-licensed TOML parser has its own license and provenance
in `lib/vendor/`.

With a Luau CLI installed:

```sh
python3 tests/run.py /path/to/luau
python3 tests/ui_workflows.py /path/to/luau
noctalia plugins lint umbriel-shaders
```

Alternatively, build the development-only test runner using Noctalia's Luau sources:

```sh
# On NixOS, enter nix-shell first.
cmake -S tests -B build-tests -G Ninja -DLUAU_SOURCE_DIR=/path/to/noctalia/third_party/luau
cmake --build build-tests
ctest --test-dir build-tests --output-on-failure
```

An optional checkout check exercises authoring metadata and activation recipes:

```sh
python3 tests/catalogue_checkout.py build-tests/luau-test-runner /path/to/community-umbriel-shaders
```
