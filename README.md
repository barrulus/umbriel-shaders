# Umbriel Shaders

A Noctalia plugin for browsing and applying community Umbriel shaders. A separate
C++20 process owns catalogue access, validation,
installation and transactions. The Luau service and panel use Noctalia's existing
plugin API. Neither Noctalia nor Umbriel needs modifications.

## Using the plugin

- Browse shaders or families, filter by type or tag, and search the complete catalogue.
  The gallery initially renders 24 cards; Show more adds another batch.
- Choose a supported destination and Apply. Review is optional and shows settings
  changes and reused local presets. Compare local copy checks the definition and
  shader fingerprint only when requested; a failed comparison does not prevent reuse.
- Families let each supported destination choose a member or Keep current. Applying
  a family is one transaction, with one Undo. Companion overlays follow their border.
- Active selections lists every saved slot, including entries withdrawn from the
  current catalogue. Remove releases one slot; Undo reverses that removal.
- Restore original returns to the original configuration. Recover rolls back an
  interrupted transaction. Both work without the catalogue or its assets.
- Troubleshooting shows bounded diagnostics and offers a copyable report. Reports
  include local paths and preset names, but exclude original configuration contents,
  environment values and window titles/identities.

The bar widget is `barrulus/umbriel-shaders-native:shaders-bar`. The control-center
shortcut opens the same panel. The panel keeps actions outside its scrolling content.
Recordings open externally; embedded video playback and rule editing are outside
this plugin's scope.

### Catalogue sources

**Online** is the default. Startup immediately reads the cached JSON when available;
first use downloads the index automatically. Refresh checks for updates and falls
back to the saved index on network failure. Failed initial loads show an error and
Retry button; live compositor-status updates do not hide that error. Only rendered
preview cards request images, with at most four downloads in parallel. Each image
appears as soon as its request finishes; a slow image does not delay the others.
Selected assets use HTTPS URLs pinned to the catalogue's commit and are checked against size and SHA-256 before installation. Corrupt cached images are
repaired on their next preview request. Refresh permits retrying failed previews.

**Local development checkout** generates the catalogue natively from authoring
TOML files, including unpublished/manual development entries. The cache invalidates
on file metadata changes; Refresh forces regeneration. Manual entries are browsable
but cannot be applied without a supported recipe. The native generator reads the
authoring metadata directly.

**Saved catalogue and snapshot** uses an already published index and matching asset
tree. Selected bytes must match their catalogue hashes. No network is required.

Set **Original Umbriel configuration** if discovery is insufficient, especially for
system config search paths. Explicit compositor `-c` and user config paths are
supported. Restore before changing the base path of an active managed selection.
If an external config replacement has abandoned the native wrapper, explicitly
selecting its original base path permits a new reviewed transaction.

## Build and test

Requirements: Linux; Noctalia plugin API 24; Umbriel with named presets, effect
inspection, explicit effect targets, config validation and `config-replace`;
C++20; CMake 3.20+; nlohmann/json 3.11+; toml++ 3.4+; OpenSSL Crypto; libcurl 7.85+.
Python 3.11+ is a development/test dependency. Ninja is optional.

```sh
# Optional Nix development environment:
nix-shell shell.nix
cmake -S . -B build-native -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-native
ctest --test-dir build-native --output-on-failure
noctalia plugins lint umbriel-shaders-native
```

For UI workflow tests, supply `-DLUAU_SOURCE_DIR=/path/to/noctalia/third_party/luau`
when configuring. This builds a test interpreter from Noctalia's vendored Luau;
it is not part of the installed plugin/helper. The tests exercise the actual panel
and service scripts with a simulated Noctalia host.

An optional complete-catalogue check prepares every applicable effect/use and each
family's defaults, then runs Umbriel's actual configuration validator. It uses a
synthetic peer and performs no config switching or GPU work:

```sh
cmake --build build-native --target native-catalogue-review
build-native/native-catalogue-review /path/to/catalogue.json /path/to/assets "$(command -v umbriel)"
```

For address and undefined-behaviour checks, configure a separate Debug build with
`-DENABLE_SANITIZERS=ON`, build it, and run CTest there. The private Unix-socket test
returns **skipped**, not passed, when the execution environment prohibits socket
binding. No automated test connects to the desktop compositor.

The standalone GPU test starts its own headless compositor with private state,
empty autostart and software GLES. It requires access to the host graphics stack:

```sh
python3 -B tests/real_compositor.py \
  --helper build-native/umbriel-shaders-native \
  --catalogue-index /absolute/path/catalogue.json \
  --assets /absolute/path/snapshot --all-types
```

## Install

This repository is the C++/Luau application. Python is used only by tests and the
startup benchmark; it is not a runtime dependency. The retired Python plugin,
reference tests, and backend-switching tools have been removed.

