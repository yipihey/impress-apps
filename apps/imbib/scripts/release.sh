#!/bin/bash
#
# Unified release script for imbib
#
# Usage:
#   ./scripts/release.sh testflight [version]     # Upload to TestFlight (iOS + macOS)
#   ./scripts/release.sh dmg [version]            # Build notarized DMG locally
#   ./scripts/release.sh github [version]         # Create GitHub release tag
#   ./scripts/release.sh setup                    # Configure credentials
#   ./scripts/release.sh status                   # Show current versions
#
# Options:
#   --ios-only    Only build iOS (testflight)
#   --macos-only  Only build macOS (testflight)
#   --skip-tests  Skip UI tests before release
#
# Examples:
#   ./scripts/release.sh testflight v1.2.0
#   ./scripts/release.sh testflight --ios-only
#   ./scripts/release.sh dmg v1.2.0
#   ./scripts/release.sh github v1.2.0
#
# See docs/RELEASE_GUIDE.md for full documentation.
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================================
# Help
# ============================================================================
show_help() {
    cat << 'EOF'
imbib Release Tool
==================

USAGE:
    ./scripts/release.sh <command> [options] [version]

COMMANDS:
    testflight      Build and upload to TestFlight (iOS + macOS)
    dmg             Build notarized DMG locally (macOS only)
    github          Create and push GitHub release tag
    setup           Configure release credentials
    status          Show current App Store Connect versions

OPTIONS:
    --ios-only      Only build iOS (testflight command)
    --macos-only    Only build macOS (testflight command)
    --skip-tests    Skip UI tests before release

EXAMPLES:
    # Upload to TestFlight
    ./scripts/release.sh testflight v1.2.0

    # iOS only TestFlight
    ./scripts/release.sh testflight v1.2.0 --ios-only

    # Build local DMG
    ./scripts/release.sh dmg v1.2.0

    # Create GitHub release
    ./scripts/release.sh github v1.2.0

    # First-time setup
    ./scripts/release.sh setup

RELEASE CHANNELS:
    TestFlight      Beta testing via App Store Connect (iOS + macOS)
    App Store       Production release (submit from App Store Connect)
    GitHub DMG      Direct download from GitHub Releases (macOS only)

For more information, see: docs/RELEASE_GUIDE.md
EOF
}

