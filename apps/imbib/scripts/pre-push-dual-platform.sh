#!/bin/bash
#
# Pre-push hook: enforces Rule 1 of the iOS/macOS parity protocol
# (ADR-023). When pushing changes that touch PublicationManagerCore,
# the imbib iOS scheme, or this hook itself, run a dry-build of both
# platforms and block the push if either fails.
#
# Install:
#   ln -sf ../../apps/imbib/scripts/pre-push-dual-platform.sh \
#          .git/hooks/pre-push
#
# The hook runs quickly in the common case — if you haven't touched
# PublicationManagerCore or the iOS target since the last push, it
# exits immediately without running a build.
#
# Skip with SKIP_DUAL_PLATFORM_CHECK=1 git push
#

set -e

if [ "${SKIP_DUAL_PLATFORM_CHECK:-0}" = "1" ]; then
    echo "pre-push: dual-platform check skipped (SKIP_DUAL_PLATFORM_CHECK=1)"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
IMBIB_DIR="$REPO_ROOT/apps/imbib/imbib"

# Detect changes since the upstream HEAD. If no upstream, diff against
# the local HEAD~1 as a best-effort fallback.
if git -C "$REPO_ROOT" rev-parse --abbrev-ref @{u} >/dev/null 2>&1; then
    BASE="@{u}"
else
    BASE="HEAD~1"
fi

CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only "$BASE" 2>/dev/null || echo "")

touches_shared=false
if echo "$CHANGED_FILES" | grep -qE \
    '^apps/imbib/PublicationManagerCore/|^apps/imbib/imbib/imbib-iOS/|^apps/imbib/imbib/project\.yml|^packages/|^apps/imbib/scripts/pre-push-dual-platform\.sh'; then
    touches_shared=true
fi

if [ "$touches_shared" = false ]; then
    echo "pre-push: no shared-core or iOS-target changes; skipping dual-platform build"
    exit 0
fi

echo "pre-push: building both platforms (Rule 1 of ADR-023)..."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "pre-push: xcodegen not installed; install with 'brew install xcodegen'"
    exit 1
fi

pushd "$IMBIB_DIR" >/dev/null

echo "pre-push: regenerating Xcode project"
xcodegen generate >/dev/null

echo "pre-push: building imbib (macOS)"
if ! xcodebuild build \
    -scheme imbib \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    >/tmp/imbib-macos-build.log 2>&1; then
    echo ""
    echo "ERROR: imbib (macOS) build failed. See /tmp/imbib-macos-build.log"
    tail -30 /tmp/imbib-macos-build.log
    popd >/dev/null
    exit 1
fi

echo "pre-push: building imbib-iOS (Simulator)"
if ! xcodebuild build \
    -scheme imbib-iOS \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    >/tmp/imbib-ios-build.log 2>&1; then
    echo ""
    echo "ERROR: imbib-iOS build failed. See /tmp/imbib-ios-build.log"
    echo ""
    echo "Rule 1 of the iOS/macOS parity protocol (ADR-023):"
    echo "  every commit that touches PublicationManagerCore must also"
    echo "  compile the iOS target. Fix the iOS build or add new broken"
    echo "  files to the 'iOS migration debt' excludes block in"
    echo "  apps/imbib/imbib/project.yml before pushing."
    echo ""
    tail -30 /tmp/imbib-ios-build.log
    popd >/dev/null
    exit 1
fi

popd >/dev/null

echo "pre-push: both platforms built successfully"
exit 0
