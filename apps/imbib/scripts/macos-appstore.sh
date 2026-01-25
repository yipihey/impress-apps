#!/bin/bash
#
# macOS App Store upload script
# Builds and uploads imbib macOS app to App Store Connect / TestFlight
#
# Usage: ./scripts/macos-appstore.sh [version]
#        ./scripts/macos-appstore.sh --setup    # Same as ios-testflight.sh --setup
#
# Example: ./scripts/macos-appstore.sh v1.2.0
#
# Prerequisites:
# - Apple Silicon Mac
# - Xcode with Mac App Store distribution certificate
# - xcodegen installed (brew install xcodegen)
# - Rust toolchain with aarch64-apple-darwin target
# - App Store Connect API key (same as iOS TestFlight)
#
# Credentials are read from macOS Keychain (run --setup first)
# Uses same credentials as ios-testflight.sh
#

set -e

# Keychain service names (shared with ios-testflight.sh)
KEYCHAIN_SERVICE="imbib-testflight"
KEYCHAIN_SERVICE_RELEASE="imbib-release"

# ============================================================================
# Keychain Setup Mode (same as ios-testflight.sh)
# ============================================================================
if [[ "$1" == "--setup" ]]; then
    echo "=== App Store Connect Credential Setup ==="
    echo ""
    echo "This will store your App Store Connect API credentials securely in macOS Keychain."
    echo "These credentials are shared with ios-testflight.sh."
    echo ""
    echo "Create an API key at: https://appstoreconnect.apple.com/access/api"
    echo "The key needs 'App Manager' or 'Admin' role."
    echo ""

    # API Key ID
    read -p "App Store Connect API Key ID: " SETUP_KEY_ID
    security add-generic-password -U -a "asc-key-id" -s "$KEYCHAIN_SERVICE" -w "$SETUP_KEY_ID" 2>/dev/null || \
    security add-generic-password -a "asc-key-id" -s "$KEYCHAIN_SERVICE" -w "$SETUP_KEY_ID"
    echo "✓ API Key ID stored"

    # Issuer ID
    echo ""
    echo "Find your Issuer ID at the top of the API keys page"
    read -p "App Store Connect Issuer ID: " SETUP_ISSUER_ID
    security add-generic-password -U -a "asc-issuer-id" -s "$KEYCHAIN_SERVICE" -w "$SETUP_ISSUER_ID" 2>/dev/null || \
    security add-generic-password -a "asc-issuer-id" -s "$KEYCHAIN_SERVICE" -w "$SETUP_ISSUER_ID"
    echo "✓ Issuer ID stored"

    # Check for API key file
    echo ""
    API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${SETUP_KEY_ID}.p8"
    if [ -f "$API_KEY_PATH" ]; then
        echo "✓ API key file found at: $API_KEY_PATH"
    else
        echo "⚠ API key file not found at: $API_KEY_PATH"
        echo ""
        echo "Download the .p8 file from App Store Connect and save it to:"
        echo "  ~/.appstoreconnect/private_keys/AuthKey_${SETUP_KEY_ID}.p8"
        echo ""
        echo "Create the directory if needed:"
        echo "  mkdir -p ~/.appstoreconnect/private_keys"
    fi

    echo ""
    echo "=== Setup Complete ==="
    echo "Credentials stored in Keychain under service: $KEYCHAIN_SERVICE"
    echo ""
    echo "Make sure you have also run: ./scripts/quick-release.sh --setup"
    echo "(The Team ID is shared between all release scripts)"
    echo ""
    echo "You can now run: ./scripts/macos-appstore.sh v1.0.0"
    exit 0
fi

# ============================================================================
# Retrieve credentials from Keychain
# ============================================================================
get_credential() {
    local account="$1"
    local service="$2"
    local keychain_value
    keychain_value=$(security find-generic-password -a "$account" -s "$service" -w 2>/dev/null) || true
    echo "$keychain_value"
}

ASC_KEY_ID=$(get_credential "asc-key-id" "$KEYCHAIN_SERVICE")
ASC_ISSUER_ID=$(get_credential "asc-issuer-id" "$KEYCHAIN_SERVICE")
TEAM_ID=$(get_credential "team-id" "$KEYCHAIN_SERVICE_RELEASE")

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

