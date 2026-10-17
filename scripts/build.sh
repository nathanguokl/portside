#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
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
PORTSIDE_PACK="${PORTSIDE_COMPATIBILITY_PACK_DIR:-$PWD/.build/compatibility-pack}"
if [ -d "$PORTSIDE_PACK" ]; then
    bash scripts/build-compatibility-pack.sh --validate-only --output "$PORTSIDE_PACK"
    ditto "$PORTSIDE_PACK/Components" "$COMPATIBILITY/Components"
    ditto "$PORTSIDE_PACK/Fonts" "$COMPATIBILITY/Fonts"
    cp "$PORTSIDE_PACK/manifest.json" "$COMPATIBILITY/manifest.json"
else
    echo "Optional compatibility data absent. Build it with: bash scripts/build-compatibility-pack.sh"
fi
codesign --force --sign - "$APP"
echo "Built $APP"
