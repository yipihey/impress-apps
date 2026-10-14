#!/usr/bin/env bash
# Install (or remove) the weekly LaunchAgent that runs
# scripts/clean-build-data.sh --apply — Sundays 03:30, log in
# ~/Library/Logs/impress-build-janitor.log.
#
#   scripts/install-build-janitor.sh            # install / refresh
#   scripts/install-build-janitor.sh --remove   # uninstall
#
# A LaunchAgent and not a build-script hook because the waste it removes —
# merged worktrees, legacy per-task dirs, swollen target dirs — is created
# by sessions that never run a build script afterwards. The 2026-10-14
# cleanup (docs/plan-build-storage.md) found 74 worktrees nobody removed.
set -euo pipefail

LABEL="com.impress.build-janitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build-env.sh
source "$SCRIPT_DIR/build-env.sh"
MAIN="$(impress_main_root "$SCRIPT_DIR")"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "--remove" ]; then
    rm -f "$PLIST"
    echo "removed $LABEL"
    exit 0
fi

mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$MAIN/scripts/clean-build-data.sh</string>
        <string>--apply</string>
    </array>
    <key>WorkingDirectory</key><string>$MAIN</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key><integer>0</integer>
        <key>Hour</key><integer>3</integer>
        <key>Minute</key><integer>30</integer>
    </dict>
    <key>LowPriorityIO</key><true/>
    <key>Nice</key><integer>10</integer>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/impress-build-janitor.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/impress-build-janitor.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL (Sundays 03:30) -> $PLIST"
