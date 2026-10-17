#!/bin/bash
# Optional native UI automation identity. Normal Portside launches do not need this.
set -euo pipefail
cd "$(dirname "$0")/.."
WINE_PATH="${1:-$HOME/Library/Application Support/Portside/Runtimes/Wine Stable.app/Contents/Resources/wine/bin/wine}"
LOADER_PATH="$(dirname "$WINE_PATH")/../lib/wine/x86_64-unix/wine"
if [ ! -x "$LOADER_PATH" ]; then
  echo "This fixture expects the tested Gcenx Wine 11 x86_64 runtime layout." >&2
  exit 1
fi
HOST_APP="$PWD/.artifacts/downloads/Wine Desktop.app"
mkdir -p "$HOST_APP/Contents/MacOS"
ln -sf "$LOADER_PATH" "$HOST_APP/Contents/MacOS/wine"
cat > "$HOST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>wine</string>
<key>CFBundleIdentifier</key><string>dev.portside.wine-test</string>
<key>CFBundleName</key><string>Wine Desktop</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
echo "Close an existing Portside frontend first. Starting the same app with a UI test identity."
export PORTSIDE_WINE_UI_BUNDLE="$HOST_APP"
exec "$PWD/dist/Portside.app/Contents/MacOS/Portside"
