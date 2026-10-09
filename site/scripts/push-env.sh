#!/bin/bash
# Run locally after filling in the file; --no-deploy only synchronizes production variables.
set +x
set -euo pipefail
umask 077
deploy=1
case "${1:-}" in
    --no-deploy) deploy=0 ;;
    '') ;;
    *) echo '用法：bash scripts/push-env.sh [--no-deploy]' >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { echo '参数过多。' >&2; exit 1; }
cd "$(dirname "$0")/.."
file=".env.production.local"
[[ -f "$file" && ! -L "$file" ]] || { echo '缺少安全的 .env.production.local；请先生成正式密钥。' >&2; exit 1; }
command -v vercel >/dev/null || { echo '未找到 Vercel CLI；请安装并登录后重试。' >&2; exit 1; }
[[ -f .vercel/project.json ]] || { echo '尚未关联 Vercel 项目；请先在 site/ 运行 vercel link 并选择正确项目。' >&2; exit 1; }
chmod 600 "$file"
while IFS='=' read -r name value || [[ -n "$name" ]]; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || { echo '环境文件包含无效变量名；请在本机修正后重试。' >&2; exit 1; }
    [[ "$name" == "LICENSE_PUBLIC_KEY" ]] && continue
    [[ "$name" != "STRIPE_FAKE" ]] || { echo '正式环境禁止 STRIPE_FAKE；请移除后重试。' >&2; exit 1; }
    [[ -z "$value" ]] && { echo "skip $name (empty)"; continue; }
    if ! printf '%s' "$value" | vercel env add "$name" production --force --sensitive >/dev/null 2>&1; then
        echo "同步 $name 失败；请检查 Vercel 登录、项目关联和权限后重试。" >&2
        exit 1
    fi
    echo "已同步 $name"
done < "$file"
unset value
if [[ "$deploy" == 1 ]]; then
    vercel deploy --prod >/dev/null 2>&1 || { echo '部署失败；请到 Vercel 后台检查。' >&2; exit 1; }
    echo '已部署。'
else
    echo 'production 环境变量同步完成；未部署。'
fi
