# R2Beat runtime investigation

Status on 17 October 2026: **Game.exe has not reached a verified responsive game window.** The installed files and saved library entry exist, but the tested Wine runtimes cannot yet run this client successfully. Reinstalling the downloader is not an established repair. The launcher's Mono crash on the configured Stable runtime has since been traced to that runtime's own 32-bit support ([Launcher crash root cause](#launcher-crash-root-cause)); a runtime that fixes it still would not unblock the game.

## Launcher error audit

The current saved launch was independently reproduced on this Mac using an APFS copy of the production prefix and the current Portside CLI. The original catalog, three registry files, launcher, game, wrapper and top-level INI/configuration files matched their before/after SHA-256 hashes. No dependency or runtime changes were made to the production bottle. The copied session was stopped using its explicit prefix.

| Launch control | Recorded value |
| --- | --- |
| Command | Selected Wine Stable.app's `Contents/Resources/wine/bin/wine`, verified `wine-11.0` |
| Executable | `C:\XYX\R2beat_XYX\VLauncher.exe` (passed to Wine as the copied absolute Unix path) |
| Additional arguments | None |
| Working directory | `C:\XYX\R2beat_XYX` |
| Prefix | Separate APFS clone; `WINEARCH=win64`, Windows 10, prefix-local Mono 10.4.1 |
| Effective environment | `LANG=LC_ALL=zh_CN.UTF-8`, `WINEDEBUG=-all,err+all`, `MVK_CONFIG_LOG_LEVEL=0`; PATH starts with the selected runtime's bin followed by standard macOS/Homebrew paths |
| Result | Normal Wine exit **3**, Mono native-crash banner after approximately two seconds |

Wine's output is also the available Mono crash report: it says an unknown native error occurred, without a usable native/managed backtrace or a named missing assembly. No separate Mono crash dump was found. It does **not** establish which native library failed, or that installing a redistributable will repair the fault. A later traced run did locate the fault; see [Launcher crash root cause](#launcher-crash-root-cause). The [runtime maintainer's regression report](https://github.com/Gcenx/macOS_Wine_builds/issues/160) logs the same fault address.

Independent PE inspection found:

- `VLauncher.exe`: x86 PE32, CLR metadata `v4.0.30319`, CLR flags `0x20003`, explicit `.NETFramework,Version=v4.7.2`, and WPF references. SHA-256 `c4c10d4b968e5fd0dc8c3c680f58c5cfddb19c32fffc57ae042b39dd97bedf78` (18,485,144 bytes).
- `WrapperClass.dll`: x86 mixed-mode CLR image, flags `0x10`, Framework 4.6.1 target and VC140/UCRT imports. This introduces a concrete compatibility concern; static metadata alone does not establish that it caused the crash. The later trace shows the crash occurs before this assembly loads, so it did not cause it.
- Original `Game.exe`: native x86, no CLR directory. SHA-256 `de0e2f2bca0fe8ba2d459c85b829f6458f27870d6a0742afb3f1e00c6927b1e8` (242,948,504 bytes).

The launcher needs **.NET Framework 4.7.2**, rather than modern .NET. CLR metadata version 4 alone would not distinguish the precise Framework release; its target attribute does. The original 4.7.2 prerequisite log reports an equal/newer framework and skips installation: Mono has registered a compatibility `Release` value. A registry version or installer exit 0 therefore does not prove Microsoft CLR is installed.

The retained native-Framework trial's ordered logs were independently checked: Mono removal exited 0 **before** the Microsoft 4.7.2 offline installer ran; that installer exited 0. The copied prefix has no `windows/mono`, and contains native x86/x64 CLR 4.7.3062.0. Subsequent experiments also supplied genuine base framework shims and repaired missing `InstallRoot` registry values. Native CLR then loaded, but the launcher stalled at high CPU with `c0000005`/Wine SEH handling; no usable window was verified. This augmented experiment is not a clean supported installation recipe. A prepared native-4.7.2/athei fixture was marked unexecuted and supplies no additional validation. The prior 4.8 comparison likewise established no usable launcher; neither version is a production fix.

The original VC++ x86 prerequisite log records successful installation of its VC140 packages (14.16.27024). Imported `msvcp140`, `vcruntime140`, UCRT and `d3dx9_43` files are present. Their presence does not prove compatibility, but neither the Mono banner nor the available launcher log identifies a missing CRT/DirectX module. Blanket dependency reinstallation is unsupported by this evidence.

Portside now records an allowlisted effective compatibility environment and bottle settings beside command/arguments/cwd/runtime in each process log. Its Mono error includes the raw exit code, log location and an isolated-copy recovery action, while retaining stop, signal and timeout precedence. The [R2Beat recipe](recipes/r2beat.md) records the requirements and blocked acceptance status; no experimental configuration is installed automatically.

The audit's complete Swift suite ran 120 tests with four opt-in integration tests skipped and zero failures. The launcher was exercised with real Wine in the copied prefix separately from these fixture tests. Native GUI presentation of the revised alert was not manually verified.

A separate 20-second probe used the saved native game entry (`Game.exe xyxOpen`, working directory `C:\XYX`) in the same copied prefix. It remained at 100% CPU and was stopped with the copied prefix's Wine server; no responsive game window was verified. This direct probe did not perform a fresh publisher handoff and does not reproduce the full updated-client flow below. Its checked original source files still matched the audit baseline afterward. The earlier normal-handoff/updated-game traces provide the separate missing-API evidence; login, anti-cheat and gameplay remain unverified.

### Changes and checks from this audit

The existing source was found in the desktop `portside` checkout; the initial chat workspace contains branding assets only. Existing uncommitted changes were preserved. This audit changed these source/documentation files:

| File | Change |
| --- | --- |
| `Sources/PortsideCore/WineFailureDiagnostics.swift` | Observed Mono failure, exit code, absolute log path and concrete isolated-copy recovery; no automatic missing-dependency diagnosis |
| `Sources/PortsideCore/WineProcessManager.swift` | Effective environment allowlist and bottle settings in log metadata; pass raw status to diagnostic |
| `Sources/PortsideCore/Models.swift` | Avoid repeating a diagnostic's log path in CLI errors |
| `Tests/PortsideCoreTests/FailureDiagnosticsTests.swift` | Recovery/status/path assertions, successful-exit exclusion and retained precedence checks |
| `Tests/PortsideCoreTests/PortsideCoreTests.swift` | Assert exact launch metadata and exclusion of arbitrary inherited locale/private variables |
| `docs/recipes/r2beat.md` | Version-specific requirements, copy/remove-Mono/native-Framework comparison protocol, evidence and blocked acceptance gates |
| `docs/setup.md` | Route Mono failures to the actual log and R2Beat recipe |
| `docs/r2beat-runtime-investigation.md` | Independently checked diagnosis, separate launch/game observations and implementation record |

`swift test --scratch-path .build/r2beat-diagnostics` completed with 116 passed, four opt-in tests skipped and zero failures. After the final log-format/privacy refinements, all four selected diagnostic/metadata tests passed. `git diff --check` passed. A final real-Wine launcher rerun retained exit 3 and verified that the CLI error includes the exact log path once. Both copied-prefix cleanup commands completed successfully.

Private evidence is retained under ignored `.artifacts/verification/r2beat-error-audit/` (`result.json`, `game-result.json`, launch/stop CLI records and copied-prefix Wine logs), `r2beat-diagnostics-static.json`, `r2beat-diagnostics-tests.log` and `r2beat-diagnostics-final-tests.log`. The original Mono log contains no usable faulting-module backtrace. No successful launch repair, production dependency migration, installed-app replacement or playable-game configuration is claimed by this patch.

## Launcher crash root cause

Added 17 October 2026 from a traced re-run after the audit above. It replaces the audit's statement that the faulting module was unknown. The configured **Gcenx Wine Stable 11.0_1** runtime cannot run 32-bit Mono code on this Mac, whatever the program. The launcher's Framework 4.7.2/WPF requirement and the `WrapperClass.dll` concern are real, but they are not what fails.

**Traced launcher run.** The saved launch was repeated in an APFS copy of the production bottle with `WINEDEBUG=err+all,+seh,+loaddll,+timestamp,+pid,+tid` and the audit's other settings. The copy was made while another Windows session was live in the source; it ran under its own Wine server and was deleted afterwards, and the source's registry files kept their size and modification time. The launcher again exited **3** after about two seconds. The last modules loaded were `libmono-2.0-x86.dll` (Wine Mono 10.4.1), `fusion.dll` and `mscorlib.dll`; no WPF assembly, `WrapperClass.dll` or other R2Beat assembly had loaded. The first exception was `c0000005` at `7BF21139`, reading address `0x4ECD`. `wow64cpu.dll`, Wine's 32-bit execution layer, was mapped at `7BF20000`, so the fault is at offset `0x1139` in that module, not in Mono, WPF or an application file. The bundle's `wow64cpu.dll` has `mov edx, dword ptr [rip + 0x4ecd]` at that offset: a RIP-relative load whose reported access address is the bare displacement. That is consistent with this 64-bit thunk being executed with 32-bit addressing at a mode switch under Rosetta. It is an inference from one instruction and the registers, not a verified mechanism.

**Control program.** A minimal C# program was built with the runtime's own `mcs.exe` for 64-bit and for 32-bit, then run on three runtimes. The procedure is the [probe in the recipe](recipes/r2beat.md#qualify-the-runtime-with-a-32-bit-net-probe).

| Runtime | 64-bit program | 32-bit program |
| --- | --- | --- |
| Gcenx Stable 11.0_1 (the configured runtime), in the copied bottle and in a new prefix | Prints `IntPtr.Size=8`, exit 0 | Mono native-crash banner, exit **3**. The copied-bottle trace shows `c0000005` at `7BF21139` |
| Gcenx Staging 11.18 (bundled Mono 11.3.0), new prefix | Prints `IntPtr.Size=8`, exit 0 | No output in 60 seconds; stopped. Not characterized further |
| athei cx-26.3.0-9 (pinned commit `93429c6e7c8`): copied bottle converted by `wineboot -u`, unchanged Mono 10.4.1 copied into the prefix, builtin `mscoree` enabled for the probes through `WINE_COMPATDB`, x87 sidecar attached by the runtime | Prints `IntPtr.Size=8`, exit 0 | Prints `IntPtr.Size=4`, exit 0 |

**Upstream correlation.** [Gcenx/macOS_Wine_builds#160](https://github.com/Gcenx/macOS_Wine_builds/issues/160) was opened on 27 April 2026 for a different .NET Framework 4.8 program on an M2 Pro. Its log contains the same two exception lines at `7BF21139` and the same "Native Crash Reporting" banner. The maintainer's reply (28 April) lists the 11.0 stable and 11.6 devel/staging packages as unsupported because they contained hacks the maintainer was asked to stop applying, and the `_1` packages as supported with none. A commenter says Wine is much less stable under Rosetta once all "CW" (presumably CodeWeavers) patches are removed. The maintainer recommends an upstream Wine bug and CrossOver, and closed the issue as not planned on 29 April. GitHub's API returned 404 for a release tagged `11.0` on 17 October 2026, so the earlier build was not found to test.

**What this changes.**

- The recorded crash cannot be attributed to the launcher's .NET target, WPF or the mixed-mode wrapper. It occurs before any of them load, and a program with none of them crashes identically.
- Removing Wine Mono, installing Microsoft Framework 4.7.2 or 4.8, or changing the locale cannot repair it on this runtime. The retained native-Framework trials (`c0000005` handling and high CPU) used the same runtime; whether they share this cause was not tested.
- A runtime must pass the probe before launcher work is meaningful. Passing is not sufficient: the athei build passes and completed the publisher update, yet cannot run the game.

**Not established.** Whether Rosetta, macOS 26.0 (build 25A354 here; the upstream reporter's macOS version is not given) or this chip is the deciding factor. Whether the athei result generalizes beyond its pinned build. Whether any setting avoids the fault on Stable 11.0_1. Private evidence for these runs is under ignored `.artifacts/verification/mono-wow64-crash/`.

## Environment and client

- Apple M4, arm64; macOS 26.0, build 25A354; Rosetta 2 installed.
- Official publisher: [R2Beat download page](https://r2beat.xiyouxi.com/download). The publisher lists Windows 7 minimum and Windows 10 recommended, and supplies DirectX, .NET and x86 Visual C++ prerequisites. macOS/Wine support is not listed there.
- Installed client: native x86 `Game.exe`, PE version 4.3.7.8. The initial installation had publisher patch 00075.
- The real publisher updater completed patch **00089** in an isolated copy. The replacement Game.exe is 264,628,632 bytes, SHA-256 `bfebe9b79bdd072e079326f90e268b3107533c1796807de44980e36c5fd906ed`; its PE version remains 4.3.7.8.
- The publisher's normal AutoStart setting launched Game.exe with one argument, `xyxOpen`, and working directory `C:\XYX`. The launcher wrote its own fresh tick; no handshake value was fabricated.

The original bottle, downloaded archives and game installation were preserved. All runtime conversion, framework and patching trials used separate copies. Experimental binaries, game copies, raw logs and private paths are excluded from Git, the app, the DMG and the source archive.

## Runtime results

| Runtime | Actual observation |
| --- | --- |
| Gcenx Stable 11.0_1 | The original client stalled with high CPU in Rosetta/Wine exception handling. The managed publisher launcher failed with a Mono native-crash report. |
| Gcenx Staging 11.18 | The original client exited with a nested exception on the signal stack. No usable game window was verified. |
| Sikarugir WineCX 24.0.7 archive revision 7, internal revision 6 | Fresh 32-bit and 64-bit command checks passed using the official template dependencies. The original client then hit a null-address crash. |
| athei/wine-build cx-26.3.0-9, pinned Wine commit 93429c6e7c8 | Fresh 32-bit and 64-bit command checks passed. With unchanged prefix-local Wine Mono 10.4.1, matching Gecko 2.47.4 and documented per-executable compatibility settings, the publisher completed the official patch flow. Its normal launch of the updated game still hit a null-address crash. |
| Sikarugir Wine 11.0 revision 1 | Prefix initialization failed in this environment. This package was not validated for game testing. |

The alternate runtime packages are external research inputs. Some include separately licensed Apple components; no such package has been added to the Portside distribution or advertised as a supported setup.

A final comparison used Wine's documented `winecfg.exe -v win7` setting, read it back as Windows 7, and kept the default graphics backend. The publisher completed its normal handoff, but the game again logged the missing `CsrGetProcessId` and immediately a null-address access violation. The full 90-second observation ended with scoped cleanup and restoration of the AutoStart preference. Both the production bottle and the updated source copy retained their checked hashes. Selecting this publisher-supported OS profile did not repair the failure.

## Focused missing-API evidence

A bounded 90-second test used the updated game and the publisher's normal launch sequence. Wine's relay filter selected only these four builtin APIs: `kernel32.GetProcAddress`, `kernelbase.GetProcAddress`, `ntdll.LdrGetProcedureAddress` and `ntdll.LdrLoadDll`. A preflight confirmed the filter, and the game log contained 16,330 selected calls with no exported API calls outside this filter. Wine also logged callback and DLL-entry records. Its size was approximately 5.05 MB.

The main game thread logged the following sequence:

```text
GetProcAddress(ntdll, "CsrGetProcessId")
LdrGetProcedureAddress: function not found in ntdll.dll
LdrGetProcedureAddress returns c000007a (STATUS_PROCEDURE_NOT_FOUND)
GetProcAddress returns NULL
Next logged event on that thread: c0000005 at address 0; x86 EIP = 0
```

This strongly implicates a call through the missing function pointer. It is an inference from adjacent runtime events; no game instruction was patched or reverse engineered to assert a complete causal backtrace. The same null fault also occurred without relay instrumentation. Other optional missing exports were present in the log and were not automatically classified as fatal.

The failing lookup's return address, `0x10bf3c52`, lies inside the `.themida` section of the updated `Game.exe` according to its PE section table (RVA `0x107f3c52`; the section spans RVAs `0x03f42000` to `0x124f2000`, and the entry point is in the following `.boot` section). The call therefore comes from the executable's Themida protection layer, not from Wine, a redistributable or the launcher. The game folder also contains nProtect GameGuard (`GameGuard.des`, `GameGuard\GameMon.des`, `GameMon64.des`, `npggNT.des`, `npggNT64.des`); a retained athei trace of the original client shows GameGuard modules loading before its null fault. It contains `TerSafe.dll` and `TenProxy.dll` as well, whose names suggest Tencent's TenProtect; those were not seen loading in that trace and were not analyzed. Supplying one export would only reach whatever these layers check next, and none has been shown to run under Wine. This report does not recommend faking the export or bypassing the protections.

Read-only PE export checks found `CsrGetProcessId` absent from all five local x86 ntdll binaries above. [Upstream Wine](https://github.com/wine-mirror/wine/blob/master/dlls/ntdll/ntdll.spec), [Valve's Wine tree](https://github.com/ValveSoftware/wine/blob/bleeding-edge/dlls/ntdll/ntdll.spec) and the [pinned athei tree](https://github.com/athei/wine/blob/93429c6e7c8/dlls/ntdll/ntdll.spec) keep the entry commented out. This is not an API supplied by a Visual C++ or .NET redistributable.

The [ReactOS reference implementation](https://github.com/reactos/reactos/blob/master/subsystems/csr/csrlib/connect.c) obtains the actual CSR server's process ID from its server connection and returns that saved value. A constant, the current game PID, or Wine's Unix server PID would not establish that Windows process contract. No fake return value, protection bypass or replacement game executable was used.

## Game-independent reproduction

The original [export probe source](diagnostics/csr-export-probe.c) checks the module, a known exported control function, and the target export. It never invokes either resolved function and does not require the game, a debugger or a game account. The program exits 0 when its module/control checks work, even if the target export is absent: inspect its JSON output rather than treating exit 0 as API support.

Build from the repository root with MinGW-w64:

```sh
i686-w64-mingw32-gcc -std=c11 -Wall -Wextra -Werror -Os -static \
  docs/diagnostics/csr-export-probe.c -o /tmp/csr-export-x86.exe
x86_64-w64-mingw32-gcc -std=c11 -Wall -Wextra -Werror -Os -static \
  docs/diagnostics/csr-export-probe.c -o /tmp/csr-export-x64.exe
```

Use a new disposable prefix and one already validated runtime. Run in a subshell to keep these environment settings local; replace the runtime path with the absolute directory containing its `bin/wine` and `bin/wineserver` executables:

```sh
(
  export PORTSIDE_PROBE_RUNTIME="/absolute/path/to/runtime-root"
  export WINEPREFIX="$(mktemp -d /tmp/portside-csr-probe.XXXXXX)"
  export WINEARCH=win64
  export WINELOADER="$PORTSIDE_PROBE_RUNTIME/bin/wine"
  export WINESERVER="$PORTSIDE_PROBE_RUNTIME/bin/wineserver"
  export WINEDEBUG=-all,err+all
  "$WINELOADER" wineboot --init
  "$WINELOADER" /tmp/csr-export-x86.exe
  "$WINELOADER" /tmp/csr-export-x64.exe
  "$WINESERVER" -w
)
```

On the tested athei runtime, both builds compiled with warnings treated as errors, prefix initialization returned 0, and both probes reported `ntdllPresent: true`, control function `present: true`, and target `present: false`, address `0x0`, `lastError: 127` (`ERROR_PROC_NOT_FOUND`). These independent results establish the export gap without running copyrighted game code. They do not prove that adding the export would make the game work.

## Remaining acceptance work

No working runtime configuration was established. For the launcher, a runtime must first pass the [32-bit .NET probe](recipes/r2beat.md#qualify-the-runtime-with-a-32-bit-net-probe); the configured Stable runtime does not. For the game, a legitimate runtime implementation or publisher-supported compatible client is needed for the observed failing startup path. Supporting one missing export might reveal further requirements; it would not itself prove compatibility. Login, anti-cheat operation and gameplay remain unverified. No authenticated account flow was attempted.

After a real repair, verification must still show the game window responding, then save the verified runtime/configuration in Portside, restart the frontend and successfully launch/interact again. No experimental runtime or framework changes should be promoted to user bottles on the strength of an alive process or an updater exit code.
