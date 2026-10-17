# macOS packaging

These checked-in inputs are used by `scripts/build.sh` and `scripts/package-dmg.sh`:

- `Info.plist` defines the application identity, version, minimum macOS version, file association, and privacy descriptions.
- `Portside.icns` and `Portside.appiconset/` contain the supplied application icon. `branding/` preserves its PNG and SVG source assets.
- `dmg/` documents the generated Finder layout for the drag-and-drop installer image.

The SwiftUI application loads its runtime branding from `Sources/Portside/Resources/Branding/` through SwiftPM. Those resources stay beside the application source.

Build outputs belong in ignored `dist/` and `.build/` directories. Local downloads and verification records belong in ignored `.artifacts/downloads/` and `.artifacts/verification/` directories.
