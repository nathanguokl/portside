# Setup and first launch

Portside needs a separately installed macOS Wine runtime. A purchased CrossOver installation is not required. Read the [tested compatibility limits](compatibility.md) before choosing a Windows application.

## Requirements

- macOS 14 or later is the frontend deployment target. The verified system is Apple M4 running macOS 26.0; other systems remain unverified.
- Swift 5.9 or later and Apple's developer command-line tools for building from source. Run `xcode-select --install` if the tools are missing.
- A complete macOS Wine distribution with executable `wine`, `wineboot`, and `wineserver` files in the same `bin` directory.
- Rosetta 2 on Apple silicon for the pinned Intel Wine distribution.
- Network access for the runtime and Windows application installers.

## Install the runtime and build

Run from the repository root:

```sh
bash scripts/setup-runtime.sh
bash scripts/build.sh
open dist/Portside.app
```

The setup script downloads Gcenx Wine Stable `11.0_1`, verifies the pinned archive SHA256, and installs it at:

```text
$HOME/Library/Application Support/Portside/Runtimes/Wine Stable.app
```

It preserves an existing runtime at that destination and checks its version response; it does not reverify that existing installation's original archive checksum. On Apple silicon it checks Intel execution and, if necessary, prints Apple's Rosetta installation command for you to review and run. It does not install Rosetta, remove quarantine, or change macOS security settings.

If macOS blocks Wine, review the publisher and the specific application in **System Settings → Privacy & Security**. The runtime publisher also lists GStreamer.framework for multimedia. Setup warns if it is absent and supplies the official installer URL. The tested 7-Zip workflow worked without it; multimedia was not verified. Exact sources, checksums, and dependency licenses are in [THIRD_PARTY.md](../THIRD_PARTY.md).

In **Runtime Setup**, choose a detected runtime or browse to its `.app`, runtime directory, `bin` directory, or Wine launcher. Enter its source and choose **Validate & Use**. Validation checks companion commands and `wine --version`; successful bottle initialization provides the next operational check. Linux Wine binaries cannot run on macOS.

## Create a drag-and-drop DMG

```sh
bash scripts/package-dmg.sh
```

This rebuilds the release app and creates `dist/Portside-VERSION-macOS-ARCH.dmg` with a matching `.sha256` file. Open the image, drag **Portside** onto **Applications**, eject it, then open Portside from Applications. Wine remains separate. The default build uses the build Mac's architecture; it is not a universal binary.

The app inside the DMG is ad-hoc signed, without Developer ID signing or notarization. Packaging uses Apple's command-line tools, Python 3, and a generated Finder layout. See [development.md](development.md) for build outputs and checks.

## Install and save a Windows application

