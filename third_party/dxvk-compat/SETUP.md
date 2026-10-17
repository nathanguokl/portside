# Set up one managed bottle

`scripts/setup-bottle-dxvk.py` installs the pinned optional component into one existing, initialized Portside bottle. It does not modify the catalog, the shared Wine runtime, or another bottle. It changes that bottle's four D3D10/11 DLL entries and three Wine registry overrides. The registry changes persist when the Mac frontend restarts.

First build the component using `bash scripts/build-dxvk-compat.sh`. Stop the selected bottle using Portside's **Stop Bottle** action, then quit the frontend to prevent a simultaneous launch while setup runs. Other bottles are not stopped by this helper.

From the repository root, substitute the selected bottle's UUID:

```sh
python3 scripts/setup-bottle-dxvk.py BOTTLE-UUID \
  --component-dir .build/dxvk-compat/component
```

The default catalog is `~/Library/Application Support/Portside/library.json`. The UUID is matched to the catalog entry, its UUID directory, and `.portside-bottle.json` ownership marker. Spaces and Unicode in the bottle's path and name are supported. The helper uses that bottle's saved Wine executable; it never builds a shell command string.

`--home /absolute/path/to/Portside` overrides the **Portside Application Support root**, not the user's home directory. This option is useful for isolated test catalogs. It does not change the `HOME` environment variable.

The helper validates the component's exact ID, version, source commit, four pinned DLL hashes, and x32/x64 PE machine types. The pinned hashes identify the packaged `1.10.3-portside1` build. A different toolchain or component build producing different DLL hashes requires an intentional component version/pin update before this helper will accept it; changing only `component.json` cannot bypass the helper's pins.

## What setup preserves

First originals, prior registry overrides, provenance, and the operational log are stored inside the selected bottle:

```text
.portside-components/dxvk-macos/
  state.json
  operations.log
  originals/
```

Original DLL symlinks are recorded as symlinks rather than followed or copied through. Replacing a builtin symlink replaces only the bottle's directory entry; it does not write into the shared runtime DLL. Regular original files are copied into the backup directory. Missing original DLL entries are recorded as absent. The helper preserves the first backups across repeated installs and removal/reinstallation.

The selected bottle receives:

- x32 `d3d10core.dll` and `d3d11.dll` in `drive_c/windows/syswow64`.
- x64 `d3d10core.dll` and `d3d11.dll` in `drive_c/windows/system32`.
- `HKCU\Software\Wine\DllOverrides`: `d3d10core` and `d3d11` set to `native,builtin`; `dxgi` set to `builtin`.

Wine's `dxgi.dll` remains builtin. Setup captures and restores previously present or missing values for those three named overrides; it does not replace the whole registry key. It refuses unsupported existing registry value types instead of guessing how to restore them.

## Stop and error behavior

Before touching component data, the helper invokes the selected runtime's `wineserver -w` with the selected `WINEPREFIX` and a 1.5-second timeout. A timeout refuses setup with an instruction to stop the bottle and retry. Only the waiting probe is terminated on timeout; no `wineserver -k` or global process kill is sent.

Registry query/update commands run with bounded timeouts. Subsequent idle checks allow up to 15 seconds for the helper's own short registry commands to finish and the Wine server to exit. A bottle that remains active is preserved rather than killed.

Commands write output to a temporary regular file instead of a pipe, so inherited stdout in Wine background services does not delay detection of the direct command's exit. Diagnostics read at most the last 64 KiB, and MoltenVK informational logging is disabled during setup.

The helper removes inherited `LC_*` values and sets `LANG` and `LC_ALL` to `en_US.UTF-8` for its subprocesses so registry absence errors can be interpreted consistently on hosts using other languages. It does not change the bottle's saved settings or the user's shell environment.

An install failure attempts to restore the original DLL entries and prior registry overrides, and records whether rollback completed. Inspect `operations.log` and `state.json` for an actionable failure reason. A setup lock prevents concurrent helper runs. A lock left after an interrupted process can be removed only after verifying that no setup helper is still running.

## Remove or recover

Stop the selected bottle and quit the frontend again, then run:

```sh
python3 scripts/setup-bottle-dxvk.py BOTTLE-UUID \
  --remove
```

Removal uses only the selected bottle's preserved state and backups. It does not require the original component directory, and an optional `--component-dir` is ignored during removal.

Removal restores original file contents, permissions, symlinks, missing entries, and the three saved registry values. It retains the backup record and operational log. It can also recover an interrupted install/remove when every current entry is still either its recorded original or the exact managed component value. It refuses to overwrite a later manual DLL or override edit; inspect the preserved state before resolving that conflict.

## Verification boundary

The helper's syntax/help checks and isolated fixture checks passed using fake Wine/wineserver executables. Those checks covered install/remove/reinstall, spaces/Unicode, symlink target preservation, another bottle and catalog remaining unchanged, hash verification, busy-prefix refusal, bad ownership and directory symlink refusal, idempotence, preservation of first backups, rollback after an injected registry failure, lock ownership, later manual edits, interrupted-install recovery, inherited stdout, bounded output, command timeouts, command locale, and removal without the component. No real Wine runtime or user's bottle was invoked by those fixture tests.

Successful graphics rendering and actual Wine registry behavior require verification by the caller on the selected runtime; source build and fixture checks alone do not establish Windows application compatibility.
