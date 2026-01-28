#!/bin/bash
#
# Combined App Store release script
# Builds and uploads both iOS and macOS apps to App Store Connect
#
# Usage: ./scripts/appstore-release.sh [version]
#        ./scripts/appstore-release.sh --setup       # Store API credentials
#        ./scripts/appstore-release.sh --ios-only    # Upload iOS only
#        ./scripts/appstore-release.sh --macos-only  # Upload macOS only
#
# Example: ./scripts/appstore-release.sh v1.2.0
#
# Prerequisites:
# - Apple Silicon Mac
# - Xcode with iOS and Mac distribution certificates
# - xcodegen installed (brew install xcodegen)
# - Rust toolchain with iOS and macOS targets
# - App Store Connect API key
#
# Credentials are read from macOS Keychain (run --setup first)
#

set -e

# Keychain service names
KEYCHAIN_SERVICE="imbib-testflight"
KEYCHAIN_SERVICE_RELEASE="imbib-release"

# Default: build both platforms
BUILD_IOS=true
BUILD_MACOS=true

# Parse arguments
for arg in "$@"; do
    case $arg in
        --ios-only)
            BUILD_MACOS=false
            shift
            ;;
        --macos-only)
            BUILD_IOS=false
            shift
            ;;
        --setup)
            # Setup mode handled below
            ;;
        *)
            # Assume it's the version
            ;;
    esac
done

# ============================================================================
# Keychain Setup Mode
# ============================================================================
if [[ "$1" == "--setup" ]]; then
    echo "=== App Store Connect Credential Setup ==="
    echo ""
    echo "This will store your App Store Connect API credentials securely in macOS Keychain."
    echo "These credentials are used for both iOS and macOS uploads."
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
    echo "You can now run: ./scripts/appstore-release.sh v1.0.0"
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
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$(dirname "$PROJECT_DIR")")"
BUILD_DIR="$PROJECT_DIR/build"
IMBIB_DIR="$PROJECT_DIR/imbib"
IMBIB_CORE_DIR="$REPO_ROOT/crates/imbib-core"

# Version from argument or git tag (skip flags)
VERSION=""
for arg in "$@"; do
    if [[ "$arg" != --* ]]; then
        VERSION="$arg"
        break
    fi
done
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "dev")}"

# Generate build number: {commit_count}.{YYMMDDHHMM}
COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "0")
TIMESTAMP=$(date +%y%m%d%H%M)
BUILD_NUMBER="${COMMIT_COUNT}.${TIMESTAMP}"

# Timing
START_TIME=$(date +%s)
STEP_NUM=0
TOTAL_STEPS=0

# Calculate total steps based on what we're building
if $BUILD_IOS && $BUILD_MACOS; then
    TOTAL_STEPS=10  # Rust, XCFramework, Xcode, Build numbers, Versions, Archive iOS, Export iOS, Upload iOS, Archive macOS, Export macOS, Upload macOS
elif $BUILD_IOS; then
    TOTAL_STEPS=7
else
    TOTAL_STEPS=7
fi

step_start() {
    STEP_NUM=$((STEP_NUM + 1))
    STEP_START=$(date +%s)
    echo -e "\n${BLUE}[$STEP_NUM/$TOTAL_STEPS]${NC} $1"
}
step_end() {
    local elapsed=$(($(date +%s) - STEP_START))
    echo -e "${GREEN}  Done in ${elapsed}s${NC}"
}

# Build platform string
PLATFORMS=""
if $BUILD_IOS; then
    PLATFORMS="iOS"
fi
if $BUILD_MACOS; then
    if [ -n "$PLATFORMS" ]; then
        PLATFORMS="$PLATFORMS + macOS"
    else
        PLATFORMS="macOS"
    fi
fi

echo -e "${GREEN}=== App Store Release ===${NC}"
echo -e "Version:      ${YELLOW}$VERSION${NC}"
echo -e "Build:        ${YELLOW}$BUILD_NUMBER${NC}"
echo -e "Platforms:    ${YELLOW}$PLATFORMS${NC}"
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
    echo "  ./scripts/appstore-release.sh --setup"
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

# ============================================================================
# App Store Connect API Helper (for version creation)
# ============================================================================

