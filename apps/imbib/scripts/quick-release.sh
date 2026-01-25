#!/bin/bash
#
# Quick release build for Apple Silicon only (arm64)
# ~3-4x faster than full CI build by skipping Intel and iOS targets
#
# Usage: ./scripts/quick-release.sh [version]
#        ./scripts/quick-release.sh --setup    # Store credentials in Keychain
#
# Example: ./scripts/quick-release.sh v1.2.1
#
# Prerequisites:
# - Apple Silicon Mac (M1/M2/M3)
# - Xcode with valid Developer ID certificate
# - xcodegen installed (brew install xcodegen)
# - create-dmg installed (brew install create-dmg)
# - Rust toolchain (rustup)
#
# Credentials are read from macOS Keychain (run --setup first)
# Fallback: environment variables APPLE_ID, APPLE_APP_PASSWORD, TEAM_ID
#

set -e

# Keychain service name
KEYCHAIN_SERVICE="imbib-release"

# ============================================================================
# Keychain Setup Mode
# ============================================================================
if [[ "$1" == "--setup" ]]; then
    echo "=== Keychain Credential Setup ==="
    echo ""
    echo "This will store your notarization credentials securely in macOS Keychain."
    echo "You only need to do this once."
    echo ""

    # Apple ID
    read -p "Apple ID (email): " SETUP_APPLE_ID
    security add-generic-password -U -a "apple-id" -s "$KEYCHAIN_SERVICE" -w "$SETUP_APPLE_ID" 2>/dev/null || \
    security add-generic-password -a "apple-id" -s "$KEYCHAIN_SERVICE" -w "$SETUP_APPLE_ID"
    echo "✓ Apple ID stored"

    # App-specific password
    echo ""
    echo "Create an app-specific password at: https://appleid.apple.com/account/manage"
    read -s -p "App-specific password: " SETUP_APP_PASSWORD
    echo ""
    security add-generic-password -U -a "app-password" -s "$KEYCHAIN_SERVICE" -w "$SETUP_APP_PASSWORD" 2>/dev/null || \
    security add-generic-password -a "app-password" -s "$KEYCHAIN_SERVICE" -w "$SETUP_APP_PASSWORD"
    echo "✓ App-specific password stored"

    # Team ID
    echo ""
    echo "Find your Team ID at: https://developer.apple.com/account -> Membership"
    read -p "Team ID: " SETUP_TEAM_ID
    security add-generic-password -U -a "team-id" -s "$KEYCHAIN_SERVICE" -w "$SETUP_TEAM_ID" 2>/dev/null || \
    security add-generic-password -a "team-id" -s "$KEYCHAIN_SERVICE" -w "$SETUP_TEAM_ID"
    echo "✓ Team ID stored"

    echo ""
    echo "=== Setup Complete ==="
    echo "Credentials stored in Keychain under service: $KEYCHAIN_SERVICE"
    echo "You can now run: ./scripts/quick-release.sh v1.2.3"
    exit 0
fi

# ============================================================================
# Retrieve credentials from Keychain (with fallback to env vars)
# ============================================================================
get_credential() {
    local account="$1"
    local env_var="$2"
    local env_value="${!env_var}"

    # Try environment variable first
    if [[ -n "$env_value" ]]; then
        echo "$env_value"
        return
    fi

    # Try Keychain
    local keychain_value
    keychain_value=$(security find-generic-password -a "$account" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) || true

    if [[ -n "$keychain_value" ]]; then
        echo "$keychain_value"
    fi
}

APPLE_ID=$(get_credential "apple-id" "APPLE_ID")
APPLE_APP_PASSWORD=$(get_credential "app-password" "APPLE_APP_PASSWORD")
TEAM_ID=$(get_credential "team-id" "TEAM_ID")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
IMBIB_DIR="$PROJECT_DIR/imbib"
IMBIB_CORE_DIR="$PROJECT_DIR/imbib-core"

# Version from argument or git tag
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "dev")}"

# Timing
START_TIME=$(date +%s)
step_start() {
    STEP_START=$(date +%s)
    echo -e "\n${BLUE}[$1]${NC} $2"
}
step_end() {
    local elapsed=$(($(date +%s) - STEP_START))
    echo -e "${GREEN}  Done in ${elapsed}s${NC}"
}

echo -e "${GREEN}=== Quick Release Build (Apple Silicon Only) ===${NC}"
echo -e "Version: ${YELLOW}$VERSION${NC}"
echo -e "Target:  ${YELLOW}aarch64-apple-darwin (arm64)${NC}"
echo ""

