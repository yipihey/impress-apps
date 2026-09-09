#!/usr/bin/env bash
# Give each self-hosted runner a Login Items row a human can tell apart.
#
# THE PROBLEM. macOS lists every LaunchAgent under Login Items & Extensions,
# labelled with its program's FILE NAME. All four GitHub runners point at a
# script called `runsvc.sh`, one per runner directory, so the list shows four
# identical rows reading "runsvc.sh — Item from unidentified developer". There
# is no way to tell which runner a row belongs to, or to switch one off on
# purpose, and every registration fires an "App Background Activity" notice for
# a name that means nothing.
#
# THE FIX. Each runner gets a distinctly named launcher beside its `runsvc.sh`,
# signed with the developer identity, and its LaunchAgent points at that. The
# rows become "GitHub Runner impress-mac-3" and friends, attributed rather than
# unidentified.
#
# WHY A SEPARATE FILE rather than renaming or signing `runsvc.sh` itself: the
# runner replaces its own files on upgrade, and a script's signature lives in
# extended attributes that any rewrite drops. A launcher the runner does not
# own survives its upgrades.
#
# RE-RUN THIS AFTER `svc.sh install` — registering a runner service rewrites
# the LaunchAgent back to `runsvc.sh`. It is idempotent and safe to re-run at
# any time.
#
# Usage: scripts/name-runner-login-items.sh [runner-name ...]
#   With no arguments, every configured runner is processed.
#   Reloading a runner's agent KILLS ANY JOB IT IS RUNNING (GitHub re-queues
#   it), so a busy runner is skipped unless you name it explicitly.

set -euo pipefail

IDENTITY="${IDENTITY:-Apple Development: THOMAS G ABEL (E9NUL9QF47)}"
LABEL_PREFIX="actions.runner.yipihey-impress-apps"

# impress-mac → ~/actions-runner-impress; impress-mac-3 → ~/actions-runner-impress-3
runner_dir_for() {
    case "$1" in
        impress-mac) echo "$HOME/actions-runner-impress" ;;
        impress-mac-*) echo "$HOME/actions-runner-impress-${1#impress-mac-}" ;;
        *) echo "" ;;
    esac
}

# A live Runner.Worker under this runner's own bin/ means a job is in flight.
# The trailing `/bin` matters: `actions-runner-impress` is a prefix of
# `actions-runner-impress-2`, and without it every runner reads as busy
# whenever the first one is.
is_busy() {
    pgrep -f "$1/bin.*Runner.Worker" >/dev/null 2>&1
}

process_runner() {
    name="$1"
    explicit="$2"
    dir="$(runner_dir_for "$name")"
    plist="$HOME/Library/LaunchAgents/$LABEL_PREFIX.$name.plist"
    launcher="$dir/GitHub Runner $name"

    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        echo "  $name: no runner directory — skipped"
        return
    fi
    if [ ! -f "$plist" ]; then
        echo "  $name: no LaunchAgent — run its svc.sh install first"
        return
    fi
    # Already done? Then do NOTHING — not "do it again harmlessly".
    #
    # Re-running is supposed to be free, and rewriting a launcher that is
    # already correct is not: it bounces a healthy runner, and an agent that
    # picked up a job since the busy check above can miss the unload window,
    # which then costs a second bounce to roll back. This happened to
    # impress-mac-3 on the very first re-run.
    current="$(plutil -extract ProgramArguments.0 raw "$plist" 2>/dev/null || true)"
    if [ "$current" = "$launcher" ] && [ -x "$launcher" ] && codesign -v "$launcher" 2>/dev/null; then
        echo "  $name: already named and signed — nothing to do"
        return 0
    fi

    if [ "$explicit" != "yes" ] && is_busy "$dir"; then
        echo "  $name: BUSY with a job — skipped (name it explicitly to interrupt it)"
        return
    fi

    # `exec`, not a call: runsvc.sh traps TERM/INT to shut its listener down
    # cleanly, and launchd has to be signalling the process that installed
    # those traps. Its relative paths (./bin, ./externals, .path) resolve
    # against the LaunchAgent's WorkingDirectory, which this does not change.
    cat > "$launcher" <<LAUNCHER
#!/bin/bash
# Named launcher for the GitHub Actions runner "$name".
# Exists so Login Items & Extensions shows a row saying which runner this is,
# instead of a fourth anonymous "runsvc.sh". Generated and signed by
# scripts/name-runner-login-items.sh — re-run that after svc.sh install.
exec "\$(dirname "\$0")/runsvc.sh"
LAUNCHER
    chmod +x "$launcher"
    codesign --force --sign "$IDENTITY" "$launcher"

    # Point the agent at it, then re-register so Background Task Management
    # picks up the new name.
    cp "$plist" "$plist.pre-rename"
    plutil -replace ProgramArguments -json "[\"$launcher\"]" "$plist"

    if ! reload_agent "$name" "$plist"; then
        # Never leave a runner offline over a cosmetic change. Put the agent
        # back the way it was and say so loudly.
        echo "  $name: RELOAD FAILED — restoring the original agent"
        mv "$plist.pre-rename" "$plist"
        reload_agent "$name" "$plist" \
            || echo "  $name: STILL OFFLINE — run: launchctl bootstrap gui/$UID $plist"
        return 1
    fi
    rm -f "$plist.pre-rename"

    authority="$(codesign -dv "$launcher" 2>&1 | awk -F= '/^Authority/{print $2; exit}')"
    echo "  $name: runs as \"GitHub Runner $name\" — signed by ${authority:-the team identity}"
}

