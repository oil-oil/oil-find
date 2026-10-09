#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf '%s\n' 'Usage: scripts/verify-release-app.sh APP_PATH' >&2
    exit 2
fi
APP_PATH="$1"
PLIST="$APP_PATH/Contents/Info.plist"
BINARY="$APP_PATH/Contents/MacOS/OilFind"
[[ -f "$BINARY" && -x "$BINARY" ]] || { printf 'Missing executable: %s\n' "$BINARY" >&2; exit 1; }
plutil -lint "$PLIST"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == com.oiloil.find ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" == OilFind ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" == 14.0 ]] || exit 1
[[ -s "$APP_PATH/Contents/Resources/AppIcon.icns" ]] || { printf '%s\n' 'Missing app icon' >&2; exit 1; }
codesign --verify --deep --strict "$APP_PATH"
codesign -d --verbose=4 "$APP_PATH" 2>&1 | grep -Fx 'Identifier=com.oiloil.find'

# Check the executable's actual deployment target, not only Info.plist.
build_info="$(xcrun vtool -show-build "$BINARY")"
printf '%s\n' "$build_info"
printf '%s\n' "$build_info" | awk '
    $1 == "platform" { platforms++; if ($2 != "MACOS") invalid = 1 }
    $1 == "minos" { targets++; if ($2 != "14.0" && $2 != "14.0.0") invalid = 1 }
    $1 == "sdk" {
        sdks++;
        split($2, version, ".");
        if (version[1] < 15 || (version[1] == 15 && version[2] < 4)) invalid = 1
    }
    END { exit (invalid || targets == 0 || targets != sdks || targets != platforms) }
'
printf 'Verified release app: %s\n' "$APP_PATH"
