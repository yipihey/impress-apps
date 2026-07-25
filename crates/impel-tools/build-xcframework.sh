#!/bin/bash
# Build script for the impel-tools Rust library.
# Creates an XCFramework for macOS.
#
# macOS-only, unlike its siblings: impel is a macOS app (deployment target 26),
# so the iOS slices the other build-xcframework.sh scripts produce would be dead
# weight and roughly triple the build time.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
echo "Using MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"

WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$WORKSPACE_ROOT/target"
FRAMEWORK_DIR="$SCRIPT_DIR/frameworks"
XCFRAMEWORK_NAME="ImpelTools"

MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"

echo "=== Building impel-tools Rust library ==="

echo "Installing Rust targets..."
rustup target add $MACOS_TARGET $MACOS_X86_TARGET 2>/dev/null || true

echo ""
echo "Building for macOS (arm64)..."
cargo build --release --target $MACOS_TARGET -p impel-tools

echo ""
echo "Building for macOS (x86_64)..."
cargo build --release --target $MACOS_X86_TARGET -p impel-tools

echo ""
echo "Creating framework structure..."
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR"

MACOS_UNIVERSAL_DIR="$FRAMEWORK_DIR/macos-universal"
mkdir -p "$MACOS_UNIVERSAL_DIR"

echo "Creating universal macOS binary..."
lipo -create \
    "$BUILD_DIR/$MACOS_TARGET/release/libimpel_tools.a" \
    "$BUILD_DIR/$MACOS_X86_TARGET/release/libimpel_tools.a" \
    -output "$MACOS_UNIVERSAL_DIR/libimpel_tools.a"

echo ""
echo "Generating Swift bindings..."
cargo run -p impel-tools --bin uniffi-bindgen generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/libimpel_tools.dylib" \
    --language swift \
    --out-dir "$FRAMEWORK_DIR/generated"

# Headers go in a uniquely-named subdirectory: several XCFrameworks are linked
# into the same Xcode workspace and a bare header name collides.
HEADERS_DIR="$FRAMEWORK_DIR/headers/impel_toolsFFI"
mkdir -p "$HEADERS_DIR"
cp "$FRAMEWORK_DIR/generated/impel_toolsFFI.h" "$HEADERS_DIR/"

cat > "$HEADERS_DIR/module.modulemap" << 'MODULEMAP'
module impel_toolsFFI {
    header "impel_toolsFFI.h"
    export *
}
MODULEMAP

echo ""
echo "Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

xcodebuild -create-xcframework \
    -library "$MACOS_UNIVERSAL_DIR/libimpel_tools.a" \
    -headers "$FRAMEWORK_DIR/headers" \
    -output "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

echo ""
echo "Cleaning up xcframework headers..."
for dir in "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"/*/Headers; do
    rm -f "$dir"/*/impel_tools.swift 2>/dev/null || true
    rm -f "$dir/impel_tools.swift" 2>/dev/null || true
    echo "  Cleaned $dir"
done

cp "$FRAMEWORK_DIR/generated/impel_tools.swift" "$FRAMEWORK_DIR/impel_tools.swift"

# Both destinations, always. Copying the XCFramework without the regenerated
# bindings (or vice versa) produces link errors that look like anything but a
# stale copy — the sibling crates learned this the hard way.
APP_FRAMEWORKS="$WORKSPACE_ROOT/apps/impel/Frameworks"
BINDINGS_DEST="$WORKSPACE_ROOT/apps/impel/Packages/CounselEngine/Sources/ImpelToolsFFI"

echo ""
echo "Installing into the impel app..."
mkdir -p "$APP_FRAMEWORKS" "$BINDINGS_DEST"
rm -rf "$APP_FRAMEWORKS/$XCFRAMEWORK_NAME.xcframework"
cp -R "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework" "$APP_FRAMEWORKS/"
cp "$FRAMEWORK_DIR/generated/impel_tools.swift" "$BINDINGS_DEST/impel_tools.swift"
echo "  $APP_FRAMEWORKS/$XCFRAMEWORK_NAME.xcframework"
echo "  $BINDINGS_DEST/impel_tools.swift"

echo ""
echo "=== Build complete! ==="
