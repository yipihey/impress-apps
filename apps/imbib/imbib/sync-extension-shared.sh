#!/bin/bash
# Sync shared extension files from canonical source to platform-specific directories.
# Run after editing any file in imbibExtensionShared/.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$SCRIPT_DIR/imbibExtensionShared"
BROWSER="$SCRIPT_DIR/imbibBrowserExtension"
SAFARI="$SCRIPT_DIR/imbibSafariExtension"

echo "Syncing shared extension files..."
for TARGET in "$BROWSER" "$SAFARI"; do
    rsync -av --checksum \
        "$SHARED/content/" "$TARGET/content/"
    rsync -av --checksum \
        "$SHARED/_locales/" "$TARGET/_locales/"
    rsync -av --checksum \
        "$SHARED/images/" "$TARGET/images/"
    echo "  → $(basename "$TARGET") updated"
done
echo "Done."
