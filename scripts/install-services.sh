#!/usr/bin/env bash
# Install (or repair) launchd supervision for the impress suite services:
#
#   com.impress.impress-ai-server — local-model conversations + the store
#       maintenance cadence (WAL checkpoints, op compaction, auto-VACUUM).
#       Port 8787 (SiblingApp.Services.impressAIPort).
#   com.impress.impel-taskd       — the impel task worker.
#
# Written after 2026-08-06, when repeated crash-kill cycles made launchd drop
# both registrations and the daemons ran hand-started (or not at all) for a
# day. Re-running this script is always safe: it rewrites the plists, boots
# the jobs out if present, and bootstraps them fresh.
#
# The AI server's bearer stays in the login keychain (com.impress.ai-http);
# run.sh resolves it at launch — the plist never contains a secret.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/impress"
mkdir -p "$AGENTS" "$LOGS"

AI_LABEL="com.impress.impress-ai-server"
AI_PLIST="$AGENTS/$AI_LABEL.plist"
TASKD_LABEL="com.impress.impel-taskd"
TASKD_PLIST="$AGENTS/$TASKD_LABEL.plist"

cat > "$AI_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AI_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$REPO_ROOT/crates/impress-ai-http/run.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$LOGS/impress-ai-server.log</string>
    <key>StandardErrorPath</key><string>$LOGS/impress-ai-server.log</string>
</dict>
</plist>
PLIST
echo "wrote $AI_PLIST"

if [ ! -f "$TASKD_PLIST" ]; then
    echo "NOTE: $TASKD_PLIST does not exist — impel-taskd was never installed"
    echo "      on this machine, or its plist was removed. Skipping taskd."
fi

for PLIST in "$AI_PLIST" ${TASKD_PLIST:+$([ -f "$TASKD_PLIST" ] && echo "$TASKD_PLIST")}; do
    LABEL="$(basename "$PLIST" .plist)"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "bootstrapped $LABEL"
done

sleep 2
echo "--- status ---"
launchctl list | grep -E "impress-ai-server|impel-taskd" || echo "(jobs not yet listed — check $LOGS)"
curl -s --max-time 5 http://127.0.0.1:8787/api/health | head -c 200 || true
echo