1. Validate a runtime in **Runtime Setup**.
2. Choose **New Bottle**, name it, and wait for initialization. Portside creates a 64-bit prefix and applies its Windows compatibility setting. A failed initialization remains visible with **Retry Initialization**.
3. Select the bottle and choose **Install Windows App…**. Select an `.exe` installer from its official publisher and complete its Windows dialogs. The acceptance workflow used the [official 7-Zip x64 installer](https://www.7-zip.org/download.html), version 26.04.
4. After the installer finishes, choose **Find Installed Apps**. Review the suggested launcher and choose **Add to Library** or **Add & Launch**. Discovery also runs on bottle selection, after relevant tasks finish, and periodically while the selected bottle is active. Finding a file does not prove that installation has finished or that the application works.
5. If the launcher is missing, use **Add Manually…**. Select the installed `.exe`, name it, and set its working directory. Enter **one launch argument per line**. Spaces within a line are part of that argument; do not add shell quotes. Save, then choose **Launch**.
6. Quit and reopen Portside, then launch the saved entry again. Bottles, settings, runtime associations, executable paths, working directories, and arguments persist in the catalog.

Installed Windows apps live inside their bottle, rather than appearing separately in the Mac Applications folder. In an app’s **…** menu, choose **Show in Finder** to reveal its executable. **Find Installed Apps** adds suggestions for executables not already saved; “No additional launchers found” means your existing entries remain listed below.

An installer or downloader entry can reopen its setup screen after installation. Use the installed program's launcher afterward. Likely setup tools have a **Setup** badge and appear below application entries. Discovery searches up to six folder levels inside the selected bottle's C: drive and filters common helpers. Saving one executable does not hide other GUI executables in that folder; candidate labels include their executable name to distinguish them. Review each candidate: some applications need publisher-specific arguments or a different working directory. Unusual layouts and console programs may need manual registration. It never automatically executes a discovered program.

**Activity & Logs** exposes process output and results. **Refresh Status** detects surviving Wine sessions. **Stop Bottle** stops the selected bottle's tracked launchers and Wine session; it is disabled when idle, busy, or showing a dialog. An intentional termination appears as **Stopped**, with the raw signal retained in its log. Unexpected signals and nonzero application exits remain failures. Quitting Portside leaves Windows applications running.

**Clear Log** resets the displayed output and stops following that selected log. Saved diagnostic files remain available through **Open Log Folder**; select an activity again to reopen its log.

**Running** and **Windows session active** describe live processes, not installation or download progress. They remain visible while the Windows application or its background session is open. Check the Windows application's own window for progress; elapsed time alone does not establish that it is hung.

A downloader can close after starting a separate installer. Its own exit code does not describe every process in the bottle. If the Windows installer is still extracting files, let it finish before reopening the downloader. Portside retains nonzero launcher codes for diagnostics and explains this possible handoff; it does not treat every nonzero exit as successful installation.

The bottle menu provides **Rename…**, **Show Files**, and **Delete Bottle…**. Deletion confirms a captured bottle, stops it, validates its managed directory and ownership marker, then removes its files and library entries. Removing an entry from the app library only removes its shortcut; use the Windows application's uninstaller to uninstall software.

## Open executables from Finder

In **Runtime Setup → Opening Windows Apps**, choose **Make Default**, or use **Portside → Make Default for Windows Apps…**. Approve the macOS prompt if one appears. Finder **Open With → Portside** also works without changing the default. Inside Portside, **Open Windows App…** uses ⌘O.

- A unique saved executable entry uses its saved bottle, working directory, and arguments. Multiple entries for the same file present a choice.
- An unregistered executable inside an initialized managed bottle uses that bottle.
- Other executables ask which initialized bottle to use, with optional library registration. If no bottle is ready, the file stays pending during setup.

Portside checks actual Intel x86/x64 MZ/PE executable headers. An `.exe` extension alone is insufficient; damaged files, DLLs, and Windows ARM executables are rejected. Both installers and installed programs use this workflow.

macOS may request Desktop, Documents, or Downloads access before Wine creates its session. Review the request for the selected application, or move the application and its supporting files to a permitted location. To change the default manually, use Finder **Get Info → Open with → Change All**; select another handler there to change it back.

## Settings and profiles

Each bottle keeps the runtime selected when it was created. Changing the default affects new bottles. If an existing runtime is moved or removed, restore its recorded location; automatic runtime migration is outside the MVP.

Stop the bottle before changing settings. **Settings** offers Windows 7, 10, or 11 compatibility, System default/English/Simplified Chinese language, and verbose Wine logging. Language affects future processes; it does not install fonts. **Open Wine Configuration** opens the runtime's additional controls. These settings do not install a copy of Windows.

**Import Settings Profile…** loads an optional JSON preset; choose **Apply Settings** afterward. The [example profile](../profiles/windows10-desktop.json) uses this schema:

```json
{
  "name": "Windows 10 desktop",
  "windowsVersion": "win10",
  "debugLogging": false,
  "notes": "Optional dependency guidance."
}
```

`name`, `windowsVersion`, and `debugLogging` are required; `notes` is optional. The Windows values are `win7`, `win10`, and `win11`. These imported settings presets do not run scripts or install dependencies. The generic workflow requires no profile.

## Known-app compatibility setup

Opening or launching a recognized executable can offer **Set Up & Run** before Wine starts. Recognition uses exact SHA256 fingerprints from the bundled data-only compatibility profiles; it does not send executables to a server or guess requirements from a filename. Initially this covers the tested R2Beat downloader 1.0.0. A changed publisher build may not match. Unknown files continue through the generic Wine workflow.

Choose a bottle, review the recommendation, then choose **Set Up & Run**. The optional R2Beat setup installs the pinned DXVK D3D10/11 component and Noto Chinese font in that bottle, selects Windows 10 and Simplified Chinese, and then runs the original executable. Stop the bottle before applying setup. You can also open **Settings → Compatibility Setup** manually. A configured bottle does not need setup before every launch.

The app checks for **Python 3.9 or newer** in standard installation locations and offers the [official Python macOS downloads](https://www.python.org/downloads/macos/) if it is missing. Python and Wine are separate dependencies. A release containing the optional data pack can apply it without downloading the graphics/font files. A source build without the pack explains how to supply one; build it with `bash scripts/build-compatibility-pack.sh` before rebuilding the app. Only the app's bundled helpers execute; selected pack folders provide data.

Setup logs are saved in Portside's log directory. Each helper validates the managed bottle and pinned component bytes before changing files and preserves component provenance. If a later step fails, successfully installed earlier components may remain; the error identifies the incomplete step. Fix that problem before retrying. This setup reproduces the recorded downloader configuration. It does not establish that R2Beat's installed .NET launcher, login, anti-cheat or gameplay works.

## Data and troubleshooting

Data lives at `$HOME/Library/Application Support/Portside/`:

| Path | Contents |
| --- | --- |
| `library.json` | Runtime selection, bottles, settings, and launch entries |
| `Bottles/BOTTLE_UUID/` | Wine prefix and `.portside-bottle.json` ownership marker |
| `Logs/` | Runtime provenance, process arguments, Wine output, and results |
| `Runtimes/` | Runtime and provenance installed by the setup helper |

Back up the catalog and bottle directories together while their processes are stopped. Leave `.library.lock` and ownership markers in place, and do not manually move managed bottle directories. Interrupted deletion recovery preserves uncertain data and reports its location. Logs survive bottle deletion, may contain personal paths and arguments, and need manual retention management.

| Problem | Next action |
| --- | --- |
| Missing runtime | Select a complete macOS runtime in Runtime Setup; check Rosetta on Apple silicon. |
| Invalid executable | Choose an actual Intel Windows executable rather than a DLL, ARM binary, or renamed document. |
| Failed installer or launch | Open its log, verify the executable and working directory still exist, and check publisher dependencies. Enable verbose diagnostics if needed. |
| Wine Mono native crash | The error includes the raw Wine exit code and log path. Mono's banner has no stack and does not show a missing .NET install. On Apple silicon first check whether the **runtime** can run any 32-bit .NET program with the [32-bit probe](recipes/r2beat.md#qualify-the-runtime-with-a-32-bit-net-probe). Gcenx Stable 11.0_1 cannot: choose another runtime, because Mono or Framework reinstalls and graphics/font setup do not help. If the probe passes, stop the bottle and inspect the application's declared .NET target in a separate copy. For R2Beat, see the [recipe and current blocker](recipes/r2beat.md). |
| Running status looks stale | Choose Refresh Status. Portside also refreshes on activation. A launcher waiting for macOS consent still counts as running. |
| Stop fails | Inspect the shutdown-confirmation log and selected runtime. The provisional stop request may return 1 for an idle prefix; successful confirmation is required. |
| Initialization fails | Resolve the runtime/dependency error from its log, then retry initialization. |

A successful launcher exit does not prove that every application feature works. Read [compatibility.md](compatibility.md) for the observed results and unresolved R2Beat startup failures.