# ============================================================================
# Setup - Configure all credentials
# ============================================================================
do_setup() {
    echo -e "${GREEN}=== imbib Release Credential Setup ===${NC}"
    echo ""
    echo "This wizard will configure all credentials needed for releases."
    echo "Credentials are stored securely in macOS Keychain."
    echo ""

    # Check if credentials already exist
    EXISTING_TEAM_ID=$(security find-generic-password -a "team-id" -s "imbib-release" -w 2>/dev/null) || true
    EXISTING_ASC_KEY=$(security find-generic-password -a "asc-key-id" -s "imbib-testflight" -w 2>/dev/null) || true

    if [ -n "$EXISTING_TEAM_ID" ] || [ -n "$EXISTING_ASC_KEY" ]; then
        echo -e "${YELLOW}Existing credentials detected:${NC}"
        [ -n "$EXISTING_TEAM_ID" ] && echo "  - Team ID: ✓ configured"
        [ -n "$EXISTING_ASC_KEY" ] && echo "  - App Store Connect API: ✓ configured"
        echo ""
        read -p "Reconfigure credentials? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Setup cancelled."
            exit 0
        fi
    fi

    echo -e "${CYAN}Step 1: Apple Developer Team ID${NC}"
    echo "Find your Team ID at: https://developer.apple.com/account -> Membership"
    echo ""
    read -p "Team ID (10 characters): " TEAM_ID
    if [ -z "$TEAM_ID" ]; then
        echo -e "${RED}Team ID is required${NC}"
        exit 1
    fi
    security add-generic-password -U -a "team-id" -s "imbib-release" -w "$TEAM_ID" 2>/dev/null || \
    security add-generic-password -a "team-id" -s "imbib-release" -w "$TEAM_ID"
    echo -e "${GREEN}✓ Team ID stored${NC}"
    echo ""

    echo -e "${CYAN}Step 2: Notarization Credentials (for DMG releases)${NC}"
    echo "Your Apple ID email and an app-specific password."
    echo "Create app-specific password at: https://appleid.apple.com/account/manage"
    echo ""
    read -p "Apple ID (email): " APPLE_ID
    if [ -z "$APPLE_ID" ]; then
        echo -e "${YELLOW}Skipping notarization credentials (DMG builds will fail)${NC}"
    else
        security add-generic-password -U -a "apple-id" -s "imbib-release" -w "$APPLE_ID" 2>/dev/null || \
        security add-generic-password -a "apple-id" -s "imbib-release" -w "$APPLE_ID"

        read -s -p "App-specific password: " APP_PASSWORD
        echo ""
        security add-generic-password -U -a "app-password" -s "imbib-release" -w "$APP_PASSWORD" 2>/dev/null || \
        security add-generic-password -a "app-password" -s "imbib-release" -w "$APP_PASSWORD"
        echo -e "${GREEN}✓ Notarization credentials stored${NC}"
    fi
    echo ""

    echo -e "${CYAN}Step 3: App Store Connect API Key (for TestFlight)${NC}"
    echo "Create an API key at: https://appstoreconnect.apple.com/access/api"
    echo "The key needs 'App Manager' or 'Admin' role."
    echo ""
    read -p "API Key ID: " ASC_KEY_ID
    if [ -z "$ASC_KEY_ID" ]; then
        echo -e "${YELLOW}Skipping App Store Connect credentials (TestFlight will fail)${NC}"
    else
        security add-generic-password -U -a "asc-key-id" -s "imbib-testflight" -w "$ASC_KEY_ID" 2>/dev/null || \
        security add-generic-password -a "asc-key-id" -s "imbib-testflight" -w "$ASC_KEY_ID"

        echo ""
        echo "Find your Issuer ID at the top of the API keys page"
        read -p "Issuer ID: " ASC_ISSUER_ID
        security add-generic-password -U -a "asc-issuer-id" -s "imbib-testflight" -w "$ASC_ISSUER_ID" 2>/dev/null || \
        security add-generic-password -a "asc-issuer-id" -s "imbib-testflight" -w "$ASC_ISSUER_ID"
        echo -e "${GREEN}✓ App Store Connect credentials stored${NC}"

        # Check for API key file
        API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
        if [ -f "$API_KEY_PATH" ]; then
            echo -e "${GREEN}✓ API key file found at: $API_KEY_PATH${NC}"
        else
            echo ""
            echo -e "${YELLOW}⚠ API key file not found at: $API_KEY_PATH${NC}"
            echo ""
            echo "Download the .p8 file from App Store Connect and save it to:"
            echo "  mkdir -p ~/.appstoreconnect/private_keys"
            echo "  # Save AuthKey_${ASC_KEY_ID}.p8 to that directory"
        fi
    fi

    echo ""
    echo -e "${GREEN}=== Setup Complete ===${NC}"
    echo ""
    echo "Credentials stored in macOS Keychain."
    echo "You can now use:"
    echo "  ./scripts/release.sh testflight v1.2.0"
    echo "  ./scripts/release.sh dmg v1.2.0"
    echo ""
}

# ============================================================================
# Status - Show current versions
# ============================================================================
do_status() {
    echo -e "${GREEN}=== imbib Release Status ===${NC}"
    echo ""

    # Get current git info
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "no tags")
    COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "0")

    echo -e "${CYAN}Git:${NC}"
    echo "  Branch:       $CURRENT_BRANCH"
    echo "  Latest tag:   $LATEST_TAG"
    echo "  Commit count: $COMMIT_COUNT"
    echo ""

    # Check credentials
    TEAM_ID=$(security find-generic-password -a "team-id" -s "imbib-release" -w 2>/dev/null) || true
    APPLE_ID=$(security find-generic-password -a "apple-id" -s "imbib-release" -w 2>/dev/null) || true
    ASC_KEY_ID=$(security find-generic-password -a "asc-key-id" -s "imbib-testflight" -w 2>/dev/null) || true

    echo -e "${CYAN}Credentials:${NC}"
    if [ -n "$TEAM_ID" ]; then
        echo -e "  Team ID:         ${GREEN}✓ configured${NC}"
    else
        echo -e "  Team ID:         ${RED}✗ missing${NC}"
    fi

    if [ -n "$APPLE_ID" ]; then
        echo -e "  Notarization:    ${GREEN}✓ configured${NC} ($APPLE_ID)"
    else
        echo -e "  Notarization:    ${RED}✗ missing${NC}"
    fi

    if [ -n "$ASC_KEY_ID" ]; then
        API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
        if [ -f "$API_KEY_PATH" ]; then
            echo -e "  App Store API:   ${GREEN}✓ configured${NC} (key: $ASC_KEY_ID)"
        else
            echo -e "  App Store API:   ${YELLOW}⚠ key configured but .p8 file missing${NC}"
        fi
    else
        echo -e "  App Store API:   ${RED}✗ missing${NC}"
    fi
    echo ""

    # Check prerequisites
    echo -e "${CYAN}Prerequisites:${NC}"
    if command -v xcodegen >/dev/null 2>&1; then
        echo -e "  xcodegen:        ${GREEN}✓ installed${NC}"
    else
        echo -e "  xcodegen:        ${RED}✗ missing (brew install xcodegen)${NC}"
    fi

    if command -v cargo >/dev/null 2>&1; then
        echo -e "  Rust:            ${GREEN}✓ installed${NC}"
    else
        echo -e "  Rust:            ${RED}✗ missing (rustup.rs)${NC}"
    fi

    if command -v create-dmg >/dev/null 2>&1; then
        echo -e "  create-dmg:      ${GREEN}✓ installed${NC}"
    else
        echo -e "  create-dmg:      ${YELLOW}optional (brew install create-dmg)${NC}"
    fi
    echo ""

    # App Store Connect status (if credentials available)
    if [ -n "$ASC_KEY_ID" ]; then
        echo -e "${CYAN}App Store Connect:${NC}"
        echo "  (Run ./scripts/appstore-release.sh to query version status)"
        echo "  Dashboard: https://appstoreconnect.apple.com/apps"
    fi
    echo ""
}

