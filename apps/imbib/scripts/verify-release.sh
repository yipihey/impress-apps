#!/bin/bash
#
# verify-release.sh
#
# Pre-release verification script for imbib.
# Checks that the build is ready for App Store submission.
#
# Verifications:
# - Build configuration is correct (Release)
# - Entitlements are properly configured
# - CloudKit container is production-ready
# - No sandbox/development contamination
# - Code signing is valid
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"

echo -e "${BLUE}=== imbib Release Verification ===${NC}"
echo ""

# Find the archive or app bundle to verify
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <path-to-app-or-archive>"
    echo ""
    echo "Examples:"
    echo "  $0 ~/Desktop/imbib.app"
    echo "  $0 ~/Library/Developer/Xcode/Archives/2026-02-01/imbib.xcarchive"
    echo ""
    exit 1
fi

TARGET="$1"
ERRORS=0
WARNINGS=0

# Helper functions
check_pass() {
    echo -e "  $PASS $1"
}

check_fail() {
    echo -e "  $FAIL $1"
    ((ERRORS++))
}

check_warn() {
    echo -e "  $WARN $1"
    ((WARNINGS++))
}

# Determine what we're checking
if [[ -d "$TARGET" && "$TARGET" == *.xcarchive ]]; then
    echo "Verifying archive: $TARGET"
    APP_PATH="$TARGET/Products/Applications/imbib.app"
    IS_ARCHIVE=true
elif [[ -d "$TARGET" && "$TARGET" == *.app ]]; then
    echo "Verifying app bundle: $TARGET"
    APP_PATH="$TARGET"
    IS_ARCHIVE=false
else
    echo -e "${RED}Error: Not a valid .app or .xcarchive${NC}"
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo -e "${RED}Error: App not found at $APP_PATH${NC}"
    exit 1
fi

echo ""

# =============================================================================
# 1. Check Code Signing
# =============================================================================
echo -e "${BLUE}1. Code Signing${NC}"

CODESIGN_OUTPUT=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)

# Check signature is valid
if codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
    check_pass "Code signature is valid"
else
    check_fail "Code signature verification failed"
fi

# Check for Developer ID or Distribution signing
if echo "$CODESIGN_OUTPUT" | grep -q "Authority=Apple Distribution"; then
    check_pass "Signed for App Store distribution"
elif echo "$CODESIGN_OUTPUT" | grep -q "Authority=Developer ID Application"; then
    check_warn "Signed with Developer ID (direct distribution only)"
elif echo "$CODESIGN_OUTPUT" | grep -q "Authority=Apple Development"; then
    check_fail "Signed with Development certificate (not for release)"
else
    check_warn "Unknown signing identity"
fi

# Check Team ID
if echo "$CODESIGN_OUTPUT" | grep -q "TeamIdentifier="; then
    TEAM_ID=$(echo "$CODESIGN_OUTPUT" | grep "TeamIdentifier=" | cut -d= -f2)
    check_pass "Team ID: $TEAM_ID"
else
    check_fail "No Team ID found"
fi

echo ""

# =============================================================================
# 2. Check Entitlements
# =============================================================================
echo -e "${BLUE}2. Entitlements${NC}"

ENTITLEMENTS=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || echo "")

# CloudKit entitlement
if echo "$ENTITLEMENTS" | grep -q "com.apple.developer.icloud-container-identifiers"; then
    check_pass "CloudKit container entitlement present"

    # Verify production container ID
    if echo "$ENTITLEMENTS" | grep -q "iCloud.com.imbib.app"; then
        check_pass "CloudKit container ID: iCloud.com.imbib.app"
    else
        check_warn "Non-standard CloudKit container ID"
    fi
else
    check_fail "CloudKit container entitlement missing"
fi

# iCloud services
if echo "$ENTITLEMENTS" | grep -q "com.apple.developer.icloud-services"; then
    check_pass "iCloud services entitlement present"
else
    check_fail "iCloud services entitlement missing"
fi

