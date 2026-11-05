# Winova

Winova is a native macOS launcher for Windows applications. It provides a
Mac-first interface for selecting a Wine engine, maintaining an isolated
Windows environment, launching `.exe` and `.msi` files, and reopening recent
applications from an automatically discovered library.

## Features

- Native AppKit interface for Apple Silicon Macs
- User-selectable open-source Wine engine
- Multiple isolated environments under `~/Library/Application Support/Winova/Prefixes`
- `.exe` application and `.msi` installer support
- Automatic discovery of installed Start Menu applications
- App icons and one-click launch in the correct environment
- Manual refresh after installing or removing software
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
and uses separate environments, leaving unrelated Wine data untouched. Installed
applications appear in the library automatically; click an app icon or title to
launch it without entering terminal commands.

## Downloadable archive

Create a compressed macOS application archive and SHA-256 checksum with:

```sh
./scripts/package.sh
```

The files are written to `dist/`. The archive contains only `Winova.app`, the
documentation, and license notices. It does not include a Wine engine, installed
Windows applications, prefixes, saved sessions, or other personal data.

- [Download Winova 1.0.1 for Apple Silicon](downloads/Winova-1.0.1-macos-arm64.tar.gz)
- [SHA-256 checksum](downloads/Winova-1.0.1-macos-arm64.tar.gz.sha256)

Current archives are ad-hoc signed development builds and are not
Apple-notarized. Only open them when you trust the repository and its download
assets. See [SECURITY.md](SECURITY.md) for the current security model.

## Project structure

```text
Sources/Winova/       Native macOS source
Resources/            App metadata and assets
scripts/              Build and launch helpers
tests/                 Static project verification
downloads/             Versioned test builds and checksums
```

## License

Winova is licensed under the MIT License. Wine is a separate project licensed
under LGPL-2.1-or-later; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
