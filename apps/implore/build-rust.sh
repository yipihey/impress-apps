#!/bin/bash
set -e

# Build Rust library and create XCFramework for implore
#
# This script builds:
# - implore-core with UniFFI bindings
# - Creates universal binary for macOS (x86_64 + arm64)
# - Packages as XCFramework

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$SCRIPT_DIR/../.."
CRATE_DIR="$PROJECT_ROOT/crates/implore-core"
FRAMEWORK_DIR="$SCRIPT_DIR/Frameworks"
SWIFT_PACKAGE_DIR="$SCRIPT_DIR/Packages/ImploreCore/Sources/ImploreCore"

# Parse arguments
RELEASE_FLAG=""
if [[ "$1" == "--release" ]]; then
    RELEASE_FLAG="--release"
    BUILD_DIR="release"
else
    BUILD_DIR="debug"
fi

echo "Building implore-core Rust library..."
cd "$PROJECT_ROOT"

# Build for macOS (both architectures)
echo "Building for macOS arm64..."
cargo build -p implore-core --features uniffi $RELEASE_FLAG --target aarch64-apple-darwin

echo "Building for macOS x86_64..."
cargo build -p implore-core --features uniffi $RELEASE_FLAG --target x86_64-apple-darwin

# Create universal binary
echo "Creating universal binary..."
mkdir -p "$FRAMEWORK_DIR/macos"

lipo -create \
    "$PROJECT_ROOT/target/aarch64-apple-darwin/$BUILD_DIR/libimplore_core.a" \
    "$PROJECT_ROOT/target/x86_64-apple-darwin/$BUILD_DIR/libimplore_core.a" \
    -output "$FRAMEWORK_DIR/macos/libimplore_core.a"

# Generate Swift bindings
echo "Generating Swift bindings..."
cargo run -p implore-core --features uniffi --bin uniffi-bindgen -- \
    generate "$CRATE_DIR/src/implore_core.udl" \
    --language swift \
    --out-dir "$SWIFT_PACKAGE_DIR"

# Create XCFramework
echo "Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR/ImploreCore.xcframework"

xcodebuild -create-xcframework \
    -library "$FRAMEWORK_DIR/macos/libimplore_core.a" \
    -headers "$SWIFT_PACKAGE_DIR" \
    -output "$FRAMEWORK_DIR/ImploreCore.xcframework"

echo "Build complete!"
echo "XCFramework: $FRAMEWORK_DIR/ImploreCore.xcframework"
echo "Swift bindings: $SWIFT_PACKAGE_DIR"
