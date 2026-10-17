# Verification summary

This is a sanitized record of observed behavior as of **17 October 2026**, including **Portside 0.1.6 build 7** desktop acceptance, **0.1.7 build 8** process checks, and **0.1.8 build 9** compatibility setup. It is not a compatibility promise for other hardware, macOS releases, runtimes, or Windows programs. Raw session logs, catalogs and screenshots remain local under ignored `.artifacts/verification/` because they include personal paths and application data.

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

The subsequent installed launcher's real launch **failed**: Wine Mono 10.4.1 reported a native crash and the process exited with code 3. The launcher targets .NET Framework 4.7.2/WPF. The failing module was later established as Wine's own `wow64cpu.dll` ([root-cause record](#mono-native-crash-root-cause-17-october-2026)); no repair was achieved on the configured runtime. Login, anti-cheat and gameplay remain unverified. See [compatibility.md](compatibility.md).


## Process outcomes, 0.1.7

Portside now distinguishes normal application exits from native terminating signals and records explicit stop intent per tracked process. An intentional Stop Bottle termination appears as **Stopped**, with the original signal retained in the log and CLI output. This is cancellation, not successful application work. Normal exit 15, an unrequested SIGTERM, timeouts, and already-exited failures remain errors.

The full suite executed **93 tests: 90 passed, three opt-in Wine tests skipped, zero failures**. All **three real-Wine integration tests** then passed separately in 69.17 seconds on the environment above. The new test initialized a disposable prefix, launched Wine's builtin Notepad, and verified that Stop Bottle ended its actual launcher with **SIGTERM (15)**, `wasStopped=true`, `succeeded=false`, and `failed=false`. The other real tests retained loader-failure diagnostics and prefix stop/deletion isolation. This check does not establish R2Beat launcher compatibility.

The native Activity view was checked in a copied-source verification host with an isolated temporary catalog and owned subprocess fixtures. Launch → Stop displayed the neutral **Stopped** row. **Clear Log** displayed the cleared placeholder and became disabled; hashes confirmed that every previously saved log file remained byte-identical. The production frontend and DMG were rebuilt with these controls. This UI fixture complements the separate real-Wine signal check above.

## Known-app setup and status, 0.1.8

The full suite executed **113 tests: 109 passed, four opt-in Wine tests skipped, zero failures**, in 29.93 seconds. The status fixture refreshed 20 bottles in 1.33 seconds. New fixtures cover exact executable hash/size recognition, same-named nonmatches, missing metadata fallback, bounded hashing, missing/old Python, trusted helper selection, literal paths and arguments, partial failure, installed payload/registry readiness, captured launch targets, queued-file cancellation, and preservation of saved arguments and working directories.

The separate **real compatibility integration test passed in 110.09 seconds** using Wine 11.0. It initialized a disposable prefix, installed the actual pinned DXVK and Noto files through the bundled helpers, applied Windows 10 and Simplified Chinese settings, and verified actual file hashes, receipts, registry entries and persisted catalog settings. Reopening the store retained configured status. A second setup left all original DLL backup hashes and the graphics receipt unchanged; a control bottle's catalog record, ownership marker and sentinel remained unchanged. This test does not run the proprietary downloader or game.

The native frontend displayed a stationary **Windows session active** indicator and explained that process activity is separate from download progress. A fresh user-created bottle was found to lack the optional components that had existed in a deleted bottle. After applying the components to that selected bottle, a later downloader launch log showed DXVK loading and selecting Direct3D feature level 10.0 on the M4. That log is evidence of graphics initialization, not proof of window responsiveness or game compatibility.

The automatic R2Beat recommendation and manual Settings entry were visually checked in a copied-source frontend with an isolated real-Wine catalog. The sheet showed the captured bottle, graphics/font/language changes, ready Python/data checks, limitations, Cancel, Run Without Setup and Set Up & Run. Cancellation returned to the saved Settings controls. The inspection service crashed while traversing the production sheet's accessibility tree, so this copied host hid that subtree from accessibility solely to permit screenshot/coordinate inspection; the production source has no such modifier. This qualifies the visual check, rather than establishing production accessibility support. Component execution, persistence and launch routing have the separate integration/fixture evidence above.

A later downloader exit code 1 occurred after the user selected **Start Game**. A separate Windows installer and `7za.exe` continued extracting the retained 41-volume archive. Two read-only samples showed approximately 1.73 GiB of file growth over 23.44 seconds with substantial extractor CPU use. This was active local extraction, not a demonstrated downloader crash or lost download. Nonzero launcher results remain recorded; the diagnostic now explains that a Windows installer may continue after its launcher exits.

## Packaging

Release apps and drag-and-drop DMGs were checked for the intended version/build, arm64 architecture, strict ad-hoc signature validity and matching executable bytes. The compressed images passed `hdiutil verify`; read-only mounts contained the app and an `Applications` symlink to `/Applications`. Images were ejected after inspection. These checks do not provide Developer ID signing or notarization.

## Reproduce

1. Follow [setup.md](setup.md) with an official Windows installer; record the OS, CPU, runtime source/version and application version.
2. Complete installation, save the installed launcher, interact with its Windows UI, restart the frontend, and launch/interact again.
3. Use temporary owned bottles for missing-runtime, invalid-file, real loader-failure, stop and deletion checks. Verify an independent control bottle remains unchanged.
4. Run `swift test`, then opt into the real-Wine tests as described in [development.md](development.md).
5. Build the DMG and verify it with `hdiutil verify` and `codesign --verify --deep --strict`. Mount read-only, compare its app with `dist/Portside.app`, inspect the Applications link, and eject it.

Record what was actually observed and distinguish unit fixtures, real process results, and GUI interaction. Sanitize any evidence intended for publication: remove user paths, bottle/application IDs, personal filenames, command arguments, tokens and unrelated screen content.

## Library clarity and Mono diagnostics, 0.1.9

Manual discovery now says “No additional launchers found. Your saved apps are listed below.” when the selected bottle already has library entries. Each saved app has **Show in Finder** in its menu to reveal the installed executable. The installed 0.1.9 frontend was restarted; the real R2Beat library entry persisted, the revised manual-scan message appeared, and Show in Finder selected the original VLauncher.exe. The packaged DMG’s executable matched the installed app and its Applications link pointed to /Applications. The installed R2Beat entry and its actual C: directory were present; an empty discovery result did not mean those files were missing.

A complete Wine Mono native-crash signature now produces specific .NET/runtime compatibility guidance for normal nonzero application exits. The reader checks only the last 64 KiB of a regular log, refuses symlinks and nonregular files, and leaves raw exit codes and failure status intact. Partial markers, successful exits, Stop, unexpected signals and timeouts retain their existing handling. The guidance wording was revised after the [root-cause investigation](#mono-native-crash-root-cause-17-october-2026).

The full suite executed **117 tests: 113 passed, four opt-in Wine tests skipped, zero failures**, in 30.17 seconds. After wording review, the three diagnostic tests passed again. These fixture tests verify Portside’s behavior; they do not establish that the game works.

Read-only inspection of the game’s original .NET 4.7.2 setup log showed that it skipped native installation because a newer compatibility version was registered. APFS-cloned prefix trials preserved the original registries. Bundled Mono 10.4.1 failed under Chinese, English and C locales; prefix-local Mono 11.3.0 also exited 3. An interpreter trial reached WPF initialization and failed during registry interop. This narrows diagnosis without proving the precise native fault or a successful game repair.

Native .NET 4.8 installation returned success in a separate copied prefix. Missing base InstallRoot values and CLR loader/message-resource files were then corrected from the verified Microsoft 4.0 prerequisite trial. Both Stable 11.0_1 and Staging 11.18 subsequently loaded native CLR and JIT but reported a nested exception on the signal stack before a usable launcher window was verified. These tests did not establish a working game configuration. Registry hashes confirmed that the original bottle was unchanged throughout.

## Other executables in a saved app folder, 0.1.10

Discovery previously preferred one executable per installation directory, then skipped that entire directory after an entry was registered. This hid the main Game.exe beside a saved VLauncher.exe and could hide other programs in an application suite. The scanner now returns all eligible GUI executables, excludes only already registered executable paths, and uses distinguishable folder/executable labels. Helper filters, protected locations, symlink containment, cancellation and scan bounds remain enforced. Discovery never launches or registers a file automatically.

The full suite executed **120 tests: 116 passed, four opt-in Wine tests skipped, zero failures**, in 31.90 seconds. All 13 focused discovery tests passed, including registered-launcher/sibling-client, shared-folder suites, architecture variants, helpers, containment, and candidate limits within one directory.

The publisher-created desktop shortcut was read independently: it targets VLauncher.exe in the installed game directory with no arguments, confirming that the saved launcher was the intended installer entrypoint. Static inspection also recovered its downstream client command: Game.exe with one argument xyxOpen and the parent XYX working directory. A copied original prefix was used to try that command while preserving the existing Patch.ini tick. The user confirmed that no game window appeared; patch/login flow equivalence and gameplay were not established. No authentication or anti-cheat checks were modified.

A final independent .NET 4.7.2 trial installed the launcher's exact target framework in another copy, but it remained busy in native CLR/SEH handling without a verified usable window. The original bottle's registry hashes remained unchanged, and each experimental prefix was stopped separately. These tests support an unresolved Wine/runtime compatibility limitation, not a successful game repair.

In the installed 0.1.10 frontend, the real game bottle visibly showed Game.exe as a discovered candidate while VLauncher remained saved. The user added the client; its entry was then saved as R2Beat Game Client with argument xyxOpen and working directory C:\XYX. These values were independently read back from the persistent catalog. A later user-triggered VLauncher failure displayed the specific Wine Mono diagnostic and raw exit3, and user-triggered Stop operations displayed Exit0/Stopped. The installed app and mounted DMG executable hashes matched and the DMG Applications link resolved to /Applications.

## Updated R2Beat client investigation

Subsequent experiments used external runtimes and private copied prefixes. No game repair was promoted into the installed frontend or its DMG. The experimental athei cx-26.3.0-9 runtime passed fresh 32-bit and 64-bit command checks. With unchanged Wine Mono 10.4.1 and matching Gecko 2.47.4, the real publisher updater completed patches 00075 through 00089. Its normal AutoStart handoff wrote a fresh tick and launched the replacement Game.exe using xyxOpen and C:\XYX. The game still reported a null-address access violation; no responsive game window was verified.

A 90-second descendant observation with a four-API Wine relay filter recorded a failed lookup of ntdll.CsrGetProcessId, STATUS_PROCEDURE_NOT_FOUND, a NULL function pointer, and immediately the same thread's null-EIP fault. This is strong evidence of a missing-API startup problem, with the inference and limits recorded in the [investigation](r2beat-runtime-investigation.md). The selected filter was verified before use; no game/protection code or authentication state was changed. Scoped cleanup stopped only the copied prefix, restored its AutoStart preference and confirmed the source metadata unchanged.

An independent original-source export probe then compiled for x86 and x64 with warnings treated as errors and ran in a fresh prefix. Both reported that ntdll and the NtQueryInformationProcess positive control were present, while CsrGetProcessId was absent with error 127. The probe never called either function pointer. Both probe runs exited 0 by design; that means the diagnostic completed, not that the target API exists. The original production bottle's three registries, Game.exe and Patch.ini retained their goal-baseline SHA-256 values. Login, anti-cheat operation, gameplay and relaunch of a functioning game after frontend restart remain unverified.

## Mono native-crash root cause, 17 October 2026

A later session traced the launcher's Wine Mono crash instead of inferring its cause. The saved `VLauncher.exe` launch was repeated in APFS copies of the production bottle with Wine's exception and DLL-load trace enabled, and a minimal C# program built with the runtime's own Mono compiler was run as 64-bit and as 32-bit on three runtimes. On Gcenx Stable 11.0_1 the first fault was `c0000005` at `7BF21139` inside Wine's `wow64cpu.dll`, right after `mscorlib.dll` loaded and before any R2Beat assembly. The 32-bit program crashed identically with exit 3 while the 64-bit one ran. The 32-bit program hung on Gcenx Staging 11.18 and ran on the experimental athei CX26 runtime. The upstream report logs the same address. The [investigation](r2beat-runtime-investigation.md#launcher-crash-root-cause) has the details and limits. Not established: the exact Rosetta mechanism, any setting that avoids the fault on Stable 11.0_1, and whether the earlier native-Framework stalls share the cause.

The documented [probe](recipes/r2beat.md#qualify-the-runtime-with-a-32-bit-net-probe) was executed exactly as written, in a new prefix under a path containing spaces: the 64-bit program exited 0 and the 32-bit program printed the Mono banner and exited 3.

Portside's Mono-crash message now says that Mono's banner has no stack and does not show a missing .NET install, that on Apple silicon the runtime itself may be unable to run 32-bit .NET programs (naming Gcenx Stable 11.0_1 and the upstream report as an example), and how to check with a minimal 32-bit program in a disposable copy before choosing another runtime or inspecting the application's .NET target. It no longer advises removing Mono or installing a Framework version. Detection, precedence of Stop, signals and timeouts, the 64 KiB tail limit and the raw exit code are unchanged, and the log path now ends the message.

The full suite executed **120 tests: 116 passed, four opt-in Wine tests skipped, zero failures**, in 31.82 seconds; the three diagnostic tests also passed when run alone. The newly built CLI launched the saved R2Beat launcher through real Wine on an isolated copy: it exited 3, reported the new message with the log path once, and Stop then completed with exit 0. The SHA-256 values, sizes and modification times of the source library, three registries, `VLauncher.exe`, `WrapperClass.dll` and `Game.exe` were unchanged. These checks verify wording and handling; they do not make the launcher or the game work. The installed 0.1.10 app and `dist/Portside.app` were neither rebuilt nor replaced and still show the previous wording, and the revised alert was not shown in the GUI.

A final isolated Windows 7 profile comparison used the documented winecfg setting with version readback and default graphics. The publisher again launched Game.exe normally; the game logged the missing CsrGetProcessId followed immediately by a null-address access violation and later the unhandled fault. The observation completed its full 90 seconds, then stopped only that test prefix and restored AutoStart. Seven checked production files and seven checked files in the updated source copy remained unchanged. The publisher's exit 0 was a handoff, not a successful game result.
