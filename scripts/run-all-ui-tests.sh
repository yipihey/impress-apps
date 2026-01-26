#!/bin/bash
#
# run-all-ui-tests.sh
#
# Runs UI tests for all impress apps (imbib, imprint, implore).
# Can be run individually with app name as argument, or all together.
#
# Usage:
#   ./scripts/run-all-ui-tests.sh          # Run all UI tests
#   ./scripts/run-all-ui-tests.sh imbib    # Run only imbib UI tests
#   ./scripts/run-all-ui-tests.sh imprint  # Run only imprint UI tests
#   ./scripts/run-all-ui-tests.sh implore  # Run only implore UI tests
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Test results
IMBIB_RESULT=""
IMPRINT_RESULT=""
IMPLORE_RESULT=""

# Print colored message
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}! $1${NC}"
}

# Run UI tests for imbib
run_imbib_tests() {
    print_header "Running imbib UI tests..."

    cd "$PROJECT_ROOT/apps/imbib"

    # Check if project exists
    if [ ! -f "imbib.xcodeproj/project.pbxproj" ]; then
        print_warning "imbib.xcodeproj not found. Run 'xcodegen generate' first."
        return 1
    fi

    if xcodebuild test \
        -project imbib.xcodeproj \
        -scheme imbib \
        -destination 'platform=macOS' \
        -only-testing:imbibUITests \
        -quiet 2>&1; then
        IMBIB_RESULT="PASSED"
        print_success "imbib UI tests passed!"
        return 0
    else
        IMBIB_RESULT="FAILED"
        print_error "imbib UI tests failed!"
        return 1
    fi
}

# Run UI tests for imprint
run_imprint_tests() {
    print_header "Running imprint UI tests..."

    cd "$PROJECT_ROOT/apps/imprint"

    # Check if project exists
    if [ ! -f "imprint.xcodeproj/project.pbxproj" ]; then
        print_warning "imprint.xcodeproj not found. Run 'xcodegen generate' first."
        return 1
    fi

    if xcodebuild test \
        -project imprint.xcodeproj \
        -scheme imprint \
        -destination 'platform=macOS' \
        -only-testing:imprintUITests \
        -quiet 2>&1; then
        IMPRINT_RESULT="PASSED"
        print_success "imprint UI tests passed!"
        return 0
    else
        IMPRINT_RESULT="FAILED"
        print_error "imprint UI tests failed!"
        return 1
    fi
}

# Run UI tests for implore
run_implore_tests() {
    print_header "Running implore UI tests..."

    cd "$PROJECT_ROOT/apps/implore"

    # Check if project exists
    if [ ! -f "implore.xcodeproj/project.pbxproj" ]; then
        print_warning "implore.xcodeproj not found. Run 'xcodegen generate' first."
        return 1
    fi

    if xcodebuild test \
        -project implore.xcodeproj \
        -scheme implore \
        -destination 'platform=macOS' \
        -only-testing:imploreUITests \
        -quiet 2>&1; then
        IMPLORE_RESULT="PASSED"
        print_success "implore UI tests passed!"
        return 0
    else
        IMPLORE_RESULT="FAILED"
        print_error "implore UI tests failed!"
        return 1
    fi
}

# Print summary
print_summary() {
    print_header "Test Summary"

    local all_passed=true

    if [ -n "$IMBIB_RESULT" ]; then
        if [ "$IMBIB_RESULT" = "PASSED" ]; then
            print_success "imbib:   $IMBIB_RESULT"
        else
            print_error "imbib:   $IMBIB_RESULT"
            all_passed=false
        fi
    fi

    if [ -n "$IMPRINT_RESULT" ]; then
        if [ "$IMPRINT_RESULT" = "PASSED" ]; then
            print_success "imprint: $IMPRINT_RESULT"
        else
            print_error "imprint: $IMPRINT_RESULT"
            all_passed=false
        fi
    fi

    if [ -n "$IMPLORE_RESULT" ]; then
        if [ "$IMPLORE_RESULT" = "PASSED" ]; then
            print_success "implore: $IMPLORE_RESULT"
        else
            print_error "implore: $IMPLORE_RESULT"
            all_passed=false
        fi
    fi

    echo ""

    if $all_passed; then
        print_success "All UI tests passed!"
        return 0
    else
        print_error "Some UI tests failed!"
        return 1
    fi
}

# Main execution
main() {
    print_header "impress-apps UI Test Suite"

    local app="${1:-all}"
    local exit_code=0

    case "$app" in
        imbib)
            run_imbib_tests || exit_code=1
            ;;
        imprint)
            run_imprint_tests || exit_code=1
            ;;
        implore)
            run_implore_tests || exit_code=1
            ;;
        all)
            # Run all tests, continuing even if one fails
            run_imbib_tests || true
            run_imprint_tests || true
            run_implore_tests || true
            ;;
        *)
            echo "Usage: $0 [imbib|imprint|implore|all]"
            exit 1
            ;;
    esac

    print_summary
    exit $?
}

# Run main with all arguments
main "$@"
