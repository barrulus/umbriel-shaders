# Local catalogue validation

Backend validated on 2026-10-27; browser updated on 2026-10-28 with Python 3.14.8, Umbriel `0.1.0 (3667399)`,
Noctalia `v5.4.0 (125a30d)`, and Mesa software rendering.

- 64 helper tests pass. They cover no-op startup/status, review without apply,
  file integrity, read-only and declarative base configs, include changes,
  customised local preset reuse, wrong-kind/pool conflicts, error responses retaining
  the discovered base and recovery state, runtime overrides, external config replacements,
  interrupted commits, failed rollback, compositor identity changes and explicit
  reapplication after restart. Catalogue coverage includes multi-use recipe filtering,
  dependencies and companions, preserving selections across slots, latest-Umbriel policy without compatibility
  confirmation, blocking known missing settings, single-copy library integrity,
  prerequisites, manual-only effects and migration from the original Glow state.
  Browser tests cover validated local preview paths, absent recordings and rejected
  preview symlinks. Local reuse also covers custom overlays, skipping unused
  catalogue dependencies, informational comparison and leaving unused customised
  plugin installs alone. Runtime tests cover suppressed overrides, pool/member
  restoration, partial action failures, interrupted transactions, closed windows,
  external changes (including changes to unrelated effect kinds), sequential Apply/Undo/Restore and one-step compatibility handling.
- `noctalia plugins lint umbriel-shaders` reports zero errors and warnings.
- A private headless Umbriel session accepted the generated wrapper, selected
  Glow, and reported its shader as compiled. Undo restored the original base;
  Restore preserved edits made to that base. A second case included Glow in the
  base first: Review reused it, Apply compiled it without duplicate definitions,
  and Undo retained the original preset.
- All nine metadata-backed catalogue effects applied, compiled and restored in
  the headless compositor. Missing capability evidence does not gate Apply; all nine used one-step selection.
  Adding Flowering Vine installed its overlay dependency and preserved the cursor;
  Undo returned to the previous cursor-only selection.
- All nine effects were tested again with modified local shader bytes and local
  border/cursor settings. Review reused the local definitions, Apply compiled them,
  and Restore preserved every local config/shader byte. No replacement library
  was installed in this case.
- A real mapped window with a suppressed Heartbeat runtime override switched to
  Flowering Vine through one-step Apply. Undo/Restore recovered the previous border
  and suppression. A runtime cursor pool recovered its selector, chosen member and
  suppression. These checks used a private `foot` window, not the desktop.
- An actual invalid GLSL source failed compilation and the helper restored the
  previous configuration. The transaction journal was cleared after recovery.
- Simulated process loss after a successful config switch but before recording
  the new state left a pending journal. Explicit recovery restored the previous
  configuration. Restarting the compositor did not implicitly apply the saved
  selection; review and reapply succeeded afterward.
- A private Noctalia instance loaded the service, shortcut and panel with an
  isolated home, config, data, state and D-Bus session. The panel was opened and
  visually inspected. Virtual pointer clicks searched the preview grid for Vampire
  Blood Wash, selected its card, applied its workspace reveal in one click and restored the original configuration.
  Optional Review was then checked separately, followed by ordinary Apply and Restore.
  Selecting Flowering Vine and clicking Apply without Review also activated it, and Restore returned to the base.
  The fixed action bar remained reachable at both 1280×1024 and 640×480. Opening it installed no shader files.
  Disabling the plugin restored an active managed wrapper using the persistent recovery helper.

The integration checks used temporary sockets and configuration files, not the
running desktop. They required execution outside the sandbox for local sockets
and graphics-device access. Test artefacts for the final native check are at
`/tmp/us-test-nu4f48vt` (all shader/runtime checks and the one-click browser flow
at 640×480). Previous layout validation at 1280×1024 is retained at
`/tmp/us-test-sqh3hxq4`. These are development artefacts, not repository inputs.

The preceding 0.2.4 read-only review against the running desktop also accepted the existing customised
Flowering Vine and overlay definitions, with 13 window targets and compatible
requirements. It did not apply the selection or modify the desktop configuration.

The helper's full transaction path and the initial panel button flow were exercised.
Every filter/recording viewer combination, removal while an apply is running, abrupt host crashes,
other distributions, hardware GPU behaviour, and simultaneous independent
configuration managers have not been exhaustively tested. Ownership and input
checks narrow races but cannot provide an atomic compare-and-swap for external
`config-replace` callers. Startup config discovery cannot identify an earlier
external replacement before first setup; the user reviews the base path.

