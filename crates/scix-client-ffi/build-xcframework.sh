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

# Incremental release codegen for the framework loop only (was
# `[profile.release] incremental = true` in the root manifest, where it also
# applied to the signed binaries in target/release).
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-1}"

# Deployment targets are pinned in the workspace .cargo/config.toml (force=true).

echo "Building ScixClientCore XCFramework"

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
XCFRAMEWORK_NAME="ScixClientCore"
LIB_NAME="scix_client_ffi"

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

echo "=== Installing Rust targets ==="
rustup target add $MACOS_TARGET $MACOS_X86_TARGET 2>/dev/null || true
if [ "$BUILD_IOS" = "1" ]; then
    rustup target add $IOS_TARGET $IOS_SIM_TARGET $IOS_SIM_X86_TARGET 2>/dev/null || true
fi

echo "=== Building (native feature) ==="
cargo rustc --release --target $MACOS_TARGET --features native --lib --crate-type staticlib
if [ "$BUILD_X86" = "1" ]; then
    cargo rustc --release --target $MACOS_X86_TARGET --features native --lib --crate-type staticlib
fi
if [ "$BUILD_IOS" = "1" ]; then
    cargo rustc --release --target $IOS_TARGET --features native --lib --crate-type staticlib
    cargo rustc --release --target $IOS_SIM_TARGET --features native --lib --crate-type staticlib
    if [ "$BUILD_X86" = "1" ]; then
        cargo rustc --release --target $IOS_SIM_X86_TARGET --features native --lib --crate-type staticlib

    fi
fi

echo "=== Creating framework structure ==="
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR"

MACOS_UNIVERSAL_DIR="$FRAMEWORK_DIR/macos-universal"
IOS_SIM_UNIVERSAL_DIR="$FRAMEWORK_DIR/ios-sim-universal"
mkdir -p "$MACOS_UNIVERSAL_DIR" "$IOS_SIM_UNIVERSAL_DIR"

if [ "$BUILD_X86" = "1" ]; then
    echo "Creating universal macOS binary..."
    lipo -create \
        "$BUILD_DIR/$MACOS_TARGET/release/lib${LIB_NAME}.a" \
        "$BUILD_DIR/$MACOS_X86_TARGET/release/lib${LIB_NAME}.a" \
        -output "$MACOS_UNIVERSAL_DIR/lib${LIB_NAME}.a"
else
    echo "Creating arm64-only macOS binary (IMPRESS_SKIP_X86=1)..."
    cp "$BUILD_DIR/$MACOS_TARGET/release/lib${LIB_NAME}.a" \
        "$MACOS_UNIVERSAL_DIR/lib${LIB_NAME}.a"
fi

if [ "$BUILD_IOS" = "1" ]; then
    echo "Creating universal iOS Simulator binary..."
    # IMPRESS_SKIP_X86=1 never built the x86_64 simulator slice, so there is
    # nothing to lipo: the simulator slice is arm64 alone.
    if [ "$BUILD_X86" = "1" ]; then
        lipo -create \
            "$BUILD_DIR/$IOS_SIM_TARGET/release/lib${LIB_NAME}.a" \
            "$BUILD_DIR/$IOS_SIM_X86_TARGET/release/lib${LIB_NAME}.a" \
            -output "$IOS_SIM_UNIVERSAL_DIR/lib${LIB_NAME}.a"
    else
        cp "$BUILD_DIR/$IOS_SIM_TARGET/release/lib${LIB_NAME}.a" \
            "$IOS_SIM_UNIVERSAL_DIR/lib${LIB_NAME}.a"
    fi
fi

echo "=== Generating Swift bindings ==="
BINDINGS_DIR="$FRAMEWORK_DIR/bindings"
mkdir -p "$BINDINGS_DIR"

# (the macOS slice with these exact features was already built above; this
# second identical invocation was a no-op that still paid a full freshness
# walk of the ~1,000-crate graph)

cargo run --release -p uniffi-bindgen -- generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/lib${LIB_NAME}.a" \
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

echo "=== Copying XCFramework and Swift bindings to ImpressScixCore ==="
IMPRESSSCIXCORE_FRAMEWORKS="$WORKSPACE_ROOT/packages/ImpressScixCore/frameworks"
IMPRESSSCIXCORE_SOURCES="$WORKSPACE_ROOT/packages/ImpressScixCore/Sources/ImpressScixCore"

mkdir -p "$IMPRESSSCIXCORE_FRAMEWORKS" "$IMPRESSSCIXCORE_SOURCES"

# Copy XCFramework
impress_sync_tree "$FRAMEWORK_DIR/${XCFRAMEWORK_NAME}.xcframework" "$IMPRESSSCIXCORE_FRAMEWORKS/${XCFRAMEWORK_NAME}.xcframework"
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
