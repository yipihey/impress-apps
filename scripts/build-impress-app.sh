#!/usr/bin/env bash
# Build an impress app at a deterministic DerivedData path and refresh
# the ~/MyApplications/<app>.app launcher symlink.
#
# Usage: scripts/build-impress-app.sh <app> [configuration]
#   <app>: imbib | imprint | implore | impel | impart | impress
#   configuration: Debug (default) | Release

set -euo pipefail

# Make Homebrew tools (xcodegen, xcbeautify) visible to non-login shells.
export PATH="/opt/homebrew/bin:$PATH"

# Pick up DEVELOPMENT_TEAM from ~/.zprofile when running from a non-login
# shell (CI, background tasks). impel's project.yml substitutes this in.
if [ -z "${DEVELOPMENT_TEAM:-}" ] && [ -f "$HOME/.zprofile" ]; then
    eval "$(grep '^export DEVELOPMENT_TEAM=' "$HOME/.zprofile" || true)"
fi

# Keep Xcode's build artifacts out of Spotlight. Every copy of an app under
# DerivedData is another bundle Spotlight can rank ABOVE the one in
# ~/Applications, and on 2026-09-08 that meant launching a day-old,
# ad-hoc-signed build that prompted for app-group access on every launch.
#
# This marker only stops FUTURE indexing — it cannot purge what is already
# indexed. To do that (and to make this stick regardless of how a build is
# invoked) add DerivedData to System Settings > Siri & Spotlight > Spotlight
# Privacy. `scripts/check-app-installs.sh` reports what Spotlight can see.
DERIVED_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
[ -d "$DERIVED_ROOT" ] && [ ! -e "$DERIVED_ROOT/.metadata_never_index" ] \
    && touch "$DERIVED_ROOT/.metadata_never_index" 2>/dev/null || true

APP="${1:?Usage: $0 <app> [Debug|Release]}"
CONFIG="${2:-Debug}"

case "$APP" in
    imbib)   PROJECT_REL="apps/imbib/imbib/imbib.xcodeproj"; SPEC_DIR="apps/imbib/imbib" ;;
    imprint) PROJECT_REL="apps/imprint/imprint.xcodeproj";   SPEC_DIR="apps/imprint" ;;
    implore) PROJECT_REL="apps/implore/implore.xcodeproj";   SPEC_DIR="apps/implore" ;;
    impel)   PROJECT_REL="apps/impel/impel.xcodeproj";       SPEC_DIR="apps/impel" ;;
    impart)  PROJECT_REL="apps/impart/impart.xcodeproj";     SPEC_DIR="apps/impart" ;;
    impress) PROJECT_REL="apps/impress/impress.xcodeproj";   SPEC_DIR="apps/impress" ;;
    *) echo "Unknown app: $APP (expected imbib|imprint|implore|impel|impart|impress)" >&2; exit 1 ;;
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
