# Umbriel Shaders

A Noctalia plugin for browsing and applying community shaders in Umbriel. Supports
cursor, border, window, screen and animation shaders, plus coordinated families.

The plugin preserves your original Umbriel configuration and local shader edits.
Apply a selection, undo the last change, or restore your original configuration
from the panel.

## Requirements

- Linux, Noctalia with plugin API 24, and Umbriel with named presets, effect
  inspection, explicit effect targets, configuration validation and `config-replace`.
- To build: a C++20 compiler, CMake 3.20+, Ninja, nlohmann/json 3.11+, toml++ 3.4+,
  OpenSSL Crypto and libcurl 7.85+.
- To run tests: Python 3.11+.

## Build and install

On Nix, enter the development environment first with `nix-shell shell.nix`.

```sh
cmake -S . -B build-native -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-native
cmake --install build-native --prefix ~/.local
```

Ensure `~/.local/bin` is on Noctalia's PATH, then add the installed plugin source
and enable the plugin:

```sh
noctalia msg plugins source add umbriel-shaders path "$HOME/.local/share/noctalia/plugins"
noctalia msg plugins enable barrulus/umbriel-shaders-native
```

Noctalia does not build or install the C++ helper itself. Keep the helper and its
shared libraries installed while the plugin manages shader selections.

To build the Nix package:

```sh
nix-build -E 'let pkgs = import <nixpkgs> {}; in pkgs.callPackage ./package.nix {}'
```

The package contains the helper in `bin/` and the plugin source in
`share/noctalia/plugins/`. Install it in your profile, or retain the `result`
symlink and use those paths directly.

## Usage

Open the panel from the plugin's bar widget or control-center shortcut, or run:

```sh
noctalia msg panel-open barrulus/umbriel-shaders-native:shaders
```

- Search or filter shaders by type and tag.
- Choose a shader and destination, then **Apply**. **Review** shows the proposed
  changes before applying.
- Choose a family to apply coordinated shaders together. Use **Keep current** for
  destinations you want to leave unchanged.
- Use **Active selections** to remove an individual selection.
- **Undo** reverses the last change. **Restore original** returns to your original
  configuration.

Existing local presets take precedence over downloaded copies. Refreshing the
catalogue does not overwrite your installed shader edits.

## Catalogue sources

Choose a source in the plugin settings:

- **Online community catalogue** is the default. The first visit downloads the
  catalogue; later visits use the saved copy. **Refresh** checks for updates.
  Shader assets download when needed.
- **Local shader checkout** reads authoring metadata from a community shader
  checkout, including unpublished experiments.
- **Saved snapshot** uses a catalogue JSON file and its matching asset directory
  for offline browsing and application.

Set **Original Umbriel configuration** if automatic discovery cannot find your
configuration. Restore active selections before changing this path.

## Troubleshooting

Use **Troubleshooting** in the panel to inspect status and copy a diagnostic
report. If an operation was interrupted, use **Recover** before applying another
selection. Recovery and Restore work without the catalogue or downloaded assets.

Restore your original configuration before removing the helper or its libraries.
On Nix, keep the package in your profile or retain its GC roots until restoration
has completed.

## Development

The C++ helper lives in `src/`, the Luau interface in `umbriel-shaders-native/`,
and tests in `tests/`.

```sh
ctest --test-dir build-native --output-on-failure
noctalia plugins lint umbriel-shaders-native
```

To include UI workflow tests, configure CMake with
`-DLUAU_SOURCE_DIR=/path/to/noctalia/third_party/luau`. For sanitizer checks, use a
Debug build with `-DENABLE_SANITIZERS=ON`.

The repository root can also be used as a Noctalia path source during development.
Make the built helper available on Noctalia's PATH or copy it to
`umbriel-shaders-native/bin/umbriel-shaders-native`.
