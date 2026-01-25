#!/bin/bash
# build-extensions.sh
# Build Chrome, Firefox, and Edge browser extensions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

echo "Building browser extensions..."
echo "Source: $SCRIPT_DIR"
echo "Output: $BUILD_DIR"

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Files to exclude from packages
EXCLUDES=(
    "build-extensions.sh"
    "build"
    ".DS_Store"
    "manifest.firefox.json"
)

# Build Chrome/Edge extension
echo ""
echo "Building Chrome/Edge extension..."
cd "$SCRIPT_DIR"

# Create zip with standard manifest (Chrome/Edge)
zip -r "$BUILD_DIR/imbib-chrome.zip" . \
    -x "build-extensions.sh" \
    -x "build/*" \
    -x "*.DS_Store" \
    -x "manifest.firefox.json"

echo "Created: $BUILD_DIR/imbib-chrome.zip"

# Build Firefox extension
echo ""
echo "Building Firefox extension..."

# Create a temporary directory for Firefox build
FIREFOX_TEMP=$(mktemp -d)
cp -r "$SCRIPT_DIR"/* "$FIREFOX_TEMP/" 2>/dev/null || true

# Replace manifest.json with Firefox version
rm "$FIREFOX_TEMP/manifest.json"
cp "$SCRIPT_DIR/manifest.firefox.json" "$FIREFOX_TEMP/manifest.json"
rm -f "$FIREFOX_TEMP/manifest.firefox.json"
rm -f "$FIREFOX_TEMP/build-extensions.sh"
rm -rf "$FIREFOX_TEMP/build"

# Create Firefox zip
cd "$FIREFOX_TEMP"
zip -r "$BUILD_DIR/imbib-firefox.zip" . -x "*.DS_Store"

# Cleanup
rm -rf "$FIREFOX_TEMP"

echo "Created: $BUILD_DIR/imbib-firefox.zip"

# Summary
echo ""
echo "Build complete!"
echo ""
echo "Extensions:"
ls -la "$BUILD_DIR"

echo ""
echo "Distribution:"
echo "  Chrome: Upload imbib-chrome.zip to Chrome Web Store"
echo "  Edge:   Upload imbib-chrome.zip to Edge Add-ons (same package)"
echo "  Firefox: Upload imbib-firefox.zip to Firefox Add-ons"
