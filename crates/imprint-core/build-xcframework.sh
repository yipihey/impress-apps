#!/bin/bash
# Build script for imprint-core Rust library
# Creates a multi-platform XCFramework: macOS + iOS device + iOS Simulator.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Set deployment targets (can be overridden by environment)
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

echo "Using MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
echo "Using IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET"

# Output directories
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$WORKSPACE_ROOT/target"
FRAMEWORK_DIR="$SCRIPT_DIR/frameworks"
XCFRAMEWORK_NAME="ImprintCore"

# Rust targets. iOS slices always build with plain `native` features —
# Typst cross-compiles cleanly; Tectonic's C-dep tree stays desktop-only.
MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"
IOS_TARGET="aarch64-apple-ios"
IOS_SIM_TARGET="aarch64-apple-ios-sim"
IOS_SIM_X86_TARGET="x86_64-apple-ios"
IOS_FEATURES="native"

# Feature set + arch selection.
#
# IMPRINT_TECTONIC=1 adds the self-contained Tectonic LaTeX engine. Its C deps
# (freetype/graphite2/harfbuzz/icu) are built statically via vcpkg so the result
# links no Homebrew dylibs. This variant is **arm64-only** for now — building
# the C-dep tree universally is future work — so it skips the x86_64 slice.
CARGO_FEATURES="native"
# IMPRESS_SKIP_X86=1 builds arm64-only (local dev loop on Apple Silicon —
# roughly halves the macOS Rust compile). CI and release keep universal.
BUILD_X86=$([ "${IMPRESS_SKIP_X86:-0}" = "1" ] && echo 0 || echo 1)
# iOS slices are on by default (skip with IMPRINT_SKIP_IOS=1). The Tectonic
# variant is macOS-arm64-only: its bindings would reference LaTeX FFI symbols
# the iOS libs don't have, so it produces a desktop-only xcframework.
BUILD_IOS=$([ "${IMPRINT_SKIP_IOS:-0}" = "1" ] && echo 0 || echo 1)
if [ "${IMPRINT_TECTONIC:-0}" = "1" ]; then
    CARGO_FEATURES="native,tectonic-render"
    BUILD_X86=0
    BUILD_IOS=0
    export VCPKG_ROOT="${VCPKG_ROOT:-$WORKSPACE_ROOT/target/vcpkg}"
    export TECTONIC_DEP_BACKEND=vcpkg
    echo "IMPRINT_TECTONIC=1 → features=$CARGO_FEATURES, arm64-only, vcpkg=$VCPKG_ROOT"
    if [ ! -d "$VCPKG_ROOT/installed" ]; then
        echo "ERROR: vcpkg static deps not found at $VCPKG_ROOT."
        echo "Build them first: cargo vcpkg build --manifest-path crates/imprint-core/Cargo.toml"
        exit 1
    fi
fi

echo "=== Building imprint-core Rust library (features: $CARGO_FEATURES) ==="

# Ensure required targets are installed
echo "Installing Rust targets..."
rustup target add $MACOS_TARGET $MACOS_X86_TARGET 2>/dev/null || true
if [ "$BUILD_IOS" = "1" ]; then
    rustup target add $IOS_TARGET $IOS_SIM_TARGET $IOS_SIM_X86_TARGET 2>/dev/null || true
fi

# Build for macOS with the selected features
echo ""
echo "Building for macOS (arm64) with features: $CARGO_FEATURES ..."
cargo build --release --target $MACOS_TARGET --features "$CARGO_FEATURES"

if [ "$BUILD_X86" = "1" ]; then
    echo ""
    echo "Building for macOS (x86_64) with features: $CARGO_FEATURES ..."
    cargo build --release --target $MACOS_X86_TARGET --features "$CARGO_FEATURES"
fi

if [ "$BUILD_IOS" = "1" ]; then
    echo ""
    echo "Building for iOS device (arm64) with features: $IOS_FEATURES ..."
    cargo build --release --target $IOS_TARGET --features "$IOS_FEATURES" -p imprint-core
    echo ""
    echo "Building for iOS Simulator (arm64) with features: $IOS_FEATURES ..."
    cargo build --release --target $IOS_SIM_TARGET --features "$IOS_FEATURES" -p imprint-core
    echo ""
    echo "Building for iOS Simulator (x86_64) with features: $IOS_FEATURES ..."
    cargo build --release --target $IOS_SIM_X86_TARGET --features "$IOS_FEATURES" -p imprint-core
fi

# Create framework directory structure
echo ""
echo "Creating framework structure..."
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR"

# Create universal binary directory
MACOS_UNIVERSAL_DIR="$FRAMEWORK_DIR/macos-universal"
mkdir -p "$MACOS_UNIVERSAL_DIR"

if [ "$BUILD_X86" = "1" ]; then
    echo "Creating universal macOS binary (arm64 + x86_64)..."
    lipo -create \
        "$BUILD_DIR/$MACOS_TARGET/release/libimprint_core.a" \
        "$BUILD_DIR/$MACOS_X86_TARGET/release/libimprint_core.a" \
        -output "$MACOS_UNIVERSAL_DIR/libimprint_core.a"
