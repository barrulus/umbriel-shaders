# Umbriel Shaders

A Noctalia plugin for browsing and applying the local Umbriel shader catalogue.
Choose an effect and a supported use, then Apply. Validation and installation
of missing local-checkout files happen automatically; Review remains optional. Undo, Restore original, and interrupted-operation recovery retain
the same transactional flow as the original Glow prototype.

The repository is `umbriel-shaders`; the Noctalia plugin ID is
`barrulus/umbriel-shaders`. Noctalia's source-repository layout places the plugin
in `umbriel-shaders/`, indexed by the root `catalog.toml`.

The browser shows recorded preview cards for 142 licensed effects, with visible tag chips, search, type and tag filters. Click a tag on a
card or in a shader view to browse that tag; Clear resets all filters. Cards show
up to two tags, with all tags available in the shader view. Select a card for a
larger preview and choose where to apply it. **Details** contains credits, licensing,
collection membership, configuration changes and the local-copy comparison.
Available recordings open in the system viewer through **Open recording externally**
in Details; embedded animated previews are not implemented yet. It reads a configured
local checkout; the public catalogue API has not been published. Downloads,
library updates and per-window/output rules
remain future work. Shader authoring metadata stays in `community-umbriel-shaders`;
this repository owns the consumer and local management.

The **Families** view derives ten coordinated collections from root
`families.toml` in the shader repository and composes existing member previews.
Families have no folders, copied assets or separate configuration files. Open a family to see members grouped by supported use;
selecting one opens its individual preview and Apply controls. **Apply family**
stays below the scrolling members and applies the chosen uses together. Single
options and explicit metadata defaults are preselected. When alternatives
share a use, choose one or **Keep current**; this leaves that use untouched.
Companion overlays follow their borders instead of being enabled globally.
One Undo restores the whole previous combination. A failure rolls the transaction
back, including affected runtime selections. Existing local customisations are
reused. Apply settings come from each selected shader’s existing recipe and remain
unchanged when later selecting an unrelated use. Back returns to the family, and the shader view also links to its families.
Search/type/tag filters work in both galleries.
The shader gallery initially renders 24 cards, with Show more for the next batch;
filters and search always consider all records.

The unlicensed `animation/example` is excluded. The two optional audio shader
variants in Accent Pulse and Pulse remain manual alternatives. Three overlays
are dependency-only and cannot be selected as standalone window effects.

## Run locally

Requirements: Linux, Python 3.11 or newer, Noctalia plugin API 24 or newer, and
Umbriel with named cursor presets, configuration validation, effect inspection
and `config-replace`, using the current IPC contract (tested with `11bbdc7`).
Configuration commands send string arrays in `args`; effect actions use typed
JSON fields with explicit window/output targets. Apply, Undo, Restore and the
persistent recovery helper use the same protocol. The helper checks the running
compositor's interface.

1. In Noctalia **Settings → Plugins**, add a **path** source pointing to
   `~/dev/umbriel-shaders`, then enable **Umbriel Shaders**.
2. Open the plugin's settings and set **Community shader checkout** to the local
   `community-umbriel-shaders` directory.
3. Set **Original Umbriel configuration** if startup discovery is insufficient.
   Custom `-c` paths and read-only/declarative configurations are supported.
4. Open the panel:

   ```sh
   noctalia msg panel-toggle barrulus/umbriel-shaders:shaders
   ```

   To put it on the bar, open **Settings → Bar → Widgets**, choose a section,
   and add **Umbriel Shaders** (`barrulus/umbriel-shaders:shaders-bar`). Its sparkle
   icon opens the browser. The existing Control Center shortcut is also available.
   Reload the plugin after updating so Noctalia discovers the bar widget entry.
5. Select a preview card, choose its supported use, then **Apply**. The plugin
   validates, installs missing presets and switches the selection in one operation.
   **Details** opens an optional review, including for workspace reveal shaders.

The action bar keeps the destination, Apply, Undo, Restore and Details below a
bounded scrolling area. Settings, Refresh and Close are in the header. Details
shows settings that actually change; identical before/after values are omitted.

Browsing reads and validates local catalogue metadata without installing shader
content or changing the compositor. Review uses existing local presets as-is.
Only missing presets, their required dependencies and notices are imported;
then a candidate wrapper is validated. Apply
rechecks the reviewed inputs before switching and verifies GPU compilation.

Selections accumulate across slots. Adding a border preserves a managed cursor;
choosing a different cursor replaces that cursor selection. A multi-use effect
changes only the chosen event, even if its recipe recommends several events.
The review shows all managed settings and shared prerequisites, including enabling
animations. Applying a persistent effect sets the global default and switches
current windows/outputs, handling existing runtime selections and suppression.
New windows still follow the configured default and any applicable base rules.
Companions without declared uses and effects without a recipe cannot be applied
independently. Requirements outside selected slots must already be satisfied by
the base; unresolved conflicts block Review.

