#!/usr/bin/env bash
#
# Build, sign and start imbib on koine's web frontend.
#
#   bash crates/imbib-host/run.sh                 # http://127.0.0.1:23127/ui/
#   bash crates/imbib-host/run.sh --window        # a native window on the Mac
#   PORT=23128 bash crates/imbib-host/run.sh      # another port
#   PROFILE=release bash crates/imbib-host/run.sh
#
# The binary is signed with the suite's app-group entitlement, the same
# identity and entitlements as impress-mcp and the impress CLI: without it the
# suite's store under ~/Library/Group Containers is unreadable (cargo build
# strips the signature, so every build is signed again here).
#
# The page is koine-web's browser bundle, built with dx in the koine checkout
# beside this repository (KOINE=<path> to name another); it is built once if
# missing. Extra arguments go to imbib-host (its flags are koine-host's).

set -euo pipefail

PROFILE="${PROFILE:-debug}"
PORT="${PORT:-23127}"
IDENTITY="${IDENTITY:-Apple Development: THOMAS G ABEL (E9NUL9QF47)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KOINE="${KOINE:-$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir | xargs dirname | xargs dirname)/koine}"
WEB_DIR="${WEB_DIR:-$KOINE/target/dx/koine-web/release/web/public}"
ENTITLEMENTS="$REPO_ROOT/crates/impress-mcp/entitlements/impress-mcp.entitlements"

if [ ! -f "$WEB_DIR/index.html" ]; then
    echo "==> Building the koine-web bundle in $KOINE"
    (cd "$KOINE/crates/koine-web" && CARGO_TARGET_DIR="$KOINE/target" dx build --platform web --release)
fi

cd "$REPO_ROOT"
if [ "$PROFILE" = release ]; then
    cargo build --release -p imbib-host
else
    cargo build -p imbib-host
fi
TARGET="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
BINARY="$TARGET/$PROFILE/imbib-host"

codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" \
    --options runtime --timestamp=none "$BINARY"

exec "$BINARY" --port "$PORT" --web-dir "$WEB_DIR" "$@"
