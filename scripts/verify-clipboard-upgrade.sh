#!/bin/bash
# Real cross-process Keychain/AES validation with a disposable self-signed identity.
# No SwiftPM, login keychain writes, search-list/default/trust changes, or ACL edits.
set -euo pipefail
umask 077

repo=$(cd "$(dirname "$0")/.." && pwd)
[[ $(uname -s) == Darwin ]] || { echo 'FAIL requires macOS'; exit 1; }
architecture=$(uname -m)
case "$architecture" in arm64|x86_64) ;; *) echo 'FAIL unsupported macOS architecture'; exit 1 ;; esac
build_directory="$repo/.build/$architecture-apple-macosx/debug"
modules="$build_directory/Modules"
[[ -f "$modules/OilFindCore.swiftmodule" ]] || { echo 'FAIL existing OilFindCore module required; no SwiftPM will be run'; exit 1; }
mkdir -p "$repo/build/validation"
evidence=$(mktemp -d "$repo/build/validation/clipboard-upgrade.XXXXXXXX")
temporary=$(mktemp -d /private/tmp/oil-clipboard-upgrade.XXXXXXXX)
chmod 700 "$temporary" "$evidence"
keychain="$temporary/isolated.keychain"
admin="$temporary/keychain-admin"
probe="$repo/Tests/Integration/ClipboardUpgradeProbe.swift"
production="$repo/Sources/OilFind/ClipboardHistory.swift"
identifier='test.oilfind.clipboard-upgrade.stable'
finished=0

