#!/usr/bin/env bash
#
# Build + codesign the `impress` CLI so it can read AND write inside the
# shared QG3MEYVHMS.com.impress.suite group container (the store and the
# ADR-0029 AI preferences under `workspace/ai/`). An unsigned binary is an
# unentitled process there: reads may work, but `mkdir`/`open` for writing
# block in the kernel forever — `impress select-model` hangs instead of
# failing. Same identity and entitlements as impress-mcp.
#
# Usage:
#   bash crates/impress-cli/sign.sh                 # release build, default identity
#   IDENTITY="045A71EC..." bash sign.sh             # specify identity SHA1 or name
#   PROFILE=debug bash sign.sh                      # sign a debug build
#
# Verify with:
#   codesign --display --entitlements - target/release/impress
#

set -euo pipefail

PROFILE="${PROFILE:-release}"
IDENTITY="${IDENTITY:-Apple Development: THOMAS G ABEL (E9NUL9QF47)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINARY="$REPO_ROOT/target/$PROFILE/impress"
ENTITLEMENTS="$REPO_ROOT/crates/impress-mcp/entitlements/impress-mcp.entitlements"

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "error: entitlements file missing: $ENTITLEMENTS" >&2
    exit 1
fi

echo "==> Building impress CLI ($PROFILE)…"
(cd "$REPO_ROOT" && cargo build --profile "${PROFILE/release/release}" -p impress-cli)

if [ ! -f "$BINARY" ]; then
    echo "error: binary not produced at $BINARY" >&2
    exit 1
fi

echo "==> Signing $BINARY"
codesign \
    --force \
    --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp=none \
    "$BINARY"

echo "==> Verifying entitlements"
codesign --display --entitlements - --xml "$BINARY" 2>&1 | grep -E "application-groups|group\." || {
    echo "warning: app-groups entitlement not visible in signed binary" >&2
}

echo "==> Done. Run:  $BINARY --help"