# Generate JWT token using Python (more reliable than bash/openssl for ES256)
generate_jwt_python() {
    python3 << PYTHON_EOF
import json
import time
import base64
import hashlib
import subprocess
import sys

key_id = "$ASC_KEY_ID"
issuer_id = "$ASC_ISSUER_ID"
key_path = "$API_KEY_PATH"

def base64url_encode(data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('utf-8')

# Read the private key
with open(key_path, 'r') as f:
    private_key = f.read()

# Create header and payload
header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
now = int(time.time())
payload = {"iss": issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}

# Encode header and payload
header_b64 = base64url_encode(json.dumps(header, separators=(',', ':')))
payload_b64 = base64url_encode(json.dumps(payload, separators=(',', ':')))
message = f"{header_b64}.{payload_b64}"

# Sign using openssl and convert DER to raw R||S format
import tempfile
with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as kf:
    kf.write(private_key)
    kf.flush()

    # Sign the message
    proc = subprocess.run(
        ['openssl', 'dgst', '-sha256', '-sign', kf.name],
        input=message.encode(),
        capture_output=True
    )
    der_sig = proc.stdout

import os
os.unlink(kf.name)

# Parse DER signature to extract R and S (each 32 bytes for P-256)
# DER format: 0x30 <len> 0x02 <r_len> <r> 0x02 <s_len> <s>
def der_to_raw(der):
    if der[0] != 0x30:
        raise ValueError("Invalid DER signature")
    idx = 2  # Skip 0x30 and length

    # Parse R
    if der[idx] != 0x02:
        raise ValueError("Invalid DER R marker")
    r_len = der[idx + 1]
    idx += 2
    r = der[idx:idx + r_len]
    idx += r_len

    # Parse S
    if der[idx] != 0x02:
        raise ValueError("Invalid DER S marker")
    s_len = der[idx + 1]
    idx += 2
    s = der[idx:idx + s_len]

    # Pad or trim to 32 bytes each
    r = r[-32:].rjust(32, b'\x00')
    s = s[-32:].rjust(32, b'\x00')

    return r + s

raw_sig = der_to_raw(der_sig)
sig_b64 = base64url_encode(raw_sig)

print(f"{message}.{sig_b64}")
PYTHON_EOF
}

# API request helper
asc_api_request() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    local jwt=$(generate_jwt_python)
    local url="https://api.appstoreconnect.apple.com/v1$endpoint"

    if [ -n "$data" ]; then
        curl -s -X "$method" \
            -H "Authorization: Bearer $jwt" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "$url"
    else
        curl -s -X "$method" \
            -H "Authorization: Bearer $jwt" \
            "$url"
    fi
}

# Get app ID by bundle ID
get_app_id() {
    local bundle_id="$1"
    local response=$(asc_api_request GET "/apps?filter[bundleId]=$bundle_id")
    echo "$response" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d['data'][0]['id'] if d.get('data') else '')" 2>/dev/null
}

# Check if version exists
version_exists() {
    local app_id="$1"
    local version="$2"
    local platform="$3"

    local response=$(asc_api_request GET "/apps/$app_id/appStoreVersions?filter[versionString]=$version&filter[platform]=$platform")
    local count=$(echo "$response" | python3 -c "import sys, json; d=json.load(sys.stdin); print(len(d.get('data', [])))" 2>/dev/null)
    [ "$count" -gt 0 ]
}

# Create new version
create_version() {
    local app_id="$1"
    local version="$2"
    local platform="$3"

    local data=$(cat << JSON
{
    "data": {
        "type": "appStoreVersions",
        "attributes": {
            "versionString": "$version",
            "platform": "$platform"
        },
        "relationships": {
            "app": {
                "data": {
                    "type": "apps",
                    "id": "$app_id"
                }
            }
        }
    }
}
JSON
)

    asc_api_request POST "/appStoreVersions" "$data"
}

# Ensure version exists (create if needed)
ensure_version_exists() {
    local bundle_id="$1"
    local version="$2"
    local platform="$3"  # IOS or MAC_OS
    local display_name="$4"

    echo -e "  Checking $display_name version $version..."

    local app_id=$(get_app_id "$bundle_id")
    if [ -z "$app_id" ]; then
        echo -e "    ${YELLOW}⚠ App not found in App Store Connect${NC}"
        return 1
    fi

    if version_exists "$app_id" "$version" "$platform"; then
        echo -e "    ${GREEN}✓ Version exists${NC}"
    else
        echo -e "    Creating version $version..."
        local result=$(create_version "$app_id" "$version" "$platform")

        # Check for errors
        if echo "$result" | python3 -c "import sys, json; d=json.load(sys.stdin); sys.exit(0 if 'data' in d else 1)" 2>/dev/null; then
            echo -e "    ${GREEN}✓ Version created${NC}"
        else
            local error=$(echo "$result" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('errors', [{}])[0].get('detail', 'Unknown error'))" 2>/dev/null)
            echo -e "    ${YELLOW}⚠ Could not create version: $error${NC}"
            return 1
        fi
    fi
}

