# Umbriel Shaders

Browse community shaders and apply individual effects or coordinated families to
Umbriel from Noctalia. The plugin is entirely Luau and uses the existing `umbriel`
command; there is no helper to build or install.

## Install for testing

Use Noctalia with plugin API 43 or later and a current Umbriel installation.
Fedora and NixOS use the same plugin:

```sh
noctalia msg plugins source add umbriel-shaders git https://github.com/barrulus/umbriel-shaders
noctalia msg plugins enable barrulus/umbriel-shaders
noctalia msg panel-toggle barrulus/umbriel-shaders:shaders
```

For a local checkout, replace the source-add command with:

```sh
noctalia msg plugins source add umbriel-shaders path "$HOME/dev/umbriel-shaders"
```

If Umbriel uses a custom `-c` path, set **Original Umbriel configuration** before
applying a shader. **Selections persist when the plugin is disabled or uninstalled.**
Use **Restore original** before deleting plugin data or switching plugin IDs.

See the [plugin guide](umbriel-shaders/README.md) for requirements, usage, settings
and recovery. See [CONTRIBUTING.md](CONTRIBUTING.md) for development checks,
translations and the handoff to the official repository after approval.
