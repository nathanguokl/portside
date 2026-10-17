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
codesign --force --sign - "$APP"
echo "Built $APP"