The community catalogue targets latest Umbriel. Maintainers update or withdraw
incompatible shaders instead of retaining old variants. Capability tags remain
diagnostic metadata; missing runtime evidence does not require confirmation.
Known missing settings, invalid configuration, file integrity failures and shader
compilation failures still stop Apply, with rollback if switching has begun.

**Undo** restores one previous plugin selection. **Restore original** returns to
the base file's current contents. Runtime selections changed by the plugin are
journaled too: Undo/Restore recover prior selectors, runtime pool members and
suppression. Closed windows are skipped by stable ID; no action falls back to the
focused window. Runtime changes made externally after Apply are left alone when
they no longer match the plugin's last selection. Neither action edits the base file. If a named preset already exists in the base configuration, its local
shader, colours and settings take precedence. Review reports **Already exists
locally — using your local copy**. No replacement copy is installed and no local
preset definition is rewritten. A local border keeps its own overlay reference;
unused catalogue dependencies are not imported. The local preset must have the
kind required by the selected use and pass the compositor's normal validation.

**Compare with catalogue** optionally reports whether local settings and shader
bytes match the configured catalogue checkout. Differences are informational and
never block reuse. This is not an online-version check; the remote catalogue API
is still unpublished. The base path stays visible after errors.

The wrapper includes the original config and serializes only validated preset
fields and recipe settings, with absolute installed shader paths. It does not
include downloaded example configs or execute contribution code. Dependencies are
defined once; existing local definitions, including customisations, remain in the base. An
inert generation marker identifies ownership; it is never selected for rendering.

## Local catalogue and library

The plugin bundles the trusted generator/planner from the community repository
as `helper/catalogue_contract.py`. It reads root metadata when present, otherwise
uses `docs/catalogue-examples` in the configured checkout. No Python code is loaded
from that checkout. `helper/catalogue_client.py` converts the validated records
into browser entries and installation plans. Keep the bundled contract in sync
with reviewed community contract changes; its source is `tools/catalogue.py`
(SPDX MIT, copyright Barrulus 2026).

Local authoring mode includes unpublished experiments from the configured checkout.
Online publication requires explicit `publish = true` on effects and families;
that flag is independent of descriptive tags.

Local authoring mode regenerates a catalogue from source files; it does not accept
a draft JSON as a downloadable publication. File sizes and hashes bind installed
content to the generated records. Each source file has one installed copy. Adding
effects is allowed only when all existing installed files match the new catalogue;
changed or customised installed bytes block installation. There is no automatic
shader update or multiple-version store. The old Glow library and recovery records
remain supported.

## Troubleshooting

Open **Settings → Troubleshooting** in the plugin, or use **Troubleshooting**
inside a shader's **Details**. The section selector shows:

- **Overview:** whether the plugin owns the live configuration, the data folder,
  catalogue source and inspection errors.
- **Original configuration:** the base path and its currently referenced files,
  including resolved symlinks and missing optional files.
- **Managed configuration:** the generated TOML, read-only, with a warning if its
  disk contents have changed since Apply. A matching runtime generation marker
  establishes ownership; Umbriel does not expose the active configuration path.
- **Saved selections:** shader IDs and managed settings, distinguished from live
  observations. Automatic cross-session restoration is still not implemented.
- **Live state:** cursor, window and output selections, runtime overrides,
  suppression, pools and loaded shader compilation states. Changes since the
  plugin's last runtime selection are highlighted. Animation defaults are shown
  from saved settings because the live effects query does not expose them.
- **Last operation:** the latest Review, Apply, family Apply, Undo, Restore or
  Recover outcome, including validation, compilation and rollback results.

**Copy report** copies these sections as plain text. **Open data folder** opens
the plugin's persistent storage in the file manager. The report contains local
paths, generated configuration and diagnostic messages; it does not dump original
configuration files, process environments or window app IDs. Large sections are
explicitly truncated. Refreshing or copying a report never switches configuration,
installs shaders, compiles them or runs recovery.

Diagnostics still show the available disk information if Umbriel is unreachable
or state files are damaged. New operations are recorded in `last-operation.json`;
older operations cannot be reconstructed. Interrupted operations remain marked
incomplete, and logging failures do not affect Apply or recovery.

The same read-only report is available without the panel:

```sh
python3 /path/to/umbriel-shaders/umbriel-shaders/helper/umbriel_shaders.py \
  --state-dir ~/.local/state/noctalia/plugins/data/barrulus/umbriel-shaders diagnostics
```

The helper prints JSON containing `diagnostics.report_text` and the individual
sections. Custom data locations are shown in Overview.

## Recovery and lifecycle

The plugin stores its shader files, hashes, candidate configurations, selection
records and transaction journal outside the replaceable plugin directory. A
standalone recovery helper is also preserved there. The default location is:

