#!/usr/bin/env bash
# Keep this machine's build data bounded. Dry run by default.
#
#   scripts/clean-build-data.sh            # report what would go
#   scripts/clean-build-data.sh --apply    # delete it
#
# Run weekly by the LaunchAgent that scripts/install-build-janitor.sh installs.
#
# WHY. On 2026-10-14 builds of this repo held ~3.2 TB and the disk filled
# mid-build: 74 agent worktrees (71 already merged), 111 private
# `target-<task>` dirs inside them, 33 per-job CI target dirs and 27 framework
# backups. Nothing ever deleted any of it (docs/plan-build-storage.md).
# scripts/build-env.sh says where builds go; this deletes what is left over.
#
# Every rule deletes only what can be rebuilt or is provably finished:
#   1. worktrees under .claude/worktrees whose branch is merged into main,
#      with a clean status and no commit or edit for IDLE_DAYS (default 2);
#   2. legacy per-task build dirs inside the worktrees that remain
#      (`target`, `target-*`, `apps/*/.ci-derived`);
#   3. the two shared Cargo target dirs (main `target/`, and
#      `.claude/target-worktrees`) when the toolchain changed or they exceed
#      TARGET_BUDGET_GB (default 150). Main's `target/release` is KEPT: the
#      signed impress-mcp, vw-mcp and impress binaries run from it;
#   4. DerivedData untouched for 14 days (prune-derived-data.sh);
#   5. unavailable simulators, and shut-down `ci-impart-*` devices a killed
#      impart-apps.yml job never deleted;
#   6. proof and pre-push scratch dirs in /tmp and $TMPDIR older than 3 days;
#   7. legacy per-job CI target dirs (runner dirs bound themselves, see
#      scripts/ci-cargo-target.sh), and CI DerivedData dirs no job has used for
#      14 days (live ones bound themselves, see scripts/ci-derived-data.sh);
#   8. framework backups beyond the newest.
set -uo pipefail

APPLY=no
for a in "$@"; do
    case "$a" in
        --apply) APPLY=yes ;;
        -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done
IDLE_DAYS="${IDLE_DAYS:-2}"
TARGET_BUDGET_GB="${TARGET_BUDGET_GB:-150}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build-env.sh
source "$SCRIPT_DIR/build-env.sh"
MAIN="$(impress_main_root "$SCRIPT_DIR")" || { echo "not in a git checkout" >&2; exit 1; }
cd "$MAIN" || exit 1

free_gb() { df -k "$HOME" | awk 'NR==2 {print int($4 / 1048576)}'; }
size_gb() { du -sk "$1" 2>/dev/null | awk '{print int($1 / 1048576)}'; }
act() {   # description, then the command
    local what="$1"; shift
    if [ "$APPLY" = yes ]; then "$@" && echo "  deleted  $what"; else echo "  would delete  $what"; fi
}
# A build running right now touches its dir; never delete under it.
in_use() { [ -n "$(find "$1" -maxdepth 3 -mmin -"${2:-120}" 2>/dev/null | head -1)" ]; }
now=$(date +%s)
start_free=$(free_gb)
echo "free: ${start_free} GB   (mode: $([ "$APPLY" = yes ] && echo apply || echo dry run))"

