#!/usr/bin/env bash
# Package the Rust HTTP adapter and task worker beneath Impart's profiled app
# identity. A raw sandboxed executable has no embedded provisioning profile and
# macOS will reject its app-group entitlement at exec time.

set -euo pipefail

PROFILE_PATH="${IMPART_PROFILE_PATH:?set IMPART_PROFILE_PATH to the macOS com.imbib.impart development profile}"
IDENTITY="${IDENTITY:-Apple Development: THOMAS G ABEL (E9NUL9QF47)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE="$REPO_ROOT/target/release/ImpartServices.app"
CONTENTS="$BUNDLE/Contents"
WORKER_BUNDLE="$REPO_ROOT/target/release/ImpartTaskWorker.app"
WORKER_CONTENTS="$WORKER_BUNDLE/Contents"

bash "$REPO_ROOT/crates/impress-ai-http/sign.sh"
bash "$REPO_ROOT/crates/impel-taskd/sign.sh"

mkdir -p "$CONTENTS/MacOS"
cp "$REPO_ROOT/crates/impress-ai-http/service-bundle/Info.plist" "$CONTENTS/Info.plist"
cp "$REPO_ROOT/target/release/impress-ai-server" "$CONTENTS/MacOS/impress-ai-server"
# Older development bundles carried taskd as an auxiliary executable, which
# macOS cannot validate against the bundle's main-executable profile.
rm -f "$CONTENTS/MacOS/impel-taskd"
cp "$PROFILE_PATH" "$CONTENTS/embedded.provisionprofile"

mkdir -p "$WORKER_CONTENTS/MacOS"
cp "$REPO_ROOT/crates/impress-ai-http/service-bundle/TaskWorker-Info.plist" "$WORKER_CONTENTS/Info.plist"
cp "$REPO_ROOT/target/release/impel-taskd" "$WORKER_CONTENTS/MacOS/impel-taskd"
cp "$PROFILE_PATH" "$WORKER_CONTENTS/embedded.provisionprofile"

codesign \
    --force \
    --sign "$IDENTITY" \
    --entitlements "$REPO_ROOT/crates/impress-ai-http/entitlements/impress-ai-server.entitlements" \
    --options runtime \
    --timestamp=none \
    "$BUNDLE"
codesign --verify --deep --strict --verbose=4 "$BUNDLE"

codesign \
    --force \
    --sign "$IDENTITY" \
    --entitlements "$REPO_ROOT/crates/impel-taskd/entitlements/impel-taskd.entitlements" \
    --options runtime \
    --timestamp=none \
    "$WORKER_BUNDLE"
codesign --verify --deep --strict --verbose=4 "$WORKER_BUNDLE"

echo "==> Built $BUNDLE"
echo "==> Built $WORKER_BUNDLE"
