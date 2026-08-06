#!/usr/bin/env bash
# Build and sign the loopback HTTP adapter with access to the Impress app group.

set -euo pipefail

PROFILE="${PROFILE:-release}"
IDENTITY="${IDENTITY:-Apple Development: THOMAS G ABEL (E9NUL9QF47)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINARY="$REPO_ROOT/target/$PROFILE/impress-ai-server"
ENTITLEMENTS="$REPO_ROOT/crates/impress-ai-http/entitlements/impress-ai-server.entitlements"

echo "==> Building impress-ai-server ($PROFILE)…"
(cd "$REPO_ROOT" && cargo build --profile "${PROFILE/release/release}" -p impress-ai-http --bin impress-ai-server)

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

echo "==> Done"
