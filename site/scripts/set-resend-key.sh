#!/bin/bash
# Takes the Resend API key from the clipboard, writes it and MAIL_FROM into .env.production.local,
# then pushes every variable to Vercel and redeploys. The key is never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
key="$(pbpaste | tr -d '[:space:]')"
case "$key" in
    re_*) ;;
    *) echo "剪贴板里不是 Resend API key（应以 re_ 开头）。先在 Resend → API Keys 复制，再运行这条命令。"; exit 1 ;;
esac
from="${MAIL_FROM:-Oil Find <hello@oiloil.org>}"
file=".env.production.local"
set_var() {
    if grep -q "^$1=" "$file"; then
        sed -i '' "s|^$1=.*|$1=$2|" "$file"
    else
        printf '%s=%s\n' "$1" "$2" >> "$file"
    fi
}
set_var RESEND_API_KEY "$key"
set_var MAIL_FROM "$from"
chmod 600 "$file"
echo "已写入 RESEND_API_KEY和 MAIL_FROM=$from，开始推送到 Vercel。"
exec scripts/push-env.sh
