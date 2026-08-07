#!/bin/bash
# Build script for impress-helix Rust library
# Creates an XCFramework for macOS and iOS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Set deployment targets (can be overridden by environment)
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-14.0}"

echo "Using MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
echo "Using IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET"

# Output directories
# When in a workspace, cargo builds to the workspace root target directory
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$WORKSPACE_ROOT/target"
FRAMEWORK_DIR="$SCRIPT_DIR/frameworks"
XCFRAMEWORK_NAME="ImpressHelix"

# Rust targets
MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"
IOS_TARGET="aarch64-apple-ios"
IOS_SIM_TARGET="aarch64-apple-ios-sim"
IOS_SIM_X86_TARGET="x86_64-apple-ios"

# IMPRESS_SKIP_X86=1 builds arm64-only (local dev loop on Apple Silicon —
# roughly halves the macOS Rust compile). CI and release keep universal.
BUILD_X86=$([ "${IMPRESS_SKIP_X86:-0}" = "1" ] && echo 0 || echo 1)
# IMPRESS_SKIP_IOS=1 skips the iOS device + simulator slices and produces a
# macOS-only xcframework for the local dev loop. CI and release keep all slices.
BUILD_IOS=$([ "${IMPRESS_SKIP_IOS:-0}" = "1" ] && echo 0 || echo 1)

echo "=== Building impress-helix Rust library ==="

# Ensure required targets are installed
echo "Installing Rust targets..."
rustup target add $MACOS_TARGET $MACOS_X86_TARGET 2>/dev/null || true
if [ "$BUILD_IOS" = "1" ]; then
    rustup target add $IOS_TARGET $IOS_SIM_TARGET $IOS_SIM_X86_TARGET 2>/dev/null || true
fi

# Build for all targets with ffi feature
echo ""
echo "Building for macOS (arm64)..."
cargo build --release --target $MACOS_TARGET --features ffi

if [ "$BUILD_X86" = "1" ]; then
    echo ""
    echo "Building for macOS (x86_64)..."
    cargo build --release --target $MACOS_X86_TARGET --features ffi
fi

if [ "$BUILD_IOS" = "1" ]; then
    echo ""
    echo "Building for iOS (arm64)..."
    cargo build --release --target $IOS_TARGET --features ffi

    echo ""
    echo "Building for iOS Simulator (arm64)..."
    cargo build --release --target $IOS_SIM_TARGET --features ffi

    echo ""
    echo "Building for iOS Simulator (x86_64)..."
    cargo build --release --target $IOS_SIM_X86_TARGET --features ffi
fi

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

if [ "$BUILD_X86" = "1" ]; then
    echo "Creating universal macOS binary..."
    lipo -create \
        "$BUILD_DIR/$MACOS_TARGET/release/libimpress_helix.a" \
        "$BUILD_DIR/$MACOS_X86_TARGET/release/libimpress_helix.a" \
        -output "$MACOS_UNIVERSAL_DIR/libimpress_helix.a"
else
    echo "Creating arm64-only macOS binary (IMPRESS_SKIP_X86=1)..."
    cp "$BUILD_DIR/$MACOS_TARGET/release/libimpress_helix.a" \
        "$MACOS_UNIVERSAL_DIR/libimpress_helix.a"
fi

if [ "$BUILD_IOS" = "1" ]; then
    echo "Creating universal iOS Simulator binary..."
    lipo -create \
        "$BUILD_DIR/$IOS_SIM_TARGET/release/libimpress_helix.a" \
        "$BUILD_DIR/$IOS_SIM_X86_TARGET/release/libimpress_helix.a" \
        -output "$IOS_SIM_UNIVERSAL_DIR/libimpress_helix.a"
fi

# Generate Swift bindings
echo ""
echo "Generating Swift bindings..."
cargo run --features ffi --bin uniffi-bindgen generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/libimpress_helix.dylib" \
    --language swift \
    --out-dir "$FRAMEWORK_DIR/generated"

# Create headers directory with unique subdirectory to avoid Xcode conflicts
# This puts headers in impress_helix/ subdirectory so multiple xcframeworks don't conflict
HEADERS_DIR="$FRAMEWORK_DIR/headers/impress_helixFFI"
mkdir -p "$HEADERS_DIR"
cp "$FRAMEWORK_DIR/generated/impress_helixFFI.h" "$HEADERS_DIR/"

# Create module map with path to header in subdirectory
cat > "$HEADERS_DIR/module.modulemap" << 'MODULEMAP'
module impress_helixFFI {
    header "impress_helixFFI.h"
    export *
}
MODULEMAP

# Create XCFramework with subdirectory headers
echo ""
echo "Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

XCFRAMEWORK_ARGS=(
    -library "$MACOS_UNIVERSAL_DIR/libimpress_helix.a"
    -headers "$FRAMEWORK_DIR/headers"
)
if [ "$BUILD_IOS" = "1" ]; then
    XCFRAMEWORK_ARGS+=(
        -library "$BUILD_DIR/$IOS_TARGET/release/libimpress_helix.a"
        -headers "$FRAMEWORK_DIR/headers"
        -library "$IOS_SIM_UNIVERSAL_DIR/libimpress_helix.a"
        -headers "$FRAMEWORK_DIR/headers"
    )
fi

xcodebuild -create-xcframework \
    "${XCFRAMEWORK_ARGS[@]}" \
    -output "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

echo ""
echo "Cleaning up xcframework headers..."
for dir in "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"/*/Headers; do
    # Remove any Swift files from headers - they're not needed there
    rm -f "$dir"/*/impress_helix.swift 2>/dev/null || true
    rm -f "$dir/impress_helix.swift" 2>/dev/null || true
    echo "  Cleaned $dir"
done

# Copy the single generated Swift bindings file
echo ""
echo "Copying Swift bindings..."
cp "$FRAMEWORK_DIR/generated/impress_helix.swift" "$FRAMEWORK_DIR/impress_helix.swift"
echo "  Copied impress_helix.swift"

echo ""
echo "=== Build complete! ==="
echo ""
echo "XCFramework: $FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"
echo "Swift bindings: $FRAMEWORK_DIR/impress_helix.swift"
echo ""
echo "To use in your Swift package, add the XCFramework as a binary target"
echo "and copy impress_helix.swift to your sources."
