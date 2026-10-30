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
- Actual panel and service scripts: search, pagination, family choices, progressive
  previews, source-change races, errors, recovery controls, and persistent selections.

The optional checkout test indexes real shader metadata and constructs activation
bindings; preview media is replaced with small fixture bytes. It checks a border
with an overlay dependency. It does not prove GPU compilation or visual appearance.

Run the commands in the README to reproduce these checks. Live compositor checks
are reported separately from fixture tests.

## Live verification — 2026-10-30

On NixOS, the plugin was exercised through the actual Noctalia service and Umbriel:
review, apply, undo, choose, restore, and disable/re-enable passed. Umbriel reported
GPU compilation of the Diya Lights border and its window overlay. The original
configuration was unchanged, and re-enabling recognized the persisted selection.
No Fedora live session was available; Fedora uses the same source plugin and CLI.
