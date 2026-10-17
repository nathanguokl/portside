# Development

Portside is a Swift Package Manager project with a small SwiftUI frontend and a shared process/persistence core. Start with [setup.md](setup.md) for runtime installation and a complete Windows application workflow.

## Layout

| Path | Responsibility |
| --- | --- |
| `Sources/Portside/` | SwiftUI views, AppKit file-opening lifecycle, frontend state and installed-app review |
| `Sources/PortsideCore/` | Codable models, catalog locking/recovery, runtime and PE validation, Wine processes and app discovery |
| `Sources/PortsideCLI/` | Diagnostic CLI using the same core and catalog |
| `Tests/PortsideAppTests/` | Frontend state/queue/runtime/discovery/Stop regressions with isolated fixtures |
| `Tests/PortsideCoreTests/` | Core safety, persistence, validation and process tests; opt-in real-Wine checks |
| `Tests/Fixtures/` | Deliberate test data, without a redistributed Windows application |
| `packaging/macos/` | App Info.plist, icon assets and DMG Finder layout |
| `Sources/Portside/Resources/Branding/` | SwiftPM frontend branding resource bundle |
| `profiles/` | Optional settings-profile examples |
| `third_party/` | Optional component source inputs, patches, notices and reproduction guides |

Wine commands use `Process` with argument arrays and explicit prefixes, rather than assembled shell command strings. Filesystem discovery runs off the main actor, bounds its work, and discards stale selections. Catalog writers acquire a nonblocking process lock, reload the latest state, then save atomically. A busy catalog returns a retryable error.

## Build and test

```sh
swift build
swift test
bash scripts/build.sh
```

The debug build and default test suite need no Wine installation. Tests use temporary catalogs, prefixes and owned process fixtures. The real-Wine integration tests are skipped unless explicitly enabled:

```sh
PORTSIDE_TEST_WINE="$HOME/Library/Application Support/Portside/Runtimes/Wine Stable.app/Contents/Resources/wine/bin/wine" \
  swift test --filter RealWineIntegrationTests
```

Those tests create isolated temporary prefixes and exercise actual Wine loader failure and prefix-scoped stop/delete behavior. They do not install or interact with a third-party GUI application. Manual acceptance steps and recorded results are in [verification.md](verification.md).

To exercise the optional compatibility helpers with real Wine, first build the data pack and app, then opt into the separate integration test:

```sh
bash scripts/build-compatibility-pack.sh
PORTSIDE_COMPATIBILITY_PACK_DIR="$PWD/.build/compatibility-pack" bash scripts/build.sh
PORTSIDE_TEST_WINE="$HOME/Library/Application Support/Portside/Runtimes/Wine Stable.app/Contents/Resources/wine/bin/wine" \
PORTSIDE_TEST_COMPATIBILITY_RESOURCES="$PWD/dist/Portside.app/Contents/Resources/Compatibility" \
  swift test --filter RealCompatibilityIntegrationTests
```

This creates disposable prefixes, applies the real pinned components and settings, checks persisted readiness and an unchanged control bottle, and repeats setup to verify that original backups remain intact. It does not download a game or certify the R2Beat launcher.

Release outputs:

| Command | Output |
| --- | --- |
| `bash scripts/build.sh` | `dist/Portside.app`; CLI at `.build/release/portside-cli` |
| `bash scripts/package-dmg.sh` | Rebuilt app, `dist/Portside-VERSION-macOS-ARCH.dmg`, and checksum sidecar |
| `python3 scripts/package-source.py` | Public source only in `dist/Portside-VERSION-source.zip`, and checksum sidecar |
| `bash scripts/build-dxvk-compat.sh` | Optional `.build/dxvk-compat/component/` and source-inclusive component archive in `dist/` |
| `bash scripts/build-compatibility-pack.sh` | Optional graphics/font data pack at `.build/compatibility-pack/` |

`build.sh` copies the Info.plist, icon, resource bundle, MIT license and dependency notice into the app, then ad-hoc signs it. Builds use the host architecture. The DMG script rebuilds the app before packaging; avoid copying `dist/Portside.app` while that script runs. Developer ID signing, notarization, and universal builds are not configured.

Compatibility profile metadata and trusted Python helper source are bundled by the app build. A generated compatibility data pack is optional and remains outside the tracked source tree. Default app and DMG builds omit it, even when a previously built pack exists. Select the pack explicitly for either output:

```sh
PORTSIDE_COMPATIBILITY_PACK_DIR="$PWD/.build/compatibility-pack" bash scripts/build.sh
PORTSIDE_COMPATIBILITY_PACK_DIR="$PWD/.build/compatibility-pack" bash scripts/package-dmg.sh
```

The native runner discovers a suitable Python without a shell, executes only the bundled helper scripts with argument arrays, captures bounded output to a saved log, and reports partial installation honestly. The helpers enforce their pinned payload hashes, bottle ownership and stopped-state checks. Exact executable fingerprints select recommendations; filename heuristics do not select component installs. Python is not needed for the generic install-and-launch workflow.

