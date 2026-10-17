# Optional component fixture checks

Run from the repository root after building the pinned component with `bash scripts/build-dxvk-compat.sh`. These use fake Wine executables and disposable data under `.artifacts/downloads/dxvk-helper-tests`; they do not invoke the real Wine runtime or normal Portside catalog.

```sh
python3 Tests/Fixtures/DXVK/verify.py
python3 Tests/Fixtures/DXVK/verify-command-output.py
python3 Tests/Fixtures/DXVK/verify-build-pins.py
```

The order matters: the first fixture creates the data used by the command/removal regressions. The build-publication checks need the component build's cached upstream archives and its compiler toolchain. Together they cover 35 lifecycle, command, and packaging assertions. Observed rendering and interaction results are summarized in [compatibility](../../../docs/compatibility.md).
