#!/bin/bash
#
# run-ui-tests-isolated.sh
#
# Runs UI tests in the testrunner account via SSH.
# Must be run from the main account.
#
# Usage:
#   ./scripts/run-ui-tests-isolated.sh          # Run all UI tests
#   ./scripts/run-ui-tests-isolated.sh imbib    # Run only imbib
#   ./scripts/run-ui-tests-isolated.sh imprint  # Run only imprint
#   ./scripts/run-ui-tests-isolated.sh implore  # Run only implore
#   ./scripts/run-ui-tests-isolated.sh all --wait  # Run and wait for result
#

set -e

TEST_USER="${IMPRESS_TEST_USER:-testrunner}"
REPO_PATH="/Users/$TEST_USER/Projects/impress-apps"
LOG_FILE="/tmp/ui-tests-$(date +%Y%m%d-%H%M%S).log"
RESULT_FILE="/tmp/ui-test-result.txt"

APP="${1:-all}"
WAIT_FLAG="${2:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}$1${NC}"
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_error() {
    echo -e "${RED}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

# Check SSH connectivity
check_ssh() {
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$TEST_USER@localhost" "echo" > /dev/null 2>&1; then
        print_error "Error: Cannot connect to $TEST_USER@localhost via SSH"
        echo ""
        echo "Troubleshooting steps:"
        echo "  1. Ensure Remote Login is enabled:"
        echo "     System Settings -> General -> Sharing -> Remote Login"
        echo ""
        echo "  2. Copy your SSH key to testrunner:"
        echo "     ssh-copy-id $TEST_USER@localhost"
        echo ""
        echo "  3. Test connection manually:"
        echo "     ssh $TEST_USER@localhost"
        exit 1
    fi
}

# Check if testrunner has a GUI session (required for UI tests)
check_gui_session() {
    if ! ssh "$TEST_USER@localhost" "pgrep -x Finder > /dev/null 2>&1"; then
        print_error "Error: $TEST_USER must be logged in with a GUI session"
        echo ""
        echo "XCTest UI tests require a graphical login session."
        echo ""
        echo "To set up:"
        echo "  1. Click your username in the menu bar (Fast User Switching)"
        echo "  2. Select '$TEST_USER' and log in"
        echo "  3. You can then lock the screen - tests will still run"
        echo "  4. Switch back to your main account"
        exit 1
    fi
}

# Check if repo exists in testrunner account
check_repo() {
    if ! ssh "$TEST_USER@localhost" "test -d $REPO_PATH"; then
        print_error "Error: Repository not found at $REPO_PATH"
        echo ""
        echo "Set up the repository in testrunner account:"
        echo "  ssh $TEST_USER@localhost"
        echo "  git clone /Users/tabel/Projects/impress-apps ~/impress-apps"
        echo ""
        echo "Or use sync-to-testrunner.sh to copy your working directory."
        exit 1
    fi
}

print_info "Starting UI tests in $TEST_USER account..."
echo "App:      $APP"
echo "Log file: $LOG_FILE"
echo ""

# Run checks
print_info "Checking prerequisites..."
check_ssh
print_success "  SSH connection OK"

check_gui_session
print_success "  GUI session active"

check_repo
print_success "  Repository found"

echo ""

# Run tests via SSH
print_info "Launching tests..."

ssh "$TEST_USER@localhost" "bash -l -c '
    cd $REPO_PATH
    export PATH=\"\$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH\"

    # Run the test script
    ./scripts/run-all-ui-tests.sh $APP 2>&1 | tee $LOG_FILE

    # Save exit code
    echo \${PIPESTATUS[0]} > $RESULT_FILE
'" &

SSH_PID=$!

echo ""
print_info "Tests running in background (PID: $SSH_PID)"
echo ""
echo "Commands:"
echo "  tail -f $LOG_FILE        # Watch progress"
echo "  kill $SSH_PID            # Cancel tests"
echo "  wait $SSH_PID            # Wait for completion"
echo ""

# Optionally wait and show result
if [[ "$WAIT_FLAG" == "--wait" ]]; then
    print_info "Waiting for tests to complete..."
    wait $SSH_PID || true

    RESULT=$(ssh "$TEST_USER@localhost" "cat $RESULT_FILE 2>/dev/null" || echo "1")

    echo ""
    if [[ "$RESULT" == "0" ]]; then
        print_success "All tests passed!"
        # Send notification
        osascript -e 'display notification "All UI tests passed!" with title "Test Runner" sound name "Glass"' 2>/dev/null || true
        exit 0
    else
        print_error "Some tests failed. Check log: $LOG_FILE"
        # Send notification with error sound
        osascript -e 'display notification "UI tests failed!" with title "Test Runner" sound name "Basso"' 2>/dev/null || true
        exit 1
    fi
fi
