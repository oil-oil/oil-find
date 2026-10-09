#!/bin/bash
set -euo pipefail
PURGE=false
case "${1:-}" in
    '') [[ $# -eq 0 ]] || exit 2 ;;
    --purge) [[ $# -eq 1 ]] || exit 2; PURGE=true ;;
    *) printf '%s\n' 'Usage: scripts/uninstall.sh [--purge]' >&2; exit 2 ;;
esac

printf '%s\n' 'The following will be deleted:' \
    '/Applications/Oil Find.app' \
    "$HOME/Library/Application Support/Oil Find" \
    'Settings: com.oiloil.find' \
    'Legacy authorization item: com.oiloil.find.trial'
if [[ "$PURGE" == true ]]; then
    printf '%s\n' 'Pro trial anchors will also be deleted.'
else
    printf '%s\n' 'Pro trial anchors will be kept.'
fi
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
# Retain both opt-in evaluation anchors across a normal reinstall.
PRO_EVALUATION_START="$(defaults read com.oiloil.find proEvaluationStartedAt 2>/dev/null || true)"
PRO_EVALUATION_SEEN="$(defaults read com.oiloil.find proEvaluationLastSeenAt 2>/dev/null || true)"
PRO_EVALUATION_ENDED="$(defaults read com.oiloil.find proEvaluationEndedAt 2>/dev/null || true)"
defaults delete com.oiloil.find >/dev/null 2>&1 || true
if [[ "$PURGE" == false ]]; then
    if [[ -n "$PRO_EVALUATION_START" && -n "$PRO_EVALUATION_SEEN" ]]; then
        defaults write com.oiloil.find proEvaluationStartedAt -float "$PRO_EVALUATION_START"
        defaults write com.oiloil.find proEvaluationLastSeenAt -float "$PRO_EVALUATION_SEEN"
        if [[ -n "$PRO_EVALUATION_ENDED" ]]; then
            defaults write com.oiloil.find proEvaluationEndedAt -float "$PRO_EVALUATION_ENDED"
        fi
    fi
else
    security delete-generic-password -s com.oiloil.find.pro.evaluation >/dev/null 2>&1 || true
fi
security delete-generic-password -s com.oiloil.find.trial >/dev/null 2>&1 || true