This is a local catalogue consumer for the nine metadata-backed examples. No
catalogue endpoint, remote installer, shader updater, coordinated family application,
or window-rule editor is implemented yet.
The local plugin is already enabled by the user. This change does not apply a
shader to their desktop or publish the plugin to GitHub.

The 0.2.6 browser places visible, clickable tags on cards and above detail previews.
Type, tag and text filters combine; Clear resets the search field and both filters.
Native UI checks include clicking a card tag (five horror results), clearing it,
searching for a workspace reveal and a border, one-click Apply, Details review,
and Restore. Configuration paths, dependency lists, licensing and comparisons
are available in Details; the normal shader view keeps its preview.

Final 0.2.6 UI artefacts: `/tmp/us-test-kytzkqbo` (1280×1024) and
`/tmp/us-test-10fxmcav` (640×480). Both tag chips and the tag selector were exercised,
and preview/detail header controls retained their identities across navigation.

## Full catalogue and families — 2026-10-28

Version 0.3.0 consumes the real root metadata: 138 licensed effects, ten families,
and 154 declared slot selections. 39 catalogue and 64 helper tests pass.
`/tmp/us-test-bikxrhno` records every declared selection applying, compiling and
restoring, then repeating with customised local definitions and preserved bytes.
Companion-only overlays are compiled through their parents. Failed compilation,
crash recovery and runtime override restoration checks also pass.

The family browser uses existing pack previews or member collages. Native UI
checks cover family search, grouped members, applying just the chosen workspace
member, Restore, and returning to the family page at 640×480
(`/tmp/us-test-b5sjkfaa`). Catalogue paging avoids building all 138 cards at once.
Earlier nine-effect results above are historical validation; the full catalogue
run supersedes that coverage. This verifies configuration/compilation and plugin
operations, not a fresh visual audit of every shader or all hardware drivers.

Normal-size family navigation and pagination passed at 1280×1024 in
`/tmp/us-test-qyeo0juh`: Show more advanced from 24 to 48 of 138 cards, then
search, member Apply, Restore and return-to-family all passed. Header, destination
and action controls retain stable identities when moving between views.

## Apply family — 0.3.1

70 helper tests cover one family transaction and one Undo, preserving unrelated
selections and runtime overrides, explicit alternatives and Keep current,
rejecting non-members and empty choices, companion-only activation, family
recommendations, retaining those settings on subsequent changes, and rollback
following partial runtime failure. The complete family selection is prepared and
validated before one configuration switch; the existing recovery journal covers
all affected runtime uses.

Native validation passed in `/tmp/us-test-wnpj_6a0`: all 154 individual uses,
all ten family transactions and their Undo, customised local reuse, runtime
restoration, compile-failure rollback and recovery. Real pointer clicks at
640×480 applied all five Vampire uses, undid them together and restored them.
`/tmp/us-test-qzuy92ed` repeats the UI flow at 1280×1024 and verifies the
ambiguous Ghostly Tear family cannot apply before its alternatives are chosen.


## Troubleshooting view (0.3.2)

83 helper tests pass, including read-only diagnostic snapshots, original include
inspection, exact generated TOML, saved versus live runtime selections, changed
managed files, external configurations and compositor restarts. Offline and
corrupt-state diagnostics retain the available evidence. Operation logging covers
successful validation/compilation, validation rejection, successful rollback,
failed rollback with pending recovery, interrupted operations and log-write
failure without breaking Apply. Read-only queries preserve the previous log.

Native private Noctalia/Umbriel tests passed at 640×480 and 1280×1024. Pointer
clicks opened Settings → Troubleshooting, selected Managed configuration, copied
the report and read it back through the Wayland clipboard. The report contained
the applied workspace selection and successful GPU-compilation result. A private
`xdg-open` stub verified the exact plugin data-directory argument without opening
a desktop file manager. Saved selection bytes remained unchanged by these
operations. Generated TOML scrolled while Copy report and Open data folder stayed
visible. Shader/family Apply, Undo, Restore and disable recovery still passed.

The native regression now waits for recorded operation completion and the service
callback before clicking the next button; a fixed 500 ms delay could otherwise
click Restore while Apply was still busy. Plugin lint reports zero errors and
warnings. No original user configuration or live desktop shader selection was
changed by these tests. Automatic cross-session restoration is still separate
work, and the Troubleshooting view labels it as not implemented.
