#!/usr/bin/env bash
# Keep this machine's build data bounded. Dry run by default.
#
#   scripts/clean-build-data.sh            # report what would go
#   scripts/clean-build-data.sh --apply    # delete it
#   scripts/clean-build-data.sh --apply --light
#                                          # only rules 3 (dead objects) and
#                                          # 6 (test scratch): the hourly run
#
# Run daily by the LaunchAgent that scripts/install-build-janitor.sh installs.
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
#      (`target`, `target-*`, `apps/*/.ci-derived`) — in every linked
#      worktree, not only those under .claude/worktrees: one made beside the
#      main checkout reads no shared cargo config and builds its own target/
#      (192 GB in impress-apps-trust, found 2026-10-18);
#   3. the two shared Cargo target dirs (main `target/`, and
#      `.claude/target-worktrees`) when the toolchain changed or they exceed
#      TARGET_BUDGET_GB (default 150). Main's `target/release` is KEPT: the
#      signed impress-mcp, vw-mcp and impress binaries run from it.
#      Before that, in these, the CI runner dirs and EXTRA_TARGETS (default:
#      the sibling koine checkout's target/): the object files no binary
#      names (scripts/sweep-objects.sh), and the whole `debug/` when its deps/
#      still holds more than FILE_BUDGET files (default 60000). Size was not
#      the problem on 2026-10-18; file count was: 461,602 dead objects in
#      koine made every rustc call four times slower at 101 GB, under budget;
#   4. DerivedData untouched for 14 days (prune-derived-data.sh);
#   5. unavailable simulators;
#   6. proof and pre-push scratch dirs in /tmp and $TMPDIR older than 3 days,
#      and test scratch in $TMPDIR (the names tests here and in koine use)
#      older than a day — rust-gate.sh gives its test runs a TMPDIR of their
#      own, this catches plain `cargo test` and the Swift suites;
#   7. legacy per-job CI target dirs (runner dirs bound themselves, see
#      scripts/ci-cargo-target.sh), and CI DerivedData dirs no job has used for
#      14 days (live ones bound themselves, see scripts/ci-derived-data.sh);
#   8. framework backups beyond the newest.
set -uo pipefail

APPLY=no
LIGHT=no
for a in "$@"; do
    case "$a" in
        --apply) APPLY=yes ;;
        --light) LIGHT=yes ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done
IDLE_DAYS="${IDLE_DAYS:-2}"
TARGET_BUDGET_GB="${TARGET_BUDGET_GB:-150}"
FILE_BUDGET="${FILE_BUDGET:-60000}"

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

if [ "$LIGHT" = no ]; then
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
# Every linked worktree, wherever it is (`git worktree list`), not the main one.
others=()
while IFS= read -r line; do
    case "$line" in
        "worktree "*) w="${line#worktree }"; [ "$w" != "$MAIN" ] && others+=("$w") ;;
    esac
done < <(git worktree list --porcelain 2>/dev/null)
dirs=(.claude/worktrees/*/target .claude/worktrees/*/target-* .claude/worktrees/*/apps/*/.ci-derived .claude/target-[!w]*)
for w in ${others[@]+"${others[@]}"}; do
    case "$w" in "$MAIN"/.claude/worktrees/*) continue ;; esac
    dirs+=("$w/target" "$w"/target-* "$w"/apps/*/.ci-derived)
done
for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    if in_use "$d"; then echo "  in use, kept  $d"; continue; fi
    act "$d ($(size_gb "$d") GB)" rm -rf "$d"
done

fi   # LIGHT

echo "3. Cargo target dirs: dead objects, file count, size"
EXTRA_TARGETS="${EXTRA_TARGETS:-$(dirname "$MAIN")/koine/target}"
# Dead objects first: a dir in use is only swept (a running build's
# binaries name their objects, so nothing it needs goes), never cleaned.
for t in "$MAIN/target" "$MAIN/.claude/target-worktrees" "$HOME"/ci-cargo-target/runner-* $EXTRA_TARGETS; do
    [ -d "$t/debug/deps" ] || continue
    if [ "$APPLY" = yes ]; then
        "$SCRIPT_DIR/sweep-objects.sh" "$t" 2>&1 | sed 's/^/  /'
    else
        echo "  would sweep dead objects in $t ($(find "$t/debug/deps" -maxdepth 1 -name '*.o' | wc -l | tr -d ' ') .o files now)"
    fi
    n=$(find "$t/debug/deps" -maxdepth 1 | wc -l | tr -d ' ')
    if [ "$n" -gt "$FILE_BUDGET" ]; then
        if in_use "$t/debug" 30; then echo "  in use, kept  $t/debug ($n files)"; continue; fi
        act "$t/debug ($n files in deps/, over the $FILE_BUDGET budget)" rm -rf "$t/debug"
    fi
done
if [ "$LIGHT" = no ]; then
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

fi   # LIGHT

echo "6. proof, pre-push and test scratch"
# Test scratch, by the names the Rust and Swift tests use, older than a day.
T="${TMPDIR:-/tmp}"; T="${T%/}"
for d in "$T"/.tmp?????? "$T"/koine-test-scratch/* "$T"/koine-store-dir-conformance-* \
         "$T"/rust-gate-tests.* "$T"/impress-examples-* "$T"/impress-provider-effects-* \
         "$T"/first-sync-merge-* "$T"/sync-peer-[ab]-* "$T"/imbib-backup-* "$T"/impress-backup-* \
         "$T"/impress-unit-tests-* "$T"/impress-mcp-resource-tests-* "$T"/imbib-search-service-test-* \
         "$T"/imprint-service-compile-tests-* "$T"/vw-mcp-test-* "$T"/impress-store-service-* \
         "$T"/Journal*Tests*; do
    [ -e "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 0 -mtime +1 2>/dev/null)" ] && act "$d" rm -rf "$d"
done | awk -v apply="$APPLY" '{n++} apply!="yes" && n<=5 {print} END {if (n) printf "  %d test scratch entries%s\n", n, (apply=="yes" ? " deleted" : " would go")}'
# Proof and pre-push scratch, older than 3 days.
for d in /tmp/impress-*-proof-* /tmp/impress-p5b-transport-* /tmp/imbib-autonomous-tests/* "${TMPDIR:-/tmp}"/impress-pre-push.* "${TMPDIR:-/tmp}"/xcfw-*; do
    [ -e "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 0 -mtime +3 2>/dev/null)" ] && act "$d" rm -rf "$d"
done

[ "$LIGHT" = yes ] && { echo "free: $(free_gb) GB (was ${start_free} GB)"; exit 0; }

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
