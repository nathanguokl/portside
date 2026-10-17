#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/build.sh
APP="$PWD/dist/Portside.app"
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
OUTPUT_NAME="Portside-$VERSION-macOS-$ARCH.dmg"
OUTPUT="$PWD/dist/$OUTPUT_NAME"
TEMPORARY="$(mktemp -d "${TMPDIR:-/tmp}/portside-dmg.XXXXXX")"
DEVICE=""
cleanup() {
    local result=$?
    if [[ -n "$DEVICE" ]] && ! hdiutil detach "$DEVICE" -quiet; then
        echo "Could not eject $DEVICE. Temporary files preserved at $TEMPORARY." >&2
        return "$result"
    fi
    rm -rf "$TEMPORARY"
    return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGING="$TEMPORARY/staging"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/Portside.app"
ln -s /Applications "$STAGING/Applications"
cp packaging/macos/Portside.icns "$STAGING/.VolumeIcon.icns"
swift scripts/make-dmg-background.swift Sources/Portside/Resources/Branding/portside-logo.png \
    "$STAGING/.background/background.png"
xcrun clang -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework CoreServices \
    scripts/make-dmg-layout.m -o "$TEMPORARY/make-dmg-layout"

# Optional compatibility sources and licenses can exceed the fixed 64 MB image.
PORTSIDE_STAGING_KB="$(du -sk "$STAGING" | awk '{print $1}')"
PORTSIDE_IMAGE_MB="$(( (PORTSIDE_STAGING_KB * 13 / 10 + 16384 + 1023) / 1024 ))"
if [ "$PORTSIDE_IMAGE_MB" -lt 64 ]; then PORTSIDE_IMAGE_MB=64; fi
hdiutil create -quiet -volname Portside -fs HFS+ -format UDRW -size "${PORTSIDE_IMAGE_MB}m" \
    -srcfolder "$STAGING" "$TEMPORARY/writable.dmg"
hdiutil attach -readwrite -nobrowse -noautoopen -plist \
    "$TEMPORARY/writable.dmg" > "$TEMPORARY/attached.plist"
DEVICE="$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$TEMPORARY/attached.plist")"
MOUNT="$(python3 - "$TEMPORARY/attached.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    mounts = [item['mount-point'] for item in plistlib.load(stream)['system-entities'] if 'mount-point' in item]
if len(mounts) != 1:
    raise SystemExit('Expected one mounted Portside image volume')
print(mounts[0])
PY
)"
"$TEMPORARY/make-dmg-layout" "$MOUNT"
SetFile -a C "$MOUNT"

hdiutil detach "$DEVICE" -quiet
DEVICE=""
hdiutil convert "$TEMPORARY/writable.dmg" -format UDZO -imagekey zlib-level=9 \
    -o "$TEMPORARY/Portside.dmg" -quiet
hdiutil verify "$TEMPORARY/Portside.dmg"
mv -f "$TEMPORARY/Portside.dmg" "$OUTPUT"
(
    cd dist
    shasum -a 256 "$OUTPUT_NAME" > "$OUTPUT_NAME.sha256"
)
echo "Built $OUTPUT"