snapshot() {
    local output=$1
    {
        /usr/bin/security list-keychains -d user
        /usr/bin/security list-keychains -d system
        /usr/bin/security list-keychains -d common
        /usr/bin/security default-keychain -d user
        /usr/bin/security default-keychain -d system
        /usr/bin/security dump-trust-settings || true
        /usr/bin/security dump-trust-settings -d || true
        /usr/bin/security dump-trust-settings -s || true
    } > "$output" 2>&1
}
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -x "$admin" && ( -f "$keychain" || -f "${keychain}-db" ) ]]; then
        if ! "$admin" delete "$keychain" >> "$evidence/results.log" 2>&1; then
            echo 'FAIL owned-keychain cleanup; private directory retained for manual investigation'
            status=1
        fi
    fi
    snapshot "$evidence/global-after.txt"
    if ! cmp -s "$evidence/global-before.txt" "$evidence/global-after.txt"; then
        echo 'FAIL search-list/default/trust snapshot changed; no global restore attempted'
        status=1
    else
        echo "PASS global-search-list-default-trust-unchanged sha256=$(shasum -a 256 "$evidence/global-after.txt" | awk '{print $1}')"
    fi
    # Failed validation retains only synthetic archives, hashes and diagnostic logs.
    # Private signing material is removed even if Keychain deletion failed.
    rm -f "$temporary"/*.pem "$temporary"/*.p12 "$temporary"/password
    if [[ ! -f "$keychain" && ! -f "${keychain}-db" ]]; then rm -rf "$temporary"; fi
    if [[ $status == 0 && $finished == 1 ]]; then echo 'PASS disposable-self-signed-upgrade (not original-author certificate)'; fi
    echo "Evidence: $evidence"
    exit "$status"
}
snapshot "$evidence/global-before.txt"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Bound each process. Security operations disable interaction inside the helper;
# timeouts fail without any attempt to approve or operate a security dialog.
bounded() {
    local pid timer status=0
    "$@" >> "$evidence/results.log" 2>&1 & pid=$!
    ( sleep 45; kill -TERM "$pid" 2>/dev/null || true ) & timer=$!
    wait "$pid" || status=$?
    kill "$timer" 2>/dev/null || true
    wait "$timer" 2>/dev/null || true
    if [[ $status != 0 ]]; then
        awk '/^(PASS|FAIL) /' "$evidence/results.log"
        echo "FAIL bounded operation exit=$status; stopping without interactive fallback"
        exit "$status"
    fi
}
echo "Compiling standalone probes: -O, Swift 5, $architecture macOS 14; existing modules read only"
compile=(-O -swift-version 5 -target "$architecture-apple-macosx14.0" -module-cache-path "$temporary/module-cache")
bounded /usr/bin/xcrun swiftc "${compile[@]}" -parse-as-library -D KEYCHAIN_ADMIN "$probe" -o "$admin"
# Freeze the production source for both builds while the main agent may edit it.
cp "$production" "$temporary/ClipboardHistory.swift"
shasum -a 256 "$temporary/ClipboardHistory.swift" > "$evidence/production.sha256"
for version in v1 v2; do
    flags=(-D UPGRADE_V2)
    if [[ $version == v1 ]]; then flags=(-D UPGRADE_V1); fi
    bounded /usr/bin/xcrun swiftc "${compile[@]}" -parse-as-library "${flags[@]}" \
        -I "$modules" -Xcc "-fmodule-map-file=$build_directory/COilFind.build/module.modulemap" \
        "$temporary/ClipboardHistory.swift" "$probe" -o "$temporary/$version"
done
openssl rand -hex 32 > "$temporary/password"
bounded "$admin" create "$keychain" "$temporary/password"
snapshot "$evidence/global-created.txt"
cmp -s "$evidence/global-before.txt" "$evidence/global-created.txt" || { echo 'FAIL keychain creation changed global settings'; exit 1; }
cat > "$temporary/certificate.cnf" <<'EOF'
[req]
distinguished_name=subject
x509_extensions=extensions
prompt=no
[subject]
CN=Oil Find Disposable Upgrade Validation
[extensions]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
bounded /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -config "$temporary/certificate.cnf" -keyout "$temporary/private.pem" -out "$temporary/certificate.pem"
bounded /usr/bin/openssl pkcs12 -export -inkey "$temporary/private.pem" -in "$temporary/certificate.pem" \
    -out "$temporary/identity.p12" -passout "file:$temporary/password"
bounded "$admin" import-sign "$keychain" "$temporary/identity.p12" "$temporary/v1" "$temporary/v2" "$identifier" "$temporary/password"
rm -f "$temporary/private.pem" "$temporary/certificate.pem" "$temporary/identity.p12" "$temporary/password"
for version in v1 v2; do
    bounded /usr/bin/codesign --verify --strict "$temporary/$version"
    /usr/bin/codesign -d -r- "$temporary/$version" > "$evidence/$version.requirement" 2>&1
    sed -n '/^designated => /p' "$evidence/$version.requirement" > "$evidence/$version.dr"
    [[ -s "$evidence/$version.dr" ]] || { echo 'FAIL absent designated requirement'; exit 1; }
    shasum -a 256 "$temporary/$version" | awk '{print $1}' > "$evidence/$version.digest"
    bounded /usr/bin/codesign -d "--extract-certificates=$temporary/$version-certificate" "$temporary/$version"
done
cmp -s "$evidence/v1.dr" "$evidence/v2.dr" || { echo 'FAIL designated requirements differ'; exit 1; }
cmp -s "$temporary/v1-certificate0" "$temporary/v2-certificate0" || { echo 'FAIL signing certificates differ'; exit 1; }
if cmp -s "$evidence/v1.digest" "$evidence/v2.digest"; then echo 'FAIL version binary digests identical'; exit 1; fi
echo "PASS same-certificate same-identifier same-designated-requirement sha256=$(shasum -a 256 "$evidence/v1.dr" | awk '{print $1}')"
echo "PASS distinct-binaries v1=$(cat "$evidence/v1.digest") v2=$(cat "$evidence/v2.digest")"

mkdir "$evidence/history"
bounded "$temporary/v1" createlegacy "$evidence/history" "$keychain"
bounded "$temporary/v2" upgrade "$evidence/history" "$keychain"
bounded "$temporary/v2" restore "$evidence/history" "$keychain"
bounded "$temporary/v2" missing "$evidence/history" "$keychain"
mkdir "$evidence/corrupt"
cp "$evidence/history/history.encrypted" "$evidence/corrupt/history.encrypted"
# Append bytes to invalidate the real authenticated ciphertext without printing it.
printf '\001\002\003' >> "$evidence/corrupt/history.encrypted"
bounded "$temporary/v2" corrupt "$evidence/corrupt" "$keychain"
# Same content and identifier, different (ad-hoc) identity. No access-list changes.
cp "$temporary/v2" "$temporary/adhoc"
bounded /usr/bin/codesign --force --sign - --identifier "$identifier" "$temporary/adhoc"
bounded "$temporary/adhoc" denied "$evidence/history" "$keychain"
bounded "$temporary/v2" restore "$evidence/history" "$keychain"
awk '/^(PASS|FAIL) /' "$evidence/results.log"
finished=1
