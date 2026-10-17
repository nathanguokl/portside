# R2Beat installation and diagnostic recipe

**Status, 17 October 2026: blocked. No successful production configuration or playable game has been verified.** This recipe makes the investigation reproducible. It must not become an automatic dependency installer or a supported-game profile.

Use the unchanged client from the [official publisher](https://r2beat.xiyouxi.com/download). Keep Wine. The existing optional graphics/font setup reproduces downloader behavior only; see [compatibility](../compatibility.md). The [runtime investigation](../r2beat-runtime-investigation.md) records the separate game failure.

**Launcher root cause:** the Mono native crash on the configured Gcenx Stable 11.0_1 runtime is that runtime's own failure to execute 32-bit .NET code, shown by a program that does not involve R2Beat. Run the [32-bit .NET probe](#qualify-the-runtime-with-a-32-bit-net-probe) first. Removing Mono, installing Microsoft Framework or changing the launcher's dependencies cannot repair a runtime that fails it. The game is blocked independently, so a launcher that starts would not make R2Beat playable.

## Requirements and launch contract

| Component | Inspected requirement or behavior |
| --- | --- |
| `C:\XYX\R2beat_XYX\VLauncher.exe` | PE32, required x86, managed IL; declares `.NETFramework,Version=v4.7.2`, references WPF, WinForms and `WrapperClass`. |
| `WrapperClass.dll` | x86 mixed native/managed code targeting Framework 4.6.1; imports VC140 and `mscoree`. Consistent with C++/CLI. It is **not** involved in the recorded Mono crash, which occurs before this assembly loads. Whether it works under a runtime that gets past Mono start-up was not tested. |
| Launcher invocation | The selected bottle's `bin/wine`, absolute prefix-local `VLauncher.exe` path, **no application arguments**, working directory `C:\XYX\R2beat_XYX`. |
| Game child | Native x86 `Game.exe`, PE version 4.3.7.8. Legitimate publisher handoff uses `xyxOpen`, working directory `C:\XYX`, after publisher patch/preprocess work and a fresh publisher-written tick. Direct execution does not reproduce that handoff. |
| Other prerequisites | x86 VC140 runtime packages and `d3dx9_43.dll` were already present; publisher setup logs report success. Verify architecture/imports and loader errors before changing them. |

The metadata string `v4.0.30319` identifies CLR metadata, not a Framework 4.0 application requirement. Modern .NET, its macOS runtime and the SDK do not replace this Windows x86 Framework/WPF target. Framework **4.7.2** is the justified first native comparison, on a runtime that passes the probe below. [Microsoft documents later 4.x releases as in-place updates](https://learn.microsoft.com/en-us/dotnet/framework/install/versions-and-dependencies); that does not establish Wine compatibility or justify blindly installing 4.8.

## Qualify the runtime with a 32-bit .NET probe

The launcher is 32-bit-only, and the recorded Mono crash happens during Mono start-up, before any R2Beat assembly loads. Before application-specific work, check that the runtime can run a 32-bit .NET program at all. This probe uses only the runtime's own Wine Mono compiler, so it needs no game files, bottle copy or account. It builds one minimal program for 64-bit and for 32-bit in a new disposable prefix and runs each under a 60-second limit. From the repository root, set the absolute directory that contains the runtime's `bin/wine` and `bin/wineserver` (for a Gcenx app bundle, `.../Wine Stable.app/Contents/Resources/wine`):

```sh
PORTSIDE_RUNTIME_ROOT='/absolute/path/to/runtime-root'
mkdir -p "$PWD/.artifacts/verification"
PROBE_DIR="$(mktemp -d "$PWD/.artifacts/verification/dotnet-probe.XXXXXX")"
cat > "$PROBE_DIR/probe.cs" <<'EOF'
using System;
class Probe { static int Main() { Console.WriteLine("managed IntPtr.Size=" + IntPtr.Size); return 0; } }
EOF
MCS="$(ls -d "$PORTSIDE_RUNTIME_ROOT"/share/wine/mono/wine-mono-*/lib/mono/4.5/mcs.exe | head -n 1)"
(
  export PATH="$PORTSIDE_RUNTIME_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export WINEPREFIX="$PROBE_DIR/prefix" WINEARCH=win64 WINEDEBUG=-all,err+all
  WIN_DIR="Z:$(printf '%s' "$PROBE_DIR" | sed 's#/#\\#g')"
  wine wineboot --init
  wine "$MCS" -platform:x64 "-out:$WIN_DIR\\probe64.exe" "$WIN_DIR\\probe.cs"
  wine "$MCS" -platform:x86 "-out:$WIN_DIR\\probe32.exe" "$WIN_DIR\\probe.cs"
  perl -e 'alarm 60; exec @ARGV' wine "$PROBE_DIR/probe64.exe"; echo "64-bit probe exit: $?"
  perl -e 'alarm 60; exec @ARGV' wine "$PROBE_DIR/probe32.exe"; echo "32-bit probe exit: $?"
  wineserver -k; wineserver -w
)
```

The subshell keeps these settings out of your shell, and every Wine command addresses only the new prefix. Ignore the `err:ole` and `err:setupapi` lines printed while `wineboot` creates it, and delete `$PROBE_DIR` afterwards.

| Result | Meaning |
| --- | --- |
| 64-bit prints `managed IntPtr.Size=8` and exits 0 | Wine Mono runs 64-bit programs. This is necessary but not sufficient. |
| 32-bit prints `managed IntPtr.Size=4` and exits 0 | The runtime can run 32-bit Mono. Look for the application's own cause: its declared .NET target, mixed-mode assemblies or WPF. |
| 32-bit prints Mono's "Native Crash Reporting" banner and exits 3 | The runtime cannot run 32-bit Mono. Observed with Gcenx Stable 11.0_1. Choose a different runtime; reinstalling Mono or .NET cannot repair it. |
| 32-bit prints nothing and exits 142 when the limit expires | The runtime hangs on 32-bit Mono. Observed with Gcenx Staging 11.18. Treat as failing. |

A runtime that bundles no Wine Mono (the experimental athei build has no `share/wine/mono`) cannot use the `mcs.exe` lookup above. Copy an unchanged Wine Mono into the prefix's `C:\windows\mono\mono-2.0` and enable the builtin `mscoree` for the probe executables through that runtime's compatibility database, as the [investigation](../r2beat-runtime-investigation.md#launcher-crash-root-cause) records.

To locate a crash, run the 32-bit probe again with `WINEDEBUG=err+all,+seh,+loaddll,+timestamp,+pid,+tid`, redirect the output to a file and find the first `code=c0000005`. On Stable 11.0_1 it is `addr=7BF21139`, right after `mscorlib.dll` loads, with `wow64cpu.dll` mapped at `7BF20000`; that module is Wine's 32-bit execution layer, not Mono, the application or a redistributable. Addresses are specific to a build. [Upstream issue #160](https://github.com/Gcenx/macOS_Wine_builds/issues/160) reports the same address for a different .NET application, and its maintainer recommends CrossOver. A pass shows only that this one obstacle is absent. It does not show that the launcher, the updater or the game works.

## Preserve and reproduce

1. Save the failed Portside process log: exact Wine path/version, executable, arguments, working directory, prefix, settings, effective environment, raw exit status, signals and stop/timeout status. Preserve stdout/stderr and any `mono_crash*.json`, dumps or launcher `Log` files from the working directory. The original Mono report exited **3**. Its banner carries no stack and does not identify a missing dependency; the `+seh,+loaddll` trace in step 4 located the fault in Wine's `wow64cpu.dll`.
2. Choose **Stop Bottle**, confirm shutdown and quit the frontend. Hash the source's `system.reg`, `user.reg`, `userdef.reg`, launcher, game and relevant configs before and after testing. Copy only a stopped prefix; use its existing Wine runtime. On the same APFS volume, from the repository root:

```sh
PORTSIDE_SOURCE_PREFIX='/absolute/path/from/saved-launch-log'
PORTSIDE_RUNTIME_ROOT='/absolute/path/to/selected/runtime-root'
mkdir -p "$PWD/.artifacts/verification"
PORTSIDE_RECIPE_ROOT="$(mktemp -d "$PWD/.artifacts/verification/r2beat.XXXXXX")"
cp -cRp "$PORTSIDE_SOURCE_PREFIX" "$PORTSIDE_RECIPE_ROOT/prefix"
```

3. For every test command, use this copy as explicit `WINEPREFIX`, `WINEARCH=win64`, and the same runtime's absolute `wine`/`wineserver` paths. The launcher is x86 inside a WoW64 prefix; do not convert the existing prefix to win32. Match the captured Windows version, locale, DLL overrides and graphics components. Start with a clean environment free of unrelated `WINE*`, `DYLD_*` and `CX_*` overrides. The recorded baseline is Windows 10, `LANG=zh_CN.UTF-8`, `LC_ALL=zh_CN.UTF-8`, `MVK_CONFIG_LOG_LEVEL=0`, runtime `bin` first in `PATH`, and `WINEDEBUG=-all,err+all`.
4. Run `wine` with the copy's absolute launcher path, empty argument list and launcher directory as cwd, capturing both output streams and the exit status. Use a bounded observation window; record stalls/timeouts and subsequent cleanup separately from a natural exit. A Wine child exiting does not establish that its Windows descendants exited. Add `+timestamp,+pid,+tid,+seh,+loaddll` only for a labelled loader/exception comparison. Preserve any Mono crash report generated beside the executable.

A fresh APFS-cloned baseline reproduced the exact production launcher contract with Wine 11.0, Mono 10.4.1, win64/Windows 10/Simplified Chinese: **exit 3 after about two seconds**. A separate direct `Game.exe xyxOpen` observation with cwd `C:\XYX` remained near 100% CPU for 20 seconds and was stopped; no responsive window or fresh publisher handoff was verified. Checked original catalog, registry, executable and config hashes remained unchanged.

## Optional native Framework 4.7.2 comparison

**Do not run this comparison on a runtime that fails the 32-bit probe above.** On Gcenx Stable 11.0_1 the failure is in Wine's 32-bit execution layer, so removing Mono and installing Microsoft Framework changes nothing about it. The recorded native-Framework attempts below used that runtime. Whether their `c0000005` and high-CPU stalls share the cause was not tested, and they are not evidence about Framework 4.7.2 itself.

On a runtime that passes the probe, use another fresh copy of the stopped source, preserving the Mono baseline. This remains unsuccessful research.

1. **Remove Wine Mono from the copy before installing Framework.** Inspect the copy's `system.reg` uninstall entries in both registry views and resolve its actual Mono product GUIDs. The preserved source contained `Wine Mono Windows Support` 10.4.1, GUID `{0591009C-75D7-5F33-B5DF-4F47111155EC}`, in the 32-bit view. This is evidence for that prefix, not a universal ID. Shared `share/wine/mono` files belong to the runtime; leave the shared runtime intact.
2. Keep `WINEDLLOVERRIDES=mscoree=d` during removal and bootstrap to prevent an implicit wineboot from reinstalling bundled Mono. The following command is a template: replace the GUID only after looking it up in **this copy**, and repeat for each installed Mono Runtime/Support package actually present. Capture its status and output.

```sh
WINEPREFIX="$PORTSIDE_RECIPE_ROOT/prefix" WINEARCH=win64 \
  WINEDLLOVERRIDES='mscoree=d' \
  "$PORTSIDE_RUNTIME_ROOT/bin/wine" uninstaller --remove '{GUID from this prefix registry}' \
  > "$PORTSIDE_RECIPE_ROOT/remove-mono.log" 2>&1
```

3. Wait for this prefix's `wineserver -w`, then verify the package is absent from flushed uninstall/installer registry records. Save before/after evidence; uninstaller exit 0 alone is insufficient. Keep the disabling override active until native files are installed. If Mono reappears, stop and correct the comparison.
4. Obtain the **runtime offline installer** from [Microsoft's Framework 4.7.2 page](https://dotnet.microsoft.com/en-us/download/dotnet-framework/net472). The recorded [Microsoft input](https://download.visualstudio.microsoft.com/download/pr/1f5af042-d0e4-4002-9c59-9ba66bcf15f6/089f837de42708daacaae7c04b7494db/NDP472-KB4054530-x86-x64-AllOS-ENU.exe) is `NDP472-KB4054530-x86-x64-AllOS-ENU.exe`, 83,937,536 bytes, SHA-256 `5cb624b97f9fd6d3895644c52231c9471cd88aacb57d6e198d3024a1839139f6`. Verify the bytes and record provenance. Install with the same explicit prefix environment, capturing outer status, inner installer results and fresh Windows `dd_*.txt`/`dd_*.log` Temp files. `/log C:\portside-dotnet472-install.log` can retain a requested setup log. The earlier trial temporarily used `winecfg -v win7` for installation and restored `win10` before launching; record any such deviation.
5. Verify x86 `Framework/v4.0.30319/clr.dll`, JIT and WPF files, architecture and file versions. Then use `WINEDLLOVERRIDES=mscoree=n` for the matching launcher comparison and confirm loader logs show **native x86 CLR/JIT/WPF from this copy**, rather than Wine Mono. A `Release` key or bootstrapper exit 0 is insufficient: the original web bootstrapper skipped native setup because Mono had registered a newer compatibility version.
6. Preserve failures if native loading is incomplete. Manual `InstallRoot` edits, borrowed loader/resource DLLs and shims from another prefix are not an established installation recipe or successful repair. Do not copy them into a user bottle or automatically retry with 4.8.

## Recorded native-comparison evidence

These paths are ignored local maintainer evidence under `.artifacts/verification/r2beat-launcher-repair/`, not distributable dependencies:

1. `direct-dotnet472-result.json` records the actual order: `remove-mono` exit 0, idle, Windows-version setting, native installer exit 0. See `direct-dotnet472-remove-mono.log`, `direct-dotnet472-install.log` and `direct-dotnet472-windows-logs/`.
2. That result also records **subsequent manual `InstallRoot` edits and borrowed loader/resource files** from an earlier Framework 4.0 experiment. These augmentations qualify the later native-runtime observation; clean installation alone was not shown to produce a usable launcher.
3. `direct-dotnet472-file-versions.json` identifies native CLR/JIT **4.7.3062.0**. `direct-dotnet472-launcher.log`, `direct-dotnet472-launcher-sample.txt` and `direct-dotnet472-final-assessment.json` record native CLR loading, `c0000005` exceptions, a later near-100% CPU stall and no verified window interaction. Prefix-scoped cleanup completed and original registry hashes matched. The exact Wine/Rosetta mechanism remains unestablished.

A separate native 4.8 trial also failed. The [upstream Apple Silicon Mono regression report](https://github.com/Gcenx/macOS_Wine_builds/issues/160) matches the fault address later traced for the Mono baseline (see the probe above). It does not explain these native-Framework stalls. An isolated experimental athei CX26/Mono 10.4.1/Gecko 2.47.4 setup, which passes the 32-bit probe, completed the legitimate update to patch 00089; that is not a supported production game configuration.

## Separate acceptance gates

**Launcher:** the runtime must first pass the 32-bit .NET probe. Then verify a responsive visible launcher, normal update/check flow and legitimate handoff. An alive process, installer exit 0, Framework registry key or opening window alone does not pass.

**Game:** after the publisher's own handoff, verify a responsive game window, legitimate authenticated login and actual anti-cheat/gameplay behavior. Recorded patch 00089 tests failed to resolve `ntdll.CsrGetProcessId` and next faulted at address zero on the same thread. This strongly implicates a null function-pointer call but is not a complete causal backtrace. The lookup's return address lies in the `.themida` section of `Game.exe`, so the call comes from the executable's Themida protection layer. The game folder also ships nProtect GameGuard and `TerSafe.dll`/`TenProxy.dll`, whose names suggest Tencent's TenProtect; the latter were not analyzed. The checked runtimes lack that export; [upstream Wine's export specification](https://github.com/wine-mirror/wine/blob/master/dlls/ntdll/ntdll.spec) keeps it commented out. Framework and VC redistributables do not supply a Wine ntdll API. Supplying a fake export or bypassing protections is not part of this recipe. See the independent probe in the [runtime investigation](../r2beat-runtime-investigation.md).

No responsive game/login window, account login, anti-cheat operation or playable session has been verified. A launcher repair or one missing API might expose further requirements. Promote a configuration only after separate launcher/game interaction and restart/persistence retests pass, recording exact inputs, runtime build, settings and limitations.

After each experiment, run the selected runtime's `wineserver -k` and `-w` with **only the copy's explicit `WINEPREFIX`**, preserve logs and compare the original source hashes. Keep prefixes, private/raw logs, game files and experimental runtimes outside Git, app bundles and release archives. Do not merge research prefix changes back into production.
