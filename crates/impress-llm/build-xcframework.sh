#!/bin/bash
# Build script for impress-llm Rust library
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
XCFRAMEWORK_NAME="ImpressLLM"

# Rust targets
MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"
IOS_TARGET="aarch64-apple-ios"
IOS_SIM_TARGET="aarch64-apple-ios-sim"
IOS_SIM_X86_TARGET="x86_64-apple-ios"

echo "=== Building impress-llm Rust library ==="

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
    "$BUILD_DIR/$MACOS_TARGET/release/libimpress_llm.a" \
    "$BUILD_DIR/$MACOS_X86_TARGET/release/libimpress_llm.a" \
    -output "$MACOS_UNIVERSAL_DIR/libimpress_llm.a"

echo "Creating universal iOS Simulator binary..."
lipo -create \
    "$BUILD_DIR/$IOS_SIM_TARGET/release/libimpress_llm.a" \
    "$BUILD_DIR/$IOS_SIM_X86_TARGET/release/libimpress_llm.a" \
    -output "$IOS_SIM_UNIVERSAL_DIR/libimpress_llm.a"

# Generate Swift bindings
echo ""
echo "Generating Swift bindings..."
cargo run --features native --bin uniffi-bindgen generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/libimpress_llm.dylib" \
    --language swift \
    --out-dir "$FRAMEWORK_DIR/generated"

# Create headers directory with unique subdirectory to avoid Xcode conflicts
# when multiple XCFrameworks are used in the same workspace
HEADERS_DIR="$FRAMEWORK_DIR/headers/impress_llmFFI"
mkdir -p "$HEADERS_DIR"
cp "$FRAMEWORK_DIR/generated/impress_llmFFI.h" "$HEADERS_DIR/"

cat > "$HEADERS_DIR/module.modulemap" << 'MODULEMAP'
module impress_llmFFI {
    header "impress_llmFFI.h"
    export *
}
MODULEMAP

# Create XCFramework with subdirectory headers
echo ""
echo "Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

xcodebuild -create-xcframework \
    -library "$MACOS_UNIVERSAL_DIR/libimpress_llm.a" \
    -headers "$FRAMEWORK_DIR/headers" \
    -library "$BUILD_DIR/$IOS_TARGET/release/libimpress_llm.a" \
    -headers "$FRAMEWORK_DIR/headers" \
    -library "$IOS_SIM_UNIVERSAL_DIR/libimpress_llm.a" \
    -headers "$FRAMEWORK_DIR/headers" \
    -output "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

echo ""
echo "Cleaning up xcframework headers..."
for dir in "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"/*/Headers; do
    rm -f "$dir"/*/impress_llm.swift 2>/dev/null || true
    rm -f "$dir/impress_llm.swift" 2>/dev/null || true
    echo "  Cleaned $dir"
done

# Copy the single generated Swift bindings file
echo ""
echo "Copying Swift bindings..."
cp "$FRAMEWORK_DIR/generated/impress_llm.swift" "$FRAMEWORK_DIR/impress_llm.swift"
echo "  Copied impress_llm.swift"

echo ""
echo "=== Build complete! ==="
echo ""
echo "XCFramework: $FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"
echo "Swift bindings: $FRAMEWORK_DIR/impress_llm.swift"
echo ""
echo "To use in your Swift package, add the XCFramework as a binary target"
echo "and copy impress_llm.swift to your sources."
