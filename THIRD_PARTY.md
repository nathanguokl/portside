# Third-party software and provenance

Portside is a native macOS frontend. Its `.app` does not redistribute Wine, CrossOver, Windows, GStreamer, Python, or a Windows application. It launches a Wine runtime installed separately by the user. Builds that explicitly select the optional compatibility data pack include the pinned DXVK and Noto components described below, with their licenses and source provenance. Default frontend builds have no component payload, even when a local data pack exists. No purchased CrossOver installation is required. `scripts/setup-runtime.sh` can fetch the pinned free runtime below into the user's Application Support directory, checking its archive SHA256 before extraction. It does not install system packages or change Gatekeeper settings.

## Runtime used for development and verification

| Item | Recorded value |
| --- | --- |
| Mac CPU architecture | Apple Silicon, `arm64`; Wine runs as Intel `x86_64` through Rosetta 2 |
| macOS | 26.0, build 25A354 |
| Verification date | 2026-10-17 |
| Runtime publisher | Gcenx, WineHQ macOS packages |
| Package version | Wine Stable `11.0_1`, published 2026-04-16 |
| Runtime version response | `wine-11.0` |
| Package architecture | `x86_64` |
| Archive size | 185,303,032 bytes |
| Archive SHA256 | `b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388` |
| App bundle destination | `~/Library/Application Support/Portside/Runtimes/Wine Stable.app` |
| Wine executable within bundle | `Contents/Resources/wine/bin/wine` |

