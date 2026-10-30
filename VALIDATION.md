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

The fixture suites pass 115 assertions. The real-checkout check covers 142 effects,
10 families and 148 activation bindings, including a border with an overlay.
First-party Luau passes StyLua using the repository configuration.

## Live verification of the initial Luau release

The following session tested commit `7898141`, before the PR-preparation changes.

On NixOS, the plugin was exercised through the actual Noctalia service and Umbriel:
review, apply, undo, choose, restore, and disable/re-enable passed. Umbriel reported
GPU compilation of the Diya Lights border and its window overlay. The original
configuration was unchanged, and re-enabling recognized the persisted selection.
No Fedora live session was available; Fedora uses the same source plugin and CLI.
