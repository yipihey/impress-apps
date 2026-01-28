#!/bin/bash
# Unified build script for all Rust XCFrameworks
# Usage:
#   ./scripts/build-xcframeworks.sh              # Build all crates
#   ./scripts/build-xcframeworks.sh imbib-core   # Build specific crate(s)
#   ./scripts/build-xcframeworks.sh --verbose    # Build with verbose output
#   ./scripts/build-xcframeworks.sh --parallel   # Build crates in parallel

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default crates to build (all UniFFI-enabled crates)
ALL_CRATES=(
    "imbib-core"
    "imprint-core"
    "implore-core"
    "impress-llm"
    "impress-helix"
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
        --help|-h)
            echo "Usage: $0 [options] [crate-names...]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v    Show detailed build output"
            echo "  --parallel, -p   Build crates in parallel (faster but uses more resources)"
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
echo ""

# Track failures
BUILD_FAILED=false

build_crate() {
    local crate=$1
    local build_script="$WORKSPACE_ROOT/crates/$crate/build-xcframework.sh"

    echo "Building $crate..."

    if [ "$VERBOSE" = true ]; then
        if bash "$build_script"; then
            echo "✓ $crate built successfully"
        else
            BUILD_FAILED=true
            echo "✗ $crate build failed"
        fi
    else
        if bash "$build_script" > /dev/null 2>&1; then
            echo "✓ $crate built successfully"
        else
            BUILD_FAILED=true
            echo "✗ $crate build failed (run with --verbose for details)"
        fi
    fi
}

if [ "$PARALLEL" = true ]; then
    # Parallel builds using background processes
    pids=()
    for crate in "${CRATES_TO_BUILD[@]}"; do
        (
            build_crate "$crate"
        ) &
        pids+=($!)
    done

    # Wait for all builds to complete
    for pid in "${pids[@]}"; do
        wait "$pid" || BUILD_FAILED=true
    done
else
    # Sequential builds
    for crate in "${CRATES_TO_BUILD[@]}"; do
        build_crate "$crate"
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
