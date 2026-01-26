#!/bin/bash
#
# start-ui-tests.sh
#
# Starts UI tests in background and notifies when done.
# This is the recommended way to run tests while continuing to work.
#
# Usage:
#   ./scripts/start-ui-tests.sh          # Run all UI tests
#   ./scripts/start-ui-tests.sh imbib    # Run only imbib
#   ./scripts/start-ui-tests.sh imprint  # Run only imprint
#   ./scripts/start-ui-tests.sh implore  # Run only implore
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/ui-tests-$(date +%Y%m%d-%H%M%S).log"
APP="${1:-all}"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${BLUE}Starting UI tests in background...${NC}"
echo "App: $APP"
echo "Log: $LOG_FILE"
echo ""

# Run the isolated test script with --wait in background
nohup "$SCRIPT_DIR/run-ui-tests-isolated.sh" "$APP" --wait > "$LOG_FILE" 2>&1 &
RUNNER_PID=$!

# Disown so it continues if this terminal closes
disown $RUNNER_PID 2>/dev/null || true

echo -e "${GREEN}Tests started!${NC}"
echo ""
echo "Runner PID: $RUNNER_PID"
echo ""
echo "Commands:"
echo "  tail -f $LOG_FILE     # Watch progress"
echo "  kill $RUNNER_PID      # Cancel tests"
echo ""
echo "You'll get a notification when tests complete."
