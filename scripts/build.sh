#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PORTSIDE_PACK="${PORTSIDE_COMPATIBILITY_PACK_DIR-}"
if [ "${PORTSIDE_COMPATIBILITY_PACK_DIR+x}" = x ]; then
    if [ -z "$PORTSIDE_PACK" ]; then
        echo "PORTSIDE_COMPATIBILITY_PACK_DIR must name a validated compatibility pack directory, or be unset to omit it." >&2
        exit 1
    fi
    bash scripts/build-compatibility-pack.sh --validate-only --output "$PORTSIDE_PACK"
fi
swift build -c release
PORTSIDE_BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/Portside.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PORTSIDE_BIN_DIR/Portside" "$APP/Contents/MacOS/Portside"
cp packaging/macos/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY.md "$APP/Contents/Resources/THIRD_PARTY.md"
if [ -f packaging/macos/Portside.icns ]; then cp packaging/macos/Portside.icns "$APP/Contents/Resources/Portside.icns"; fi
ditto "$PORTSIDE_BIN_DIR/Portside_Portside.bundle" "$APP/Contents/Resources/Portside_Portside.bundle"
COMPATIBILITY="$APP/Contents/Resources/Compatibility"
rm -rf "$COMPATIBILITY"
mkdir -p "$COMPATIBILITY/Scripts"
cp scripts/setup-bottle-dxvk.py scripts/setup-bottle-cjk.py "$COMPATIBILITY/Scripts/"
cp profiles/compatibility.json "$COMPATIBILITY/profiles.json"
if [ -n "$PORTSIDE_PACK" ]; then
    ditto "$PORTSIDE_PACK/Components" "$COMPATIBILITY/Components"
    ditto "$PORTSIDE_PACK/Fonts" "$COMPATIBILITY/Fonts"
    cp "$PORTSIDE_PACK/manifest.json" "$COMPATIBILITY/manifest.json"
else
    echo "Optional compatibility data omitted. Set PORTSIDE_COMPATIBILITY_PACK_DIR to a validated pack to include it."
fi
codesign --force --sign - "$APP"
echo "Built $APP"