# CloudKit environment (should be Production for release)
if echo "$ENTITLEMENTS" | grep -q "com.apple.developer.icloud-container-environment"; then
    if echo "$ENTITLEMENTS" | grep -A1 "icloud-container-environment" | grep -q "Production"; then
        check_pass "CloudKit environment: Production"
    elif echo "$ENTITLEMENTS" | grep -A1 "icloud-container-environment" | grep -q "Development"; then
        check_fail "CloudKit environment: Development (should be Production)"
    else
        check_warn "CloudKit environment not explicitly set"
    fi
fi

# App Groups (for sharing data with extensions)
if echo "$ENTITLEMENTS" | grep -q "com.apple.security.application-groups"; then
    check_pass "App Groups entitlement present"
else
    check_warn "App Groups entitlement missing (extensions may not work)"
fi

# Sandbox
if echo "$ENTITLEMENTS" | grep -q "com.apple.security.app-sandbox"; then
    check_pass "App Sandbox enabled"
else
    check_warn "App Sandbox not enabled (required for Mac App Store)"
fi

echo ""

# =============================================================================
# 3. Check Info.plist
# =============================================================================
echo -e "${BLUE}3. Info.plist${NC}"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
    # Try iOS location
    INFO_PLIST="$APP_PATH/Info.plist"
fi

if [[ -f "$INFO_PLIST" ]]; then
    # Check version
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "")
    BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "")

    if [[ -n "$VERSION" ]]; then
        check_pass "Version: $VERSION (build $BUILD)"
    else
        check_fail "Version not set"
    fi

    # Check bundle ID
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null || echo "")
    if [[ "$BUNDLE_ID" == "com.imbib.app" ]]; then
        check_pass "Bundle ID: $BUNDLE_ID"
    else
        check_warn "Bundle ID: $BUNDLE_ID (expected com.imbib.app)"
    fi

    # Check minimum deployment target
    MIN_MACOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$INFO_PLIST" 2>/dev/null || echo "")
    if [[ -n "$MIN_MACOS" ]]; then
        check_pass "Minimum macOS: $MIN_MACOS"
    fi
else
    check_fail "Info.plist not found"
fi

echo ""

# =============================================================================
# 4. Check for Debug/Development Artifacts
# =============================================================================
echo -e "${BLUE}4. Build Configuration${NC}"

# Check for debug symbols in main binary
MAIN_BINARY="$APP_PATH/Contents/MacOS/imbib"
if [[ ! -f "$MAIN_BINARY" ]]; then
    # Try iOS
    MAIN_BINARY="$APP_PATH/imbib"
fi

if [[ -f "$MAIN_BINARY" ]]; then
    # Check if it's a Release build (no debug symbols embedded)
    if file "$MAIN_BINARY" | grep -q "stripped"; then
        check_pass "Binary is stripped (Release build)"
    else
        check_warn "Binary may not be stripped (check build configuration)"
    fi

    # Check for DEBUG references
    if strings "$MAIN_BINARY" 2>/dev/null | grep -q "DEBUG" | head -1; then
        check_warn "DEBUG strings found in binary (may be intentional logging)"
    else
        check_pass "No DEBUG strings in binary"
    fi
fi

# Check for .dSYM (should be separate, not in app)
if find "$APP_PATH" -name "*.dSYM" 2>/dev/null | grep -q .; then
    check_fail "dSYM found inside app bundle (should be separate)"
else
    check_pass "No dSYM inside app bundle"
fi

echo ""

# =============================================================================
# 5. Summary
# =============================================================================
echo -e "${BLUE}=== Summary ===${NC}"
echo ""

if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
    echo -e "${GREEN}All checks passed! Ready for release.${NC}"
elif [[ $ERRORS -eq 0 ]]; then
    echo -e "${YELLOW}Passed with $WARNINGS warning(s). Review before release.${NC}"
else
    echo -e "${RED}Failed with $ERRORS error(s) and $WARNINGS warning(s).${NC}"
    echo "Fix errors before submitting to App Store."
fi

echo ""
exit $ERRORS
