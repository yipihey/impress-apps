#!/usr/bin/env bash
#
# Build + codesign the impel-taskd binary so it can read the shared
# group.com.impress.suite SQLite store (which is otherwise blocked by the
# macOS sandbox for unsigned binaries).
#
# Usage:
#   bash crates/impel-taskd/sign.sh                  # release build, default identity
#   IDENTITY="045A71EC..."  bash sign.sh             # specify identity SHA1 or name
#   PROFILE=debug  bash sign.sh                      # sign a debug build
#   INSTALL_FOR_IMPART=1 bash sign.sh                # also stage for Impart startup
#
# Verify with:
#   codesign --display --entitlements - target/release/impel-taskd
#

set -euo pipefail

PROFILE="${PROFILE:-release}"
# Default to the Apple Development cert on team QG3MEYVHMS (the team that
# registered group.com.impress.suite). Override with $IDENTITY.
IDENTITY="${IDENTITY:-Apple Development: THOMAS G ABEL (E9NUL9QF47)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINARY="$REPO_ROOT/target/$PROFILE/impel-taskd"
ENTITLEMENTS="$REPO_ROOT/crates/impel-taskd/entitlements/impel-taskd.entitlements"

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "error: entitlements file missing: $ENTITLEMENTS" >&2
    exit 1
fi

echo "==> Building impel-taskd ($PROFILE)…"
(cd "$REPO_ROOT" && cargo build --profile "${PROFILE/release/release}" -p impel-taskd)

if [ ! -f "$BINARY" ]; then
    echo "error: binary not produced at $BINARY" >&2
    exit 1
fi

echo "==> Signing $BINARY"
echo "    identity:     $IDENTITY"
echo "    entitlements: $ENTITLEMENTS"

# --force: re-sign even if previously signed
# --options runtime: hardened runtime (Apple's recommended baseline)
# --timestamp=none: skip the Apple timestamp server (fine for local dev,
#                   omit/flip for distribution)
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

if [ "${INSTALL_FOR_IMPART:-0}" = "1" ]; then
    INSTALL_DIRECTORY="$HOME/Library/Application Scripts/com.imbib.impart"
    INSTALL_PATH="$INSTALL_DIRECTORY/impel-taskd"
    mkdir -p "$INSTALL_DIRECTORY"
    cp "$BINARY" "$INSTALL_PATH"
    chmod 755 "$INSTALL_PATH"
    echo "==> Installed Impart model worker: $INSTALL_PATH"
fi

echo "==> Done. Run:  $BINARY --help"
