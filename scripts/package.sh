#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
MODE="${OILFIND_PACKAGE_MODE:-developer-id}"
APP_PATH="$PROJECT_DIR/build/Oil Find.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
ARCHIVE_PATH="$PROJECT_DIR/build/Oil-Find-$VERSION.zip"

if [[ ! -d Pro/Sources ]]; then
    printf '%s\n' 'Packaging requires the private Pro repository.' >&2
    exit 1
fi
if [[ -n "${OILFIND_FREE+x}" ]]; then
    printf '%s\n' 'Packaging refuses OILFIND_FREE; unset it to include Pro.' >&2
    exit 1
fi
if ! python3 - <<'PYKEY'
from pathlib import Path
import re
config = next(Path('Pro/Sources').glob('*/License/LicenseConfig.swift'), None)
if config is None:
    raise SystemExit('Packaging requires the private Pro authorization sources.')
source = config.read_text()
key = re.search(r'static let productionPublicKey = "([^"]*)"', source)
if not key or not key.group(1):
    raise SystemExit('Packaging requires the new production authorization public key (M23).')
PYKEY
then
    exit 1
fi
if [[ -e "$ARCHIVE_PATH" ]]; then
    printf '%s\n' "Refusing to overwrite the existing release archive: $ARCHIVE_PATH" >&2
    exit 1
fi

case "$MODE" in
    bridge)
        if ! security find-identity -v -p codesigning | grep -q '"Oil Find Self-Signed"'; then
            printf '%s\n' 'Bridge packaging requires the existing "Oil Find Self-Signed" identity.' >&2
            exit 1
        fi
        unset OILFIND_SIGN_IDENTITY
        FEED_NAME="latest.json"
        REQUIREMENT='identifier "com.oiloil.find" and certificate leaf = H"5E8387B327002CEC74DE49DBA3FA9D8F6764DEE0"'
        ;;
    developer-id)
        if [[ "${OILFIND_SIGN_IDENTITY:-}" != Developer\ ID\ Application:* ]]; then
            printf '%s\n' 'Set OILFIND_SIGN_IDENTITY to a Developer ID Application identity.' >&2
            exit 1
        fi
        if ! security find-identity -v -p codesigning | grep -F "\"${OILFIND_SIGN_IDENTITY}\"" >/dev/null; then
            printf '%s\n' 'The Developer ID Application identity and private key are unavailable.' >&2
            exit 1
        fi
        if [[ -z "${OILFIND_NOTARY_PROFILE:-}" ]]; then
            printf '%s\n' 'Set OILFIND_NOTARY_PROFILE for Apple notarization.' >&2
            exit 1
        fi
        xcrun notarytool history --keychain-profile "$OILFIND_NOTARY_PROFILE" >/dev/null
        FEED_NAME="latest-v2.json"
        REQUIREMENT='identifier "com.oiloil.find" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "4NZ3X494AF"'
        ;;
    *)
        printf '%s\n' 'OILFIND_PACKAGE_MODE must be bridge or developer-id.' >&2
        exit 1
        ;;
esac

FEED_PATH="site/public/updates/$FEED_NAME"
if [[ -f "$FEED_PATH" ]]; then
    if ! python3 - "$FEED_PATH" "$BUILD_NUMBER" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    current = json.load(source)
new_build = int(sys.argv[2])
if int(current.get("build", -1)) >= new_build:
    raise SystemExit("Refusing to replace the update feed with the same or an older build.")
PY
    then
        exit 1
    fi
fi

"$PROJECT_DIR/scripts/build-app.sh"
codesign --verify --deep --strict "$APP_PATH"
swift "$PROJECT_DIR/scripts/verify-signature.swift" "$APP_PATH" com.oiloil.find "$REQUIREMENT"

if [[ "$MODE" == developer-id ]]; then
    SUBMISSION_PATH="$PROJECT_DIR/build/Oil-Find-$VERSION-notary.zip"
    NOTARY_RESULT="$PROJECT_DIR/build/Oil-Find-$VERSION-notary.json"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$SUBMISSION_PATH"
    xcrun notarytool submit "$SUBMISSION_PATH" \
        --keychain-profile "$OILFIND_NOTARY_PROFILE" --wait --output-format json > "$NOTARY_RESULT"
    python3 - "$NOTARY_RESULT" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    raise SystemExit(f"Apple notarization failed; inspect {sys.argv[1]} for the submission ID.")
print(f"Apple notarization accepted: {result.get('id', 'unknown submission')}")
PY
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    rm -f "$SUBMISSION_PATH"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
LAUNCH_ARGUMENTS=("$ARCHIVE_PATH")
if [[ "${OILFIND_ISOLATED_LAUNCH_CHECK:-0}" == 1 ]]; then
    LAUNCH_ARGUMENTS=(--isolated-instance "${LAUNCH_ARGUMENTS[@]}")
fi
if [[ "$MODE" == developer-id ]]; then
    spctl -a -vv -t exec "$APP_PATH"
    LAUNCH_ARGUMENTS=(--developer-id "${LAUNCH_ARGUMENTS[@]}")
fi
python3 Tests/Scripts/test_packaged_launch.py "${LAUNCH_ARGUMENTS[@]}"
mkdir -p site/public/downloads site/public/updates
node --experimental-strip-types scripts/generate-update-manifest.mjs Resources/Info.plist "$ARCHIVE_PATH" "$FEED_PATH"
cp "$ARCHIVE_PATH" "site/public/downloads/Oil-Find-$VERSION.zip"
if [[ "$MODE" == developer-id ]]; then
    cp "$ARCHIVE_PATH" site/public/downloads/Oil-Find.zip
fi

printf 'File: %s\n' "$ARCHIVE_PATH"
printf 'Feed: %s\n' "$FEED_NAME"
printf 'Size: %s bytes\n' "$(stat -f '%z' "$ARCHIVE_PATH")"
printf 'SHA-256: %s\n' "$(shasum -a 256 "$ARCHIVE_PATH" | cut -d ' ' -f 1)"