Run `python3 scripts/package-source.py --list` to review source archive inputs. The packager uses an explicit allowlist, excludes local history, artifacts, environment/signing files and compiled runtimes, and never follows symbolic links. Entries use sorted paths and fixed timestamps/permissions; unchanged inputs produce identical ZIPs with the same Python/zlib implementation. Application icons and branding assets are included as source inputs.

Local downloads, backup bundles, raw logs, catalogs and screenshots belong under ignored `.artifacts/`, not in source. `.build/` and `dist/` are generated. See [branding.md](branding.md) for asset locations.

## CLI

The CLI reads the same default catalog as the app. Use `--help` for current syntax:

```text
portside-cli runtime [PATH]
portside-cli list
portside-cli create NAME
portside-cli install BOTTLE_UUID EXE [installer arguments…]
portside-cli register BOTTLE_UUID NAME EXE [--working-directory DIR] [-- launch arguments…]
portside-cli launch APP_UUID
portside-cli stop BOTTLE_UUID
portside-cli rename BOTTLE_UUID NAME
portside-cli delete BOTTLE_UUID
portside-cli settings BOTTLE_UUID win10|win11|win7 debug|quiet [system|en_US.UTF-8|zh_CN.UTF-8]
```

`runtime PATH` validates and saves a selection; without PATH it tries the saved runtime and detected candidates. `list` reports bottle and launch-entry IDs. Replace the placeholders below with IDs from its JSON output:

```sh
.build/release/portside-cli runtime "$HOME/Library/Application Support/Portside/Runtimes/Wine Stable.app"
.build/release/portside-cli create "Desktop Apps"
.build/release/portside-cli list
.build/release/portside-cli install BOTTLE_UUID "$HOME/Downloads/7z2604-x64.exe"
# After completing the Windows installer:
.build/release/portside-cli register BOTTLE_UUID "7-Zip" \
  "$HOME/Library/Application Support/Portside/Bottles/BOTTLE_UUID/drive_c/Program Files/7-Zip/7zFM.exe" \
  --working-directory "$HOME/Library/Application Support/Portside/Bottles/BOTTLE_UUID/drive_c/Program Files/7-Zip" -- 'C:\'
.build/release/portside-cli launch APP_UUID
```

Quote terminal paths/names containing spaces. Arguments after `--` are saved literally; this terminal quoting differs from the frontend's one-argument-per-line editor. Registration defaults the working directory to the executable's parent if omitted.

Successful operations emit JSON. Process commands emit separate started/finished objects, not one JSON document. Finished events preserve `exitCode`, include `terminationSignal` when terminated by a signal, and expose `wasStopped` for an intentional stop by that process manager. `succeeded` remains strict: a stopped installer is not a completed installation. Stop intent from another frontend/CLI instance cannot be inferred from signal 15 alone. Failures emit an error object on stderr and return status 1. Install/launch waits for the direct Wine launcher; background Windows processes can survive it. Use `stop` from another terminal to stop that bottle. Avoid simultaneous installation, configuration, or deletion in the same prefix.

## Environment and isolated diagnostics

| Variable | Scope |
| --- | --- |
| `PORTSIDE_HOME` | CLI-only Application Support root override; the native app keeps its normal data location |
| `PORTSIDE_TEST_WINE` | Wine launcher for opt-in real-Wine tests |
| `PORTSIDE_WINE_UI_BUNDLE` | Optional automation-only identity wrapper; leave unset for ordinary use |
| `PORTSIDE_DXVK_BUILD_DIR` | Optional component build/download directory; defaults to `.build/dxvk-compat` |
| `PORTSIDE_COMPATIBILITY_PACK_DIR` | Explicit data-pack input for app/DMG builds; unset omits the pack |
| `PORTSIDE_TEST_COMPATIBILITY_RESOURCES` | Built app's Compatibility resource directory for the opt-in helper integration test |

For a temporary CLI catalog:

```sh
export PORTSIDE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/portside-check.XXXXXXXX")"
.build/release/portside-cli list
```

Keep that export only for commands intended to share the temporary catalog, then `unset PORTSIDE_HOME`. Runtime discovery still searches standard runtime locations. A temporary catalog does not sandbox Wine or an application you explicitly run.

For native GUI automation, close the frontend first and run `bash scripts/ui-verification-host.sh`. It creates an ignored Wine identity wrapper and starts the same frontend with `PORTSIDE_WINE_UI_BUNDLE`. The fixture uses macOS's undocumented `CFProcessPath` behavior to help tooling attach to Wine's unbundled windows. It changes neither Wine binaries nor Windows arguments and is unnecessary for manual use. See [verification.md](verification.md) for the qualification on recorded GUI observations.
