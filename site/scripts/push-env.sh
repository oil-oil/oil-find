#!/bin/bash
# Pushes every variable in .env.production.local to the Vercel production environment, then redeploys.
# Run from site/ after filling in the file. Values never leave this machine except to Vercel.
set -euo pipefail
cd "$(dirname "$0")/.."
file=".env.production.local"
[[ -f "$file" ]] || { echo "missing $file"; exit 1; }
while IFS='=' read -r name value; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    [[ "$name" == "LICENSE_PUBLIC_KEY" ]] && continue
    [[ -z "$value" ]] && { echo "skip $name (empty)"; continue; }
    printf '%s' "$value" | vercel env add "$name" production --force >/dev/null
    echo "set $name"
done < "$file"
vercel deploy --prod
