#!/bin/bash
# Build script for impress-llm Rust library (macOS only)
# Creates an XCFramework for macOS development

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
echo "Using MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"

WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$WORKSPACE_ROOT/target"
FRAMEWORK_DIR="$SCRIPT_DIR/frameworks"
XCFRAMEWORK_NAME="ImpressLLM"

MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"

echo "=== Building impress-llm Rust library (macOS only) ==="

# Ensure targets are installed
rustup target add $MACOS_TARGET $MACOS_X86_TARGET 2>/dev/null || true

# Build for macOS
echo "Building for macOS (arm64)..."
cargo build --release --target $MACOS_TARGET --features native

echo "Building for macOS (x86_64)..."
cargo build --release --target $MACOS_X86_TARGET --features native

# Create framework directory
echo "Creating framework structure..."
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR"

MACOS_UNIVERSAL_DIR="$FRAMEWORK_DIR/macos-universal"
mkdir -p "$MACOS_UNIVERSAL_DIR"

echo "Creating universal macOS binary..."
lipo -create \
    "$BUILD_DIR/$MACOS_TARGET/release/libimpress_llm.a" \
    "$BUILD_DIR/$MACOS_X86_TARGET/release/libimpress_llm.a" \
    -output "$MACOS_UNIVERSAL_DIR/libimpress_llm.a"

# Generate Swift bindings
echo "Generating Swift bindings..."
cargo run --features native --bin uniffi-bindgen generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/libimpress_llm.dylib" \
    --language swift \
    --out-dir "$FRAMEWORK_DIR/generated"

# Create XCFramework (macOS only)
echo "Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

xcodebuild -create-xcframework \
    -library "$MACOS_UNIVERSAL_DIR/libimpress_llm.a" \
    -headers "$FRAMEWORK_DIR/generated" \
    -output "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

# Rename modulemap
echo "Renaming modulemaps for SPM compatibility..."
for dir in "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"/*/Headers; do
    if [ -f "$dir/impress_llmFFI.modulemap" ]; then
        mv "$dir/impress_llmFFI.modulemap" "$dir/module.modulemap"
        echo "  Renamed modulemap in $dir"
    fi
done

# Copy Swift bindings
echo "Copying Swift bindings..."
cp "$FRAMEWORK_DIR/generated/impress_llm.swift" "$FRAMEWORK_DIR/impress_llm.swift"

echo ""
echo "=== Build complete (macOS only) ==="
echo "XCFramework: $FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"
echo ""
echo "NOTE: iOS builds are disabled due to ioctl-rs dependency incompatibility."
echo "For iOS support, the llm crate needs to exclude serial port dependencies."
