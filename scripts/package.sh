#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Official updates always include the optional private application library.
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

# Every update must satisfy the preceding release's certificate requirement.
if ! security find-identity -v -p codesigning | grep -q '"Oil Find Self-Signed"'; then
    printf '%s\n' 'Packaging requires the existing "Oil Find Self-Signed" identity.' >&2
    exit 1
fi
unset OILFIND_SIGN_IDENTITY
"$PROJECT_DIR/scripts/build-app.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ARCHIVE_PATH="$PROJECT_DIR/build/Oil-Find-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "build/Oil Find.app" "$ARCHIVE_PATH"
mkdir -p site/public/downloads site/public/updates
node --experimental-strip-types scripts/generate-update-manifest.mjs Resources/Info.plist "$ARCHIVE_PATH" site/public/updates/latest.json
cp "$ARCHIVE_PATH" "site/public/downloads/Oil-Find-$VERSION.zip"
cp "$ARCHIVE_PATH" site/public/downloads/Oil-Find.zip

printf 'File: %s\n' "$ARCHIVE_PATH"
printf 'Size: %s bytes\n' "$(stat -f '%z' "$ARCHIVE_PATH")"
printf 'SHA-256: %s\n' "$(shasum -a 256 "$ARCHIVE_PATH" | cut -d ' ' -f 1)"
