# Native replacement validation — 2026-10-30

The C++/Luau implementation is the only application in this repository. The
Python application, reference tests, comparison benchmark and backend-switching
scripts have been retired. Python remains a development/test dependency.

Validated from the flattened source layout:

- Fresh CMake Release configuration and build, with GCC 16.2 and warnings-as-errors
  on the shared core. A fresh cache removes paths from the earlier Nix environment.
- All four CTest suites passed, with no skips: transactions (170 assertions),
  private Unix-socket CLI/IPC, offline CLI, and actual Luau workflows (40 assertions).
- Private headless compositor/GPU checks passed for all five shader kinds, family
  transactions, per-slot removal, Undo and Restore.
- CMake staged installation includes the native executable, root catalogue and
  plugin scripts/resources; it contains no retired application or migration tools.
- Plugin lint: zero errors and zero warnings.
- Nix package expression parses; native-only startup benchmark runs successfully.

The UI harness simulates Noctalia; it is not a visual desktop test. A complete Nix
package build and cross-architecture distribution were not tested in this change.

The replacement was installed in `~/dev/umbriel-shaders`, preserving its Git
history. Noctalia lists the native plugin as enabled under the permanent
`experimental` path source; the temporary test source and retired Python widget
were removed. The native panel opened successfully. A bundled executable and Nix
library GC roots live in ignored local directories. Shader configuration was
restored before the source switch; no shader was applied to the desktop.
