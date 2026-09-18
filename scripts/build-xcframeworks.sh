#!/bin/bash
# Unified build script for all Rust XCFrameworks
# Usage:
#   ./scripts/build-xcframeworks.sh              # Build all crates
#   ./scripts/build-xcframeworks.sh imbib-core   # Build specific crate(s)
#   ./scripts/build-xcframeworks.sh --verbose    # Build with verbose output
#   ./scripts/build-xcframeworks.sh --parallel   # Build crates in parallel
#   ./scripts/build-xcframeworks.sh --fast       # Local macOS dev loop:
#                                                #   IMPRESS_SKIP_X86=1 + IMPRESS_SKIP_IOS=1
#   ./scripts/build-xcframeworks.sh --macos-only # IMPRESS_SKIP_IOS=1 only
#
# The skip envs also work directly with any crates/*/build-xcframework.sh;
# the flags just export them for every crate built here. CI and release set
# neither and stay universal + all-slices.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default crates to build (every crate with a build-xcframework.sh)
# impart-core is deliberately NOT here: apps/impart/ImpartRustCore is a
# placeholder target with no binaryTarget, nothing references ImpartCore
# .xcframework, and impart-tests.yml already skips it for the same reason.
# Building it by default cost five release cross-compiles of a 211-crate
# graph plus a binding pass, for an artifact no target opens. Name it
# explicitly (`build-xcframeworks.sh impart-core`) once it has a consumer.
ALL_CRATES=(
    "imbib-core"
    "imprint-core"
    "implore-core"
    "impress-store-ffi"
    "impress-helix"
    "scix-client-ffi"
    "impel-tools"
)

# Parse arguments
VERBOSE=false
PARALLEL=false
CRATES_TO_BUILD=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --parallel|-p)
            PARALLEL=true
            shift
            ;;
        --fast|-f)
            # Local macOS dev loop: arm64-only, no iOS slices. Roughly a
            # 5x cut in Rust compile per crate on Apple Silicon.
            export IMPRESS_SKIP_X86=1
            export IMPRESS_SKIP_IOS=1
            shift
            ;;
        --macos-only)
            export IMPRESS_SKIP_IOS=1
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options] [crate-names...]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v    Show detailed build output"
            echo "  --parallel, -p   Build crates in parallel (faster but uses more resources)"
            echo "  --fast, -f       Local macOS dev loop: skip x86_64 and iOS slices"
            echo "                   (IMPRESS_SKIP_X86=1 IMPRESS_SKIP_IOS=1)"
            echo "  --macos-only     Skip only the iOS slices (IMPRESS_SKIP_IOS=1)"
            echo "  --help, -h       Show this help message"
            echo ""
            echo "Available crates:"
            for crate in "${ALL_CRATES[@]}"; do
                echo "  - $crate"
            done
            echo ""
            echo "Examples:"
            echo "  $0                          # Build all crates"
            echo "  $0 imbib-core              # Build only imbib-core"
            echo "  $0 --parallel              # Build all crates in parallel"
            echo "  $0 -v imbib-core imprint-core  # Build two crates with verbose output"
            exit 0
            ;;
        *)
            CRATES_TO_BUILD+=("$1")
            shift
            ;;
    esac
done

# If no crates specified, build all
if [ ${#CRATES_TO_BUILD[@]} -eq 0 ]; then
    CRATES_TO_BUILD=("${ALL_CRATES[@]}")
fi

# Validate crate names
for crate in "${CRATES_TO_BUILD[@]}"; do
    if [[ ! -d "$WORKSPACE_ROOT/crates/$crate" ]]; then
        echo "Error: Crate '$crate' not found in crates/"
        exit 1
    fi
    if [[ ! -f "$WORKSPACE_ROOT/crates/$crate/build-xcframework.sh" ]]; then
        echo "Error: No build-xcframework.sh found for '$crate'"
        exit 1
    fi
done

echo "=== Building XCFrameworks ==="
echo "Crates: ${CRATES_TO_BUILD[*]}"
echo "Parallel: $PARALLEL"
echo "Verbose: $VERBOSE"
echo "Skip x86_64: ${IMPRESS_SKIP_X86:-0}  Skip iOS: ${IMPRESS_SKIP_IOS:-0}"
echo ""

# Track failures
BUILD_FAILED=false

build_crate() {
    local crate=$1
    local build_script="$WORKSPACE_ROOT/crates/$crate/build-xcframework.sh"

    echo "Building $crate..."

    # NB: this runs inside a subshell under --parallel, so it must report
    # failure through its EXIT STATUS. Setting BUILD_FAILED here is invisible
    # to the parent, and ending the function on an `echo` made every parallel
    # build exit 0 — a failed crate printed "✗" and the run still reported
    # "All builds completed successfully" and exited 0.
    local log
    log="$(mktemp -t "xcfw-$crate")"
    if [ "$VERBOSE" = true ]; then
        if bash "$build_script" 2>&1 | tee "$log"; then
            echo "✓ $crate built successfully"; rm -f "$log"; return 0
        fi
    else
        # Not silenced: cargo's "Blocking waiting for file lock on build
        # directory" lines were being discarded, which is why --parallel looked
        # like it was overlapping when it was in fact serialising.
        if bash "$build_script" > "$log" 2>&1; then
            echo "✓ $crate built successfully"; rm -f "$log"; return 0
        fi
    fi
    echo "✗ $crate build FAILED — last 20 lines of $log:"
    tail -20 "$log" | sed 's/^/    /'
    return 1
}

if [ "$PARALLEL" = true ]; then
    # Parallel builds using background processes
    # One cargo build-directory lock serialises the cargo phases of these
    # scripts no matter how many run at once; only the packaging steps (lipo,
    # create-xcframework, copies) actually overlap.
    pids=()
    for crate in "${CRATES_TO_BUILD[@]}"; do
        ( build_crate "$crate" ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || BUILD_FAILED=true
    done
else
    # Sequential builds
    for crate in "${CRATES_TO_BUILD[@]}"; do
        build_crate "$crate" || BUILD_FAILED=true
    done
fi

echo ""
echo "=== Build Summary ==="

for crate in "${CRATES_TO_BUILD[@]}"; do
    framework_dir="$WORKSPACE_ROOT/crates/$crate/frameworks"
    if [ -d "$framework_dir" ]; then
        # Find the xcframework
        xcframework=$(find "$framework_dir" -maxdepth 1 -name "*.xcframework" -type d | head -1)
        swift_binding=$(find "$framework_dir" -maxdepth 1 -name "*.swift" -type f | head -1)

        if [ -n "$xcframework" ]; then
            echo "✓ $crate"
            echo "  XCFramework: $xcframework"
            if [ -n "$swift_binding" ]; then
                echo "  Swift binding: $swift_binding"
            fi
        else
            echo "✗ $crate (no xcframework found)"
        fi
    else
        echo "✗ $crate (no frameworks directory)"
    fi
done

if [ "$BUILD_FAILED" = true ]; then
    echo ""
    echo "Some builds failed. Run with --verbose for details."
    exit 1
fi

echo ""
echo "All builds completed successfully!"
