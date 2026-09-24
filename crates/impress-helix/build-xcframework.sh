#!/bin/bash
# Build script for impress-helix Rust library
# Creates an XCFramework for macOS and iOS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Incremental release codegen for the framework loop only. This used to be
# `[profile.release] incremental = true` in the root manifest, where it also
# applied to the signed binaries in target/release.
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-1}"

# Deployment targets are pinned in the workspace .cargo/config.toml (force=true)
# so script builds and plain `cargo test`/`clippy` agree; exporting them here
# re-ran every cc-rs build script on each alternation.


# Output directories
# When in a workspace, cargo builds to the workspace root target directory
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="${CARGO_TARGET_DIR:-$WORKSPACE_ROOT/target}"
FRAMEWORK_DIR="$SCRIPT_DIR/frameworks"

# --- content-guarded publication -------------------------------------------
# Xcode stages the FFI headers into DerivedData preserving their mtime, so
# rewriting a byte-identical header invalidates every precompiled module built
# against it: a cold rebuild of PublicationManagerCore (602 files) in every app,
# plus the manual module-cache purge. Only the .a really changes on a rebuild,
# so publish by content and leave everything else alone.
impress_sync_file() {   # src dst|dstdir/
    [ -f "$1" ] || return 0
    local dst="$2"
    case "$dst" in */) dst="$dst$(basename "$1")";; esac
    [ -d "$dst" ] && dst="$dst/$(basename "$1")"
    if [ -f "$dst" ] && cmp -s "$1" "$dst"; then return 0; fi
    mkdir -p "$(dirname "$dst")" && cp "$1" "$dst"
}
impress_sync_tree() {   # srcdir dstdir
    [ -d "$1" ] || return 0
    mkdir -p "$2"
    if command -v rsync >/dev/null 2>&1; then
        rsync -rlc --delete "$1/" "$2/"
    else
        rm -rf "$2" && cp -R "$1" "$2"
    fi
}

# Snapshot the previous framework so unchanged files can keep their timestamps.
PREV_SNAPSHOT="$(mktemp -d)"
if [ -d "$FRAMEWORK_DIR" ]; then
    cp -Rp "$FRAMEWORK_DIR/." "$PREV_SNAPSHOT/" 2>/dev/null || true
fi
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
cargo rustc --release --target $MACOS_TARGET --features ffi --lib --crate-type staticlib

if [ "$BUILD_X86" = "1" ]; then
    echo ""
    echo "Building for macOS (x86_64)..."
    cargo rustc --release --target $MACOS_X86_TARGET --features ffi --lib --crate-type staticlib
fi

if [ "$BUILD_IOS" = "1" ]; then
    echo ""
    echo "Building for iOS (arm64)..."
    cargo rustc --release --target $IOS_TARGET --features ffi --lib --crate-type staticlib

    echo ""
    echo "Building for iOS Simulator (arm64)..."
    cargo rustc --release --target $IOS_SIM_TARGET --features ffi --lib --crate-type staticlib

    echo ""
    echo "Building for iOS Simulator (x86_64)..."
    if [ "$BUILD_X86" = "1" ]; then
        cargo rustc --release --target $IOS_SIM_X86_TARGET --features ffi --lib --crate-type staticlib

    fi
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
    # IMPRESS_SKIP_X86=1 never built the x86_64 simulator slice, so there is
    # nothing to lipo: the simulator slice is arm64 alone.
    if [ "$BUILD_X86" = "1" ]; then
        lipo -create \
            "$BUILD_DIR/$IOS_SIM_TARGET/release/libimpress_helix.a" \
            "$BUILD_DIR/$IOS_SIM_X86_TARGET/release/libimpress_helix.a" \
            -output "$IOS_SIM_UNIVERSAL_DIR/libimpress_helix.a"
    else
        cp "$BUILD_DIR/$IOS_SIM_TARGET/release/libimpress_helix.a" \
            "$IOS_SIM_UNIVERSAL_DIR/libimpress_helix.a"
    fi
fi

# Generate Swift bindings
echo ""
echo "Generating Swift bindings..."
cargo run --release -p uniffi-bindgen -- generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/libimpress_helix.a" \
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
impress_sync_file "$FRAMEWORK_DIR/generated/impress_helix.swift" "$FRAMEWORK_DIR/impress_helix.swift"
echo "  Copied impress_helix.swift"

# Keep the package's committed bindings paired with the freshly built
# framework (imbib, imprint, implore and impel-tools all do the same). Until
# 2026-09-07 this script had no such step, so packages/ImpressHelixCore's
# committed copy had to be hand-copied after every build — and a hand step
# that is easy to forget is exactly how imbib's bindings went stale and broke
# the PublicationManagerCore build.
#
# Resolve via git, not $0: the script cds internally, so a relative $0 breaks
# when invoked from the repo root (as scripts/build-xcframeworks.sh does).
PKG_BINDINGS_DIR="$(git rev-parse --show-toplevel)/packages/ImpressHelixCore/Sources/ImpressHelixCore"
if [ -d "$PKG_BINDINGS_DIR" ]; then
    cp "$FRAMEWORK_DIR/generated/impress_helix.swift" "$PKG_BINDINGS_DIR/impress_helix.swift"
    echo "  Synced bindings to ImpressHelixCore package"
fi

echo ""
echo "=== Build complete! ==="
echo ""
echo "XCFramework: $FRAMEWORK_DIR/$XCFRAMEWORK_NAME.xcframework"
echo "Swift bindings: $FRAMEWORK_DIR/impress_helix.swift"
echo ""
echo "To use in your Swift package, add the XCFramework as a binary target"
echo "and copy impress_helix.swift to your sources."

# Restore timestamps on every file whose bytes did not change during this
# rebuild, so SwiftPM/clang see "unchanged" rather than "rewritten". Paired
# with the PREV_SNAPSHOT capture above.
if [ -n "${PREV_SNAPSHOT:-}" ] && [ -d "$PREV_SNAPSHOT" ]; then
    ( cd "$FRAMEWORK_DIR" && find . -type f -print | while IFS= read -r f; do
        if [ -f "$PREV_SNAPSHOT/$f" ] && cmp -s "$f" "$PREV_SNAPSHOT/$f"; then
            cp -p "$PREV_SNAPSHOT/$f" "$f"
        fi
      done )
    rm -rf "$PREV_SNAPSHOT"
fi
