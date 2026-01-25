#!/bin/bash
# imbib UI Test Runner with Live Progress and Detailed Summary

set -o pipefail

# Colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Temp files for tracking
LOG_FILE="/tmp/imbib_ui_tests.log"
RESULTS_FILE="/tmp/imbib_ui_results.txt"
ERRORS_FILE="/tmp/imbib_ui_errors.txt"

# Clear temp files
> "$LOG_FILE"
> "$RESULTS_FILE"
> "$ERRORS_FILE"

# Start time
START_TIME=$(date +%s)

# Print header
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║                    imbib UI Test Runner                       ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${DIM}Started: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo ""

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_SUITE=""
CURRENT_TEST=""
BUILD_DONE=0

# Run tests and process output
xcodebuild test \
    -scheme imbib \
    -destination 'platform=macOS' \
    -only-testing:imbibUITests \
    -parallel-testing-enabled NO \
    2>&1 | while IFS= read -r line; do

    # Log everything
    echo "$line" >> "$LOG_FILE"

    # Build progress indicators
    if [[ "$line" == *"Compiling"* && $BUILD_DONE -eq 0 ]]; then
        file=$(echo "$line" | grep -oE '[^ ]+\.swift' | head -1)
        if [[ -n "$file" ]]; then
            echo -ne "\r${DIM}Compiling: $file                              ${NC}\r"
        fi
    fi

    if [[ "$line" == *"Linking"* && $BUILD_DONE -eq 0 ]]; then
        echo -ne "\r${DIM}Linking...                                        ${NC}\r"
    fi

    if [[ "$line" == *"Build Succeeded"* ]]; then
        BUILD_DONE=1
        echo -e "\r${GREEN}✓ Build succeeded${NC}                                    "
        echo ""
        echo -e "${YELLOW}Running UI tests...${NC}"
    fi

    # Test suite start
    if [[ "$line" =~ Test\ Suite\ \'([^\']+)\'\ started ]]; then
        suite="${BASH_REMATCH[1]}"
        if [[ "$suite" != "All tests" && "$suite" != "imbibUITests.xctest" && "$suite" != "Selected tests" ]]; then
            echo ""
            echo -e "${BOLD}${CYAN}┌─ $suite${NC}"
            CURRENT_SUITE="$suite"
        fi
    fi

    # Test case start
    if [[ "$line" =~ Test\ Case\ \'-\[([^\ ]+)\ ([^\]]+)\]\'\ started ]]; then
        suite="${BASH_REMATCH[1]}"
        test="${BASH_REMATCH[2]}"
        CURRENT_TEST="$test"
        echo -ne "${DIM}│  ▶ $test...${NC}\r"
    fi

    # Test passed
    if [[ "$line" =~ Test\ Case\ \'-\[([^\ ]+)\ ([^\]]+)\]\'\ passed\ \(([0-9.]+)\ seconds\) ]]; then
        suite="${BASH_REMATCH[1]}"
        test="${BASH_REMATCH[2]}"
        duration="${BASH_REMATCH[3]}"
        echo -e "\033[2K${GREEN}│  ✓${NC} $test ${DIM}(${duration}s)${NC}"
        echo "PASS|$suite|$test|$duration" >> "$RESULTS_FILE"
        ((PASS_COUNT++))
    fi

    # Test failed
    if [[ "$line" =~ Test\ Case\ \'-\[([^\ ]+)\ ([^\]]+)\]\'\ failed\ \(([0-9.]+)\ seconds\) ]]; then
        suite="${BASH_REMATCH[1]}"
        test="${BASH_REMATCH[2]}"
        duration="${BASH_REMATCH[3]}"
        echo -e "\033[2K${RED}│  ✗${NC} $test ${DIM}(${duration}s)${NC}"
        echo "FAIL|$suite|$test|$duration" >> "$RESULTS_FILE"
        ((FAIL_COUNT++))
    fi

    # Capture error messages
    if [[ "$line" =~ error:\ (.+) ]]; then
        error_msg="${BASH_REMATCH[1]}"
        # Filter out noisy build errors
        if [[ "$error_msg" != *"Build input"* && "$error_msg" != *"module"* ]]; then
            echo "$CURRENT_SUITE.$CURRENT_TEST|$error_msg" >> "$ERRORS_FILE"
            # Show short error inline
            short_error=$(echo "$error_msg" | head -c 70)
            echo -e "${DIM}│     └─ ${RED}$short_error${NC}"
        fi
    fi

    # Suite completion
    if [[ "$line" =~ Executed\ ([0-9]+)\ tests?,\ with\ ([0-9]+)\ failures? ]]; then
        total="${BASH_REMATCH[1]}"
        failures="${BASH_REMATCH[2]}"
        passed=$((total - failures))
        if [[ "$failures" == "0" ]]; then
            echo -e "${GREEN}└─ $passed/$total passed${NC}"
        else
            echo -e "${RED}└─ $passed/$total passed ($failures failed)${NC}"
        fi
    fi

    # Build failed
    if [[ "$line" == *"BUILD FAILED"* ]]; then
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                       BUILD FAILED                            ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi

done

# Capture exit code
EXIT_CODE=$?

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

# Count results from file (subprocess variables don't persist)
TOTAL_PASS=$(grep -c "^PASS|" "$RESULTS_FILE" 2>/dev/null || echo "0")
TOTAL_FAIL=$(grep -c "^FAIL|" "$RESULTS_FILE" 2>/dev/null || echo "0")
TOTAL_TESTS=$((TOTAL_PASS + TOTAL_FAIL))

# Calculate pass rate
if [ $TOTAL_TESTS -gt 0 ]; then
    PASS_RATE=$((TOTAL_PASS * 100 / TOTAL_TESTS))
else
    PASS_RATE=0
fi

# Print summary
echo ""
echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}                         TEST SUMMARY                          ${NC}"
echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Overall Results:${NC}"
echo -e "  Total Tests:   $TOTAL_TESTS"
echo -e "  ${GREEN}Passed:        $TOTAL_PASS${NC}"
echo -e "  ${RED}Failed:        $TOTAL_FAIL${NC}"
echo -e "  Pass Rate:     ${PASS_RATE}%"
echo -e "  Duration:      ${MINUTES}m ${SECONDS}s"
echo ""

# Suite breakdown
echo -e "${BOLD}Results by Suite:${NC}"
echo ""
printf "  ${DIM}%-35s %7s %7s %7s${NC}\n" "Suite" "Pass" "Fail" "Total"
echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

# Get unique suites and their stats
declare -A SUITE_PASS
declare -A SUITE_FAIL

while IFS='|' read -r status suite test duration; do
    if [ "$status" = "PASS" ]; then
        SUITE_PASS[$suite]=$((${SUITE_PASS[$suite]:-0} + 1))
    elif [ "$status" = "FAIL" ]; then
        SUITE_FAIL[$suite]=$((${SUITE_FAIL[$suite]:-0} + 1))
    fi
done < "$RESULTS_FILE"

for suite in $(echo "${!SUITE_PASS[@]} ${!SUITE_FAIL[@]}" | tr ' ' '\n' | sort -u); do
    p=${SUITE_PASS[$suite]:-0}
    f=${SUITE_FAIL[$suite]:-0}
    t=$((p + f))
    if [ $f -gt 0 ]; then
        printf "  ${RED}%-35s${NC} ${GREEN}%7d${NC} ${RED}%7d${NC} %7d\n" "$suite" "$p" "$f" "$t"
    else
        printf "  ${GREEN}%-35s %7d${NC} %7d %7d\n" "$suite" "$p" "$f" "$t"
    fi
done

echo ""

# Show failed tests
if [ $TOTAL_FAIL -gt 0 ]; then
    echo -e "${BOLD}${RED}Failed Tests:${NC}"
    echo ""

    current_suite=""
    while IFS='|' read -r status suite test duration; do
        if [ "$status" = "FAIL" ]; then
            if [ "$suite" != "$current_suite" ]; then
                echo -e "  ${CYAN}$suite${NC}"
                current_suite="$suite"
            fi
            echo -e "    ${RED}✗${NC} $test ${DIM}(${duration}s)${NC}"
        fi
    done < "$RESULTS_FILE"
    echo ""

    # Show error details
    if [ -s "$ERRORS_FILE" ]; then
        echo -e "${BOLD}Error Details:${NC}"
        echo ""

        error_count=0
        while IFS='|' read -r test_name error_msg; do
            if [ $error_count -lt 15 ]; then
                short_error=$(echo "$error_msg" | head -c 80)
                echo -e "  ${DIM}$test_name:${NC}"
                echo -e "    ${RED}$short_error${NC}"
                ((error_count++))
            fi
        done < "$ERRORS_FILE"

        total_errors=$(wc -l < "$ERRORS_FILE")
        if [ $total_errors -gt 15 ]; then
            echo ""
            echo -e "  ${DIM}... and $((total_errors - 15)) more errors${NC}"
        fi
        echo ""
    fi
fi

# Final status banner
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
if [ $TOTAL_FAIL -eq 0 ] && [ $TOTAL_PASS -gt 0 ]; then
    echo -e "${BOLD}${GREEN}                     ✓ ALL TESTS PASSED                        ${NC}"
elif [ $TOTAL_FAIL -gt 0 ]; then
    echo -e "${BOLD}${RED}                     ✗ $TOTAL_FAIL TEST(S) FAILED                        ${NC}"
else
    echo -e "${BOLD}${YELLOW}                     ⚠ NO TESTS RUN                             ${NC}"
fi
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${DIM}Finished: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${DIM}Full log: $LOG_FILE${NC}"
echo ""

exit $EXIT_CODE
