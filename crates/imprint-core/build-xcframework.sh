#!/bin/bash
# Build script for imprint-core Rust library
# Creates an XCFramework for macOS (iOS support can be added later)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Set deployment targets (can be overridden by environment)
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

echo "Using MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"

# Output directories
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$WORKSPACE_ROOT/target"
FRAMEWORK_DIR="$SCRIPT_DIR/frameworks"
XCFRAMEWORK_NAME="ImprintCore"

# Rust targets (macOS only for now - Typst has heavy dependencies)
MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"

echo "=== Building imprint-core Rust library ==="

# Ensure required targets are installed
echo "Installing Rust targets..."
rustup target add $MACOS_TARGET $MACOS_X86_TARGET 2>/dev/null || true

# Build for macOS with the native feature (uniffi + typst-render)
echo ""
echo "Building for macOS (arm64) with native features..."
cargo build --release --target $MACOS_TARGET --features native

echo ""
echo "Building for macOS (x86_64) with native features..."
cargo build --release --target $MACOS_X86_TARGET --features native

# Create framework directory structure
echo ""
echo "Creating framework structure..."
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR"

# Create universal binary directory
MACOS_UNIVERSAL_DIR="$FRAMEWORK_DIR/macos-universal"
mkdir -p "$MACOS_UNIVERSAL_DIR"

echo "Creating universal macOS binary..."
lipo -create \
    "$BUILD_DIR/$MACOS_TARGET/release/libimprint_core.a" \
    "$BUILD_DIR/$MACOS_X86_TARGET/release/libimprint_core.a" \
    -output "$MACOS_UNIVERSAL_DIR/libimprint_core.a"

# Generate Swift bindings
echo ""
echo "Generating Swift bindings..."

# First, build the uniffi-bindgen binary
cargo build --release --target $MACOS_TARGET --features native --bin uniffi-bindgen

# Then use it to generate bindings
cargo run --release --target $MACOS_TARGET --features native --bin uniffi-bindgen -- generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/libimprint_core.dylib" \
    --language swift \
    --out-dir "$FRAMEWORK_DIR/generated"

# Check if binding generation succeeded
if [ ! -f "$FRAMEWORK_DIR/generated/imprint_coreFFI.h" ]; then
    echo "Warning: Swift bindings generation may have failed. Creating minimal placeholder..."
    mkdir -p "$FRAMEWORK_DIR/generated"

    # Create minimal header
    cat > "$FRAMEWORK_DIR/generated/imprint_coreFFI.h" << 'HEADER'
// Placeholder header - UniFFI binding generation pending
#ifndef imprint_coreFFI_h
#define imprint_coreFFI_h

#include <stdint.h>
#include <stdbool.h>

// Placeholder for UniFFI-generated functions
// These will be populated when bindings are properly generated

#endif /* imprint_coreFFI_h */
HEADER

    # Create minimal modulemap
    cat > "$FRAMEWORK_DIR/generated/imprint_coreFFI.modulemap" << 'MODULEMAP'
module imprint_coreFFI {
    header "imprint_coreFFI.h"
    export *
}
MODULEMAP
fi

# Create XCFramework
echo ""
echo "Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

xcodebuild -create-xcframework \
    -library "$MACOS_UNIVERSAL_DIR/libimprint_core.a" \
    -headers "$FRAMEWORK_DIR/generated" \
    -output "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

# Rename modulemap files for SPM compatibility
echo ""
echo "Renaming modulemaps for SPM compatibility..."
for dir in "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"/*/Headers; do
    if [ -f "$dir/imprint_coreFFI.modulemap" ]; then
        mv "$dir/imprint_coreFFI.modulemap" "$dir/module.modulemap"
        echo "  Renamed modulemap in $dir"
    fi
done

# Copy Swift bindings if they exist
if [ -f "$FRAMEWORK_DIR/generated/imprint_core.swift" ]; then
    echo ""
    echo "Copying Swift bindings..."
    cp "$FRAMEWORK_DIR/generated/imprint_core.swift" "$FRAMEWORK_DIR/"

    # Also copy to the Swift package if it exists (flat structure, no Generated/ subdir)
    SWIFT_PACKAGE_DIR="$WORKSPACE_ROOT/apps/imprint/Packages/ImprintCore/Sources/ImprintCore"
    if [ -d "$SWIFT_PACKAGE_DIR" ]; then
        echo "Copying Swift bindings to ImprintCore package..."
        cp "$FRAMEWORK_DIR/generated/imprint_core.swift" "$SWIFT_PACKAGE_DIR/"
    fi
fi

echo ""
echo "=== Build complete! ==="
echo ""
echo "XCFramework: $FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"
if [ -f "$FRAMEWORK_DIR/imprint_core.swift" ]; then
    echo "Swift bindings: $FRAMEWORK_DIR/imprint_core.swift"
fi
echo ""
echo "To use in your Swift package:"
echo "1. Add the XCFramework as a binary target"
echo "2. Copy imprint_core.swift to your sources (if generated)"