echo "1. merged, clean, idle worktrees"
for w in .claude/worktrees/*/; do
    w="${w%/}"; [ -e "$w/.git" ] || continue
    b=$(git -C "$w" branch --show-current 2>/dev/null)
    [ -n "$b" ] || continue
    git merge-base --is-ancestor "$b" main 2>/dev/null || continue
    [ -z "$(git -C "$w" status --porcelain 2>/dev/null)" ] || continue
    last=$(git -C "$w" log -1 --format=%ct 2>/dev/null || echo "$now")
    touched=$(stat -f %m "$w")
    [ "$touched" -gt "$last" ] && last=$touched
    [ $(( (now - last) / 86400 )) -ge "$IDLE_DAYS" ] || continue
    act "$w ($b)" git worktree remove "$w"
done
[ "$APPLY" = yes ] && git worktree prune

echo "2. per-task build dirs inside remaining worktrees"
for d in .claude/worktrees/*/target .claude/worktrees/*/target-* .claude/worktrees/*/apps/*/.ci-derived .claude/target-[!w]*; do
    [ -d "$d" ] || continue
    if in_use "$d"; then echo "  in use, kept  $d"; continue; fi
    act "$d ($(size_gb "$d") GB)" rm -rf "$d"
done

echo "3. shared Cargo target dirs"
toolchain=$(cd "$MAIN" && rustc -V 2>/dev/null || echo unknown)
for t in "$MAIN/target" "$MAIN/.claude/target-worktrees"; do
    [ -d "$t" ] || continue
    if in_use "$t"; then echo "  in use, kept  $t"; continue; fi
    stamp="$t/.impress-toolchain"
    reason=""
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" != "$toolchain" ]; then
        reason="toolchain changed: $(cat "$stamp") -> $toolchain"
    else
        gb=$(size_gb "$t")
        [ "${gb:-0}" -gt "$TARGET_BUDGET_GB" ] && reason="${gb} GB is over the ${TARGET_BUDGET_GB} GB budget"
    fi
    if [ -n "$reason" ]; then
        for sub in "$t"/*/; do
            sub="${sub%/}"
            # main's target/release holds the running, signed binaries
            [ "$sub" = "$MAIN/target/release" ] && continue
            act "$sub ($reason)" rm -rf "$sub"
        done
    else
        echo "  ok  $t"
    fi
    [ "$APPLY" = yes ] && echo "$toolchain" > "$stamp"
done

echo "4. DerivedData untouched for 14 days"
if [ "$APPLY" = yes ]; then
    "$SCRIPT_DIR/prune-derived-data.sh" --apply --stale-days 14 | tail -1
else
    "$SCRIPT_DIR/prune-derived-data.sh" --stale-days 14 | tail -1
fi

echo "5. unavailable simulators"
n=$(xcrun simctl list devices unavailable 2>/dev/null | grep -c '(unavailable')
if [ "${n:-0}" -gt 0 ]; then act "$n unavailable simulators" xcrun simctl delete unavailable; fi
# impart-apps.yml creates one device per job and deletes it in an always()
# step; a job killed with the runner leaves its device behind. A booted one may
# belong to a running job, so only shut-down devices go.
for udid in $(xcrun simctl list devices 2>/dev/null | grep -E '^ +ci-impart-' | grep '(Shutdown)' | grep -oE '[0-9A-F-]{36}'); do
    act "simulator $udid (ci-impart-*)" xcrun simctl delete "$udid"
done

echo "6. proof and pre-push scratch older than 3 days"
for d in /tmp/impress-*-proof-* /tmp/impress-p5b-transport-* /tmp/imbib-autonomous-tests/* "${TMPDIR:-/tmp}"/impress-pre-push.* "${TMPDIR:-/tmp}"/xcfw-*; do
    [ -e "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 0 -mtime +3 2>/dev/null)" ] && act "$d" rm -rf "$d"
done

echo "7. legacy per-job CI target dirs"
for d in "$HOME"/ci-cargo-target/*/; do
    d="${d%/}"; [ -d "$d" ] || continue
    case "$(basename "$d")" in
        runner-*|*build-cost|*"Tectonic engine"*) continue ;;
    esac
    [ -n "$(find "$d" -maxdepth 0 -mtime +7 2>/dev/null)" ] && act "$d" rm -rf "$d"
done

for d in "$HOME"/ci-derived-data.noindex/*/*/; do
    d="${d%/}"; [ -d "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 0 -mtime +14 2>/dev/null)" ] && act "$d" rm -rf "$d"
done

echo "8. framework backups beyond the newest"
newest=$(ls -dt .claude/framework-backup* 2>/dev/null | head -1)
for d in .claude/framework-backup*; do
    [ -d "$d" ] && [ "$d" != "$newest" ] && act "$d" rm -rf "$d"
done

impress_install_worktree_cargo_config "$MAIN"
echo "free: $(free_gb) GB (was ${start_free} GB)"
