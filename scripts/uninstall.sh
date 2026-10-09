#!/bin/bash
set -euo pipefail
if [[ $# -ne 0 ]]; then
    printf '%s\n' 'Usage: scripts/uninstall.sh' >&2
    exit 2
fi

printf '%s\n' 'The following will be deleted:' \
    '/Applications/Oil Find.app' \
    "$HOME/Library/Application Support/Oil Find" \
    'Settings: com.oiloil.find' \
    'Legacy authorization item: com.oiloil.find.trial' \
    'Clipboard encryption key: com.oiloil.find.clipboard-history'
read -r -p 'Continue? [y/N] ' confirmation
[[ "$confirmation" == y ]] || exit 0

if pgrep -x OilFind >/dev/null; then
    osascript -e 'quit app id "com.oiloil.find"' &
    QUIT_REQUEST_PID=$!
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! pgrep -x OilFind >/dev/null; then break; fi
        sleep 0.1
    done
    if kill -0 "$QUIT_REQUEST_PID" 2>/dev/null; then kill "$QUIT_REQUEST_PID" 2>/dev/null || true; fi
    wait "$QUIT_REQUEST_PID" 2>/dev/null || true
    if pgrep -x OilFind >/dev/null; then
        printf '%s\n' 'Oil Find did not quit within 5 seconds.' >&2
        exit 1
    fi
fi

rm -rf "/Applications/Oil Find.app" "$HOME/Library/Application Support/Oil Find"
defaults delete com.oiloil.find >/dev/null 2>&1 || true
security delete-generic-password -s com.oiloil.find.trial >/dev/null 2>&1 || true
security delete-generic-password -s com.oiloil.find.clipboard-history -a aes-gcm-v1 >/dev/null 2>&1 || true
