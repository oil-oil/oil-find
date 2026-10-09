#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION=release
APP_PATH="$PROJECT_DIR/build/Oil Find.app"
case "${1:-}" in
    '') [[ $# -eq 0 ]] || exit 2 ;;
    --debug) [[ $# -eq 1 ]] || exit 2; CONFIGURATION=debug; APP_PATH="$PROJECT_DIR/build/debug/Oil Find.app" ;;
    *) printf '%s\n' 'Usage: scripts/build-app.sh [--debug]' >&2; exit 2 ;;
esac
swift build -c "$CONFIGURATION"
BINARY_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_PARENT="$(dirname "$APP_PATH")"
mkdir -p "$APP_PARENT"
STAGE_DIR="$(mktemp -d "$APP_PARENT/.oilfind-stage.XXXXXX")"
STAGED_APP="$STAGE_DIR/Oil Find.app"
PREVIOUS_APP="$STAGE_DIR/previous.app"
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    # Restore the previous bundle if promotion failed or was interrupted.
    if [[ -e "$PREVIOUS_APP" && ! -e "$APP_PATH" ]]; then
        if ! mv "$PREVIOUS_APP" "$APP_PATH"; then
            printf 'Could not restore previous app; retained at %s\n' "$PREVIOUS_APP" >&2
            exit 1
        fi
    fi
    rm -rf "$STAGE_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BINARY_DIR/OilFind" "$STAGED_APP/Contents/MacOS/OilFind"
if [[ "$CONFIGURATION" == release ]]; then
    # Release bundles omit debug symbols containing local source paths.
    strip -S "$STAGED_APP/Contents/MacOS/OilFind"
fi
cp "Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
fi
SELF_SIGNED="Oil Find Self-Signed"
if [[ -n "${OILFIND_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$OILFIND_SIGN_IDENTITY" --identifier com.oiloil.find --options runtime --timestamp "$STAGED_APP"
elif security find-identity -v -p codesigning | grep -q "\"$SELF_SIGNED\""; then
    # Stable identity: macOS keeps Full Disk Access across updates. See scripts/create-signing-cert.sh.
    codesign --force --sign "$SELF_SIGNED" --identifier com.oiloil.find "$STAGED_APP"
else
    codesign --force --sign - --identifier com.oiloil.find "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"
if [[ -e "$APP_PATH" ]]; then
    mv "$APP_PATH" "$PREVIOUS_APP"
fi
mv "$STAGED_APP" "$APP_PATH"
printf '%s\n' "$APP_PATH"
