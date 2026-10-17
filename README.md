# Portside

A native macOS app for installing and launching Windows desktop applications with an external Wine runtime. Portside manages isolated bottles, interactive installers, a persistent app library, bottle settings, process status and logs. No purchased CrossOver installation is required.

The frontend targets **macOS 14+**. The verified configuration is **Apple M4, macOS 26.0, Wine 11.0**; other Macs and macOS versions are untested. The x64 **7-Zip 26.04** install, interaction and relaunch workflow passed. Windows application compatibility varies; see [tested behavior and limitations](docs/compatibility.md).

## Build and try

Install Apple's command-line developer tools (`xcode-select --install`) and use Swift 5.9 or newer. Then, from the repository root:

```sh
bash scripts/setup-runtime.sh
bash scripts/build.sh
open dist/Portside.app
```

Runtime setup downloads a pinned, checksum-verified free macOS Wine package into `~/Library/Application Support/Portside/Runtimes/`. On Apple silicon this runtime requires Rosetta 2; setup explains missing dependencies. Wine remains separate from the app. You can also select an existing compatible runtime in **Runtime Setup**.

Create a bottle, run an official Windows `.exe` installer, complete its dialogs, then use **Find Installed Apps** to add the installed program to your library. **Add Manually…** lets you set its executable, working directory and launch arguments. Choose **Launch** to run it again. [Detailed setup and troubleshooting](docs/setup.md).

For a recognized executable, Portside offers an optional **Set Up & Run** workflow for its chosen bottle. The initial compatibility profile recognizes the tested R2Beat downloader by its exact SHA256 fingerprint. Unknown applications keep the generic workflow. **Settings → Compatibility Setup** provides manual access. Applying these optional components requires Python 3; the app checks for it and explains how to install it.

The app is locally ad-hoc signed, **not Developer ID signed or notarized**. Builds target the build Mac's architecture. Review any macOS security prompt and the software publisher before running it.

## Drag-and-drop installer

```sh
bash scripts/package-dmg.sh
```

Open the generated `dist/Portside-<version>-macOS-<architecture>.dmg`, drag **Portside** onto **Applications**, then eject the image. A matching SHA256 file is generated. Wine is installed separately.

To include the optional tested graphics/font data pack in a release, first run `bash scripts/build-compatibility-pack.sh`, then package the DMG. A normal source build does not require this pack or its component build toolchain. The release app includes the component licenses and corresponding graphics source archive; see [THIRD_PARTY.md](THIRD_PARTY.md).

## Documentation

- [Setup, first install and troubleshooting](docs/setup.md)
- [Compatibility and known limitations](docs/compatibility.md)
- [Architecture, CLI, builds and tests](docs/development.md)
- [Recorded verification results](docs/verification.md)
- [Contributing](CONTRIBUTING.md)
- [Dependency provenance and third-party licenses](THIRD_PARTY.md)
- [Optional DXVK component](third_party/dxvk-compat/README.md)

## Source layout

| Directory | Purpose |
| --- | --- |
| `Sources/Portside/` | SwiftUI macOS frontend and branding |
| `Sources/PortsideCore/` | Bottle catalog, runtime validation and Wine processes |
| `Sources/PortsideCLI/` | Diagnostic command-line companion |
| `Tests/` | Core, frontend policy and opt-in Wine tests |
| `packaging/macos/` | App metadata, icons and DMG layout |
| `scripts/` | Build, packaging and optional setup helpers |
| `profiles/` | Optional data-only bottle settings |
| `third_party/` | Optional component pins, patches and license notices |
| `docs/` | Portable setup, development and verification documentation |

Generated `.build/` and `dist/` outputs are ignored. Local downloads, raw verification and recovery backups belong in ignored `.artifacts/`. User bottles, logs and the catalog live in macOS Application Support, outside the repository. Do not commit installers, runtimes, bottle data, personal logs or credentials. Build a public source archive with `python3 scripts/package-source.py`.

## Compatibility and security

Bottles separate Windows configuration and data; **they are not a security boundary**. Windows programs run with the logged-in user's access. Run software you trust.

Games, anti-cheat, DRM, Windows drivers, Microsoft Store packages and arbitrary .NET applications are outside the verified desktop workflow. The optional R2Beat downloader setup renders and downloads. The installed R2Beat launcher fails on the configured Stable runtime, which cannot run any 32-bit .NET program on Apple silicon. An experimental runtime completed the publisher update, but the updated game still crashed after requesting a missing Wine API; no responsive game window has been verified. See [compatibility](docs/compatibility.md) and the [runtime investigation](docs/r2beat-runtime-investigation.md) before relying on it.

## License

Portside's own code is available under the [MIT License](LICENSE). Third-party software retains its own licenses; see [THIRD_PARTY.md](THIRD_PARTY.md). Wine and Windows applications are installed separately. Releases built with the optional compatibility pack include its graphics/font files, notices and corresponding graphics source.
