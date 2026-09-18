#!/bin/bash
#
# Pre-commit hook to verify ImbibCore.xcframework has all required slices
#
# Install: ln -sf ../../scripts/pre-commit-xcframework-check.sh .git/hooks/pre-commit
# Or add to existing pre-commit: source scripts/pre-commit-xcframework-check.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
XCFRAMEWORK_DIR="$PROJECT_DIR/imbib-core/frameworks/ImbibCore.xcframework"

# Required slices for full platform support
# A simulator slice may be arm64-only now: the gate builds with ARCHS=arm64, and
# IMPRESS_SKIP_X86=1 skips x86_64 on macOS and the simulator alike. Accept either
# spelling per platform rather than demanding the universal one.
REQUIRED_SLICES=(
    "ios-arm64"                                          # iOS device
    "ios-arm64-simulator|ios-arm64_x86_64-simulator"     # iOS Simulator
    "macos-arm64|macos-arm64_x86_64"                     # macOS
)

# Check if xcframework directory is being modified
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")

if ! echo "$STAGED_FILES" | grep -q "imbib-core/frameworks/ImbibCore.xcframework"; then
    # XCFramework not being modified, skip check
    exit 0
fi

echo "Checking ImbibCore.xcframework slices..."

# Verify all required slices exist
MISSING_SLICES=()
for slice in "${REQUIRED_SLICES[@]}"; do
    # Each entry may list alternatives separated by "|": a simulator or macOS
    # slice is arm64-only when built with IMPRESS_SKIP_X86=1, and universal in
    # CI/release builds. Either satisfies the platform.
    found=0
    IFS='|' read -r -a alts <<< "$slice"
    for alt in "${alts[@]}"; do
        if [ -d "$XCFRAMEWORK_DIR/$alt" ]; then found=1; break; fi
    done
    if [ "$found" -eq 0 ]; then
        MISSING_SLICES+=("${alts[0]}")
    fi
done

if [ ${#MISSING_SLICES[@]} -gt 0 ]; then
    echo ""
    echo "ERROR: ImbibCore.xcframework is missing required slices!"
    echo ""
    echo "Missing slices:"
    for slice in "${MISSING_SLICES[@]}"; do
        echo "  - $slice"
    done
    echo ""
    echo "This can happen if you ran quick-release.sh which only builds arm64."
    echo ""
    echo "To fix, rebuild the full xcframework:"
    echo "  cd imbib-core && ./build-xcframework.sh"
    echo ""
    echo "Then stage the changes:"
    echo "  git add imbib-core/frameworks/"
    echo ""
    exit 1
fi

# Verify Info.plist declares all slices
INFO_PLIST="$XCFRAMEWORK_DIR/Info.plist"
if [ -f "$INFO_PLIST" ]; then
    for slice in "${REQUIRED_SLICES[@]}"; do
        if ! grep -q "$slice" "$INFO_PLIST"; then
            echo ""
            echo "ERROR: Info.plist doesn't declare slice: $slice"
            echo "The xcframework may be corrupted. Rebuild with:"
            echo "  cd imbib-core && ./build-xcframework.sh"
            echo ""
            exit 1
        fi
    done
fi

echo "✓ All required xcframework slices present"
exit 0
