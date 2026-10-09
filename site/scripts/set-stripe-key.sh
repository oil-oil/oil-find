#!/bin/bash
# Takes the Stripe secret key from the clipboard, writes it into .env.production.local,
# then pushes every variable to Vercel and redeploys. The key is never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
key="$(pbpaste | tr -d '[:space:]')"
case "$key" in
    sk_live_*|sk_test_*|rk_live_*|rk_test_*) ;;
    *) echo "剪贴板里不是 Stripe 密钥（应以 sk_live_ 开头）。先在 Stripe 后台复制 Secret key，再运行这条命令。"; exit 1 ;;
esac
file=".env.production.local"
if grep -q '^STRIPE_SECRET_KEY=' "$file"; then
    sed -i '' "s|^STRIPE_SECRET_KEY=.*|STRIPE_SECRET_KEY=$key|" "$file"
else
    printf 'STRIPE_SECRET_KEY=%s\n' "$key" >> "$file"
fi
chmod 600 "$file"
echo "已写入 STRIPE_SECRET_KEY，开始推送到 Vercel。"
exec scripts/push-env.sh
