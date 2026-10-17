# Verification summary

This is a sanitized record of observed behavior as of **17 October 2026**. It is not a compatibility promise for other hardware, macOS releases, runtimes or Windows programs. Raw logs, catalogs and screenshots remain local under ignored `.artifacts/verification/` because they include personal paths and application data.

## Tested system and inputs

| Item | Recorded value |
| --- | --- |
| Hardware and OS | Apple M4 (`arm64`), macOS 26.0 (`25A354`) |
| Toolchain | Swift 6.2.3; native SwiftUI frontend |
| Desktop runtime | Gcenx Wine Stable `11.0_1`, `wine-11.0`, Intel `x86_64` through Rosetta 2 |
| Acceptance application | Official 7-Zip 26.04 Windows x64 desktop installer |
| Optional compatibility application | Official R2Beat downloader 1.0.0, Intel x86 |

Pinned inputs, publisher URLs and licenses are in [THIRD_PARTY.md](../THIRD_PARTY.md). The app does not bundle Wine or a Windows application. Alternate-runtime experiments below were isolated from the desktop acceptance configuration.

## Desktop workflow

The native frontend validated Wine, initialized a managed bottle and ran the official 7-Zip installer. Its Windows installer accepted **Install** and reported completion. The installed File Manager was saved with its working directory and literal `C:\` argument, launched from the library and responded to folder navigation.

After restarting the frontend, the Unicode bottle name, Windows 10 and diagnostic settings, executable path, working directory and argument persisted. Relaunch opened at C: and responded to navigation into Program Files. A separate shared-core launch verified an installed path and working directory containing spaces and Unicode. Selected-bottle stop and deletion left an independent control bottle intact.

These Windows UI interactions used an optional process-identity fixture because native automation could not reliably attach to unbundled Wine windows. It used the same runtime, prefix and Windows arguments but relied on undocumented macOS process-identity behavior. Ordinary production launch and Finder dispatch were checked separately; the fixture interaction remains the evidence for Windows UI responsiveness.

## Product behavior and diagnostics

| Check | Recorded result |
| --- | --- |
| Runtime and executable validation | Missing-runtime errors were actionable and preserved the working selection. A text file named `.exe` was rejected before Wine ran. A header-valid corrupt x64 PE reached the actual Wine loader and exposed a failure log. |
| Finder opening | Cold file dispatch launched a saved entry with its working directory and arguments. Unknown files prompted for a bottle; queued files waited for editors/errors. |
| Installed-app discovery | Real installed launchers appeared without automatic execution. Fixtures cover sibling GUI executables in a saved app's directory, suite members, labels, helpers, architecture checks, containment and scan limits. |
| Library clarity | Saved entries survived restart. The empty manual-scan message distinguished existing entries from additional candidates. **Show in Finder** selected the installed executable. |
| Process outcomes | Explicit Stop Bottle termination appeared as **Stopped**. Actual Wine Notepad termination retained SIGTERM (15), `wasStopped=true`, `succeeded=false` and `failed=false`. Unexpected signals, ordinary nonzero exits and timeouts remained errors. |
| Status and logs | An idle bottle showed Ready with Stop disabled. Refresh preserved that state. **Windows session active** described processes independently of download progress. Clear Log reset the displayed view while saved log bytes remained unchanged. |
| Catalog and deletion | Fixtures covered stale writers, process locking, atomic-save rollback, ownership/symlink rejection, captured deletion targets and interrupted-deletion recovery. Real-Wine checks covered prefix-scoped stop/deletion and a surviving control prefix. |
| Wine Mono diagnostics | Complete native-crash markers produced .NET/runtime guidance while preserving raw failure status and exit code. The reader was limited to the last 64 KiB of a regular log; partial markers, symlinks, successful exits, Stop, signals and timeouts retained their existing handling. |

The recorded full suite executed **120 tests: 116 passed, four opt-in Wine tests skipped, zero failures**. The three real-Wine lifecycle integration tests also passed separately. Fixture tests verify Portside's behavior; they do not establish application compatibility. A 20-bottle subprocess-fixture status refresh completed in approximately 1.3 seconds using up to four overlapping probes; this is not a real-Wine benchmark.

## Optional downloader setup

With the optional patched DXVK and CJK font setup, the R2Beat downloader rendered, opened a folder picker, transferred data and paused. Its retained payload later matched the publisher manifest and extracted files were present. Reopening the downloader at 0% did not establish lost data. A nonzero downloader exit also occurred while a separate Windows installer continued extracting files, so the direct launcher result did not describe every process in the bottle.

The real compatibility integration test passed using Wine 11.0. It installed the pinned graphics/font files in a disposable bottle, applied Windows 10 and Simplified Chinese settings, verified file hashes, receipts, registry entries and persisted readiness, then repeated setup without changing the original graphics backups. An independent control bottle remained unchanged. This test does not run the proprietary downloader or game.

Fixtures cover exact executable hash/size recognition, same-named nonmatches, missing metadata, bounded hashing, Python checks, trusted helper selection, literal paths and arguments, partial failure, captured launch targets and queued-file cancellation. The recommendation and manual Settings sheet were visually inspected in an isolated copied-source frontend. Its accessibility subtree was hidden for inspection after the inspection service crashed; that modification was not added to production. Production accessibility support for that sheet remains unverified.

## R2Beat launcher and game limits

The installed launcher and game remain unsupported. The launcher targets .NET Framework 4.7.2/WPF and crashed with Wine Mono on the configured Stable runtime. A minimal 32-bit Mono program reproduced a fault in Wine's `wow64cpu.dll`, while the 64-bit program passed. This supports a runtime/Mono failure for those tested programs; it does not establish that every 32-bit .NET configuration fails.

In isolated copied bottles, an experimental CX26 runtime passed both 32-bit and 64-bit native .NET probes after Microsoft .NET 4.8 installed successfully. The launcher still crashed in WPF graphics with default rendering. Software rendering avoided that crash during a 90-second observation, but the user confirmed that no launcher window appeared. A separate 90-second WineD3D trial also produced no verified usable interface. Native Framework installation therefore did not establish a launcher repair.

An alternate-runtime Mono trial completed the publisher update and normal game handoff. The updated game then crashed immediately after a failed lookup of `ntdll.CsrGetProcessId`; independent export checks confirmed that the tested runtimes lacked that API. No responsive game window, login, anti-cheat operation or gameplay was verified. These experiments were not promoted into Portside's runtime setup or optional compatibility pack.

## Packaging

Recorded app and DMG checks verified the intended metadata, arm64 architecture, strict ad-hoc signature validity and matching executable bytes. Compressed images passed `hdiutil verify`; read-only mounts contained the app and an `Applications` symlink to `/Applications`. These checks do not provide Developer ID signing or notarization.

Default builds omit the optional graphics/font data pack. Pack-enabled builds require an explicit `PORTSIDE_COMPATIBILITY_PACK_DIR`; see [development.md](development.md) for build and test commands. Packaging behavior does not extend the application's compatibility results.

## Reproduce

1. Follow [setup.md](setup.md) with an official Windows installer; record the OS, CPU, runtime source/version and application version.
2. Complete installation, save the installed launcher, interact with its Windows UI, restart the frontend and launch/interact again.
3. Use temporary owned bottles for validation, real loader failure, stop and deletion checks. Verify an independent control bottle remains unchanged.
4. Run `swift test`, then explicitly enable the real-Wine tests described in [development.md](development.md).
5. Build the DMG and verify it with `hdiutil verify` and `codesign --verify --deep --strict`. Mount read-only, compare its app with `dist/Portside.app`, inspect the Applications link and eject it.

Record only what was observed, distinguishing fixtures, actual process results and UI interaction. Sanitize evidence intended for publication by removing personal paths, bottle/application IDs, filenames, command arguments, tokens and unrelated screen content.