else
    echo "Creating arm64-only macOS binary (Tectonic variant)..."
    cp "$BUILD_DIR/$MACOS_TARGET/release/libimprint_core.a" \
        "$MACOS_UNIVERSAL_DIR/libimprint_core.a"
fi

# Generate Swift bindings
echo ""
echo "Generating Swift bindings..."

# First, build the uniffi-bindgen binary
cargo build --release --target $MACOS_TARGET --features "$CARGO_FEATURES" --bin uniffi-bindgen

# Then use it to generate bindings (features must match so Tectonic exports
# like `compileLatexTectonic` appear when IMPRINT_TECTONIC=1)
cargo run --release --target $MACOS_TARGET --features "$CARGO_FEATURES" --bin uniffi-bindgen -- generate \
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
fi

# Create headers directory with unique subdirectory to avoid Xcode conflicts
# when multiple XCFrameworks are used in the same workspace
HEADERS_DIR="$FRAMEWORK_DIR/headers/imprint_coreFFI"
mkdir -p "$HEADERS_DIR"
cp "$FRAMEWORK_DIR/generated/imprint_coreFFI.h" "$HEADERS_DIR/"

cat > "$HEADERS_DIR/module.modulemap" << 'MODULEMAP'
module imprint_coreFFI {
    header "imprint_coreFFI.h"
    export *
}
MODULEMAP

# Create XCFramework with subdirectory headers
echo ""
echo "Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

XCFRAMEWORK_ARGS=(
    -library "$MACOS_UNIVERSAL_DIR/libimprint_core.a"
    -headers "$FRAMEWORK_DIR/headers"
)
if [ "$BUILD_IOS" = "1" ]; then
    # Simulator slice must be universal (arm64 + x86_64) — the generic
    # "iOS Simulator" destination links both architectures.
    IOS_SIM_UNIVERSAL_DIR="$FRAMEWORK_DIR/ios-simulator-universal"
    mkdir -p "$IOS_SIM_UNIVERSAL_DIR"
    lipo -create \
        "$BUILD_DIR/$IOS_SIM_TARGET/release/libimprint_core.a" \
        "$BUILD_DIR/$IOS_SIM_X86_TARGET/release/libimprint_core.a" \
        -output "$IOS_SIM_UNIVERSAL_DIR/libimprint_core.a"
    XCFRAMEWORK_ARGS+=(
        -library "$BUILD_DIR/$IOS_TARGET/release/libimprint_core.a"
        -headers "$FRAMEWORK_DIR/headers"
        -library "$IOS_SIM_UNIVERSAL_DIR/libimprint_core.a"
        -headers "$FRAMEWORK_DIR/headers"
    )
fi

xcodebuild -create-xcframework \
    "${XCFRAMEWORK_ARGS[@]}" \
    -output "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"

echo ""
echo "Cleaning up xcframework headers..."
for dir in "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"/*/Headers; do
    rm -f "$dir"/*/imprint_core.swift 2>/dev/null || true
    rm -f "$dir/imprint_core.swift" 2>/dev/null || true
    echo "  Cleaned $dir"
done

# Copy Swift bindings if they exist
if [ -f "$FRAMEWORK_DIR/generated/imprint_core.swift" ]; then
    echo ""
    echo "Copying Swift bindings..."
    cp "$FRAMEWORK_DIR/generated/imprint_core.swift" "$FRAMEWORK_DIR/"

    # Also copy to the Swift packages if they exist
    SWIFT_PACKAGE_DIR="$WORKSPACE_ROOT/apps/imprint/Packages/ImprintCore/Sources/ImprintCore"
    if [ -d "$SWIFT_PACKAGE_DIR" ]; then
        echo "Copying Swift bindings to ImprintCore package..."
        cp "$FRAMEWORK_DIR/generated/imprint_core.swift" "$SWIFT_PACKAGE_DIR/"
    fi

    RUST_CORE_PKG_DIR="$WORKSPACE_ROOT/apps/imprint/ImprintRustCore/Sources/ImprintRustCore"
    if [ -d "$RUST_CORE_PKG_DIR" ]; then
        echo "Copying Swift bindings to ImprintRustCore package..."
        cp "$FRAMEWORK_DIR/generated/imprint_core.swift" "$RUST_CORE_PKG_DIR/"
    fi
fi

# Copy XCFramework to the location referenced by the SPM package.
# mkdir -p, not a -d guard: the directory holds only this gitignored
# artifact, so it doesn't exist on fresh checkouts (CI) and an existence
# check silently skips the copy the app build then fails without.
APP_FRAMEWORKS_DIR="$WORKSPACE_ROOT/apps/imprint/Frameworks"
mkdir -p "$APP_FRAMEWORKS_DIR"
echo "Copying XCFramework to app Frameworks directory..."
rm -rf "$APP_FRAMEWORKS_DIR/$XCFRAMEWORK_NAME.xcframework"
cp -R "$FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework" "$APP_FRAMEWORKS_DIR/"

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
