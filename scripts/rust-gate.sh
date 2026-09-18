#!/bin/bash
# The Rust gate, in ONE place.
#
# It used to be spelled five ways: four copies in workspace-rust.yml (clippy and
# test x imprint and rest, with the note "keep the four copies identical when
# editing"), plus a different, unsharded spelling in CLAUDE.md and AGENTS.md
# that told developers to run `cargo clippy --workspace --all-targets --features
# native` - the exact command CI abandoned in 2026-07 because a cold cache made
# it a ~90-minute job.
#
# Usage:
#   scripts/rust-gate.sh clippy imprint     # the Typst half
#   scripts/rust-gate.sh clippy rest        # everything else
#   scripts/rust-gate.sh clippy auto        # the shard(s) your changes touch
#   scripts/rust-gate.sh test  auto
#   scripts/rust-gate.sh fmt                # always cheap
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# The imprint tree links Typst and dominates cold compile time; impress-mcp is
# in this list because it is the one crate that enables imprint-service's
# typst-render, and leaving it in `rest` put the whole Typst tree there too.
IMPRINT_SELECT=(-p imprint-core -p imprint-service -p imprint-service-http
                -p imprint-selftest -p imprint-cli -p impress-mcp)
IMPRINT_FEATURES=(--features imprint-core/native)
# uniffi-bindgen is excluded deliberately: selecting it would unify uniffi's
# `cli` feature back onto every library in the shard.
REST_SELECT=(--workspace --exclude imprint-core --exclude imprint-service
             --exclude imprint-service-http --exclude imprint-selftest
             --exclude imprint-cli --exclude impress-mcp --exclude uniffi-bindgen)
REST_FEATURES=(--features native)

MODE="${1:-clippy}"; SHARD="${2:-auto}"

if [ "$MODE" = "fmt" ]; then exec cargo fmt --all --check; fi

pick_shards() {
    if [ "$SHARD" != "auto" ]; then echo "$SHARD"; return; fi
    local base changed
    base="$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo HEAD~1)"
    changed="$(git diff --name-only "$base" 2>/dev/null || true)"
    [ -z "$changed" ] && { echo "imprint rest"; return; }
    local want=""
    case "$changed" in *crates/imprint-*|*crates/impress-mcp/*) want="imprint";; esac
    # anything outside the imprint tree, or a shared crate, needs `rest` too
    if printf '%s\n' "$changed" | grep -qvE '^crates/(imprint-[a-z]*|impress-mcp)/'; then
        want="$want rest"
    fi
    [ -z "$want" ] && want="imprint rest"
    echo "$want"
}

run_shard() {
    local shard="$1"
    local -a sel feat
    if [ "$shard" = "imprint" ]; then sel=("${IMPRINT_SELECT[@]}"); feat=("${IMPRINT_FEATURES[@]}")
    else                              sel=("${REST_SELECT[@]}");    feat=("${REST_FEATURES[@]}"); fi
    case "$MODE" in
        clippy) echo "== clippy [$shard]"; cargo clippy "${sel[@]}" --all-targets "${feat[@]}" -- -D warnings ;;
        test)   echo "== test [$shard]";   cargo test   "${sel[@]}" "${feat[@]}" ;;
        *) echo "unknown mode: $MODE (clippy|test|fmt)" >&2; exit 2 ;;
    esac
}

for s in $(pick_shards); do run_shard "$s"; done
