# Branding assets

Portside uses the supplied P-and-wave logo and macOS icon. The primary colors are blue `#0876EF` and cyan `#18B8DA`; native control tint uses the blue.

| Location | Contents |
| --- | --- |
| `Sources/Portside/Resources/Branding/` | Frontend PNGs and editable logo SVGs, copied as a SwiftPM resource bundle |
| `packaging/macos/branding/` | Editable app-icon SVG and PNG |
| `packaging/macos/Portside.appiconset/` | macOS iconset source sizes |
| `packaging/macos/Portside.icns` | Packaged app and DMG icon |
| `packaging/macos/dmg/` | Finder layout and its documentation |

`bash scripts/build.sh` includes the icon and resource bundle, so the app can move independently of the repository. The AppKit launch delegate also assigns the running-app icon, with a bundled PNG fallback for direct SwiftPM launches.

`swift scripts/make-icon.swift` repackages the iconset into the `.icns`; it does not redraw the design. `scripts/make-dmg-background.swift` creates the DMG background from the supplied logo during packaging.

When changing artwork, preserve editable sources and verify both the relocated app's resources and its Dock/About icon. Check the app at its minimum window size so artwork and labels do not displace controls. See the root [LICENSE](../LICENSE) and [THIRD_PARTY.md](../THIRD_PARTY.md) for licensing boundaries.