# ============================================================================
# TestFlight
# ============================================================================
do_testflight() {
    shift  # Remove 'testflight' from args

    # Pass through to appstore-release.sh
    echo -e "${GREEN}=== TestFlight Release ===${NC}"
    echo ""

    # Build args for appstore-release.sh
    ARGS=()
    for arg in "$@"; do
        ARGS+=("$arg")
    done

    exec "$SCRIPT_DIR/appstore-release.sh" "${ARGS[@]}"
}

# ============================================================================
# DMG
# ============================================================================
do_dmg() {
    shift  # Remove 'dmg' from args

    echo -e "${GREEN}=== Local DMG Build ===${NC}"
    echo ""

    # Pass through to quick-release.sh
    exec "$SCRIPT_DIR/quick-release.sh" "$@"
}

# ============================================================================
# GitHub
# ============================================================================
do_github() {
    shift  # Remove 'github' from args

    VERSION="$1"
    if [ -z "$VERSION" ]; then
        echo -e "${RED}Error: Version required${NC}"
        echo ""
        echo "Usage: ./scripts/release.sh github v1.2.0"
        exit 1
    fi

    # Ensure version starts with 'v'
    if [[ "$VERSION" != v* ]]; then
        VERSION="v$VERSION"
    fi

    # Tag format for GitHub Actions
    TAG="imbib-$VERSION"

    echo -e "${GREEN}=== GitHub Release ===${NC}"
    echo ""
    echo -e "Version:  ${YELLOW}$VERSION${NC}"
    echo -e "Tag:      ${YELLOW}$TAG${NC}"
    echo ""

    # Check if tag already exists
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        echo -e "${RED}Error: Tag $TAG already exists${NC}"
        echo ""
        echo "To delete and recreate:"
        echo "  git tag -d $TAG"
        echo "  git push origin :refs/tags/$TAG"
        exit 1
    fi

    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo -e "${YELLOW}Warning: You have uncommitted changes${NC}"
        git status --short
        echo ""
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi

    # Create and push tag
    echo "Creating tag $TAG..."
    git tag "$TAG"

    echo "Pushing tag to origin..."
    git push origin "$TAG"

    echo ""
    echo -e "${GREEN}=== GitHub Release Triggered ===${NC}"
    echo ""
    echo "GitHub Actions will now build and upload the DMG."
    echo ""
    echo -e "${BLUE}Monitor progress:${NC}"
    echo "  https://github.com/$(git remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')/actions"
    echo ""
    echo -e "${BLUE}Release will appear at:${NC}"
    echo "  https://github.com/$(git remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')/releases/tag/$TAG"
    echo ""
}

# ============================================================================
# Main
# ============================================================================
COMMAND="${1:-help}"

case "$COMMAND" in
    testflight|tf)
        do_testflight "$@"
        ;;
    dmg|local)
        do_dmg "$@"
        ;;
    github|gh)
        do_github "$@"
        ;;
    setup)
        do_setup
        ;;
    status|info)
        do_status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