# Generate build number: {commit_count}.{YYMMDDHHMM}
COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "0")
TIMESTAMP=$(date +%y%m%d%H%M)
BUILD_NUMBER="${COMMIT_COUNT}.${TIMESTAMP}"

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

echo -e "${GREEN}=== macOS App Store Build ===${NC}"
echo -e "Version:      ${YELLOW}$VERSION${NC}"
echo -e "Build:        ${YELLOW}$BUILD_NUMBER${NC}"
echo -e "Target:       ${YELLOW}aarch64-apple-darwin (arm64)${NC}"
echo ""

# Check we're on Apple Silicon
if [[ "$(uname -m)" != "arm64" ]]; then
    echo -e "${RED}Error: This script is designed for Apple Silicon Macs${NC}"
    exit 1
fi

# Check prerequisites
command -v xcodegen >/dev/null 2>&1 || { echo -e "${RED}xcodegen is required. Install with: brew install xcodegen${NC}"; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo -e "${RED}Rust/cargo is required. Install from rustup.rs${NC}"; exit 1; }

# Check credentials
MISSING_CREDS=()
if [ -z "$ASC_KEY_ID" ]; then
    MISSING_CREDS+=("ASC_KEY_ID")
fi
if [ -z "$ASC_ISSUER_ID" ]; then
    MISSING_CREDS+=("ASC_ISSUER_ID")
fi
if [ -z "$TEAM_ID" ]; then
    MISSING_CREDS+=("TEAM_ID (run quick-release.sh --setup)")
fi