```text
~/.local/state/noctalia/plugins/data/barrulus/umbriel-shaders/
```

Noctalia's `NOCTALIA_STATE_HOME` / `XDG_STATE_HOME` overrides change that location.
The helper serializes operations with a lock and records intent before sending
`config-replace`. A rejected switch or detected compilation failure restores the
previous configuration. A process crash leaves a journal; **Recover interrupted
operation** explicitly restores the previous known configuration. If the
compositor also restarted, recovery restores the original base.

Ordinary plugin reloads and Noctalia restarts leave active selections intact.
An Umbriel restart leaves the saved selection inactive until **Apply** is chosen again. This prototype deliberately has no automatic
startup application or networking.

Disabling/uninstalling an active plugin starts the persistent helper to restore
the base, but only while the plugin still owns the active wrapper. Cleanup
cannot be guaranteed after a crash, an interrupted apply, or removal of an
already-disabled plugin. If the panel is unavailable, recovery remains usable:

```sh
python3 ~/.local/state/noctalia/plugins/data/barrulus/umbriel-shaders/recovery.py \
  --state-dir ~/.local/state/noctalia/plugins/data/barrulus/umbriel-shaders recover
```

Use `restore` instead of `recover` for an ordinary active selection without an
interrupted-operation journal. From a TTY, pass `--socket` with the correct
absolute Umbriel socket path if the session environment is unavailable. These
commands refuse a foreign socket/session rather than guessing. If the compositor
cannot answer IPC, fix the original configuration and restart the compositor;
the plugin does not change its startup command.

## Current limits

- Shaders are imported from a local checkout. No draft catalogue is treated as an
  installable release, and nothing is fetched from GitHub or an API.
- There is one installed copy per shader. Customised files are preserved and shader
  updates are refused in this prototype. Undo changes selections, not shader bytes.
- Startup config discovery reads the socket peer's process arguments and
  environment. Umbriel does not expose its current config path, so an external
  `config-replace` **before first setup** cannot be inferred. Review the base path
  explicitly. After setup, generation markers detect loss of wrapper ownership;
  external replacements are left unchanged. To manage a replacement, explicitly
  choose its base path in settings and perform a new review; Undo then returns
  to that newly chosen base.
- One compositor socket is supported per data directory. A second session needs
  a separate state directory. A restart on the same socket is recognized by the
  process identity and boot/start time.
- Config includes are inspected with bounded size/depth and missing optional
  includes are tracked. Duplicate/cyclic includes are reported. Validation uses
  the executable and environment of the running compositor, not a different
  Umbriel found on `PATH`.
- Live compilation is checked for every selected shader and dependency. Passing
  compilation does not establish visual suitability or support for unknown API
  capabilities; those remain visible in Review.
- The compositor exposes current selectors, pool members and suppression, but not
  hidden pool-selection history. Returning to a configuration-driven pool may make
  a fresh policy choice; explicit runtime pool members are restored.
- Lifecycle cleanup is best effort. Keep the persistent data until the compositor
  no longer references it. Deleting shader files is not a disable operation.

## Development checks

```sh
python3 -m unittest discover -s tests -v
noctalia plugins lint umbriel-shaders
python3 tests/integration.py --source-root ../community-umbriel-shaders
```

The integration runner starts its own headless Umbriel with private runtime,
config and state directories and Mesa software rendering. It still requires a
usable graphics device. Runtime override checks also require `foot` to map a real
window in the private compositor. It checks Review/Apply/Undo/Restore, compilation,
interrupted commit recovery and compositor restart. It never connects to the
desktop's compositor socket.

To also load the Luau service and panel in a private Noctalia instance and verify
disable cleanup:

```sh
python3 tests/integration.py --source-root ../community-umbriel-shaders \
  --host-smoke --keep
```

Add `--pointer-client /path/to/umbriel/build-debug/tests/pointer-client` to also
exercise visual search, card selection, a long workspace review, scrolling,
single-click reveal Apply and Restore with virtual pointer clicks. Use `--host-only` for
just these panel/lifecycle checks and `--size 640x480` for the compact regression.

This needs Noctalia, `dbus-run-session` and `grim`. It isolates the shell's home,
config, data, state, D-Bus session and IPC sockets, disables networking and plugin
updates, and retains logs plus a panel capture when `--keep` is supplied. See
[validation results](VALIDATION.md) for the tested versions and remaining work.

The plugin uses the documented [manifest/identity format](https://docs.noctalia.dev/noctalia/plugins/development/manifest/),
[source repository layout](https://docs.noctalia.dev/noctalia/plugins/development/workflow/),
and [service lifecycle](https://docs.noctalia.dev/noctalia/plugins/development/entries/#cleaning-up-when-an-entry-exits).

Code is MIT licensed. Imported shaders keep their own notices; the plugin does
not relicense community content.
