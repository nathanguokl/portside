#!/bin/bash
# Install the pinned, external Wine runtime for this user's Portside installation.
# This script does not install Rosetta, request administrator privileges, change
# Gatekeeper settings, remove quarantine attributes, or touch bottles.
set -euo pipefail

readonly archive_url='https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz'
readonly archive_sha256='b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388'
readonly release_url='https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1'
readonly runtime_root="$HOME/Library/Application Support/Portside/Runtimes"
readonly runtime_bundle="$runtime_root/Wine Stable.app"
readonly runtime_relative_executable='Contents/Resources/wine/bin/wine'
readonly gstreamer_url='https://gstreamer.freedesktop.org/data/pkg/osx/1.28.6/gstreamer-1.0-1.28.6-universal.pkg'

fail() {
    printf 'Portside runtime setup: %s\n' "$*" >&2
    exit 1
}

validate_runtime() {
    local wine_executable="$1"
    local version_output
    [ -x "$wine_executable" ] || fail "Wine is missing or not executable: $wine_executable"
    if ! version_output="$("$wine_executable" --version 2>&1)"; then
        printf '%s\n' "$version_output" >&2
        printf '%s\n' \
            'Wine could not start. On Apple Silicon, verify that Rosetta 2 is installed.' \
            'If macOS blocks Wine, review the specific app in System Settings > Privacy & Security.' \
            "Publisher and expected checksum: $release_url / $archive_sha256" \
            'Review the publisher before granting an exception; this script changes no security settings.' >&2
        exit 1
    fi
    case "$version_output" in
        wine-*) printf 'Validated: %s\n' "$version_output" ;;
        *) fail "Unexpected Wine version response: $version_output" ;;
    esac
}

[ "$(/usr/bin/uname -s)" = 'Darwin' ] || fail 'This runtime is for macOS only.'
macos_version="$(/usr/bin/sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
macos_remainder="${macos_version#*.}"
macos_minor="${macos_remainder%%.*}"
if [ "$macos_major" -lt 10 ] || { [ "$macos_major" -eq 10 ] && [ "$macos_minor" -lt 15 ]; }; then
    fail "Wine Stable 11.0_1 requires macOS 10.15 or later; this Mac runs $macos_version."
fi

case "$(/usr/bin/uname -m)" in
    arm64)
        if ! /usr/bin/arch -x86_64 /usr/bin/uname -m >/dev/null 2>&1; then
            printf '%s\n' \
                'Wine Stable is an Intel runtime and requires Rosetta 2 on Apple Silicon.' \
                'Install Rosetta yourself after reviewing the Apple license:' \
                '  softwareupdate --install-rosetta --agree-to-license' >&2
            exit 1
        fi
        ;;
    x86_64) ;;
    *) fail 'Unsupported Mac CPU architecture. Expected arm64 or x86_64.' ;;
esac

printf 'macOS %s; architecture %s\n' "$macos_version" "$(/usr/bin/uname -m)"
if [ ! -d '/Library/Frameworks/GStreamer.framework' ]; then
    printf '%s\n' \
        'GStreamer.framework is absent. The tested simple desktop workflow works without it.' \
        'Install the official universal runtime package for applications needing multimedia:' \
        "  $gstreamer_url" \
        'Choose installation for all users. Portside does not install it automatically.' >&2
fi

if [ -e "$runtime_bundle" ] || [ -L "$runtime_bundle" ]; then
    [ -d "$runtime_bundle" ] || fail "The runtime destination already exists and is not an app directory: $runtime_bundle"
    printf 'Keeping existing runtime: %s\n' "$runtime_bundle"
    validate_runtime "$runtime_bundle/$runtime_relative_executable"
    printf '%s\n' \
        'An existing runtime was not downloaded or modified; its archive checksum was not reverified.' \
        'Select this Wine Stable.app in Portside Runtime settings.'
    exit 0
fi

staging_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/portside-wine.XXXXXXXX")"
trap '/bin/rm -rf -- "$staging_dir"' EXIT
readonly archive_path="$staging_dir/${archive_url##*/}"
printf 'Downloading pinned Wine Stable 11.0_1 from %s\n' "$release_url"
/usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    --output "$archive_path" "$archive_url"
actual_sha256="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
[ "$actual_sha256" = "$archive_sha256" ] || fail "Archive checksum mismatch. Expected $archive_sha256; received $actual_sha256. Nothing was installed."

/bin/mkdir "$staging_dir/extracted"
/usr/bin/tar -xf "$archive_path" -C "$staging_dir/extracted"
readonly extracted_bundle="$staging_dir/extracted/Wine Stable.app"
validate_runtime "$extracted_bundle/$runtime_relative_executable"
/bin/mkdir -p "$runtime_root"
# Do not replace a runtime that appeared while the download was in progress.
if [ -e "$runtime_bundle" ] || [ -L "$runtime_bundle" ]; then
    fail "The destination appeared during setup. Nothing was replaced: $runtime_bundle"
fi
/bin/mv "$extracted_bundle" "$runtime_bundle"
validate_runtime "$runtime_bundle/$runtime_relative_executable"
/bin/cat > "$runtime_root/wine-stable-11.0_1-provenance.json" <<JSON
{
  "publisher": "Gcenx / WineHQ macOS packaging",
  "packageVersion": "11.0_1",
  "wineVersion": "11.0",
  "architecture": "x86_64",
  "source": "$release_url",
  "archiveURL": "$archive_url",
  "sha256": "$archive_sha256",
  "license": "LGPL-2.1-or-later; bundled components retain their own licenses"
}
JSON
printf 'Installed external runtime: %s\n' "$runtime_bundle"
printf '%s\n' 'Open Portside and select Wine Stable.app under Runtime settings.'