if [ ${#MISSING_CREDS[@]} -gt 0 ]; then
    echo -e "${RED}Missing credentials: ${MISSING_CREDS[*]}${NC}"
    echo ""
    echo "Run this command first to store credentials in Keychain:"
    echo "  ./scripts/macos-appstore.sh --setup"
    echo ""
    echo "Also ensure quick-release.sh --setup has been run for Team ID"
    exit 1
fi

# Check API key file
API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
if [ ! -f "$API_KEY_PATH" ]; then
    echo -e "${RED}API key file not found: $API_KEY_PATH${NC}"
    echo ""
    echo "Download the .p8 file from App Store Connect and save it to:"
    echo "  $API_KEY_PATH"
    exit 1
fi

echo -e "Credentials: ${GREEN}✓ loaded from Keychain${NC}"
echo -e "API Key:     ${GREEN}✓ found at $API_KEY_PATH${NC}"

# Create build directory
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR"/*

# ============================================================================
# Step 1: Build Rust for macOS
# ============================================================================
step_start "1/7" "Building Rust library (macOS arm64)..."

cd "$IMBIB_CORE_DIR"

# Set deployment target
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

# Ensure target is installed
rustup target add aarch64-apple-darwin 2>/dev/null || true

# Build for macOS
cargo build --release --target aarch64-apple-darwin

step_end

# ============================================================================
# Step 2: Create combined XCFramework (iOS + macOS)
# ============================================================================
step_start "2/7" "Creating combined XCFramework..."

RUST_BUILD_DIR="$IMBIB_CORE_DIR/target"
FRAMEWORK_DIR="$IMBIB_CORE_DIR/frameworks"
XCFRAMEWORK_NAME="ImbibCore"

# Clean and create framework directory
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR"

# Build iOS target (for combined XCFramework)
echo "  Building iOS target..."
rustup target add aarch64-apple-ios 2>/dev/null || true
cargo build --release --target aarch64-apple-ios

# Generate Swift bindings
echo "  Generating Swift bindings..."
cargo run --bin uniffi-bindgen generate \
    --library "$RUST_BUILD_DIR/aarch64-apple-darwin/release/libimbib_core.dylib" \
    --language swift \
    --out-dir "$FRAMEWORK_DIR/generated"

# Create module map
cat > "$FRAMEWORK_DIR/module.modulemap" << 'MODULEMAP'
module imbib_core {
    header "imbib_coreFFI.h"
    export *
}
MODULEMAP

# Create combined XCFramework (iOS + macOS)
echo "  Creating XCFramework with iOS and macOS..."
rm -rf "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

xcodebuild -create-xcframework \
    -library "$RUST_BUILD_DIR/aarch64-apple-ios/release/libimbib_core.a" \
    -headers "$FRAMEWORK_DIR/generated" \
    -library "$RUST_BUILD_DIR/aarch64-apple-darwin/release/libimbib_core.a" \
    -headers "$FRAMEWORK_DIR/generated" \
    -output "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

# Rename modulemap for SPM compatibility
for dir in "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"/*/Headers; do
    if [ -f "$dir/imbib_coreFFI.modulemap" ]; then
        mv "$dir/imbib_coreFFI.modulemap" "$dir/module.modulemap"
    fi
done

# Copy Swift bindings to framework dir and ImbibRustCore package
cp "$FRAMEWORK_DIR/generated/imbib_core.swift" "$FRAMEWORK_DIR/"
cp "$FRAMEWORK_DIR/generated/imbib_core.swift" "$PROJECT_DIR/ImbibRustCore/Sources/ImbibRustCore/imbib_core.swift"

step_end

# ============================================================================
# Step 3: Generate Xcode project
# ============================================================================
step_start "3/7" "Generating Xcode project..."

cd "$IMBIB_DIR"
xcodegen generate

step_end

# ============================================================================
# Step 4: Set build number in project
# ============================================================================
step_start "4/7" "Setting build number ($BUILD_NUMBER)..."

# Update build number using PlistBuddy on the Info.plist
PLIST_PATH="$IMBIB_DIR/imbib/Resources/Info.plist"
if [ -f "$PLIST_PATH" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$PLIST_PATH"

    # Also set short version string
    SHORT_VERSION="${VERSION#v}"  # Remove leading 'v' if present
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$PLIST_PATH" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $SHORT_VERSION" "$PLIST_PATH"

    echo "  CFBundleVersion: $BUILD_NUMBER"
    echo "  CFBundleShortVersionString: $SHORT_VERSION"
else
    echo -e "  ${YELLOW}Warning: Info.plist not found, build number will use defaults${NC}"
fi

step_end

# ============================================================================
# Step 5: Archive macOS app
# ============================================================================
step_start "5/7" "Archiving macOS app..."

cd "$IMBIB_DIR"

xcodebuild -scheme imbib \
    -configuration Release \
    -archivePath "$BUILD_DIR/imbib-macOS.xcarchive" \
    -destination 'generic/platform=macOS' \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    archive \
    | grep -E "^(Build|Archive|Compiling|Linking|Signing|error:|warning:)" || true

if [ ! -d "$BUILD_DIR/imbib-macOS.xcarchive" ]; then
    echo -e "${RED}Error: Archive failed${NC}"
    exit 1
fi

step_end

# ============================================================================
# Step 6: Export for App Store
# ============================================================================
step_start "6/7" "Exporting for App Store..."

# Create export options plist for Mac App Store
cat > "$BUILD_DIR/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

# Export pkg
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/imbib-macOS.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    2>&1 | grep -E "^(Export|error:|warning:)" || true

# Verify pkg was created
PKG_PATH="$BUILD_DIR/export/imbib.pkg"
if [ ! -f "$PKG_PATH" ]; then
    echo -e "${RED}Error: Package export failed${NC}"
    echo "Check $BUILD_DIR/export/ for details"
    ls -la "$BUILD_DIR/export/" 2>/dev/null || true
    exit 1
fi

echo -e "  ${GREEN}✓ Package created: $PKG_PATH${NC}"

step_end

# ============================================================================
# Step 7: Upload to App Store Connect
# ============================================================================
step_start "7/7" "Uploading to App Store Connect..."

xcrun altool --upload-app \
    --type macos \
    --file "$PKG_PATH" \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID"

step_end

# ============================================================================
# Summary
# ============================================================================
TOTAL_TIME=$(($(date +%s) - START_TIME))
MINUTES=$((TOTAL_TIME / 60))
SECONDS=$((TOTAL_TIME % 60))

echo ""
echo -e "${GREEN}=== App Store Connect Upload Complete ===${NC}"
echo ""
echo -e "Version:  ${YELLOW}$VERSION${NC}"
echo -e "Build:    ${YELLOW}$BUILD_NUMBER${NC}"
echo -e "Package:  ${YELLOW}$PKG_PATH${NC}"
echo -e "Time:     ${YELLOW}${MINUTES}m ${SECONDS}s${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Check App Store Connect for build processing (15-30 min)"
echo "  2. Add build to TestFlight for beta testing, or"
echo "  3. Submit for App Store review"
echo ""
echo -e "${BLUE}App Store Connect:${NC}"
echo "  https://appstoreconnect.apple.com/apps"
echo ""
