#!/usr/bin/env bash
# Print a persistent, bounded Xcode DerivedData dir for a self-hosted CI job.
#
#   ./scripts/ci-derived-data.sh <lane>        # -> /Users/…/ci-derived-data.noindex/<runner>/<lane>
#
# The DerivedData counterpart of ci-cargo-target.sh. A lane that builds into
# `$PWD/.ci-derived` starts cold on every job, because actions/checkout's
# `git clean -ffdx` deletes it: impart-apps.yml spent 85-195 s on its macOS
# build and 94-190 s on its iOS build recompiling the whole package graph
# (PublicationManagerCore and the packages under packages/) that had not
# changed. A dir outside the checkout survives the clean, and the runner's
# checkout path never changes, so Xcode's incremental build applies.
#
# ONE DIR PER RUNNER AND LANE. A runner executes one job at a time, so nothing
# else writes the dir during a build; separate lanes keep separate dirs so one
# lane's scheme layout cannot invalidate another's.
#
# `.noindex` on the root, so Spotlight never indexes the .app bundles built
# here (docs/build-machine-hygiene.md: it is the one suffix that works).
#
# BOUNDED. The dir is emptied when Xcode changes (modules built by one Xcode
# are useless to the next) or when it exceeds the budget
# (IMPRESS_CI_DERIVED_BUDGET_GB, default 30), checked at most once a day.
set -euo pipefail

lane="${1:?usage: ci-derived-data.sh <lane>}"
runner="runner-${RUNNER_NAME:?RUNNER_NAME is unset}"
dir="$HOME/ci-derived-data.noindex/$runner/$lane"
budget_gb="${IMPRESS_CI_DERIVED_BUDGET_GB:-30}"
mkdir -p "$dir"

empty() {
    echo "ci-derived-data: emptying $dir ($1)" >&2
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' || echo unknown)
stamp="$dir/.impress-xcode"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" != "$xcode" ]; then
    empty "Xcode changed: $(cat "$stamp") -> $xcode"
fi

checked="$dir/.impress-size-checked"
if [ ! -f "$checked" ] || [ -n "$(find "$checked" -mtime +0 2>/dev/null)" ]; then
    size_gb=$(du -sk "$dir" 2>/dev/null | awk '{print int($1 / 1048576)}')
    if [ "${size_gb:-0}" -gt "$budget_gb" ]; then
        empty "${size_gb} GB is over the ${budget_gb} GB budget"
    fi
    touch "$checked"
fi

echo "$xcode" > "$stamp"
touch "$dir"   # clean-build-data.sh ages these dirs by their own mtime
echo "$dir"