CMake installs `bin/umbriel-shaders-native` and the plugin source under
`share/noctalia/plugins`. Add that directory as a Noctalia path source and keep the
helper on Noctalia's PATH:

```sh
cmake --install build-native --prefix ~/.local
# Or build the complete Nix package:
nix-build -E 'let pkgs = import <nixpkgs> {}; in pkgs.callPackage ./package.nix {}'
```

For development, the repository root is itself a Noctalia path source. Build the
helper, then make it available either on Noctalia's PATH or at
`umbriel-shaders-native/bin/umbriel-shaders-native`. The bundled executable takes
precedence. Binaries and local installation files are ignored by Git.

The permanent local checkout is `~/dev/umbriel-shaders`. It replaces the earlier
Python checkout and the temporary native test source. The plugin ID remains
`barrulus/umbriel-shaders-native`, preserving native settings, state and widget IDs.
Enable only this source's shader plugin. On Nix, retain the helper's library store
paths through an installed package/profile or GC roots while effects are managed.

Noctalia copies plugin sources; it does not compile C++ or install the external
helper dependency. Keep the executable and its libraries available for
Disable/Uninstall cleanup and recovery.

## Transactions and recovery

The plugin keeps separate state under `native-v1` in its Noctalia data directory.
State schema 3 reads schema 2 from the cursor prototype. The state directory belongs to this native plugin.

A reviewed plan records the compositor session, active selections and fingerprints
of base/generated files. Apply checks them again, writes durable intent, validates
with the authenticated compositor's executable/environment, replaces the config,
applies explicit runtime targets and verifies shader compilation. Errors roll back;
a failed rollback retains the recovery journal. Another managed wrapper blocks
replacement. Closed-window records are pruned, and compositor restarts discard old
window identities. Unrelated external runtime changes are preserved on Undo/Restore.

The original configuration is included by a generated wrapper and is never edited.
Base presets take precedence over installed copies. Installed records contain
validated definitions with controlled shader paths, rather than downloaded include
graphs. Reused border presets resolve their actual overlay through the same
base-first resolver. Unchanged selections retain their activation recipes even if
the catalogue withdraws them or changes those recipes.

Before a preparation that may lead to Apply, the helper preserves an executable
at `native-v1/recovery`. Disable/uninstall starts that copy with `--wait-lock restore`.
If cleanup was interrupted, use the preserved helper explicitly:

```sh
/path/to/native-v1/recovery --state-dir /path/to/native-v1 \
  --socket /absolute/umbriel.sock recover
```

Use `restore` when there is no pending journal. Recovery needs neither the original
helper install path nor catalogue assets. It **does** need the executable's shared
libraries. On Nix, keep its package/profile or test-bundle GC roots until Restore
has completed. The copied executable is not a static distribution.

## Implementation and bounds

- `storage.cpp`: bounded JSON/files, fingerprints, durable replacement and locks.
- `registry.cpp`, `source.cpp`, `local.cpp`: metadata validation, HTTPS/cache access
  and native authoring generation. Downloads are bounded and have deadlines.
- `catalogue.cpp`, `selection.cpp`: projections, shared dependency resolution,
  installation, validated activation settings and family choices.
- `peer.cpp`, `runtime.cpp`: authenticated IPC, explicit targets and batched runtime
  restoration. Ordinary batches use a constant number of full status queries;
  only pool cycling and disappearing-target recovery need extra queries.
- `controller.cpp`: Review/Apply/Undo/Restore/recovery and generation lifetime.
- `diagnostics.cpp`, `main.cpp`: reports and the versioned CLI JSON protocol.
- Luau `lib/catalogue.luau`: cached UI indexes shared by gallery/family rendering.
  The service serializes operations while at most four background preview processes
  publish images individually as they finish.

There is one outstanding review, one current generation and one Undo generation.
Catalogue responses are paginated below Noctalia's 1 MiB transport ceiling. Indexes
are capped at 4 MiB, 512 effects and 64 families; individual display records and
selected file sizes are bounded. Stale cache objects are collected on Refresh;
current catalogue objects and customized installed presets are retained.

## Source layout

- `src/`: the C++ helper, shared core, catalogue, storage and transactions.
- `umbriel-shaders-native/`: Luau panel/service/widget, manifest and translations.
- `tests/`: native unit, CLI, UI workflow and private-compositor checks.
- `tools/benchmark.py`: native process-start measurements.
- `CMakeLists.txt`, `package.nix`, `shell.nix`: build, packaging and development.

The root `catalog.toml` advertises only the native plugin. Tests use synthetic
fixtures or explicitly supplied catalogue assets; no retired application is needed.

## Validation

See [VALIDATION.md](VALIDATION.md) for checks run during the in-place replacement.
The Unix-socket fixture reports a skip when sandbox restrictions prevent binding;
run it on the host to exercise IPC. The separate compositor test needs a working
graphics stack. UI tests require `LUAU_SOURCE_DIR` as described above.
