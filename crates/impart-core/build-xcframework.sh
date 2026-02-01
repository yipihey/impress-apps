#!/bin/bash
# Build script for impart-core Rust library
# Creates an XCFramework for macOS and iOS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Set deployment targets (can be overridden by environment)
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

echo "Using MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
echo "Using IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET"

# Output directories
# When in a workspace, cargo builds to the workspace root target directory
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$WORKSPACE_ROOT/target"
FRAMEWORK_DIR="$SCRIPT_DIR/frameworks"
XCFRAMEWORK_NAME="ImpartCore"

# Rust targets
MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"
IOS_TARGET="aarch64-apple-ios"
IOS_SIM_TARGET="aarch64-apple-ios-sim"
IOS_SIM_X86_TARGET="x86_64-apple-ios"

echo "=== Building impart-core Rust library ==="

# Ensure required targets are installed
echo "Installing Rust targets..."
rustup target add $MACOS_TARGET $MACOS_X86_TARGET $IOS_TARGET $IOS_SIM_TARGET $IOS_SIM_X86_TARGET 2>/dev/null || true

# Build for all targets with native feature (uniffi + native dependencies)
echo ""
echo "Building for macOS (arm64)..."
cargo build --release --target $MACOS_TARGET --features native

echo ""
echo "Building for macOS (x86_64)..."
cargo build --release --target $MACOS_X86_TARGET --features native

echo ""
echo "Building for iOS (arm64)..."
cargo build --release --target $IOS_TARGET --features native

echo ""
echo "Building for iOS Simulator (arm64)..."
cargo build --release --target $IOS_SIM_TARGET --features native

echo ""
echo "Building for iOS Simulator (x86_64)..."
cargo build --release --target $IOS_SIM_X86_TARGET --features native

# Create framework directory structure
echo ""
echo "Creating framework structure..."
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR"

# Create universal binaries
MACOS_UNIVERSAL_DIR="$FRAMEWORK_DIR/macos-universal"
IOS_SIM_UNIVERSAL_DIR="$FRAMEWORK_DIR/ios-sim-universal"

mkdir -p "$MACOS_UNIVERSAL_DIR"
mkdir -p "$IOS_SIM_UNIVERSAL_DIR"

echo "Creating universal macOS binary..."
lipo -create \
    "$BUILD_DIR/$MACOS_TARGET/release/libimpart_core.a" \
    "$BUILD_DIR/$MACOS_X86_TARGET/release/libimpart_core.a" \
    -output "$MACOS_UNIVERSAL_DIR/libimpart_core.a"

echo "Creating universal iOS Simulator binary..."
lipo -create \
    "$BUILD_DIR/$IOS_SIM_TARGET/release/libimpart_core.a" \
    "$BUILD_DIR/$IOS_SIM_X86_TARGET/release/libimpart_core.a" \
    -output "$IOS_SIM_UNIVERSAL_DIR/libimpart_core.a"

# Generate Swift bindings
echo ""
echo "Generating Swift bindings..."
cargo run --features native --bin uniffi-bindgen generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/libimpart_core.dylib" \
    --language swift \
    --out-dir "$FRAMEWORK_DIR/generated"

# Create module map
MODULE_MAP="$FRAMEWORK_DIR/module.modulemap"
cat > "$MODULE_MAP" << 'MODULEMAP'
module impart_core {
    header "impart_coreFFI.h"
    export *
}
MODULEMAP

# Create XCFramework
echo ""
echo "Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

xcodebuild -create-xcframework \
    -library "$MACOS_UNIVERSAL_DIR/libimpart_core.a" \
    -headers "$FRAMEWORK_DIR/generated" \
    -library "$BUILD_DIR/$IOS_TARGET/release/libimpart_core.a" \
    -headers "$FRAMEWORK_DIR/generated" \
    -library "$IOS_SIM_UNIVERSAL_DIR/libimpart_core.a" \
    -headers "$FRAMEWORK_DIR/generated" \
    -output "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

# Rename modulemap files from impart_coreFFI.modulemap to module.modulemap
# SPM requires the modulemap to be named module.modulemap
echo ""
echo "Renaming modulemaps for SPM compatibility..."
for dir in "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"/*/Headers; do
    if [ -f "$dir/impart_coreFFI.modulemap" ]; then
        mv "$dir/impart_coreFFI.modulemap" "$dir/module.modulemap"
        echo "  Renamed modulemap in $dir"
    fi
done

# Copy the single generated Swift bindings file
echo ""
echo "Copying Swift bindings..."
cp "$FRAMEWORK_DIR/generated/impart_core.swift" "$FRAMEWORK_DIR/impart_core.swift"
echo "  Copied impart_core.swift"

echo ""
echo "=== Build complete! ==="
echo ""
echo "XCFramework: $FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"
echo "Swift bindings: $FRAMEWORK_DIR/impart_core.swift"
echo ""
echo "To use in your Swift package, add the XCFramework as a binary target"
echo "and copy impart_core.swift to your sources."
