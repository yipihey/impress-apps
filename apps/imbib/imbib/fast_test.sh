#!/bin/bash
# Fast UI Test Runner - Runs a quick subset of tests for sanity checking

set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Parse arguments
TEST_SUITE="${1:-basic}"
PARALLEL="${2:-NO}"

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║                 imbib Fast UI Test Runner                     ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Help
if [ "$TEST_SUITE" = "-h" ] || [ "$TEST_SUITE" = "--help" ]; then
    echo "Usage: $0 [suite] [parallel]"
    echo ""
    echo "Suites:"
    echo "  basic      - Run basic tests only (default, ~2 min)"
    echo "  sidebar    - Sidebar tests only"
    echo "  search     - Global search tests only"
    echo "  keyboard   - Keyboard shortcut tests only"
    echo "  workflow   - All workflow tests (~5 min)"
    echo "  component  - All component tests (~5 min)"
    echo "  all        - All tests (~15 min)"
    echo ""
    echo "Options:"
    echo "  parallel   - YES or NO (default: NO)"
    echo ""
    echo "Examples:"
    echo "  $0                    # Run basic tests"
    echo "  $0 sidebar            # Run sidebar tests only"
    echo "  $0 all YES            # Run all tests in parallel"
    exit 0
fi

# Build test filter based on suite
case "$TEST_SUITE" in
    basic)
        echo -e "${YELLOW}Running basic tests (quick sanity check)${NC}"
        TESTS="-only-testing:imbibUITests/imbibUITests"
        ;;
    sidebar)
        echo -e "${YELLOW}Running sidebar tests${NC}"
        TESTS="-only-testing:imbibUITests/SidebarTests"
        ;;
    search)
        echo -e "${YELLOW}Running global search tests${NC}"
        TESTS="-only-testing:imbibUITests/GlobalSearchTests"
        ;;
    keyboard)
        echo -e "${YELLOW}Running keyboard shortcut tests${NC}"
        TESTS="-only-testing:imbibUITests/KeyboardShortcutsTests"
        ;;
    workflow)
        echo -e "${YELLOW}Running all workflow tests${NC}"
        TESTS="-only-testing:imbibUITests/ImportWorkflowTests -only-testing:imbibUITests/TriageWorkflowTests -only-testing:imbibUITests/SearchWorkflowTests -only-testing:imbibUITests/OrganizationWorkflowTests -only-testing:imbibUITests/ExportWorkflowTests"
        ;;
    component)
        echo -e "${YELLOW}Running all component tests${NC}"
        TESTS="-only-testing:imbibUITests/SidebarTests -only-testing:imbibUITests/PublicationListTests -only-testing:imbibUITests/DetailPanelTests -only-testing:imbibUITests/ToolbarTests -only-testing:imbibUITests/GlobalSearchTests"
        ;;
    all)
        echo -e "${YELLOW}Running all UI tests (this will take a while)${NC}"
        TESTS="-only-testing:imbibUITests"
        ;;
    *)
        echo -e "${RED}Unknown suite: $TEST_SUITE${NC}"
        echo "Run '$0 --help' for usage"
        exit 1
        ;;
esac

echo ""
echo -e "${DIM}Started: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo ""

# Temp files
RESULTS_FILE="/tmp/imbib_fast_results.txt"
> "$RESULTS_FILE"

START_TIME=$(date +%s)

# Run tests
xcodebuild test \
    -scheme imbib \
    -destination 'platform=macOS' \
    $TESTS \
    -parallel-testing-enabled "$PARALLEL" \
    2>&1 | while IFS= read -r line; do

    # Build progress
    if [[ "$line" == *"Compiling"* ]]; then
        file=$(echo "$line" | grep -oE '[^ ]+\.swift' | head -1)
        if [[ -n "$file" ]]; then
            echo -ne "\r${DIM}Building: $file${NC}                    \r"
        fi
    fi

    if [[ "$line" == *"Build Succeeded"* ]]; then
        echo -e "\r${GREEN}✓ Build succeeded${NC}                              "
        echo ""
    fi

    # Test suite
    if [[ "$line" =~ Test\ Suite\ \'([^\']+)\'\ started ]]; then
        suite="${BASH_REMATCH[1]}"
        if [[ "$suite" != "All tests" && "$suite" != "imbibUITests.xctest" && "$suite" != "Selected tests" ]]; then
            echo -e "${BOLD}${CYAN}$suite${NC}"
        fi
    fi

    # Test case start
    if [[ "$line" =~ Test\ Case\ \'-\[([^\ ]+)\ ([^\]]+)\]\'\ started ]]; then
        test="${BASH_REMATCH[2]}"
        echo -ne "  ${DIM}▶ $test${NC}\r"
    fi

    # Test passed
    if [[ "$line" =~ Test\ Case\ \'-\[([^\ ]+)\ ([^\]]+)\]\'\ passed\ \(([0-9.]+)\ seconds\) ]]; then
        suite="${BASH_REMATCH[1]}"
        test="${BASH_REMATCH[2]}"
        duration="${BASH_REMATCH[3]}"
        echo -e "  ${GREEN}✓${NC} $test ${DIM}(${duration}s)${NC}"
        echo "PASS|$suite|$test" >> "$RESULTS_FILE"
    fi

    # Test failed
    if [[ "$line" =~ Test\ Case\ \'-\[([^\ ]+)\ ([^\]]+)\]\'\ failed\ \(([0-9.]+)\ seconds\) ]]; then
        suite="${BASH_REMATCH[1]}"
        test="${BASH_REMATCH[2]}"
        duration="${BASH_REMATCH[3]}"
        echo -e "  ${RED}✗${NC} $test ${DIM}(${duration}s)${NC}"
        echo "FAIL|$suite|$test" >> "$RESULTS_FILE"
    fi

    # Error
    if [[ "$line" =~ error:\ (.+) ]]; then
        error="${BASH_REMATCH[1]}"
        if [[ "$error" != *"Build input"* ]]; then
            echo -e "    ${RED}└─ ${error:0:60}${NC}"
        fi
    fi
done

EXIT_CODE=$?

# Summary
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

PASSED=$(grep -c "^PASS|" "$RESULTS_FILE" 2>/dev/null || echo "0")
FAILED=$(grep -c "^FAIL|" "$RESULTS_FILE" 2>/dev/null || echo "0")
TOTAL=$((PASSED + FAILED))

echo ""
echo -e "${BOLD}────────────────────────────────────────────────────────────────${NC}"
echo -e "${BOLD}Results:${NC} ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC} (${DURATION}s)"

if [ $FAILED -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed:${NC}"
    grep "^FAIL|" "$RESULTS_FILE" | while IFS='|' read -r status suite test; do
        echo -e "  ${RED}✗${NC} $test"
    done
fi

echo -e "${BOLD}────────────────────────────────────────────────────────────────${NC}"

if [ $FAILED -eq 0 ] && [ $PASSED -gt 0 ]; then
    echo -e "${GREEN}${BOLD}✓ All tests passed!${NC}"
elif [ $FAILED -gt 0 ]; then
    echo -e "${RED}${BOLD}✗ $FAILED test(s) failed${NC}"
fi

echo ""
exit $EXIT_CODE
