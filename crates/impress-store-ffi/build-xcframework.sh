#!/bin/bash
# Build script for impress-store-ffi
# Creates ImpressStoreFfi.xcframework for use by all impress Swift apps.
#
# Usage:
#   cd crates/impress-store-ffi && ./build-xcframework.sh
#
# Output:
#   crates/impress-store-ffi/frameworks/ImpressStoreFfi.xcframework
#   packages/ImpressKit/Frameworks/ImpressStoreFfi.xcframework  (copied)
#   packages/ImpressKit/Sources/ImpressKit/impress_store_ffi.swift  (bindings)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-14.0}"

echo "Building ImpressStoreFfi XCFramework"
echo "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"

WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$WORKSPACE_ROOT/target"
FRAMEWORK_DIR="$SCRIPT_DIR/frameworks"
XCFRAMEWORK_NAME="ImpressStoreFfi"
LIB_NAME="impress_store_ffi"

MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"
IOS_TARGET="aarch64-apple-ios"
IOS_SIM_TARGET="aarch64-apple-ios-sim"
IOS_SIM_X86_TARGET="x86_64-apple-ios"

# IMPRESS_SKIP_IOS=1 skips the iOS device + simulator slices and produces a
# macOS-only xcframework for the local dev loop. CI and release keep all
# slices — imprint-iOS and imbib-iOS link this framework and need them.
BUILD_IOS=$([ "${IMPRESS_SKIP_IOS:-0}" = "1" ] && echo 0 || echo 1)

echo "=== Installing Rust targets ==="
rustup target add $MACOS_TARGET $MACOS_X86_TARGET 2>/dev/null || true
if [ "$BUILD_IOS" = "1" ]; then
    rustup target add $IOS_TARGET $IOS_SIM_TARGET $IOS_SIM_X86_TARGET 2>/dev/null || true
fi

echo "=== Building (native feature) ==="
# IMPRESS_SKIP_X86=1 → arm64-only macOS slice (local dev loop); CI keeps
# universal.
cargo build --release --target $MACOS_TARGET --features native
if [ "${IMPRESS_SKIP_X86:-0}" != "1" ]; then
    cargo build --release --target $MACOS_X86_TARGET --features native
fi
if [ "$BUILD_IOS" = "1" ]; then
    cargo build --release --target $IOS_TARGET --features native
    cargo build --release --target $IOS_SIM_TARGET --features native
    cargo build --release --target $IOS_SIM_X86_TARGET --features native
fi

echo "=== Creating framework structure ==="
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR"

MACOS_UNIVERSAL_DIR="$FRAMEWORK_DIR/macos-universal"
IOS_SIM_UNIVERSAL_DIR="$FRAMEWORK_DIR/ios-sim-universal"
mkdir -p "$MACOS_UNIVERSAL_DIR" "$IOS_SIM_UNIVERSAL_DIR"

echo "Creating universal macOS binary..."
if [ "${IMPRESS_SKIP_X86:-0}" != "1" ]; then
    lipo -create \
        "$BUILD_DIR/$MACOS_TARGET/release/lib${LIB_NAME}.a" \
        "$BUILD_DIR/$MACOS_X86_TARGET/release/lib${LIB_NAME}.a" \
        -output "$MACOS_UNIVERSAL_DIR/lib${LIB_NAME}.a"
else
    cp "$BUILD_DIR/$MACOS_TARGET/release/lib${LIB_NAME}.a" \
        "$MACOS_UNIVERSAL_DIR/lib${LIB_NAME}.a"
fi

if [ "$BUILD_IOS" = "1" ]; then
    echo "Creating universal iOS Simulator binary..."
    lipo -create \
        "$BUILD_DIR/$IOS_SIM_TARGET/release/lib${LIB_NAME}.a" \
        "$BUILD_DIR/$IOS_SIM_X86_TARGET/release/lib${LIB_NAME}.a" \
        -output "$IOS_SIM_UNIVERSAL_DIR/lib${LIB_NAME}.a"
fi

echo "=== Generating Swift bindings ==="
BINDINGS_DIR="$FRAMEWORK_DIR/bindings"
mkdir -p "$BINDINGS_DIR"

CARGO_TARGET_DIR="$BUILD_DIR/uniffi-bindgen" \
    cargo run --bin uniffi-bindgen --features native -- generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/lib${LIB_NAME}.dylib" \
    --language swift \
    --out-dir "$BINDINGS_DIR"

