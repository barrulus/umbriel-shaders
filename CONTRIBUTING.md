# Development and upstream handoff

The installable plugin is `umbriel-shaders/`. Its `lib/` directory contains shared
modules; `lib/vendor/` contains the MIT-licensed TOML parser and its provenance.
Tests and thumbnail tooling belong to this development repository.

## Checks

With a Luau CLI installed:

```sh
python3 tests/run.py /path/to/luau
python3 tests/ui_workflows.py /path/to/luau
noctalia plugins lint umbriel-shaders
stylua --check umbriel-shaders/*.luau umbriel-shaders/lib/*.luau
```

Alternatively, build the development-only runner using Noctalia's Luau sources:

```sh
# On NixOS, enter nix-shell first.
cmake -S tests -B build-tests -G Ninja -DLUAU_SOURCE_DIR=/path/to/noctalia/third_party/luau
cmake --build build-tests
ctest --test-dir build-tests --output-on-failure
```

An optional checkout check exercises real metadata and activation recipes:

```sh
python3 tests/catalogue_checkout.py build-tests/luau-test-runner /path/to/community-umbriel-shaders
```

The fixtures cover application and recovery logic but do not prove GPU rendering
or the shell's resource limits. See [VALIDATION.md](VALIDATION.md) for scope.

## Translations and artwork

Edit only `umbriel-shaders/translations/en.json`. Use nested lowercase keys and
`noctalia.tr()` with named substitutions, or `noctalia.trp()` with `one` and `other`
variants for counts. Keep protocol identifiers and catalogue contributor metadata
untranslated. The official translation platform manages additional languages.

The original illustrative card artwork can be regenerated with Python and FFmpeg:

```sh
python3 tools/thumbnail.py
```

It produces a 960×540 WebP. It is an illustration, not a screenshot of shader output.

## After approval for the official repository

1. Agree the manifest ID with the maintainers. Moving the folder into
   `noctalia-dev/official-plugins` does not itself require an ID change.
2. If switching to `noctalia/umbriel-shaders`, first use **Restore original** in
   `barrulus/umbriel-shaders`, complete any pending recovery, then disable it.
   The new ID has separate settings and storage. Re-add its widget/shortcut and
   select shaders again; local edits remain in the old data directory.
   Do not copy `state.json`, plans or journals between IDs: they contain absolute
   paths and ownership records. Do not enable both IDs simultaneously.
3. Copy only `umbriel-shaders/` into the official repository. If changing the ID,
   replace its occurrences in `plugin.toml`, `widget.luau`, `shortcut.luau` and
   the plugin's `README.md` together. Preserve author and license attribution.
4. Run the official repository's `.github/workflows/validate-plugins.py`, and
   `noctalia plugins lint umbriel-shaders`. Test enabling, opening the panel,
   applying, undoing and restoring from that checkout.
5. Open the agreed PR. Do not copy this repository's root files or manually edit
   upstream `catalog.toml`; upstream generates its own catalog.

Until that handoff, this repository deliberately retains the working
`barrulus/umbriel-shaders` identity and its installation instructions.
