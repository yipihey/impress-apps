#!/bin/bash
# Build script for scix-client-ffi
# Creates ScixClientCore.xcframework for use by ImpressScixCore Swift package.
#
# Usage:
#   cd crates/scix-client-ffi && ./build-xcframework.sh
#
# Output:
#   crates/scix-client-ffi/frameworks/ScixClientCore.xcframework
#   packages/ImpressScixCore/frameworks/ScixClientCore.xcframework  (copied)
#   packages/ImpressScixCore/Sources/ImpressScixCore/scix_client_ffi.swift  (bindings)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-14.0}"

echo "Building ScixClientCore XCFramework"
echo "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"

WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$WORKSPACE_ROOT/target"
FRAMEWORK_DIR="$SCRIPT_DIR/frameworks"
XCFRAMEWORK_NAME="ScixClientCore"
LIB_NAME="scix_client_ffi"

MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"
IOS_TARGET="aarch64-apple-ios"
IOS_SIM_TARGET="aarch64-apple-ios-sim"
IOS_SIM_X86_TARGET="x86_64-apple-ios"

echo "=== Installing Rust targets ==="
rustup target add $MACOS_TARGET $MACOS_X86_TARGET $IOS_TARGET $IOS_SIM_TARGET $IOS_SIM_X86_TARGET 2>/dev/null || true

echo "=== Building (native feature) ==="
cargo build --release --target $MACOS_TARGET --features native
cargo build --release --target $MACOS_X86_TARGET --features native
cargo build --release --target $IOS_TARGET --features native
cargo build --release --target $IOS_SIM_TARGET --features native
cargo build --release --target $IOS_SIM_X86_TARGET --features native

echo "=== Creating framework structure ==="
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR"

MACOS_UNIVERSAL_DIR="$FRAMEWORK_DIR/macos-universal"
IOS_SIM_UNIVERSAL_DIR="$FRAMEWORK_DIR/ios-sim-universal"
mkdir -p "$MACOS_UNIVERSAL_DIR" "$IOS_SIM_UNIVERSAL_DIR"

echo "Creating universal macOS binary..."
lipo -create \
    "$BUILD_DIR/$MACOS_TARGET/release/lib${LIB_NAME}.a" \
    "$BUILD_DIR/$MACOS_X86_TARGET/release/lib${LIB_NAME}.a" \
    -output "$MACOS_UNIVERSAL_DIR/lib${LIB_NAME}.a"

echo "Creating universal iOS Simulator binary..."
lipo -create \
    "$BUILD_DIR/$IOS_SIM_TARGET/release/lib${LIB_NAME}.a" \
    "$BUILD_DIR/$IOS_SIM_X86_TARGET/release/lib${LIB_NAME}.a" \
    -output "$IOS_SIM_UNIVERSAL_DIR/lib${LIB_NAME}.a"

echo "=== Generating Swift bindings ==="
BINDINGS_DIR="$FRAMEWORK_DIR/bindings"
mkdir -p "$BINDINGS_DIR"

# Build a macOS dylib for bindgen (cdylib target)
cargo build --release --target $MACOS_TARGET --features native

cargo run --bin uniffi-bindgen --features native -- generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/lib${LIB_NAME}.dylib" \
    --language swift \
    --out-dir "$BINDINGS_DIR"

HEADER_FILE="$BINDINGS_DIR/${XCFRAMEWORK_NAME}FFI.h"
if [ ! -f "$HEADER_FILE" ]; then
    HEADER_FILE=$(ls "$BINDINGS_DIR"/*.h 2>/dev/null | head -1)
fi

echo "=== Building XCFramework ==="
MACOS_FRAMEWORK_DIR="$FRAMEWORK_DIR/macos.framework"
IOS_FRAMEWORK_DIR="$FRAMEWORK_DIR/ios.framework"
IOS_SIM_FRAMEWORK_DIR="$FRAMEWORK_DIR/ios-sim.framework"

for dir in "$MACOS_FRAMEWORK_DIR" "$IOS_FRAMEWORK_DIR" "$IOS_SIM_FRAMEWORK_DIR"; do
    mkdir -p "$dir/Headers" "$dir/Modules"
done

for dir in "$MACOS_FRAMEWORK_DIR" "$IOS_FRAMEWORK_DIR" "$IOS_SIM_FRAMEWORK_DIR"; do
    if [ -n "$HEADER_FILE" ] && [ -f "$HEADER_FILE" ]; then
        cp "$HEADER_FILE" "$dir/Headers/"
    fi
    MODULEMAP_FILE="$BINDINGS_DIR/${XCFRAMEWORK_NAME}FFI.modulemap"
    if [ ! -f "$MODULEMAP_FILE" ]; then
        MODULEMAP_FILE=$(ls "$BINDINGS_DIR"/*.modulemap 2>/dev/null | head -1)
    fi
    if [ -n "$MODULEMAP_FILE" ] && [ -f "$MODULEMAP_FILE" ]; then
        cp "$MODULEMAP_FILE" "$dir/Headers/module.modulemap"
    fi
done

cp "$MACOS_UNIVERSAL_DIR/lib${LIB_NAME}.a" "$MACOS_FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.a"
cp "$BUILD_DIR/$IOS_TARGET/release/lib${LIB_NAME}.a" "$IOS_FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.a"
cp "$IOS_SIM_UNIVERSAL_DIR/lib${LIB_NAME}.a" "$IOS_SIM_FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.a"

xcodebuild -create-xcframework \
    -library "$MACOS_FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.a" \
    -headers "$MACOS_FRAMEWORK_DIR/Headers" \
    -library "$IOS_FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.a" \
    -headers "$IOS_FRAMEWORK_DIR/Headers" \
    -library "$IOS_SIM_FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.a" \
    -headers "$IOS_SIM_FRAMEWORK_DIR/Headers" \
    -output "$FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.xcframework"

echo "=== Copying XCFramework and Swift bindings to ImpressScixCore ==="
IMPRESSSCIXCORE_FRAMEWORKS="$WORKSPACE_ROOT/packages/ImpressScixCore/frameworks"
IMPRESSSCIXCORE_SOURCES="$WORKSPACE_ROOT/packages/ImpressScixCore/Sources/ImpressScixCore"

mkdir -p "$IMPRESSSCIXCORE_FRAMEWORKS" "$IMPRESSSCIXCORE_SOURCES"

# Copy XCFramework
rm -rf "$IMPRESSSCIXCORE_FRAMEWORKS/${XCFRAMEWORK_NAME}.xcframework"
cp -R "$FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.xcframework" "$IMPRESSSCIXCORE_FRAMEWORKS/"

# Copy Swift bindings (rename to avoid conflicts with hand-written wrappers)
SWIFT_BINDING=$(ls "$BINDINGS_DIR"/*.swift 2>/dev/null | head -1)
if [ -n "$SWIFT_BINDING" ]; then
    cp "$SWIFT_BINDING" "$IMPRESSSCIXCORE_SOURCES/${LIB_NAME}.swift"
    echo "Copied Swift bindings to $IMPRESSSCIXCORE_SOURCES/${LIB_NAME}.swift"
fi

echo ""
echo "=== Done ==="
echo "XCFramework: $FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.xcframework"
echo "ImpressScixCore: $IMPRESSSCIXCORE_SOURCES/${LIB_NAME}.swift"
echo ""
echo "Next steps:"
echo "  1. Verify the XCFramework at packages/ImpressScixCore/frameworks/"
echo "  2. Build PublicationManagerCore: swift build"
