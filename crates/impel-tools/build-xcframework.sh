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

echo ""
echo "Generating Swift bindings..."
cargo run -p impel-tools --bin uniffi-bindgen generate \
    --library "$BUILD_DIR/$MACOS_TARGET/release/libimpel_tools.dylib" \
    --language swift \
    --out-dir "$FRAMEWORK_DIR/generated"

# ---------------------------------------------------------------------------
# Symbol filtering
# ---------------------------------------------------------------------------
#
# This crate links imbib-service, which links imbib-core with its `native`
# feature — and `native` is what turns on imbib-core's UniFFI scaffolding. So
# `libimpel_tools.a` contains a *second* copy of every `_uniffi_imbib_core_*`
# and `_UNIFFI_META_IMBIB_CORE_*` symbol. impel links both this XCFramework and
# ImbibCore.xcframework (via the PublicationManagerCore chassis), and the app
# link then dies with ~1300 duplicate symbols.
#
# Cargo features are additive, so impel-tools cannot ask for imbib-core without
# `native`: imbib-service requires it, and unification would re-enable it
# anyway. The fix therefore belongs here, at packaging time. For each arch we
# `ld -r` the whole archive into one relocatable object with an
# `-exported_symbols_list` naming only impel-tools' own FFI surface. Everything
# else — the imbib-core scaffolding, the Rust runtime, the vendored C — is
# demoted to private-extern: still linked, still callable from inside this
# object, but no longer visible to (or collidable with) the app link.
#
# Note what is deliberately NOT exported: `_rust_eh_personality`, `___rust_alloc`
# and friends. Those are already duplicated across the suite's XCFrameworks and
# already tolerated; localising ours removes one copy from the pile rather than
# adding to it.
#
# The keep-list is derived by prefix, not hand-maintained, and then checked
# against the freshly generated header — if UniFFI ever emits an entry point
# under a prefix this pattern misses, the build fails here instead of at the
# app's link.
KEEP_SYMBOLS_RE='^_(uniffi|ffi)_impel_tools_|^_UNIFFI_META_IMPEL_TOOLS_|^_UNIFFI_META_NAMESPACE_IMPEL$'

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
GENERATED_HEADER="$FRAMEWORK_DIR/generated/impel_toolsFFI.h"
FILTER_DIR="$FRAMEWORK_DIR/filtered"
rm -rf "$FILTER_DIR"
mkdir -p "$FILTER_DIR"

# Every C entry point the generated header declares is, by definition, what the
# Swift bindings will ask the linker for. Anything here that the prefix pattern
# would drop is a packaging bug.
grep -oE '\b(uniffi|ffi)_[A-Za-z0-9_]+' "$GENERATED_HEADER" \
    | sed 's/^/_/' | sort -u > "$FILTER_DIR/header-symbols.txt"
if grep -vE "$KEEP_SYMBOLS_RE" "$FILTER_DIR/header-symbols.txt" > "$FILTER_DIR/header-unmatched.txt"; then
    echo "ERROR: the generated header declares entry points the keep-list pattern misses:" >&2
    sed 's/^/  /' "$FILTER_DIR/header-unmatched.txt" >&2
    echo "Widen KEEP_SYMBOLS_RE in $(basename "${BASH_SOURCE[0]}")." >&2
    exit 1
fi

# nm cannot read a Mach-O that still carries the __LLVM,__bitcode section
# rustc's prebuilt std objects bring along, and `ld -r` concatenates those
# sections into the merged object. Dropping the section makes the result
# inspectable (and ~10% smaller); bitcode has been dead on Apple platforms for
# years, so nothing needs it.
RUST_TOOL_BIN="$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | sed -n 's/^host: //p')/bin"
OBJCOPY=""
if [ -x "$RUST_TOOL_BIN/rust-objcopy" ]; then
    OBJCOPY="$RUST_TOOL_BIN/rust-objcopy"
elif command -v llvm-objcopy > /dev/null 2>&1; then
    OBJCOPY="$(command -v llvm-objcopy)"
fi

# filter_archive <arch> <input .a> <output .a>
filter_archive() {
    local arch="$1"
    local in_lib="$2"
    local out_lib="$3"
    local work="$FILTER_DIR/$arch"

    mkdir -p "$work"
    nm -gjU "$in_lib" 2>/dev/null | grep -E "$KEEP_SYMBOLS_RE" | sort -u > "$work/exported.txt"

    local missing
    missing="$(comm -23 "$FILTER_DIR/header-symbols.txt" "$work/exported.txt")"
    if [ -n "$missing" ]; then
        echo "ERROR: $arch archive is missing entry points the header declares:" >&2
        echo "$missing" | sed 's/^/  /' >&2
        exit 1
    fi
    echo "  $arch: keeping $(wc -l < "$work/exported.txt" | tr -d ' ') exported symbols"

    ld -r -arch "$arch" \
        -platform_version macos "$MACOSX_DEPLOYMENT_TARGET" "$SDK_VERSION" \
        -exported_symbols_list "$work/exported.txt" \
        -all_load "$in_lib" \
        -o "$work/impel_tools.o"

    if [ -n "$OBJCOPY" ]; then
        "$OBJCOPY" --remove-section=__LLVM,__bitcode \
            "$work/impel_tools.o" "$work/impel_tools.stripped.o"
        mv "$work/impel_tools.stripped.o" "$work/impel_tools.o"
    else
        echo "  WARNING: no llvm-objcopy found; leaving __LLVM,__bitcode in place" >&2
    fi

    rm -f "$out_lib"
    ar crs "$out_lib" "$work/impel_tools.o"
}

echo ""
echo "Localizing non-impel_tools symbols (imbib-core's UniFFI scaffolding rides along)..."
filter_archive arm64 \
    "$BUILD_DIR/$MACOS_TARGET/release/libimpel_tools.a" \
    "$FILTER_DIR/libimpel_tools-arm64.a"
filter_archive x86_64 \
    "$BUILD_DIR/$MACOS_X86_TARGET/release/libimpel_tools.a" \
    "$FILTER_DIR/libimpel_tools-x86_64.a"

echo ""
echo "Creating universal macOS binary..."
lipo -create \
    "$FILTER_DIR/libimpel_tools-arm64.a" \
    "$FILTER_DIR/libimpel_tools-x86_64.a" \
    -output "$MACOS_UNIVERSAL_DIR/libimpel_tools.a"

# The check that matters: a sibling crate's UniFFI symbols must not be visible
# here, or impel's link fails on duplicates again.
for arch in arm64 x86_64; do
    if ! nm -gjU --arch "$arch" "$MACOS_UNIVERSAL_DIR/libimpel_tools.a" > "$FILTER_DIR/after-$arch.txt" 2>/dev/null; then
        echo "  WARNING: could not read $arch exports back; skipping the leak check" >&2
        continue
    fi
    leaked="$(grep -cE '^_(uniffi|ffi)_imbib_core_|^_UNIFFI_META_IMBIB' "$FILTER_DIR/after-$arch.txt" || true)"
    kept="$(grep -cE "$KEEP_SYMBOLS_RE" "$FILTER_DIR/after-$arch.txt" || true)"
    echo "  $arch: $kept impel_tools symbols exported, $leaked imbib-core symbols leaked"
    if [ "$leaked" -ne 0 ] || [ "$kept" -eq 0 ]; then
        echo "ERROR: $arch export surface is wrong (see $FILTER_DIR/after-$arch.txt)" >&2
        exit 1
    fi
done

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
