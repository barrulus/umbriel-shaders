# Validation

The executable application consists of Luau source. The C++ file in `tests/` is
an optional development-only Luau runner and is not installed with the plugin.

Automated checks exercise the actual application modules against a deterministic
Noctalia/compositor fixture:

- SHA-256 standard vectors, including one million input bytes; TOML nested tables,
  quoted keys, arrays of tables, and invalid input.
- Catalogue validation, lazy downloads, verified previews, cache repair, offline
  refresh, path traversal, dependency cycles, and host queue saturation.
- All five effect kinds, family choices, review invalidation, application, undo,
  individual-slot removal, external selections, rollback, interrupted callbacks,
  recovery, persistence across reload, and restore without catalogue files.
- Timestamp jitter across millisecond boundaries, socket replacement and reboot
  detection; exact effect/destination association of a prepared review.
- Actual panel and service scripts: search, pagination, family choices, progressive
  previews, source-change races, errors, recovery controls, and persistent selections.
  Translation fixtures load the shipped English catalog and reject missing keys;
  UI checks exercise translated substitutions and plural forms.

The optional checkout test indexes real shader metadata and constructs activation
bindings; preview media is replaced with small fixture bytes. It checks a border
with an overlay dependency. It does not prove GPU compilation or visual appearance.

Run the commands in CONTRIBUTING.md to reproduce these checks. Live compositor checks
are reported separately from fixture tests.

## PR preparation checks

The prepared package passes the official manifest validator at repository revision
`9e8da3201aed794fce6b9f3bc7422c8b35e0bcd0` and Noctalia plugin lint. A temporary
export with the proposed `noctalia/umbriel-shaders` ID also passes both checks;
no upstream repository was modified.

The fixture suites pass 189 assertions. The real-checkout check covers 148 effects,
10 families and 154 activation bindings, including a border with an overlay.
First-party Luau passes StyLua using the repository configuration.

## Startup CPU budget regression

The JSON budget fixture charges host calls deterministic time and enforces a
25 ms callback limit while four catalogue-sized serializations run concurrently.
It checks that serialization yields, completes, and preserves canonical output.
The test fails on the implementation before the startup fix.

A temporary plugin in the running Noctalia host reproduced the `update` CPU-budget
error with the 325,630-byte cached online index. With yielding JSON serialization,
the same startup loaded 136 published effects and 10 families in approximately
three seconds. The probe read a separate cache copy and did not apply shaders.

## Local catalogue performance

The local-performance fixture rejects any attempt to read preview media while
indexing or navigating. It checks timestamp jitter, persistent and in-memory cache
reuse, edit/removal invalidation, forced refresh, and selected-asset verification.
Published catalogues still require SHA-256 hashes for every asset. Only local
preview media may omit hashes; installable shader/config/notice files may not.

With the actual local checkout and Noctalia host, the old loader was still indexing
after 40 seconds and had read 18.7 MB of preview media. The revised loader indexed
148 effects and 10 families in 3.2 seconds, reopened its cache in 1.1 seconds, and
resolved family previews in under 1 ms. It read no preview media. These timings are
for the backend on this machine; they exclude the shell's image decoding/rendering.

## Local Refresh regression

The local-refresh fixture checks active shader and preset updates, retained family
animation timing, external runtime selections, revision-specific Undo, no-change
Refresh preserving Undo, and rollback after new GLSL fails compilation. It also
covers pre-upgrade installations with manually edited shader files and stale
fingerprints, rejects modified generated wrappers and edits after review, checks
retired-asset cleanup, and exercises online preservation and offline removal/restore.
The panel fixture checks preview identity changes and the local Refresh tooltip.

In the live Noctalia/Umbriel session, local Refresh completed in 6.5 seconds. All
seven installed shaders matched the checkout and compiled, while six selections
and their activation settings stayed unchanged. The previous revision retained
its manually patched files with valid rollback fingerprints; the original
configuration stayed unchanged. No-change Refresh is covered by the fixture suite.

## Live verification of the initial Luau release

The following session tested commit `7898141`, before the PR-preparation changes.

On NixOS, the plugin was exercised through the actual Noctalia service and Umbriel:
review, apply, undo, choose, restore, and disable/re-enable passed. Umbriel reported
GPU compilation of the Diya Lights border and its window overlay. The original
configuration was unchanged, and re-enabling recognized the persisted selection.
No Fedora live session was available; Fedora uses the same source plugin and CLI.


## Effect allocation coverage

`tests/luau/allocations.luau` exercises application includes loaded before the
original configuration, exact app-ID regex escaping, per-field rule precedence,
focus-dependent rules, global defaults, explicit off versus inheritance, external
runtime overrides and suppression, duration/curve overrides (including spring rejection), local refresh, generation
fingerprint checks, failed shader rollback, migration of legacy plugin-owned
runtime selections, Undo, and removal/Restore without the source catalogue.
The host fixture models literal app-ID expressions and focus matching; it does
not implement Umbriel's full regex engine. Production regex parsing and the
include syntax were additionally checked using `umbriel config validate` against
configuration files emitted by the actual plugin modules.

The panel fixture covers collapsed slot cards, exclusive expansion, nested window
rules, adding multiple applications without duplicates, removing draft and saved
assignments, compatible shader filtering, explicit application targets, reported
source and suppression, duration/curve controls and disabled actions during recovery. It does not
prove native panel layout or GPU rendering. Live selection inspection is an
explicitly refreshed snapshot; winning-rule provenance and per-application
animation settings are not currently supplied by Umbriel.

Unreferenced shader presets are accepted as saved assignments. GPU verification
is deferred until a shader becomes reachable; a reported compilation failure
still rolls back the operation.


## Community animation examples

`tests/luau/examples.luau` covers all five additional animation targets, native
Default, metadata-driven selection, dimming activation, timing changes, Undo,
Restore and incompatible destinations. Installed examples remain manageable
without a source checkout. `tests/catalogue_checkout.py` also checks the real
community entries' exact `uses` and derived activation recipes.

Example shader code lives only in `community-umbriel-shaders/animation/`. The
plugin maps slots to canonical catalogue IDs and does not inject private entries
or bypass catalogue asset verification. Previous plugin-generated copies remain
ordinary installed assets, preserving existing selections and Undo history.

The community catalogue unit tests and generator validate the `example` tag and
the bounded, slot-specific `dim` setting. Community installation validation checks
all installation examples and the combined preset library with real Umbriel.
The PNG previews are explicitly labelled CPU illustrations, not live captures;
GPU compilation and visual testing on the real animation targets remain separate.