# Check we're on Apple Silicon
if [[ "$(uname -m)" != "arm64" ]]; then
    echo -e "${RED}Error: This script is designed for Apple Silicon Macs${NC}"
    echo "For Intel builds, use the full CI pipeline"
    exit 1
fi

# Check prerequisites
command -v xcodegen >/dev/null 2>&1 || { echo -e "${RED}xcodegen is required. Install with: brew install xcodegen${NC}"; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo -e "${RED}Rust/cargo is required. Install from rustup.rs${NC}"; exit 1; }

# Check credentials
MISSING_CREDS=()
if [ -z "$APPLE_ID" ]; then
    MISSING_CREDS+=("APPLE_ID")
fi
if [ -z "$APPLE_APP_PASSWORD" ]; then
    MISSING_CREDS+=("APPLE_APP_PASSWORD")
fi
if [ -z "$TEAM_ID" ]; then
    MISSING_CREDS+=("TEAM_ID")
fi

if [ ${#MISSING_CREDS[@]} -gt 0 ]; then
    echo -e "${RED}Missing credentials: ${MISSING_CREDS[*]}${NC}"
    echo ""
    echo "Run this command first to store credentials in Keychain:"
    echo "  ./scripts/quick-release.sh --setup"
    echo ""
    echo "Or set environment variables: APPLE_ID, APPLE_APP_PASSWORD, TEAM_ID"
    exit 1
fi

echo -e "Credentials: ${GREEN}✓ loaded from Keychain${NC}"

# Create build directory
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR"/*

# ============================================================================
# Cleanup trap - restore committed framework on exit (success or failure)
# ============================================================================
cleanup_framework() {
    local COMMITTED_FRAMEWORK_DIR="$PROJECT_DIR/imbib-core/frameworks"
    local BACKUP_FRAMEWORK_DIR="$BUILD_DIR/frameworks-backup"

    if [ -d "$BACKUP_FRAMEWORK_DIR" ]; then
        echo -e "\n${YELLOW}Restoring committed framework...${NC}"
        rm -rf "$COMMITTED_FRAMEWORK_DIR"
        mv "$BACKUP_FRAMEWORK_DIR" "$COMMITTED_FRAMEWORK_DIR"
        echo -e "${GREEN}✓ Committed framework restored${NC}"
    fi
}
trap cleanup_framework EXIT

# ============================================================================
# Step 1: Build Rust for Apple Silicon only
# ============================================================================
step_start "1/6" "Building Rust library (arm64 only)..."

cd "$IMBIB_CORE_DIR"

# Set deployment target
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

# Ensure target is installed
rustup target add aarch64-apple-darwin 2>/dev/null || true

# Build only arm64 macOS
cargo build --release --target aarch64-apple-darwin

step_end

# ============================================================================
# Step 2: Create arm64-only XCFramework (in BUILD directory, not source)
# ============================================================================
step_start "2/6" "Creating XCFramework (arm64 only)..."

RUST_BUILD_DIR="$IMBIB_CORE_DIR/target"
# IMPORTANT: Use BUILD_DIR, not the committed frameworks directory
# The committed imbib-core/frameworks/ has all slices for Xcode Cloud
LOCAL_FRAMEWORK_DIR="$BUILD_DIR/frameworks"
XCFRAMEWORK_NAME="ImbibCore"

# Clean and create LOCAL framework directory (not the committed one!)
rm -rf "$LOCAL_FRAMEWORK_DIR"
mkdir -p "$LOCAL_FRAMEWORK_DIR"

# Generate Swift bindings
echo "  Generating Swift bindings..."
cargo run --bin uniffi-bindgen generate \
    --library "$RUST_BUILD_DIR/aarch64-apple-darwin/release/libimbib_core.dylib" \
    --language swift \
    --out-dir "$LOCAL_FRAMEWORK_DIR/generated"

# Create module map
cat > "$LOCAL_FRAMEWORK_DIR/module.modulemap" << 'MODULEMAP'
module imbib_core {
    header "imbib_coreFFI.h"
    export *
}
MODULEMAP

# Create XCFramework with single architecture (no lipo needed)
echo "  Creating XCFramework..."
rm -rf "$LOCAL_FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

xcodebuild -create-xcframework \
    -library "$RUST_BUILD_DIR/aarch64-apple-darwin/release/libimbib_core.a" \
    -headers "$LOCAL_FRAMEWORK_DIR/generated" \
    -output "$LOCAL_FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

# Rename modulemap for SPM compatibility
for dir in "$LOCAL_FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"/*/Headers; do
    if [ -f "$dir/imbib_coreFFI.modulemap" ]; then
        mv "$dir/imbib_coreFFI.modulemap" "$dir/module.modulemap"
    fi
done

# Copy Swift bindings
cp "$LOCAL_FRAMEWORK_DIR/generated/imbib_core.swift" "$LOCAL_FRAMEWORK_DIR/"

# Temporarily replace the committed framework for local build
echo "  Replacing committed framework for local build..."
COMMITTED_FRAMEWORK_DIR="$IMBIB_CORE_DIR/frameworks"
BACKUP_FRAMEWORK_DIR="$BUILD_DIR/frameworks-backup"
mv "$COMMITTED_FRAMEWORK_DIR" "$BACKUP_FRAMEWORK_DIR"
cp -R "$LOCAL_FRAMEWORK_DIR" "$COMMITTED_FRAMEWORK_DIR"

step_end

# ============================================================================
# Step 3: Generate Xcode project and build archive
# ============================================================================
step_start "3/6" "Building Xcode archive..."

cd "$IMBIB_DIR"
xcodegen generate

xcodebuild -scheme imbib \
    -configuration Release \
    -archivePath "$BUILD_DIR/imbib.xcarchive" \
    -destination 'generic/platform=macOS' \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    ARCHS="arm64" \
    ONLY_ACTIVE_ARCH=NO \
    archive \
    | grep -E "^(Build|Archive|Compiling|Linking|Signing|error:|warning:)" || true

step_end

# ============================================================================
# Step 4: Export and notarize app
# ============================================================================
step_start "4/6" "Exporting and notarizing app..."

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
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/imbib.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    2>&1 | grep -E "^(Export|error:|warning:)" || true

# Verify Safari extension is bundled
if [ -d "$BUILD_DIR/export/imbib.app/Contents/PlugIns/imbib Safari Extension.appex" ]; then
    echo -e "  ${GREEN}✓ Safari extension bundled${NC}"
else
    echo -e "  ${RED}✗ Safari extension NOT found in bundle!${NC}"
    exit 1
fi

# Notarize app
echo "  Notarizing app (this may take a few minutes)..."
cd "$BUILD_DIR/export"
ditto -c -k --keepParent imbib.app imbib-notarize.zip

xcrun notarytool submit imbib-notarize.zip \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

# Staple notarization ticket
xcrun stapler staple imbib.app

step_end

# ============================================================================
# Step 5: Create and notarize DMG
# ============================================================================
step_start "5/6" "Creating and notarizing DMG..."

cd "$BUILD_DIR"
DMG_NAME="imbib-${VERSION}-macOS-arm64.dmg"

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
        "export/imbib.app" 2>/dev/null || {
            echo -e "  ${YELLOW}create-dmg failed, using hdiutil fallback${NC}"
            hdiutil create -volname "imbib" -srcfolder "export/imbib.app" -ov -format UDZO "$DMG_NAME"
        }
else
    hdiutil create -volname "imbib" -srcfolder "export/imbib.app" -ov -format UDZO "$DMG_NAME"
fi

# Notarize DMG
echo "  Notarizing DMG..."
xcrun notarytool submit "$DMG_NAME" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

xcrun stapler staple "$DMG_NAME"

step_end

# ============================================================================
# Step 6: Summary (cleanup handled by EXIT trap)
# ============================================================================
step_start "6/6" "Build complete!"

TOTAL_TIME=$(($(date +%s) - START_TIME))
MINUTES=$((TOTAL_TIME / 60))
SECONDS=$((TOTAL_TIME % 60))

echo ""
echo -e "${GREEN}=== Release Ready ===${NC}"
echo ""
echo -e "DMG:      ${YELLOW}$BUILD_DIR/$DMG_NAME${NC}"
echo -e "Version:  ${YELLOW}$VERSION${NC}"
echo -e "Arch:     ${YELLOW}arm64 (Apple Silicon only)${NC}"
echo -e "Time:     ${YELLOW}${MINUTES}m ${SECONDS}s${NC}"
echo ""
echo -e "${BLUE}To upload to GitHub release:${NC}"
echo "  gh release upload $VERSION \"$BUILD_DIR/$DMG_NAME\""
echo ""
echo -e "${BLUE}Or create a new release:${NC}"
echo "  gh release create $VERSION \"$BUILD_DIR/$DMG_NAME\" --title \"$VERSION\" --notes \"Apple Silicon only\""
echo ""
echo -e "${YELLOW}Note: This build only supports Apple Silicon Macs (M1/M2/M3+)${NC}"