HEADER_FILE="$BINDINGS_DIR/${XCFRAMEWORK_NAME}FFI.h"
if [ ! -f "$HEADER_FILE" ]; then
    # UniFFI may use a different naming convention
    HEADER_FILE=$(ls "$BINDINGS_DIR"/*.h 2>/dev/null | head -1)
fi

echo "=== Building XCFramework ==="
MACOS_FRAMEWORK_DIR="$FRAMEWORK_DIR/macos.framework"
IOS_FRAMEWORK_DIR="$FRAMEWORK_DIR/ios.framework"
IOS_SIM_FRAMEWORK_DIR="$FRAMEWORK_DIR/ios-sim.framework"

for dir in "$MACOS_FRAMEWORK_DIR" "$IOS_FRAMEWORK_DIR" "$IOS_SIM_FRAMEWORK_DIR"; do
    mkdir -p "$dir/Headers" "$dir/Modules"
done

# Nest headers in a unique subdirectory to avoid Xcode conflicts when
# multiple XCFrameworks are used in the same workspace. Without nesting,
# e.g. impress_store_ffiFFI and ScixClientCore both produce
# Headers/module.modulemap, which collide in
# DerivedData/Build/Products/Debug/include/ ("Multiple commands produce").
# Same pattern as crates/imbib-core/build-xcframework.sh.
for dir in "$MACOS_FRAMEWORK_DIR" "$IOS_FRAMEWORK_DIR" "$IOS_SIM_FRAMEWORK_DIR"; do
    NESTED_DIR="$dir/Headers/${LIB_NAME}FFI"
    mkdir -p "$NESTED_DIR"
    if [ -n "$HEADER_FILE" ] && [ -f "$HEADER_FILE" ]; then
        cp "$HEADER_FILE" "$NESTED_DIR/"
    fi
    # Copy modulemap so SPM can import the module by name (e.g. impress_store_ffiFFI)
    MODULEMAP_FILE="$BINDINGS_DIR/${XCFRAMEWORK_NAME}FFI.modulemap"
    if [ ! -f "$MODULEMAP_FILE" ]; then
        MODULEMAP_FILE=$(ls "$BINDINGS_DIR"/*.modulemap 2>/dev/null | head -1)
    fi
    if [ -n "$MODULEMAP_FILE" ] && [ -f "$MODULEMAP_FILE" ]; then
        cp "$MODULEMAP_FILE" "$NESTED_DIR/module.modulemap"
    fi
done

# Copy static libs (keep .a extension so xcodebuild can detect library type)
cp "$MACOS_UNIVERSAL_DIR/lib${LIB_NAME}.a" "$MACOS_FRAMEWORK_DIR/lib${XCFRAMEWORK_NAME}.a"
if [ "$BUILD_IOS" = "1" ]; then
    cp "$BUILD_DIR/$IOS_TARGET/release/lib${LIB_NAME}.a" "$IOS_FRAMEWORK_DIR/lib${XCFRAMEWORK_NAME}.a"
    cp "$IOS_SIM_UNIVERSAL_DIR/lib${LIB_NAME}.a" "$IOS_SIM_FRAMEWORK_DIR/lib${XCFRAMEWORK_NAME}.a"
fi

XCFRAMEWORK_ARGS=(
    -library "$MACOS_FRAMEWORK_DIR/lib${XCFRAMEWORK_NAME}.a"
    -headers "$MACOS_FRAMEWORK_DIR/Headers"
)
if [ "$BUILD_IOS" = "1" ]; then
    XCFRAMEWORK_ARGS+=(
        -library "$IOS_FRAMEWORK_DIR/lib${XCFRAMEWORK_NAME}.a"
        -headers "$IOS_FRAMEWORK_DIR/Headers"
        -library "$IOS_SIM_FRAMEWORK_DIR/lib${XCFRAMEWORK_NAME}.a"
        -headers "$IOS_SIM_FRAMEWORK_DIR/Headers"
    )
fi

xcodebuild -create-xcframework \
    "${XCFRAMEWORK_ARGS[@]}" \
    -output "$FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.xcframework"

echo "=== Copying Swift bindings to ImpressRustCore ==="
IMPRESSRUSTCORE_SOURCES="$WORKSPACE_ROOT/packages/ImpressRustCore/Sources/ImpressRustCore"

mkdir -p "$IMPRESSRUSTCORE_SOURCES"

SWIFT_BINDING=$(ls "$BINDINGS_DIR"/*.swift 2>/dev/null | head -1)
if [ -n "$SWIFT_BINDING" ]; then
    cp "$SWIFT_BINDING" "$IMPRESSRUSTCORE_SOURCES/${LIB_NAME}.swift"
    echo "Copied Swift bindings to $IMPRESSRUSTCORE_SOURCES/${LIB_NAME}.swift"
fi

echo ""
echo "=== Done ==="
echo "XCFramework: $FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.xcframework"
echo "ImpressRustCore: $IMPRESSRUSTCORE_SOURCES/${LIB_NAME}.swift"
