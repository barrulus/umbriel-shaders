# Development

The installable plugin is `umbriel-shaders/`. `panel.luau` is the UI; `lib/` holds the
logic and is covered by unit tests in `tests/`.

## Checks

```sh
nix-shell --run "python3 tests/run.py"   # or: python3 tests/run.py /path/to/luau
stylua --check umbriel-shaders tests
noctalia plugins lint umbriel-shaders
```

The tests run the real `lib/` modules with the stock `luau` CLI. They do not exercise
the panel, Umbriel or the network; check those live with a local `path` source.

## Translations and artwork

Edit only `umbriel-shaders/translations/en.json`, using nested lowercase keys and
`noctalia.tr()` with named substitutions. `python3 tools/thumbnail.py` regenerates the
illustrative card artwork (needs FFmpeg).

## Official repository submission

Copy only `umbriel-shaders/` into `noctalia-dev/official-plugins`, keep the ID
`barrulus/umbriel-shaders` unless maintainers ask otherwise, and run upstream's validator
and `noctalia plugins lint`. Do not copy this repository's root files or edit upstream's
generated `catalog.toml`.
