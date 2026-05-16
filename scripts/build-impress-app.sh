#!/usr/bin/env bash
# Build an impress app at a deterministic DerivedData path and refresh
# the ~/MyApplications/<app>.app launcher symlink.
#
# Usage: scripts/build-impress-app.sh <app> [configuration]
#   <app>: imbib | imprint | implore | impel | impart
#   configuration: Debug (default) | Release

set -euo pipefail

# Make Homebrew tools (xcodegen, xcbeautify) visible to non-login shells.
export PATH="/opt/homebrew/bin:$PATH"

# Pick up DEVELOPMENT_TEAM from ~/.zprofile when running from a non-login
# shell (CI, background tasks). impel's project.yml substitutes this in.
if [ -z "${DEVELOPMENT_TEAM:-}" ] && [ -f "$HOME/.zprofile" ]; then
    eval "$(grep '^export DEVELOPMENT_TEAM=' "$HOME/.zprofile" || true)"
fi

APP="${1:?Usage: $0 <app> [Debug|Release]}"
CONFIG="${2:-Debug}"

case "$APP" in
    imbib)   PROJECT_REL="apps/imbib/imbib/imbib.xcodeproj"; SPEC_DIR="apps/imbib/imbib" ;;
    imprint) PROJECT_REL="apps/imprint/imprint.xcodeproj";   SPEC_DIR="apps/imprint" ;;
    implore) PROJECT_REL="apps/implore/implore.xcodeproj";   SPEC_DIR="apps/implore" ;;
    impel)   PROJECT_REL="apps/impel/impel.xcodeproj";       SPEC_DIR="apps/impel" ;;
    impart)  PROJECT_REL="apps/impart/impart.xcodeproj";     SPEC_DIR="apps/impart" ;;
    *) echo "Unknown app: $APP (expected imbib|imprint|implore|impel|impart)" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/$APP"
APP_PATH="$DERIVED/Build/Products/$CONFIG/$APP.app"
LAUNCHER="$HOME/MyApplications/$APP.app"

cd "$REPO_ROOT"

# Regenerate .xcodeproj from project.yml if xcodegen is installed.
if command -v xcodegen >/dev/null 2>&1 && [ -f "$SPEC_DIR/project.yml" ]; then
    (cd "$SPEC_DIR" && xcodegen generate >/dev/null)
fi

# Pretty-print via xcbeautify when available; fall back to raw output.
if command -v xcbeautify >/dev/null 2>&1; then
    PIPE=(xcbeautify --renderer terminal)
else
    PIPE=(cat)
fi

set -o pipefail
xcodebuild \
    -project "$PROJECT_REL" \
    -scheme "$APP" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build 2>&1 | "${PIPE[@]}"

mkdir -p "$HOME/MyApplications"
ln -sfn "$APP_PATH" "$LAUNCHER"
echo
echo "✓ Built $APP_PATH"
echo "✓ Launcher $LAUNCHER → $APP_PATH"
