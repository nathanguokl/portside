# Compatibility and limitations

Portside is an MVP for installing and launching Windows desktop applications through an external Wine runtime. It does not make arbitrary Windows software compatible with macOS. The [verification summary](verification.md) separates actual application interaction from fixture tests.

## Recorded environment

Verification took place on 17 October 2026:

| Component | Tested value |
| --- | --- |
| Mac | Apple M4, `arm64` |
| macOS | 26.0, build 25A354 |
| Swift | 6.2.3 |
| Runtime | Gcenx Wine Stable `11.0_1`, reporting `wine-11.0` |
| Wine execution | Intel `x86_64` through Rosetta 2 |
| Desktop acceptance app | 7-Zip 26.04, Windows x64 |

macOS 14 is the frontend deployment target. Earlier macOS releases, Intel Macs and other Apple silicon models have not been verified. The desktop acceptance workflow used the Stable runtime above; the isolated alternate-runtime game experiments below do not extend that supported configuration. Runtime version validation is a setup check, not a compatibility certification.

## Application results

| Application or feature | Observed result |
| --- | --- |
| 7-Zip 26.04 x64 | Official interactive installer completed; File Manager launched from the persistent library and responded to folder navigation. Relaunch after frontend restart and paths containing spaces/Unicode were verified. |
| R2Beat downloader 1.0.0, x86 | With the optional patched DXVK component and CJK setup below, rendering, folder selection, a real transfer, and pause worked. |
| Installed R2Beat `VLauncher.exe` | The configured Stable runtime fails: Wine Mono's native-crash banner and exit 3. A traced run located the fault in Wine's own `wow64cpu.dll`, before any R2Beat assembly loads, and a minimal 32-bit .NET program crashes identically; the same program passes on the experimental athei CX26 runtime (see the [root cause](r2beat-runtime-investigation.md#launcher-crash-root-cause)). That isolated athei runtime with unchanged Mono 10.4.1 and matching Gecko 2.47.4 completed the publisher's normal update from patch 00075 to 00089 and launched its game child. This experimental setup is not included in Portside. |
| R2Beat `Game.exe` 4.3.7.8, patch 00089, x86 | Not runnable in the recorded tests. The normal publisher launch reached a null-address crash immediately after Wine failed to resolve `ntdll.CsrGetProcessId`. All five locally checked runtimes lack that export. See the [runtime investigation](r2beat-runtime-investigation.md). |
| R2Beat login, anti-cheat, and gameplay | No responsive game/start/login window has been verified. Reaching updater completion or starting a game process does not establish compatibility. |
| Multimedia/GStreamer | Unverified. The simple desktop workflow succeeded without GStreamer.framework; the Wine publisher lists it for multimedia support. |

The R2Beat downloader's later 0% screen did not establish lost data: its downloaded payload matched the publisher manifest and extracted game files were present. The installed desktop shortcut targets VLauncher.exe. Early direct-client trials produced no usable window; a later isolated test completed the real publisher update and normal launcher handoff with a fresh publisher-written tick, but the updated client still crashed. Reopening a downloader remains different from launching the installed application. Portside's discovery and Setup badge address that distinction; they do not supply missing Wine APIs.

## Optional R2Beat graphics and fonts

The tested WineD3D drivers exposed Direct3D feature level 9.3 on the M4, while the downloader required 10.0. The opt-in **DXVK-macOS 1.10.3-portside1** component uses a source-built D3D10Core wrapper that removes a preliminary WineD3D capability check; DXVK still validates the requested device feature level. Wine's shared runtime binaries are left intact.

This experimental component is installed into one stopped, owned bottle. It is applied only through optional compatibility setup and is not enabled globally. Releases prepared with the compatibility data pack include its files and corresponding source. It supplies D3D10/11 components, without D3D9 or D3D12 support. DXMT and D3DMetal are not configured.

The app recognizes the tested downloader by its exact executable fingerprint and offers **Set Up & Run** when its bottle needs the known setup. **Settings → Compatibility Setup** also provides manual setup. Python 3.9 or newer is required for the bundled helpers. A newly created bottle does not inherit another bottle's optional components; deleting and recreating a bottle requires applying setup again. Recognition does not establish general dependency detection or game compatibility. See [setup.md](setup.md#known-app-compatibility-setup).

For the pinned inputs, patch, exact toolchain, source archive, build hashes, and notices, see the [component build guide](../third_party/dxvk-compat/README.md). Follow its [per-bottle setup and removal guide](../third_party/dxvk-compat/SETUP.md). The build requires Python 3 and the documented MinGW toolchain; different compiler output requires an intentional component pin update.

```sh
bash scripts/build-dxvk-compat.sh
# Stop this bottle and quit Portside before applying components.
python3 scripts/setup-bottle-dxvk.py BOTTLE_UUID --component-dir .build/dxvk-compat/component
```

For Chinese glyphs, obtain the unchanged pinned **Noto Sans CJK SC Regular 2.004** font and its OFL license:

```sh
mkdir -p .artifacts/downloads/noto-cjk
curl --fail --location --output .artifacts/downloads/noto-cjk/NotoSansCJKsc-Regular.otf \
  https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf
curl --fail --location --output .artifacts/downloads/noto-cjk/OFL.txt \
  https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/LICENSE
python3 scripts/setup-bottle-cjk.py BOTTLE_UUID --font-dir .artifacts/downloads/noto-cjk
```

The font helper verifies pinned hashes. Reopen Portside and select **Simplified Chinese** in that bottle's settings. The graphics helper can restore its first DLL entries and prior overrides with `--remove`. The font helper has no removal mode; deleting a dedicated bottle removes its component and font files. Exact licenses and provenance remain in [THIRD_PARTY.md](../THIRD_PARTY.md).

These steps establish only the recorded downloader behavior. They do not resolve the later Mono/.NET launcher crash in the configured Stable runtime or the updated game's separate failure. The game’s .NET 4.7.2 prerequisite log reported a newer framework already present and skipped native installation: Wine Mono had registered that compatibility version. Locale changes and a newer prefix-local Mono did not resolve the recorded Stable crash, and the traced cause explains why: the configured runtime cannot run 32-bit .NET programs at all (see the [root cause](r2beat-runtime-investigation.md#launcher-crash-root-cause)), so no Mono or Framework change was expected to help. Separate native Microsoft .NET 4.8 and 4.7.2 comparisons also failed to reach a verified usable launcher on that runtime; those framework changes were not applied to the original bottle, and whether those failures share the cause was not tested. The [upstream report](https://github.com/Gcenx/macOS_Wine_builds/issues/160) logs the same fault address; its maintainer says the 11.0_1 packages dropped extra patches that earlier builds carried, and recommends CrossOver. A later experimental runtime reached the publisher updater, as recorded above, without establishing game compatibility.

## Product boundaries

- The supported file-opening workflow is Intel x86/x64 `.exe`; MSI packages, DLL launching, and Windows ARM binaries are outside it.
- Installed-app discovery uses bounded folder and PE-header heuristics. Per-user installs, console tools, and unusual layouts can require **Add Manually…**. A discovered executable may appear before its installer finishes.
- Each bottle retains its original runtime association. Automatic migration, a large application-profile catalog, arbitrary dependency installation, and automatic log retention are outside the MVP. The initial optional compatibility setup covers only the pinned R2Beat downloader configuration.
- Games, anti-cheat, DRM, kernel drivers, Microsoft Store applications, hardware integration, and every installer format have no general compatibility guarantee.

## Signing, security, and licenses

Builds are ad-hoc signed, without Developer ID signing or Apple notarization. A pinned checksum identifies a downloaded asset; it does not grant Apple approval. The setup scripts do not disable Gatekeeper or remove quarantine.

Portside is not sandboxed. Wine applications run with the logged-in user's access, and Wine filesystem mappings can expose host files. Bottles separate Windows configuration and data; they are **not a security boundary**. Run trusted software. Stopping or deleting a bottle cannot undo changes outside its prefix.

Portside's original code is covered by the root [MIT license](../LICENSE). Wine, optional components, Windows applications, and their dependencies retain separate licenses. The native app ships no Wine runtime or Windows application; review [THIRD_PARTY.md](../THIRD_PARTY.md) before redistributing dependencies.
