#!/usr/bin/env bash
# Print the persistent CARGO_TARGET_DIR for a self-hosted CI job, bounded.
#
#   ./scripts/ci-cargo-target.sh >> "$GITHUB_ENV"          # the runner's dir
#   ./scripts/ci-cargo-target.sh <lane> >> "$GITHUB_ENV"   # a dedicated lane
#
# ONE DIR PER RUNNER, NOT PER JOB. Until 2026-10-14 every workflow job had its
# own `~/ci-cargo-target/<workflow>-<job>`: 33 dirs, each a full cold build of
# the workspace (most with 5 triples), 1.3 TB in all, never swept. A runner
# executes one job at a time, so all jobs on it can share one dir with no lock
# contention; jobs with the same features now reuse each other's artifacts,
# and the dir holds the union of what they build instead of the sum.
#
# Only two lanes keep a dir of their own: build-cost (it `rm -rf`s its dir to
# time a cold build) and the Tectonic lane (its vcpkg tree lives under the
# target dir; one copy, not one per runner).
#
# BOUNDED. The dir is emptied when the Rust toolchain changes (the old
# compiler's artifacts can never be reused) or when it exceeds the budget
# (IMPRESS_CI_TARGET_BUDGET_GB, default 120). The size is measured at most
# once a day: `du` over a large target dir is not free.
set -euo pipefail

lane="${1:-runner-${RUNNER_NAME:?RUNNER_NAME is unset; pass a lane name}}"
dir="$HOME/ci-cargo-target/$lane"
budget_gb="${IMPRESS_CI_TARGET_BUDGET_GB:-120}"
mkdir -p "$dir"

empty() {
    echo "ci-cargo-target: emptying $dir ($1)" >&2
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

toolchain=$(rustc -V 2>/dev/null || echo unknown)
stamp="$dir/.impress-toolchain"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" != "$toolchain" ]; then
    empty "toolchain changed: $(cat "$stamp") -> $toolchain"
fi

checked="$dir/.impress-size-checked"
if [ ! -f "$checked" ] || [ -n "$(find "$checked" -mtime +0 2>/dev/null)" ]; then
    size_gb=$(du -sk "$dir" 2>/dev/null | awk '{print int($1 / 1048576)}')
    if [ "${size_gb:-0}" -gt "$budget_gb" ]; then
        empty "${size_gb} GB is over the ${budget_gb} GB budget"
    fi
    touch "$checked"
fi

echo "$toolchain" > "$stamp"
echo "CARGO_TARGET_DIR=$dir"
