#!/usr/bin/env bash
# Build koine's browser frontend and put it where every app serves it.
#
# The frontend is `crates/koine-web` in the koine repository (koine
# docs/plan-koine-web.md D9). This script runs `dx build --platform web
# --release` there and copies the bundle into
# packages/ImpressAutomation/Sources/ImpressAutomation/Resources/koine-web/,
# which `KoineWebRoutes` serves as `GET /ui/*` on every app's automation port.
# The bundle is not committed (.gitignore); rebuild it when the pinned koine
# rev changes, then rebuild the apps.
#
# Where koine is: $KOINE_DIR if set, else the git checkout cargo already has
# for the rev pinned in Cargo.toml (so the bundle matches the Rust the app
# links). `dx` is the Dioxus CLI: `cargo install dioxus-cli --version '^0.7'
# --locked` (or `cargo binstall dioxus-cli`).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$here/packages/ImpressAutomation/Sources/ImpressAutomation/Resources/koine-web"

if [[ -z "${KOINE_DIR:-}" ]]; then
  manifest="$(cd "$here" && cargo metadata --format-version 1 2>/dev/null \
    | jq -r '.packages[] | select(.name == "koine-web") | .manifest_path' | head -1)"
  if [[ -z "$manifest" ]]; then
    echo "build-koine-web: no koine-web crate in this workspace's dependency graph." >&2
    echo "  Bump the koine rev in Cargo.toml to one that has crates/koine-web, or set KOINE_DIR." >&2
    exit 1
  fi
  KOINE_DIR="$(cd "$(dirname "$manifest")/../.." && pwd)"
fi
crate="$KOINE_DIR/crates/koine-web"
[[ -f "$crate/Cargo.toml" ]] || { echo "build-koine-web: $crate has no Cargo.toml" >&2; exit 1; }
command -v dx >/dev/null || { echo "build-koine-web: dx not on PATH (cargo install dioxus-cli --version '^0.7' --locked)" >&2; exit 1; }

echo "build-koine-web: building $crate"
(cd "$crate" && dx build --platform web --release)

public="$KOINE_DIR/target/dx/koine-web/release/web/public"
[[ -f "$public/index.html" ]] || { echo "build-koine-web: no bundle at $public" >&2; exit 1; }

mkdir -p "$dest"
# Keep the README (the one committed file); replace everything else.
find "$dest" -mindepth 1 ! -name README.md -exec rm -rf {} + 2>/dev/null || true
cp -R "$public"/. "$dest"/
echo "build-koine-web: bundle copied to $dest"
ls "$dest"
