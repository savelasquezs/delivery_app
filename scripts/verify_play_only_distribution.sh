#!/usr/bin/env bash
set -euo pipefail

failed=0

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  echo "::error file=$file::No se permiten binarios Android versionados."
  failed=1
done < <(git ls-files '*.apk')

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  echo "::error file=$file::Se encontró un manifiesto de distribución retirado."
  failed=1
done < <(git ls-files | grep -E '(^|/)delivery-app-release\.json$' || true)

patterns=(
  'flutter[[:space:]]+build[[:space:]]+apk'
  'apkUrl'
  'apkFileName'
  'DELIVERY_ANDROID_APK_PATH'
  'DELIVERY_APP_UPDATE_MANIFEST_URL'
)

for pattern in "${patterns[@]}"; do
  if matches="$(git grep -n -I -E "$pattern" -- . ':!scripts/verify_play_only_distribution.sh' || true)" \
    && [[ -n "$matches" ]]; then
    echo "$matches"
    echo "::error::Se encontró configuración operativa de distribución externa."
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "Distribución validada: Google Play y App Bundle únicamente."
