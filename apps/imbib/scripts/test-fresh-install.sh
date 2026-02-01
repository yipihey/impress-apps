#!/bin/bash
#
# test-fresh-install.sh
#
# Simulates a fresh install of imbib for testing the new user experience.
# This is useful for testing:
# - Welcome screen / onboarding flow
# - Default library creation with canonical ID
# - CloudKit sync from scratch
# - Migration from existing data
#
# WARNING: This deletes all local imbib data! Make sure you have a backup.
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== imbib Fresh Install Test ===${NC}"
echo ""

# App identifiers
BUNDLE_ID="com.imbib.app"
APP_NAME="imbib"

# Data locations
APP_SUPPORT_DIR="$HOME/Library/Application Support/$APP_NAME"
CLOUDKIT_CACHE_DIR="$HOME/Library/Caches/CloudKit/$BUNDLE_ID"
PREFERENCES_FILE="$HOME/Library/Preferences/$BUNDLE_ID.plist"
CONTAINER_DIR="$HOME/Library/Containers/$BUNDLE_ID"

# Safety check - confirm with user
echo -e "${RED}WARNING: This will delete ALL local imbib data!${NC}"
echo ""
echo "The following will be deleted:"
echo "  - $APP_SUPPORT_DIR"
echo "  - $PREFERENCES_FILE"
echo "  - CloudKit cache data"
echo "  - Container data (if sandboxed)"
echo ""
echo "CloudKit data in iCloud will NOT be deleted (sync will restore it)."
echo ""
read -p "Are you sure? Type 'yes' to continue: " confirm

if [[ "$confirm" != "yes" ]]; then
    echo -e "${YELLOW}Aborted.${NC}"
    exit 0
fi

# Kill the app if running
echo -e "${BLUE}Stopping imbib if running...${NC}"
pkill -9 "$APP_NAME" 2>/dev/null || true
sleep 1

# Delete local data
echo -e "${BLUE}Deleting local data...${NC}"

if [[ -d "$APP_SUPPORT_DIR" ]]; then
    rm -rf "$APP_SUPPORT_DIR"
    echo "  Deleted: $APP_SUPPORT_DIR"
fi

if [[ -f "$PREFERENCES_FILE" ]]; then
    rm -f "$PREFERENCES_FILE"
    echo "  Deleted: $PREFERENCES_FILE"
fi

if [[ -d "$CLOUDKIT_CACHE_DIR" ]]; then
    rm -rf "$CLOUDKIT_CACHE_DIR"
    echo "  Deleted: $CLOUDKIT_CACHE_DIR"
fi

if [[ -d "$CONTAINER_DIR" ]]; then
    rm -rf "$CONTAINER_DIR"
    echo "  Deleted: $CONTAINER_DIR"
fi

# Also check for any other CloudKit-related caches
CLOUDKIT_METADATA="$HOME/Library/Application Support/CloudKit"
if [[ -d "$CLOUDKIT_METADATA" ]]; then
    rm -rf "$CLOUDKIT_METADATA/$BUNDLE_ID" 2>/dev/null || true
fi

# Reset UserDefaults via defaults command
echo -e "${BLUE}Resetting UserDefaults...${NC}"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
echo "  Reset: $BUNDLE_ID defaults"

# Optional: Set a flag that the app can detect for showing welcome screen
echo -e "${BLUE}Setting fresh install flag...${NC}"
defaults write "$BUNDLE_ID" "_freshInstallTestMode" -bool true
defaults write "$BUNDLE_ID" "showWelcomeScreen" -bool true
echo "  Set: _freshInstallTestMode = true"
echo "  Set: showWelcomeScreen = true"

echo ""
echo -e "${GREEN}Done! Local data has been cleared.${NC}"
echo ""
echo "Next steps:"
echo "  1. Launch imbib from Xcode or /Applications"
echo "  2. The app should show the welcome/onboarding screen"
echo "  3. Create a new library - it should use the canonical UUID"
echo "  4. If CloudKit is enabled, previous data should sync down"
echo ""
echo "To verify canonical UUID, check the console logs for:"
echo "  'Using canonical default library ID for first library'"
echo ""
echo -e "${YELLOW}Note: To test with a specific Xcode scheme:${NC}"
echo "  xcodebuild -workspace imbib.xcworkspace -scheme imbib run"
echo ""