# Is this launchd label currently loaded?
#
# Capture rather than pipe into `grep -q`. grep exits at the first match, which
# SIGPIPEs `launchctl list` mid-write, and `set -o pipefail` turns that 141
# into a failed pipeline — so a label that IS loaded reports as absent. Every
# caller below decides whether a runner is up, and the wrong answer at the
# first one bootstraps over a still-registered label: "Bootstrap failed: 5:
# Input/output error", which is precisely how this script took runners offline
# before it learned to wait.
agent_loaded() {
    case "$(launchctl list 2>/dev/null)" in
        *"$1"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Unload and reload one agent, waiting for the unload to actually finish.
#
# `launchctl bootout` returns before the job is gone, and bootstrapping a label
# that is still registered fails with "Input/output error" — which is how the
# first run of this script took impress-mac-3 offline and left it there.
reload_agent() {
    local name="$1" plist="$2" label="$LABEL_PREFIX.$1"
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    for _ in $(seq 1 60); do
        agent_loaded "$label" || break
        sleep 1
    done
    if agent_loaded "$label"; then
        echo "  $name: agent would not unload after 60s"
        return 1
    fi
    # Capture rather than pipe: the output is wanted in the failure message,
    # and a caller's grep filter must not be able to swallow the one line that
    # explains what went wrong.
    # Let the OLD incarnation finish dying before starting a new one.
    #
    # `runsvc.sh` does not merely exit when its listener shuts down cleanly —
    # it STOPS THE SERVICE ("Runner listener exit with 0 return code, stop the
    # service, no retry needed"), i.e. it unloads its own launchd job. That
    # unload lands seconds after the bootout returns, so a bootstrap issued
    # immediately gets registered and then torn down by the previous
    # incarnation's shutdown. The job vanishes, and with no KeepAlive in the
    # runner's plist nothing brings it back — which is how impress-mac ended
    # up offline twice. Waiting for the label to disappear is not enough: it
    # disappears, reappears on bootstrap, and is removed again.
    sleep 10
    bootstrap_out="$(launchctl bootstrap "gui/$UID" "$plist" 2>&1)"
    # 45s, not 15: on a Mac running four runners plus their Xcode builds,
    # launchd has taken longer than 15s to register a job whose program path
    # changed, and the old window turned that into a spurious rollback of a
    # bootstrap that had actually succeeded.
    for _ in $(seq 1 45); do
        if agent_loaded "$label"; then
            # Appearing is not surviving. Confirm it is STILL there after the
            # old incarnation's self-stop would have landed; a job that is
            # about to be torn down looks identical to a healthy one.
            sleep 10
            if agent_loaded "$label"; then
                return 0
            fi
            echo "  $name: agent loaded then vanished — the previous incarnation stopped the service under it"
            return 1
        fi
        sleep 1
    done
    echo "  $name: agent did not appear in launchctl within 45s of bootstrap"
    [ -n "$bootstrap_out" ] && echo "  $name: launchctl said: $bootstrap_out"
    return 1
}

if [ "$#" -eq 0 ]; then
    explicit=no
    set -- impress-mac impress-mac-2 impress-mac-3 impress-mac-4
else
    explicit=yes
fi

echo "Naming Login Items rows for: $*"
for name in "$@"; do
    # `|| true`: set -e would abandon the remaining runners the moment one
    # fails, and a partly-applied rename is how a runner gets left behind.
    process_runner "$name" "$explicit" || true
done

cat <<'NOTE'

Each re-registration fires one more "App Background Activity" notification —
macOS noticing the new name. It does not repeat.
NOTE
