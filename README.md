# Umbriel Shaders

A Noctalia plugin that applies community GLSL shaders to Umbriel. See the
[plugin guide](umbriel-shaders/README.md) for setup and usage, and
[CONTRIBUTING.md](CONTRIBUTING.md) for development.

## Install for testing

```sh
noctalia msg plugins source add umbriel-shaders git https://github.com/barrulus/umbriel-shaders
noctalia msg plugins enable barrulus/umbriel-shaders
noctalia msg panel-toggle barrulus/umbriel-shaders:shaders
```

For a local checkout, replace the source-add command with:

```sh
noctalia msg plugins source add umbriel-shaders path "$HOME/dev/umbriel-shaders"
```

Upgrading from 0.6 or earlier: press **Restore original** in the old version before
updating. 0.7 no longer uses a wrapper configuration.