Sources: [publisher release and requirements](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1), [exact archive](https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz), [publisher release API with asset digest](https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/tags/11.0_1), and [Homebrew package metadata](https://formulae.brew.sh/api/cask/wine-stable.json).

The Gcenx package includes shared Wine Gecko 2.47.4 and Wine Mono 10.4.1. Its packaging repository lists freetype, GStreamer, GnuTLS, libinotify, SDL2, MoltenVK, and vulkan-loader as runtime components, using MacPorts and the publisher's MacPorts overlay. See [the packaging repository](https://github.com/Gcenx/macOS_Wine_builds). The base workflow does not install DXVK, DXMT, D3DMetal, Winetricks components, or Microsoft redistributables. The optional per-bottle DXVK and Noto CJK helpers are documented below. Their availability and compatibility are separate from the tested basic desktop workflow.

## Rosetta and GStreamer

Rosetta 2 is an Apple component, installed separately under Apple's terms. The setup script checks Intel execution with `arch -x86_64 uname -m`; if unavailable, it prints Apple's `softwareupdate --install-rosetta --agree-to-license` command for the user to run after reviewing the license. Portside does not redistribute Rosetta.

The runtime publisher lists a system-wide GStreamer.framework as a requirement. The simple desktop command workflow was observed to start on this Mac without that framework; multimedia support is not covered by that observation. Setup warns when the framework is missing and links the official universal runtime installer. It does not claim multimedia compatibility or install GStreamer automatically.

The release originally links [GStreamer runtime 1.28.1](https://gstreamer.freedesktop.org/data/pkg/osx/1.28.1/gstreamer-1.0-1.28.1-universal.pkg). The current installer linked by setup is [GStreamer runtime 1.28.6](https://gstreamer.freedesktop.org/data/pkg/osx/1.28.6/gstreamer-1.0-1.28.6-universal.pkg), SHA256 `a8eb366c59b7e9e5dc049848fed6bcd203a8878aa7517c051639fda78797c6ad`, from [Homebrew metadata](https://formulae.brew.sh/api/cask/gstreamer-runtime.json). Install it for all users under `/Library/Frameworks/GStreamer.framework` when required by an application. That package was not installed or tested as part of the recorded simple desktop workflow.

As of the recorded date, Homebrew's `wine-stable` and `gstreamer-runtime` casks report disabled since 2026-09-01 because they fail Homebrew's Gatekeeper check. The setup script therefore uses the publisher's pinned archive directly. A checksum establishes that the download matches the recorded publisher asset; it is not Apple notarization. If macOS blocks the package, review the publisher and the specific app under System Settings → Privacy & Security. The script does not remove quarantine or disable system security checks.

## Windows application selected for acceptance verification

| Item | Recorded value |
| --- | --- |
| Publisher | Igor Pavlov / 7-Zip |
| Windows application | 7-Zip 26.04, Windows x64 desktop edition |
| Publisher release date | 2026-10-05 on download page; GitHub release published 2026-10-06 |
| Installer | `7z2604-x64.exe` |
| Installer size | 1,664,082 bytes |
| Installer SHA256 | `d54bf805f9f3704d1e8db2fa3498ae7ef2df0312b40b558e7c71c734430a665d` |
| Default GUI executable | `C:\Program Files\7-Zip\7zFM.exe` |

The [official 7-Zip download page](https://www.7-zip.org/download.html) links to [this exact x64 installer](https://github.com/ip7z/7zip/releases/download/26.04/7z2604-x64.exe). The [publisher's release API](https://api.github.com/repos/ip7z/7zip/releases/tags/26.04) records the digest and size. The installer is a separately downloaded verification fixture, not an app bundle resource. See [the verification summary](docs/verification.md) for which acceptance steps actually passed; selection and provenance alone do not establish that installation or interaction succeeded.

## Licenses and any future redistribution

Wine is licensed under [GNU LGPL 2.1 or later](https://raw.githubusercontent.com/wine-mirror/wine/master/LICENSE). The package's dependencies, Wine Mono, Wine Gecko, and graphics libraries retain their respective notices and licenses. The modified Wine source is maintained in [Gcenx/wine](https://github.com/Gcenx/wine); anyone preparing a redistributed package should retain the exact corresponding sources and build changes for that binary, rather than assuming that the current branch is the matching source.

Portside currently invokes this external software as a separate process. If a later release bundles or redistributes a runtime, preserve each component's copyright and license notices, provide the corresponding source or other source delivery required by its license, include modifications and build material where required, and preserve users' ability to replace or modify LGPL components as applicable. Review every included dependency and optional codec; the aggregate package cannot accurately be described as having only one license. [GStreamer's licensing documentation](https://gstreamer.freedesktop.org/documentation/frequently-asked-questions/licensing.html) explains the LGPL core and the additional considerations around plugin dependencies and multimedia codecs.

7-Zip has its own [license information](https://www.7-zip.org/license.txt), including LGPL, BSD, and unRAR restrictions for relevant portions. Windows programs, Microsoft components, Apple components, and third-party application installers remain subject to their own licenses. Access to Portside's source does not grant rights to redistribute those dependencies. This file records dependency provenance and release engineering requirements; no third-party dependency is relicensed by the frontend.

## Optional graphics and Chinese font components

The native Compatibility Setup feature applies these components only to a selected stopped, managed bottle after the user chooses a profile. Trusted helper source and profile metadata are bundled with every frontend build. Build the optional data pack with `scripts/build-compatibility-pack.sh`, then set `PORTSIDE_COMPATIBILITY_PACK_DIR` to its absolute directory when running `scripts/build.sh` or `scripts/package-dmg.sh`. Only those explicitly configured builds copy its validated data into `Contents/Resources/Compatibility/Components` and `Fonts`, with the source archives and notices. An externally selected pack supplies data only: Portside executes the helpers from its own app bundle, never scripts from that selected folder. Python 3 is a separately available dependency and is checked before setup.

- **DXVK-macOS 1.10.3-portside1:** upstream [v1.10.3-20230507-repack](https://github.com/Gcenx/DXVK-macOS/releases/tag/v1.10.3-20230507-repack), source commit `8f1e28deed3ad30802f7e1bdff428ec14e6e7817`. The two D3D11 DLLs are unchanged upstream binaries. The two D3D10Core DLLs are altered source builds removing a preliminary WineD3D-backed adapter check; DXVK's own feature validation remains. [Exact inputs, patch, full zlib/libpng license, attribution, and toolchain notices](third_party/dxvk-compat/README.md) accompany the source. Both the bundled component directory and `Portside-DXVK-Compat-1.10.3-portside1.tar.gz` include the full pinned source archive, upstream binary input archive, exact patch, reproduction scripts, upstream license, Portside MIT license, and MinGW-w64/GCC runtime notices. Compiler runtime support is statically linked as recorded in those notices. The pack builder verifies the four DLL hashes and the two input archive hashes before packaging. It provides no D3D9 or D3D12 support. Wine and its bundled MoltenVK remain external.
- **Noto Sans CJK SC Regular 2.004:** [official Noto CJK repository](https://github.com/notofonts/noto-cjk), commit `f8d157532fbfaeda587e826d4cd5b21a49186f7c`, distributed unchanged under [SIL Open Font License 1.1](https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/LICENSE). Font SHA256 `2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b`; OFL text SHA256 `6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2`. The unchanged font, exact OFL text, and pinned publisher URLs are included together in a prepared app/data pack and stored alongside the installed component. No proprietary Microsoft font is included.
- **R2Beat downloader 1.0.0:** the official `downloader.exe`, obtained from the [official publisher download page](https://r2beat.xiyouxi.com/download), is a separately supplied proprietary verification fixture. SHA256 `1655e25f7ae84ea0b7ec001cfa5d237cded583341b892d3a44fecdf98118530a`, publisher-listed MD5 `b7ccd93f8ad0f41af900a335117b7375`, 664,472 bytes, x86 PE32. It is not redistributed in the app or setup archives. Downloader success does not establish game or anti-cheat compatibility.
