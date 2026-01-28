#!/bin/bash
#
# App Store Screenshot Capture Script
# Run this script to capture screenshots for App Store submission
#
# Usage: ./scripts/capture-screenshots.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCREENSHOTS_DIR="$PROJECT_DIR/screenshots"

# Create directories
mkdir -p "$SCREENSHOTS_DIR/macos"
mkdir -p "$SCREENSHOTS_DIR/ios-6.7"
mkdir -p "$SCREENSHOTS_DIR/ios-6.5"
mkdir -p "$SCREENSHOTS_DIR/ipad-12.9"

echo "=== App Store Screenshot Capture ==="
echo ""
echo "This script will help you capture screenshots for App Store submission."
echo ""

# ============================================================================
# macOS Screenshots
# ============================================================================
echo "📱 macOS Screenshots"
echo "===================="
echo ""
echo "Required size: 2880 x 1800 (or at least 1280 x 800)"
echo ""

# Open the app
APP_PATH="$PROJECT_DIR/build/imbib-macOS.xcarchive/Products/Applications/imbib.app"
if [ -d "$APP_PATH" ]; then
    echo "Opening imbib.app..."
    open "$APP_PATH"
    sleep 3
else
    echo "⚠️  Built app not found. Please build the app first or open it manually."
fi

echo ""
echo "Instructions for macOS screenshots:"
echo "1. Resize the imbib window to show the main interface nicely"
echo "2. Press Cmd+Shift+4, then Space, then click on the imbib window"
echo "3. Screenshots will be saved to your Desktop"
echo "4. Capture these views:"
echo "   - Main library view with publications"
echo "   - Publication detail view"
echo "   - Search results"
echo "   - Settings/preferences"
echo ""
echo "Move screenshots to: $SCREENSHOTS_DIR/macos/"
echo ""

read -p "Press Enter when macOS screenshots are done..."

# ============================================================================
# iOS Screenshots (via Simulator)
# ============================================================================
echo ""
echo "📱 iOS Screenshots"
echo "=================="
echo ""

# Check if we need to build for simulator
echo "Note: iOS screenshots require the Rust library built for simulator."
echo ""
read -p "Do you want to build for iOS Simulator? (y/n) " BUILD_SIM

if [ "$BUILD_SIM" = "y" ]; then
    echo "Building Rust library for iOS Simulator..."
    cd "$PROJECT_DIR/../../crates/imbib-core"

    # Build for iOS Simulator
    rustup target add aarch64-apple-ios-sim 2>/dev/null || true
    cargo build --release --features native --target aarch64-apple-ios-sim

    echo "Rebuilding XCFramework with simulator support..."
    # This would need to rebuild the XCFramework to include simulator
    echo "⚠️  Manual XCFramework rebuild needed for simulator support."
fi

echo ""
echo "Alternative: Take screenshots on a physical iOS device"
echo ""
echo "Required sizes:"
echo "  - iPhone 6.7\" (iPhone 16 Pro Max): 1320 x 2868"
echo "  - iPhone 6.5\" (iPhone 16 Plus):    1290 x 2796"
echo "  - iPad 12.9\":                       2048 x 2732"
echo ""
echo "Instructions:"
echo "1. Install imbib from TestFlight on your device"
echo "2. Take screenshots of:"
echo "   - Main library view"
echo "   - Publication detail view"
echo "   - Search/browse view"
echo "   - Any unique features"
echo "3. AirDrop or sync screenshots to your Mac"
echo ""
echo "Move screenshots to:"
echo "  - iPhone 6.7\": $SCREENSHOTS_DIR/ios-6.7/"
echo "  - iPhone 6.5\": $SCREENSHOTS_DIR/ios-6.5/"
echo "  - iPad 12.9\":  $SCREENSHOTS_DIR/ipad-12.9/"
echo ""

read -p "Press Enter when iOS screenshots are done..."

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== Screenshot Summary ==="
echo ""
echo "macOS screenshots:"
ls -la "$SCREENSHOTS_DIR/macos/" 2>/dev/null || echo "  (none)"
echo ""
echo "iOS 6.7\" screenshots:"
ls -la "$SCREENSHOTS_DIR/ios-6.7/" 2>/dev/null || echo "  (none)"
echo ""
echo "iOS 6.5\" screenshots:"
ls -la "$SCREENSHOTS_DIR/ios-6.5/" 2>/dev/null || echo "  (none)"
echo ""
echo "iPad 12.9\" screenshots:"
ls -la "$SCREENSHOTS_DIR/ipad-12.9/" 2>/dev/null || echo "  (none)"
echo ""

echo "Next steps:"
echo "1. Upload screenshots to App Store Connect"
echo "2. Go to: https://appstoreconnect.apple.com/apps"
echo "3. Select imbib → App Store → Your version"
echo "4. Add screenshots for each device size"
echo ""
echo "Done!"
