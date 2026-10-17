# Verification summary

This is a sanitized record of observed behavior as of **17 October 2026**, through **Portside 0.1.6 build 7**. It is not a compatibility promise for other hardware, macOS releases, runtimes, or Windows programs. Raw session logs, catalogs and screenshots remain local under ignored `.artifacts/verification/` because they include personal paths and application data.

## Tested system and inputs

| Item | Recorded value |
| --- | --- |
| Hardware and OS | Apple M4 (`arm64`), macOS 26.0 (`25A354`) |
| Toolchain | Swift 6.2.3; native SwiftUI frontend |
| Runtime | Gcenx Wine Stable `11.0_1`, `wine-11.0`, Intel `x86_64` through Rosetta 2 |
| Acceptance application | Official 7-Zip 26.04 Windows x64 desktop installer |
| Optional compatibility probe | Official R2Beat downloader 1.0.0, Intel x86 |

Pinned runtime/installer hashes, publisher URLs and licenses are in [THIRD_PARTY.md](../THIRD_PARTY.md). The app did not bundle Wine or a Windows application.

## Complete desktop workflow

The native frontend validated Wine, created and initialized a managed bottle, and ran the real publisher's 7-Zip installer. Its Windows installer window appeared, accepted **Install**, and reported completion.

The installed `C:\Program Files\7-Zip\7zFM.exe` was registered with its working directory and launched from the library. The actual Windows File Manager opened and responded to folder navigation. After quitting and restarting the frontend, the Unicode bottle name, Windows 10 setting, diagnostic setting, executable path, working directory and literal `C:\` launch argument persisted. Another launch opened at C: and responded to navigation into Program Files.

A separate shared-core launch used an installed application path and working directory containing spaces and Unicode, opened the real application, and responded to navigation. Selected-bottle stopping and deletion left a control bottle intact.

These GUI interactions used the optional Wine-window identity fixture because native automation could not reliably attach to unbundled Wine windows. The fixture used the existing runtime and application with the same prefix and arguments, but relied on undocumented macOS process-identity behavior. Normal production launch and later Finder dispatch were checked separately. Later production launch checks did not repeat Windows folder interaction; the earlier interaction is the evidence for responsiveness.

## Diagnostics and reliability

| Check | Recorded result |
| --- | --- |
| Missing runtime | Actionable setup error; failed validation preserved the working selection. |
| Invalid executable | A text file named `.exe` was rejected before Wine ran. |
| Actual failed launch | A header-valid corrupt x64 PE reached the real Wine loader, failed, and exposed a useful log. |
| Finder opening | Cold file dispatch started the frontend and launched the saved entry with its saved arguments and working directory. Unknown files prompted for a bottle. Queued files waited for editors/errors. |
| Catalog and deletion | Isolated tests covered stale writers, process locking, atomic-save rollback, ownership/symlink rejection, captured deletion targets and interrupted-deletion recovery. |
| Process lifecycle | Real-Wine tests verified selected-prefix stop, repeated idle stop, a surviving control prefix, and deletion isolation. Live frontend quit disposed wait helpers while Windows applications survived. |
| Stop control, 0.1.6 | The installed frontend showed an idle bottle as Ready, Stop Bottle disabled and Refresh Status enabled. Refresh preserved that state without launching/stopping a user application. |

The **0.1.6 full suite executed 85 tests: 83 passed, two opt-in real-Wine tests skipped, zero failures**. The two real-Wine tests separately passed during 0.1.4 reliability verification in 29.58 seconds. Later discovery/Stop-control changes did not modify the Wine process implementation. Fixture checks cover expected behavior; they do not establish Windows application compatibility.

A 20-bottle fixture status refresh completed in approximately 1.32 seconds using up to four overlapping probes. This is a subprocess-fixture measurement, not a real-Wine benchmark or a guarantee for other machines.

## Installed-app discovery and R2Beat

The read-only scanner found the actual installed `VLauncher.exe` in the R2Beat bottle in 43–59 ms and the expected 7-Zip GUI executable in a separate fixture prefix in 5–6 ms. In the installed frontend, the inline candidate card showed a readable C: path; **Add to Library** preserved the downloader while saving the installed launcher. Application entries appeared before the downloader's **Setup** entry. Detection did not automatically launch anything.

With the optional patched DXVK and CJK setup, the actual R2Beat downloader rendered, opened a folder picker, transferred data and paused. A later check found its complete publisher-manifest-matching payload and extracted game files; reopening the downloader at 0% did not mean those files had disappeared.

The subsequent installed launcher's real launch **failed**: Wine Mono 10.4.1 reported a native crash and the process exited with code 3. The launcher targets .NET Framework 4.7.2/WPF. The exact failing module and a successful fix were not established. Login, anti-cheat and gameplay remain unverified. See [compatibility.md](compatibility.md).

## Packaging

Release apps and drag-and-drop DMGs were checked for the intended version/build, arm64 architecture, strict ad-hoc signature validity and matching executable bytes. The compressed images passed `hdiutil verify`; read-only mounts contained the app and an `Applications` symlink to `/Applications`. Images were ejected after inspection. These checks do not provide Developer ID signing or notarization.

## Reproduce

1. Follow [setup.md](setup.md) with an official Windows installer; record the OS, CPU, runtime source/version and application version.
2. Complete installation, save the installed launcher, interact with its Windows UI, restart the frontend, and launch/interact again.
3. Use temporary owned bottles for missing-runtime, invalid-file, real loader-failure, stop and deletion checks. Verify an independent control bottle remains unchanged.
4. Run `swift test`, then opt into the real-Wine tests as described in [development.md](development.md).
5. Build the DMG and verify it with `hdiutil verify` and `codesign --verify --deep --strict`. Mount read-only, compare its app with `dist/Portside.app`, inspect the Applications link, and eject it.

Record what was actually observed and distinguish unit fixtures, real process results, and GUI interaction. Sanitize any evidence intended for publication: remove user paths, bottle/application IDs, personal filenames, command arguments, tokens and unrelated screen content.
