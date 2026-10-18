#!/usr/bin/env bash
# Install (or remove) the two LaunchAgents that run scripts/clean-build-data.sh:
#   com.impress.build-janitor         --apply, every day at 03:30;
#   com.impress.build-janitor-hourly  --apply --light, every hour: the dead
#     object files in the Cargo target dirs and old test scratch, which a
#     day of plain `cargo test` grows by hundreds of thousands of files.
# Logs in ~/Library/Logs/impress-build-janitor{,-hourly}.log (the hourly one
# is rotated at 1 MB).
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
HOURLY="$LABEL-hourly"
HOURLY_PLIST="$HOME/Library/LaunchAgents/$HOURLY.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build-env.sh
source "$SCRIPT_DIR/build-env.sh"
MAIN="$(impress_main_root "$SCRIPT_DIR")"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$HOURLY" 2>/dev/null || true
if [ "${1:-}" = "--remove" ]; then
    rm -f "$PLIST" "$HOURLY_PLIST"
    echo "removed $LABEL and $HOURLY"
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
echo "installed $LABEL (daily 03:30) -> $PLIST"

LOG="$HOME/Library/Logs/impress-build-janitor-hourly.log"
cat > "$HOURLY_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$HOURLY</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>[ "\$(stat -f %z '$LOG' 2&gt;/dev/null || echo 0)" -gt 1048576 ] &amp;&amp; mv -f '$LOG' '$LOG.1'; exec /bin/bash '$MAIN/scripts/clean-build-data.sh' --apply --light &gt;&gt; '$LOG' 2&gt;&amp;1</string>
    </array>
    <key>WorkingDirectory</key><string>$MAIN</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartInterval</key><integer>3600</integer>
    <key>LowPriorityIO</key><true/>
    <key>Nice</key><integer>15</integer>
</dict>
</plist>
PLISTEOF
plutil -lint "$HOURLY_PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$HOURLY_PLIST"
echo "installed $HOURLY (hourly, light) -> $HOURLY_PLIST"