# Create build directory
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR"/*

# ============================================================================
# Step 1: Build Rust for all platforms
# ============================================================================
step_start "Building Rust library for all platforms..."

cd "$IMBIB_CORE_DIR"

# Set deployment targets
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

# Check if Rust source has changed since last build
RUST_SRC_HASH=$(find "$IMBIB_CORE_DIR/src" -name "*.rs" -exec cat {} \; 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
RUST_HASH_FILE="$REPO_ROOT/target/.build_hash"
PREV_HASH=$(cat "$RUST_HASH_FILE" 2>/dev/null || echo "")

RUST_NEEDS_BUILD=false
if [ "$RUST_SRC_HASH" != "$PREV_HASH" ]; then
    RUST_NEEDS_BUILD=true
fi

# Build macOS (both architectures for universal binary)
MACOS_ARM_LIB="$REPO_ROOT/target/aarch64-apple-darwin/release/libimbib_core.a"
if $RUST_NEEDS_BUILD || [ ! -f "$MACOS_ARM_LIB" ]; then
    echo "  Building macOS (aarch64-apple-darwin)..."
    rustup target add aarch64-apple-darwin 2>/dev/null || true
    cargo build --release --features native --target aarch64-apple-darwin
else
    echo "  Skipping macOS arm64 (up to date)"
fi

if $BUILD_MACOS; then
    MACOS_X86_LIB="$REPO_ROOT/target/x86_64-apple-darwin/release/libimbib_core.a"
    if $RUST_NEEDS_BUILD || [ ! -f "$MACOS_X86_LIB" ]; then
        echo "  Building macOS (x86_64-apple-darwin)..."
        rustup target add x86_64-apple-darwin 2>/dev/null || true
        cargo build --release --features native --target x86_64-apple-darwin
    else
        echo "  Skipping macOS x86_64 (up to date)"
    fi
fi

# Build iOS if needed
if $BUILD_IOS; then
    IOS_LIB="$REPO_ROOT/target/aarch64-apple-ios/release/libimbib_core.a"
    if $RUST_NEEDS_BUILD || [ ! -f "$IOS_LIB" ]; then
        echo "  Building iOS (aarch64-apple-ios)..."
        rustup target add aarch64-apple-ios 2>/dev/null || true
        cargo build --release --features native --target aarch64-apple-ios
    else
        echo "  Skipping iOS (up to date)"
    fi
fi

# Save hash for next run
echo "$RUST_SRC_HASH" > "$RUST_HASH_FILE"

step_end

# ============================================================================
# Step 2: Create combined XCFramework
# ============================================================================
step_start "Creating combined XCFramework..."

RUST_BUILD_DIR="$REPO_ROOT/target"
FRAMEWORK_DIR="$IMBIB_CORE_DIR/frameworks"
XCFRAMEWORK_NAME="ImbibCore"

# Check if XCFramework needs to be rebuilt
XCFRAMEWORK_PATH="$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"
XCFRAMEWORK_NEEDS_BUILD=false

if [ ! -d "$XCFRAMEWORK_PATH" ]; then
    XCFRAMEWORK_NEEDS_BUILD=true
elif $RUST_NEEDS_BUILD; then
    XCFRAMEWORK_NEEDS_BUILD=true
elif [ "$MACOS_ARM_LIB" -nt "$XCFRAMEWORK_PATH" ] 2>/dev/null; then
    XCFRAMEWORK_NEEDS_BUILD=true
fi

if ! $XCFRAMEWORK_NEEDS_BUILD; then
    echo "  Skipping XCFramework (up to date)"
    step_end
else

# Clean and create framework directory
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR"

# Generate Swift bindings
echo "  Generating Swift bindings..."
cargo run --features native --bin uniffi-bindgen generate \
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

# Build XCFramework with both platforms
echo "  Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

# Create universal macOS library if building for macOS
if $BUILD_MACOS; then
    echo "  Creating universal macOS library..."
    lipo -create \
        "$RUST_BUILD_DIR/aarch64-apple-darwin/release/libimbib_core.a" \
        "$RUST_BUILD_DIR/x86_64-apple-darwin/release/libimbib_core.a" \
        -output "$RUST_BUILD_DIR/libimbib_core_macos_universal.a"
    MACOS_LIB="$RUST_BUILD_DIR/libimbib_core_macos_universal.a"
else
    MACOS_LIB="$RUST_BUILD_DIR/aarch64-apple-darwin/release/libimbib_core.a"
fi

if $BUILD_IOS; then
    # Combined iOS + macOS
    xcodebuild -create-xcframework \
        -library "$RUST_BUILD_DIR/aarch64-apple-ios/release/libimbib_core.a" \
        -headers "$FRAMEWORK_DIR/generated" \
        -library "$MACOS_LIB" \
        -headers "$FRAMEWORK_DIR/generated" \
        -output "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"
else
    # macOS only
    xcodebuild -create-xcframework \
        -library "$MACOS_LIB" \
        -headers "$FRAMEWORK_DIR/generated" \
        -output "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"
fi

# Rename modulemap for SPM compatibility
for dir in "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"/*/Headers; do
    if [ -f "$dir/imbib_coreFFI.modulemap" ]; then
        mv "$dir/imbib_coreFFI.modulemap" "$dir/module.modulemap"
    fi
done

# Copy Swift bindings
cp "$FRAMEWORK_DIR/generated/imbib_core.swift" "$FRAMEWORK_DIR/"
cp "$FRAMEWORK_DIR/generated/imbib_core.swift" "$PROJECT_DIR/ImbibRustCore/Sources/ImbibRustCore/imbib_core.swift"

step_end
fi

# ============================================================================
# Step 3: Generate Xcode project
# ============================================================================
step_start "Generating Xcode project..."

cd "$IMBIB_DIR"

# Check if project.yml has changed since last generation
PROJECT_YML_HASH=$(cat "$IMBIB_DIR/project.yml" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
PROJECT_HASH_FILE="$IMBIB_DIR/.xcodegen_hash"
PREV_PROJECT_HASH=$(cat "$PROJECT_HASH_FILE" 2>/dev/null || echo "")

if [ "$PROJECT_YML_HASH" = "$PREV_PROJECT_HASH" ] && [ -f "$IMBIB_DIR/imbib.xcodeproj/project.pbxproj" ]; then
    echo "  Skipping xcodegen (project.yml unchanged)"
else
    xcodegen generate
    echo "$PROJECT_YML_HASH" > "$PROJECT_HASH_FILE"
fi

step_end

# ============================================================================
# Step 4: Set build numbers
# ============================================================================
step_start "Setting build numbers ($BUILD_NUMBER)..."

SHORT_VERSION="${VERSION#v}"  # Remove leading 'v' if present

# Helper function to set version in plist
set_plist_version() {
    local plist="$1"
    local name="$2"
    if [ -f "$plist" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $SHORT_VERSION" "$plist"
        echo "  $name: $SHORT_VERSION ($BUILD_NUMBER)"
    fi
}

# iOS Info.plist files
if $BUILD_IOS; then
    set_plist_version "$IMBIB_DIR/imbib-iOS/Resources/Info.plist" "iOS App"
    set_plist_version "$IMBIB_DIR/imbib-iOS/ShareExtension/Info.plist" "iOS ShareExtension"
fi

# macOS Info.plist files
if $BUILD_MACOS; then
    set_plist_version "$IMBIB_DIR/imbib/Resources/Info.plist" "macOS App"
    set_plist_version "$IMBIB_DIR/ShareExtension/Info.plist" "macOS ShareExtension"
fi

# Safari Extension (shared between iOS and macOS)
if $BUILD_IOS || $BUILD_MACOS; then
    set_plist_version "$IMBIB_DIR/imbibSafariExtension/Info.plist" "Safari Extension"
fi

step_end

# ============================================================================
# Step 5: Ensure App Store versions exist
# ============================================================================
step_start "Ensuring App Store Connect versions exist..."

if $BUILD_IOS; then
    ensure_version_exists "com.imbib.app.ios" "$SHORT_VERSION" "IOS" "iOS" || true
fi

if $BUILD_MACOS; then
    ensure_version_exists "com.imbib.app.ios" "$SHORT_VERSION" "MAC_OS" "macOS" || true
fi

step_end

# ============================================================================
# iOS Build & Upload
# ============================================================================
if $BUILD_IOS; then
    # Archive iOS
    step_start "Archiving iOS app..."

    cd "$IMBIB_DIR"

    xcodebuild -scheme imbib-iOS \
        -configuration Release \
        -archivePath "$BUILD_DIR/imbib-iOS.xcarchive" \
        -destination 'generic/platform=iOS' \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic \
        -allowProvisioningUpdates \
        archive \
        | grep -E "^(Build|Archive|Compiling|Linking|Signing|error:|warning:)" || true

    if [ ! -d "$BUILD_DIR/imbib-iOS.xcarchive" ]; then
        echo -e "${RED}Error: iOS archive failed${NC}"
        exit 1
    fi

    step_end

    # Export iOS IPA
    step_start "Exporting iOS IPA..."

    cat > "$BUILD_DIR/ExportOptions-iOS.plist" << EOF
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

    xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/imbib-iOS.xcarchive" \
        -exportPath "$BUILD_DIR/export-ios" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-iOS.plist" \
        -allowProvisioningUpdates \
        2>&1 | grep -E "^(Export|error:|warning:)" || true

    IPA_PATH="$BUILD_DIR/export-ios/imbib.ipa"
    if [ ! -f "$IPA_PATH" ]; then
        echo -e "${RED}Error: iOS IPA export failed${NC}"
        exit 1
    fi

    echo -e "  ${GREEN}✓ IPA created: $IPA_PATH${NC}"
    step_end

    # Upload iOS
    step_start "Uploading iOS to TestFlight..."

    xcrun altool --upload-app \
        --type ios \
        --file "$IPA_PATH" \
        --apiKey "$ASC_KEY_ID" \
        --apiIssuer "$ASC_ISSUER_ID"

    step_end
fi

# ============================================================================
# macOS Build & Upload
# ============================================================================
if $BUILD_MACOS; then
    # Archive macOS
    step_start "Archiving macOS app..."

    cd "$IMBIB_DIR"

    xcodebuild -scheme imbib \
        -configuration Release \
        -archivePath "$BUILD_DIR/imbib-macOS.xcarchive" \
        -destination 'generic/platform=macOS' \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic \
        -allowProvisioningUpdates \
        archive \
        | grep -E "^(Build|Archive|Compiling|Linking|Signing|error:|warning:)" || true

    if [ ! -d "$BUILD_DIR/imbib-macOS.xcarchive" ]; then
        echo -e "${RED}Error: macOS archive failed${NC}"
        exit 1
    fi

    step_end

    # Export macOS pkg
    step_start "Exporting macOS package..."

    cat > "$BUILD_DIR/ExportOptions-macOS.plist" << EOF
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

    xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/imbib-macOS.xcarchive" \
        -exportPath "$BUILD_DIR/export-macos" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-macOS.plist" \
        -allowProvisioningUpdates \
        2>&1 | grep -E "^(Export|error:|warning:)" || true

    PKG_PATH="$BUILD_DIR/export-macos/imbib.pkg"
    if [ ! -f "$PKG_PATH" ]; then
        echo -e "${RED}Error: macOS package export failed${NC}"
        exit 1
    fi

    echo -e "  ${GREEN}✓ Package created: $PKG_PATH${NC}"
    step_end

    # Upload macOS
    step_start "Uploading macOS to App Store Connect..."

    xcrun altool --upload-app \
        --type macos \
        --file "$PKG_PATH" \
        --apiKey "$ASC_KEY_ID" \
        --apiIssuer "$ASC_ISSUER_ID"

    step_end
fi

# ============================================================================
# Summary
# ============================================================================
TOTAL_TIME=$(($(date +%s) - START_TIME))
MINUTES=$((TOTAL_TIME / 60))
SECONDS=$((TOTAL_TIME % 60))

echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo -e "${GREEN}       App Store Release Complete!          ${NC}"
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo ""
echo -e "Version:    ${YELLOW}$VERSION${NC}"
echo -e "Build:      ${YELLOW}$BUILD_NUMBER${NC}"
echo -e "Time:       ${YELLOW}${MINUTES}m ${SECONDS}s${NC}"
echo ""

if $BUILD_IOS; then
    echo -e "${CYAN}iOS:${NC}"
    echo -e "  IPA:      ${YELLOW}$IPA_PATH${NC}"
    echo -e "  Status:   ${GREEN}✓ Uploaded to TestFlight${NC}"
    echo ""
fi

if $BUILD_MACOS; then
    echo -e "${CYAN}macOS:${NC}"
    echo -e "  Package:  ${YELLOW}$PKG_PATH${NC}"
    echo -e "  Status:   ${GREEN}✓ Uploaded to App Store Connect${NC}"
    echo ""
fi

echo -e "${BLUE}Next steps:${NC}"
echo "  1. Check App Store Connect for build processing (15-30 min)"
echo "  2. iOS: Add build to TestFlight testing groups"
echo "  3. macOS: Submit for App Store review or add to TestFlight"
echo ""
echo -e "${BLUE}App Store Connect:${NC}"
echo "  https://appstoreconnect.apple.com/apps"
echo ""
