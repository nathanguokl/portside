# Contributing

Portside focuses on a small native Mac frontend around an existing Wine runtime. Keep generic installation, bottle isolation and saved launching understandable. App-specific workarounds should stay optional and document their evidence and limits.

## Local checks

Use macOS with Swift 5.9 or later and Apple's command-line tools:

```sh
swift build
swift test
bash scripts/build.sh
git diff --check
```

The default suite does not require Wine. Use temporary libraries and owned process fixtures for tests; never point a test at a normal application catalog or stop unrelated Windows processes. Opt-in Wine tests and project layout are explained in [development.md](docs/development.md).

For frontend changes, inspect the actual native app at normal and minimum window size. Exercise relevant cold launch, sheet/file-panel queues, cancellation, errors and persisted state. For runtime compatibility changes, record the Mac/OS, Wine source/version, application publisher/version, and real interaction observed. A clean process exit or a fixture pass alone is insufficient evidence that an application works.

## Pull requests

Describe the concrete problem, resulting behavior, relevant checks, and remaining limitations. Keep changes scoped and add regression coverage when behavior or safety changes. Do not add tests that only repeat implementation details.

Keep downloaded runtimes, proprietary installers, generated apps, DLL build products, user catalogs, logs and screenshots out of source. Use ignored `.artifacts/` for local evidence and sanitize anything included in a report. Preserve dependency pins, corresponding source/build material, and license notices when changing optional components.

Original contributions use the repository's [MIT license](LICENSE). Third-party code and assets retain their own terms; consult [THIRD_PARTY.md](THIRD_PARTY.md). This repository does not grant permission to redistribute Windows applications or runtime dependencies.
