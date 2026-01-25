#!/bin/bash
#
# Build a signed and notarized release of imbib
#
# Usage: ./scripts/build-release.sh [version]
# Example: ./scripts/build-release.sh v1.2.1
#
# Prerequisites:
# - Xcode with valid Developer ID certificate
# - xcodegen installed (brew install xcodegen)
# - create-dmg installed (brew install create-dmg)
# - App-specific password for notarization
#
# Environment variables (or will prompt):
# - APPLE_ID: Your Apple ID email
# - APPLE_APP_PASSWORD: App-specific password for notarization
# - TEAM_ID: Your Apple Developer Team ID
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
IMBIB_DIR="$PROJECT_DIR/imbib"

# Version from argument or git tag
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "dev")}"

echo -e "${GREEN}Building imbib $VERSION${NC}"
echo "================================"

# Check prerequisites
command -v xcodegen >/dev/null 2>&1 || { echo -e "${RED}xcodegen is required. Install with: brew install xcodegen${NC}"; exit 1; }
command -v create-dmg >/dev/null 2>&1 || { echo -e "${YELLOW}create-dmg not found. Will use hdiutil fallback.${NC}"; }

# Prompt for credentials if not set
if [ -z "$APPLE_ID" ]; then
    read -p "Apple ID (email): " APPLE_ID
fi

if [ -z "$APPLE_APP_PASSWORD" ]; then
    read -s -p "App-specific password: " APPLE_APP_PASSWORD
    echo
fi

if [ -z "$TEAM_ID" ]; then
    read -p "Team ID: " TEAM_ID
fi

# Create build directory
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR"/*

# Generate Xcode project
echo -e "\n${GREEN}Generating Xcode project...${NC}"
cd "$IMBIB_DIR"
xcodegen generate

# Build archive
echo -e "\n${GREEN}Building archive...${NC}"
xcodebuild -scheme imbib \
    -configuration Release \
    -archivePath "$BUILD_DIR/imbib.xcarchive" \
    -destination 'generic/platform=macOS' \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    archive

# Create export options
cat > "$BUILD_DIR/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

# Export app
echo -e "\n${GREEN}Exporting app...${NC}"
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/imbib.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

# Verify Safari extension is bundled
if [ -d "$BUILD_DIR/export/imbib.app/Contents/PlugIns/imbib Safari Extension.appex" ]; then
    echo -e "${GREEN}✓ Safari extension bundled${NC}"
else
    echo -e "${RED}✗ Safari extension NOT found in bundle!${NC}"
    exit 1
fi

# Notarize app
echo -e "\n${GREEN}Notarizing app...${NC}"
cd "$BUILD_DIR/export"
ditto -c -k --keepParent imbib.app imbib-notarize.zip

xcrun notarytool submit imbib-notarize.zip \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

# Staple notarization ticket
echo -e "\n${GREEN}Stapling notarization ticket...${NC}"
xcrun stapler staple imbib.app

# Create DMG
echo -e "\n${GREEN}Creating DMG...${NC}"
cd "$BUILD_DIR"

DMG_NAME="imbib-${VERSION}-macOS.dmg"

if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "imbib" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "imbib.app" 150 190 \
        --hide-extension "imbib.app" \
        --app-drop-link 450 190 \
        --no-internet-enable \
        "$DMG_NAME" \
        "export/imbib.app" || {
            echo -e "${YELLOW}create-dmg failed, using hdiutil fallback${NC}"
            hdiutil create -volname "imbib" -srcfolder "export/imbib.app" -ov -format UDZO "$DMG_NAME"
        }
else
    hdiutil create -volname "imbib" -srcfolder "export/imbib.app" -ov -format UDZO "$DMG_NAME"
fi

# Notarize DMG
echo -e "\n${GREEN}Notarizing DMG...${NC}"
xcrun notarytool submit "$DMG_NAME" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

xcrun stapler staple "$DMG_NAME"

# Done
echo -e "\n${GREEN}================================${NC}"
echo -e "${GREEN}Build complete!${NC}"
echo -e "DMG: ${BUILD_DIR}/${DMG_NAME}"
echo ""
echo "To upload to GitHub release:"
echo "  gh release upload $VERSION \"$BUILD_DIR/$DMG_NAME\""
