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

macOS 14 is the frontend deployment target. Earlier macOS releases, Intel Macs and other Apple silicon models have not been verified. Runtime version validation is a setup check, not a compatibility certification.

## Application results

| Application or feature | Observed result |
| --- | --- |
| 7-Zip 26.04 x64 | Official interactive installer completed; File Manager launched from the persistent library and responded to folder navigation. Relaunch after frontend restart and paths containing spaces/Unicode were verified. |
| R2Beat downloader 1.0.0, x86 | With the optional patched DXVK component and CJK setup below, rendering, folder selection, a real transfer, and pause worked. |
| Installed R2Beat `VLauncher.exe` | Unsupported. Wine Mono crashed on the configured Stable runtime. An isolated alternate runtime passed 32-bit/native .NET probes, but native .NET 4.8 and graphics comparisons did not produce a verified usable launcher. |
| R2Beat `Game.exe` 4.3.7.8, patch 00089, x86 | Unsupported. An isolated alternate runtime completed the publisher update and launched the game, which then crashed after a missing Wine API lookup. |
| R2Beat login, anti-cheat, and gameplay | No responsive game/start/login window has been verified. Reaching updater completion or starting a game process does not establish compatibility. |
| Multimedia/GStreamer | Unverified. The simple desktop workflow succeeded without GStreamer.framework; the Wine publisher lists it for multimedia support. |

Reopening a downloader is different from launching the installed application. Portside's discovery and **Setup** badge help distinguish those entries; finding an installed executable does not establish compatibility. The [verification summary](verification.md) records the observed launcher and game limits.

## Optional R2Beat graphics and fonts

The tested WineD3D drivers exposed Direct3D feature level 9.3 on the M4, while the downloader required 10.0. The opt-in **DXVK-macOS 1.10.3-portside1** component uses a source-built D3D10Core wrapper that removes a preliminary WineD3D capability check; DXVK still validates the requested device feature level. Wine's shared runtime binaries are left intact.

This experimental component is installed into one stopped, owned bottle. It is applied only through optional compatibility setup and is not enabled globally. Pack-enabled builds include its files and corresponding source; default builds omit the pack. It supplies D3D10/11 components, without D3D9 or D3D12 support. DXMT and D3DMetal are not configured.

The app recognizes the tested downloader by its exact executable fingerprint and offers **Set Up & Run** when its bottle needs the known setup. **Settings → Compatibility Setup** also provides manual setup. Python 3.9 or newer is required for the bundled helpers. A newly created bottle does not inherit another bottle's optional components; deleting and recreating a bottle requires applying setup again. Recognition does not establish general dependency detection or game compatibility. See [setup.md](setup.md#known-app-compatibility-setup).

For pack-enabled app builds, see [development.md](development.md). The [component build guide](../third_party/dxvk-compat/README.md) records pinned inputs, patches, toolchain, source archive and hashes. Its [per-bottle setup and removal guide](../third_party/dxvk-compat/SETUP.md) covers manual graphics installation. The pack also contains the pinned **Noto Sans CJK SC Regular 2.004** font. All helpers verify their pinned inputs; exact licenses and provenance are in [THIRD_PARTY.md](../THIRD_PARTY.md).

This setup establishes only the recorded downloader behavior. It does not install Microsoft .NET or repair the installed launcher and game. A Mono crash banner alone does not identify its cause. A minimal 32-bit Mono program reproduced the Stable runtime crash while its 64-bit counterpart passed, narrowing that particular failure to the tested runtime/Mono combination. That result does not establish that every 32-bit .NET configuration fails or that changing Framework versions cannot help another application.

## Product boundaries

- The supported file-opening workflow is Intel x86/x64 `.exe`; MSI packages, DLL launching, and Windows ARM binaries are outside it.
- Installed-app discovery uses bounded folder and PE-header heuristics. Per-user installs, console tools, and unusual layouts can require **Add Manually…**. A discovered executable may appear before its installer finishes.
- Each bottle retains its original runtime association. Automatic migration, a large application-profile catalog, arbitrary dependency installation, and automatic log retention are outside the MVP. The initial optional compatibility setup covers only the pinned R2Beat downloader configuration.
- Games, anti-cheat, DRM, kernel drivers, Microsoft Store applications, hardware integration, and every installer format have no general compatibility guarantee.

## Signing, security, and licenses

Builds are ad-hoc signed, without Developer ID signing or Apple notarization. A pinned checksum identifies a downloaded asset; it does not grant Apple approval. The setup scripts do not disable Gatekeeper or remove quarantine.

Portside is not sandboxed. Wine applications run with the logged-in user's access, and Wine filesystem mappings can expose host files. Bottles separate Windows configuration and data; they are **not a security boundary**. Run trusted software. Stopping or deleting a bottle cannot undo changes outside its prefix.

Portside's original code is covered by the root [MIT license](../LICENSE). Wine, optional components, Windows applications, and their dependencies retain separate licenses. The native app ships no Wine runtime or Windows application; review [THIRD_PARTY.md](../THIRD_PARTY.md) before redistributing dependencies.
