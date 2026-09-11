#!/bin/bash
# Clippy every workspace crate ALONE, with no features (or, for the few crates
# that have no featureless build at all, the features every consumer uses).
#
# Cargo unifies features across every package one invocation selects, so a
# build of many crates proves nothing about any one of them built by itself.
# The workspace shards enable `native` (imprint-core's Typst included), and even
# a featureless `cargo clippy --workspace` inherits whatever any member turns
# on: impress-mcp enables imprint-service's `typst-render`. So the workspace
# gate never compiled imprint-service against an imprint-core without Typst,
# and its `not(typst-render)` fallback named a type that only exists with Typst
# on. Both shards stayed green while the lanes that build it alone (`cargo test
# -p imprint-service`, `cargo clippy -p impel-tools`) went red at 536776e9.
#
# Only an invocation that selects a crate on its own proves it builds on its
# own. Two passes per crate, because they resolve different feature sets:
#   lib   cargo clippy -p <crate>                what a dependent crate compiles
#   all   cargo clippy -p <crate> --all-targets  what `cargo test -p <crate>` compiles
# Under --all-targets the crate's dev-dependencies join feature resolution and
# can switch on the very feature whose absence the lib pass exists to catch.
#
# Usage:
#   scripts/clippy-each-crate.sh                 # both passes, every member
#   scripts/clippy-each-crate.sh lib             # one pass, every member
#   scripts/clippy-each-crate.sh all imprint-service impel-tools
#
# Prints one line per crate and pass, and a failing crate's full clippy output
# after its line. Exits 1 if any crate failed.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

# Crates that do not exist without a feature. Each is built alone with the
# features all of its consumers turn on, and says why here. Keep this short: a
# crate that merely FAILS without features, while something builds it that
# way, gets fixed rather than listed (imprint-service was that crate).
features_for() {
    case "$1" in
        # Two flavours, `native` (UniFFI, tokio, reqwest, rusqlite) and `wasm`,
        # and no third: bibtex/ re-exports native-only functions. Every
        # dependent and imbib-rust.yml build `native`.
        imbib-core) echo native ;;
    esac
}

PASS="${1:-both}"
[ "$#" -gt 0 ] && shift
case "$PASS" in
    lib | all) passes=("$PASS") ;;
    both) passes=(lib all) ;;
    *) echo "usage: $0 [lib|all|both] [crate ...]" >&2; exit 2 ;;
esac

crates=()
if [ "$#" -gt 0 ]; then
    crates=("$@")
else
    # python3 is already a dependency of this workflow (check-schema-refs.sh).
    if ! names="$(cargo metadata --no-deps --format-version 1 | python3 -c '
import json, sys
print("\n".join(sorted(p["name"] for p in json.load(sys.stdin)["packages"])))')"; then
        echo "could not list the workspace members" >&2
        exit 2
    fi
    while IFS= read -r name; do
        [ -n "$name" ] && crates+=("$name")
    done <<<"$names"
fi
if [ "${#crates[@]}" -eq 0 ]; then
    echo "no crates to check" >&2
    exit 2
fi

log="$(mktemp "${TMPDIR:-/tmp}/clippy-each-crate.XXXXXX")"
trap 'rm -f "$log"' EXIT

failed=()
start=$SECONDS
for pass in "${passes[@]}"; do
    for crate in "${crates[@]}"; do
        t0=$SECONDS
        feats="$(features_for "$crate")"
        # Never empty, so safe under -u on macOS's bash 3.2.
        args=(-p "$crate")
        [ "$pass" = all ] && args+=(--all-targets)
        [ -n "$feats" ] && args+=(--features "$feats")
        if cargo clippy "${args[@]}" -- -D warnings >"$log" 2>&1; then
            status=ok
        else
            status=FAIL
            failed+=("$pass  $crate${feats:+  [$feats]}")
        fi
        printf '%-4s  %-3s  %-34s %-9s %5ds\n' "$status" "$pass" "$crate" \
            "${feats:+[$feats]}" $((SECONDS - t0))
        [ "$status" = FAIL ] && cat "$log"
    done
done

echo "$((${#passes[@]} * ${#crates[@]})) invocation(s) in $((SECONDS - start))s"
if [ "${#failed[@]}" -gt 0 ]; then
    echo "${#failed[@]} failed when built alone with no features:"
    printf '  %s\n' "${failed[@]}"
    exit 1
fi
