# Winova

Winova is a native macOS launcher for Windows applications. It provides a
Mac-first interface for selecting a Wine engine, maintaining an isolated
Windows environment, launching `.exe` and `.msi` files, and reopening recent
applications.

## Features

- Native AppKit interface for Apple Silicon Macs
- User-selectable open-source Wine engine
- Isolated prefix at `~/Library/Application Support/Winova/Prefixes/default`
- `.exe` application and `.msi` installer support
- Recent application library with one-click relaunch
- Environment configuration, local logs, and Finder access
- No telemetry or online account

## Requirements

- macOS 13 or later
- Apple Command Line Tools for building
- A compatible Wine engine for running Windows software
- Rosetta 2 when the selected engine contains Intel executables

Winova does not redistribute an engine. Select the `wine` executable from an
installed open-source Wine distribution, or place an engine at
`Winova.app/Contents/Resources/engine/bin/wine` when packaging your own build.
Redistributors are responsible for complying with the engine's license.

## Build

```sh
./scripts/build.sh
```

The application is created at `build/Winova.app` and ad-hoc signed for local
development.

## Run

```sh
./scripts/run.sh
```

On first launch, choose a Wine engine. Winova stores the chosen path locally
and uses a separate prefix, leaving other Wine environments untouched.

## Project structure

```text
Sources/Winova/       Native macOS source
Resources/            App metadata and assets
scripts/              Build and launch helpers
tests/                 Static project verification
```

## License

Winova is licensed under the MIT License. Wine is a separate project licensed
under LGPL-2.1-or-later; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
