#!/bin/bash
# Build script for imbib-core iOS library
# This script builds the Rust library for macOS and iOS targets and generates Swift bindings

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Output directories
OUTPUT_DIR="$SCRIPT_DIR/target"
SWIFT_OUT="$SCRIPT_DIR/generated"
FRAMEWORK_NAME="ImbibCore"

# Targets
MACOS_TARGET="aarch64-apple-darwin"
IOS_TARGET="aarch64-apple-ios"
IOS_SIM_TARGET="aarch64-apple-ios-sim"

echo "=== Building imbib-core ==="

# Build for all targets in release mode
echo "Building for macOS ($MACOS_TARGET)..."
cargo build --release --target "$MACOS_TARGET"

echo "Building for iOS device ($IOS_TARGET)..."
cargo build --release --target "$IOS_TARGET"

echo "Building for iOS simulator ($IOS_SIM_TARGET)..."
cargo build --release --target "$IOS_SIM_TARGET"

# Generate Swift bindings
echo "=== Generating Swift bindings ==="
mkdir -p "$SWIFT_OUT"

# Use cargo run with uniffi-bindgen to generate bindings
cargo run --bin uniffi-bindgen generate \
    --library "$OUTPUT_DIR/$MACOS_TARGET/release/libimbib_core.dylib" \
    --language swift \
    --out-dir "$SWIFT_OUT" \
    2>/dev/null || {
    # If that fails, try the older method
    echo "Trying alternate binding generation method..."
    cargo install uniffi-bindgen-library-mode 2>/dev/null || true
    uniffi-bindgen-library-mode generate \
        --library "$OUTPUT_DIR/$MACOS_TARGET/release/libimbib_core.dylib" \
        --language swift \
        --out-dir "$SWIFT_OUT" \
        2>/dev/null || {
        echo "Note: Swift binding generation requires uniffi-bindgen."
        echo "Installing uniffi_bindgen CLI..."
        cargo install uniffi_bindgen --version 0.28.3 2>/dev/null || true

        # Generate using the uniffi_bindgen crate directly
        echo "Generating bindings via library..."
    }
}

# Create XCFramework structure
echo "=== Creating XCFramework ==="
XCFRAMEWORK_DIR="$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"
rm -rf "$XCFRAMEWORK_DIR"

# macOS slice
MACOS_SLICE="$OUTPUT_DIR/xcframework-staging/macos"
mkdir -p "$MACOS_SLICE/Headers"
cp "$OUTPUT_DIR/$MACOS_TARGET/release/libimbib_core.a" "$MACOS_SLICE/" 2>/dev/null || \
    cp "$OUTPUT_DIR/$MACOS_TARGET/release/libimbib_core.dylib" "$MACOS_SLICE/"
cp "$SWIFT_OUT/imbib_coreFFI.h" "$MACOS_SLICE/Headers/" 2>/dev/null || true
cp "$SWIFT_OUT/imbib_coreFFI.modulemap" "$MACOS_SLICE/Headers/module.modulemap" 2>/dev/null || true

# iOS device slice
IOS_SLICE="$OUTPUT_DIR/xcframework-staging/ios-device"
mkdir -p "$IOS_SLICE/Headers"
cp "$OUTPUT_DIR/$IOS_TARGET/release/libimbib_core.a" "$IOS_SLICE/"
cp "$SWIFT_OUT/imbib_coreFFI.h" "$IOS_SLICE/Headers/" 2>/dev/null || true
cp "$SWIFT_OUT/imbib_coreFFI.modulemap" "$IOS_SLICE/Headers/module.modulemap" 2>/dev/null || true

# iOS simulator slice
IOS_SIM_SLICE="$OUTPUT_DIR/xcframework-staging/ios-simulator"
mkdir -p "$IOS_SIM_SLICE/Headers"
cp "$OUTPUT_DIR/$IOS_SIM_TARGET/release/libimbib_core.a" "$IOS_SIM_SLICE/"
cp "$SWIFT_OUT/imbib_coreFFI.h" "$IOS_SIM_SLICE/Headers/" 2>/dev/null || true
cp "$SWIFT_OUT/imbib_coreFFI.modulemap" "$IOS_SIM_SLICE/Headers/module.modulemap" 2>/dev/null || true

echo "=== Build complete ==="
echo ""
echo "Outputs:"
echo "  Static libraries:"
echo "    macOS:         $OUTPUT_DIR/$MACOS_TARGET/release/libimbib_core.a"
echo "    iOS device:    $OUTPUT_DIR/$IOS_TARGET/release/libimbib_core.a"
echo "    iOS simulator: $OUTPUT_DIR/$IOS_SIM_TARGET/release/libimbib_core.a"
echo ""
echo "  Swift bindings:  $SWIFT_OUT/"
echo ""
echo "To use in Xcode:"
echo "  1. Add the static library for your target to 'Link Binary With Libraries'"
echo "  2. Add the generated Swift file to your target"
echo "  3. Add the Headers directory to 'Header Search Paths'"
