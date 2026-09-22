#!/usr/bin/env bash
# scripts/check-kit-deps.sh — pins ADR-0033 D7's dependency line.
#
# D7: "no kit crate depends on impress-core's domain modules." The kit is
# meant to leave the repository one day as its own standalone package, and
# impress-core is where the suite's domain data (collections, schemas, the
# built-in view-kind manifest) lives — a kit crate that reaches it cannot be
# cut loose.
#
# This checks the crates cargo can actually pin: impress-pane-query,
# impress-layout, impress-surface. `impress-layout-service` and
# `impress-surface-service` are also nominally "kit", but D7 lets them reach
# impress-core through the STORE path (SqliteItemStore, the `impress/ui/*`
# schema rows) — and `cargo tree` has no way to tell "depends on
# impress-core's store" apart from "depends on impress-core's domain
# modules", so those two service crates are not checked here.
#
# TODO(ADR-0033 D7 / S4): once impress-surface-service exists, decide whether
# the store-path exception needs its own check (e.g. grepping its Cargo.toml
# for `impress-core = { ..., features = ["sqlite", ...] }` and nothing more)
# rather than staying unchecked by name alone.
#
# Usage: scripts/check-kit-deps.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/home/user/impress-apps/target}"

KIT_CRATES=(impress-pane-query impress-layout impress-surface)

# Crates temporarily allowed to reach impress-core, with the package that
# removes each entry named beside it. Empty since S0 and S1 landed: every kit
# crate now depends on impress-pane-query, not impress-core (ADR-0033 D7).
ALLOW_IMPRESS_CORE=()

is_allowed() {
    local crate="$1" allowed
    for allowed in "${ALLOW_IMPRESS_CORE[@]}"; do
        [[ "$crate" == "$allowed" ]] && return 0
    done
    return 1
}

status=0

for crate in "${KIT_CRATES[@]}"; do
    if [[ ! -d "crates/$crate" ]]; then
        echo "SKIP: crates/$crate does not exist yet"
        continue
    fi

    tree_output="$(cargo tree -p "$crate" -e normal --prefix none 2>&1)" || {
        echo "FAIL: 'cargo tree -p $crate' errored:" >&2
        echo "$tree_output" >&2
        status=1
        continue
    }

    offenders="$(printf '%s\n' "$tree_output" | grep -E '^impress-core ' || true)"

    if [[ -z "$offenders" ]]; then
        echo "ok: $crate does not depend on impress-core"
        continue
    fi

    if is_allowed "$crate"; then
        echo "ok (allowed for now, ADR-0033 D7 — see ALLOW_IMPRESS_CORE above): $crate depends on impress-core"
        continue
    fi

    echo "FAIL: $crate depends on impress-core, which ADR-0033 D7 forbids for kit crates." >&2
    echo "  (docs/ADR-0033-agent-surfaces.md, decision D7: 'no kit crate depends on impress-core's domain modules')" >&2
    echo "  offending path (cargo tree -i impress-core -p $crate):" >&2
    cargo tree -i impress-core -p "$crate" >&2 || true
    status=1
done

if [[ $status -ne 0 ]]; then
    echo
    echo "kit-deps check failed. If this is impress-layout before S0 has landed" >&2
    echo "(docs/plan-agent-surfaces.md S0: the pane-query algebra has not yet" >&2
    echo "moved out of impress-core into impress-pane-query), that failure is" >&2
    echo "expected and will clear once S0 merges." >&2
fi

exit "$status"
