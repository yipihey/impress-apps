#!/usr/bin/env bash
# Refresh vendor/typst-packages from the typst CLI cache, pinned closure only.
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${TYPST_PACKAGE_CACHE_PATH:-$HOME/Library/Caches/typst/packages}"
PINNED=(lilaq/0.6.0 tiptoe/0.4.0 zero/0.6.1 elembic/1.1.1 komet/0.1.0 komet/0.2.0)
for p in "${PINNED[@]}"; do
  src="$CACHE/preview/$p"
  [ -d "$src" ] || { echo "missing in cache: $p (warm it with the typst CLI)"; exit 1; }
  dst="vendor/typst-packages/preview/$p"
  rm -rf "$dst" && mkdir -p "$(dirname "$dst")" && cp -R "$src" "$dst"
done
echo "synced ${#PINNED[@]} pinned packages into vendor/typst-packages"
