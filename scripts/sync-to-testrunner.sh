#!/bin/bash
#
# sync-to-testrunner.sh
#
# Syncs the current working directory to the test user account.
# Use this to test uncommitted changes without committing.
#
# Usage:
#   ./scripts/sync-to-testrunner.sh           # Sync all files
#   ./scripts/sync-to-testrunner.sh --dry-run # Preview what would be synced
#
# Override test user: IMPRESS_TEST_USER=otheruser ./scripts/sync-to-testrunner.sh
#

set -e

TEST_USER="${IMPRESS_TEST_USER:-testrunner}"
SOURCE_PATH="/Users/tabel/Projects/impress-apps/"
DEST_PATH="/Users/$TEST_USER/Projects/impress-apps/"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DRY_RUN=""
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN="--dry-run"
    echo -e "${YELLOW}DRY RUN - no files will be changed${NC}"
    echo ""
fi

echo -e "${BLUE}Syncing to $TEST_USER account...${NC}"
echo "Source:      $SOURCE_PATH"
echo "Destination: $TEST_USER@localhost:$DEST_PATH"
echo ""

# Check SSH connectivity first
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$TEST_USER@localhost" "echo" > /dev/null 2>&1; then
    echo -e "${YELLOW}Error: Cannot connect to $TEST_USER@localhost${NC}"
    echo "Run: ssh-copy-id $TEST_USER@localhost"
    exit 1
fi

# Ensure destination directory exists
ssh "$TEST_USER@localhost" "mkdir -p $DEST_PATH"

# Sync with rsync
# Excludes:
#   - .git (use git operations instead for version control)
#   - DerivedData, build, .build, target (build artifacts)
#   - *.xcodeproj (will be regenerated with xcodegen)
#   - Frameworks (built frameworks, will be rebuilt)
#   - node_modules (if any JS tooling is used)
rsync -avz --progress $DRY_RUN \
    --delete \
    --exclude '.git' \
    --exclude 'DerivedData' \
    --exclude '*.xcodeproj' \
    --exclude 'build' \
    --exclude '.build' \
    --exclude 'target' \
    --exclude 'Frameworks' \
    --exclude '*.xcframework' \
    --exclude 'node_modules' \
    --exclude '.DS_Store' \
    "$SOURCE_PATH" \
    "$TEST_USER@localhost:$DEST_PATH"

echo ""
echo -e "${GREEN}Sync complete!${NC}"
echo ""
echo "Note: Xcode projects and Rust frameworks were excluded."
echo "In testrunner account, run:"
echo "  cd ~/Projects/impress-apps"
echo "  ./apps/imprint/build-rust.sh          # If Rust code changed"
echo "  cd apps/imprint && xcodegen generate  # Regenerate Xcode project"
