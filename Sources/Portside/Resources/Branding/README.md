# Portside branding

The supplied P-and-wave artwork is bundled with the SwiftUI frontend:

- `portside-logo.svg` / `.png`: primary logo on a transparent background.
- `portside-logo-mono.svg` / `.png`: single-color variant.
- `portside-icon.png`: fallback Dock icon for direct SwiftPM launches.

Primary colors: blue `#0876EF`, cyan `#18B8DA`, ink `#102947`.
The SVGs contain editable paths and require no fonts or external resources.

The macOS `.icns`, iconset and editable app-icon artwork live in
[`packaging/macos`](../../../../packaging/macos/). Run
`swift scripts/make-icon.swift` from the repository root to repackage the
provided iconset. See [development](../../../../docs/development.md) for builds.
