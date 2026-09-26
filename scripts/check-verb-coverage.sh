#!/usr/bin/env bash
# scripts/check-verb-coverage.sh: the source-only half of the verb census.
#
# docs/verb-coverage.md records, between marker comments, one row per
# #[impress_service] service the `full` inventory links and one verdict per
# workspace crate (verb-crate / covered-through / internal / should-be-verb).
# The census test in crates/impress-capabilities/tests/census.rs checks the
# per-service COUNTS against the linked inventory, which needs the whole
# suite built. This script checks what needs no build, so a hosted runner can
# block a pull request cheaply (plan-auto-gui-and-self-docs.md G0):
#
#   * every workspace member in Cargo.toml has a crate row, with a verdict
#     from the known set, and every crate row names a member;
#   * every `impress_service_impl! { service = X }` block under crates/*/src
#     has a service row (kebab-cased), and every service row has a block;
#   * at most CEILING crates are `should-be-verb` (C-1: the gap is held, not
#     allowed to grow). The ceiling is read from the test file so the two
#     checks cannot disagree.
#
# Usage:
#   scripts/check-verb-coverage.sh
#
# Written for bash 3.2 (stock macOS): no namerefs, no associative arrays.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DOC="docs/verb-coverage.md"
TEST="crates/impress-capabilities/tests/census.rs"
VERDICTS="verb-crate covered-through internal should-be-verb"

for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

block() {
    awk -v b="<!-- $1:begin -->" -v e="<!-- $1:end -->" \
        'index($0, b) { p = 1; next } index($0, e) { p = 0 } p' "$DOC"
}

in_list() { # in_list <word> <space/newline separated list>
    local w="$1" x
    for x in $2; do [[ "$x" == "$w" ]] && return 0; done
    return 1
}

kebab() { # CamelCase_or_snake -> kebab-case, as the macro spells tool names
    printf '%s\n' "$1" | sed -E 's/([A-Z])/-\1/g; s/_/-/g; s/^-//' | tr '[:upper:]' '[:lower:]'
}

status=0
fail() { echo "FAIL: $*"; status=1; }

# --- crate rows vs workspace members -----------------------------------------

MEMBERS="$(awk '/^members = \[/ { p = 1; next } p && /^\]/ { p = 0 } p' Cargo.toml \
    | grep -o '"[^"]*"' | tr -d '"' | awk -F/ '{ print $NF }')"
CRATE_ROWS="$(block verb-coverage-crates | awk -F'|' '/^\| `/ {
    name = $2; verdict = $4
    gsub(/[` ]/, "", name); gsub(/ /, "", verdict)
    print name, verdict }')"

[[ -n "$MEMBERS" && -n "$CRATE_ROWS" ]] || { echo "FAIL: could not read the workspace members or the crate table in $DOC" >&2; exit 1; }

ROW_NAMES="$(printf '%s\n' "$CRATE_ROWS" | awk '{ print $1 }')"
for m in $MEMBERS; do
    in_list "$m" "$ROW_NAMES" || fail "workspace member $m has no verdict in $DOC"
done
while read -r name verdict; do
    [[ -z "$name" ]] && continue
    in_list "$name" "$MEMBERS" || fail "$DOC lists $name, which is not a workspace member; delete the row"
    in_list "$verdict" "$VERDICTS" || fail "$name has verdict '$verdict'; one of: $VERDICTS"
done <<< "$CRATE_ROWS"

# --- should-be-verb ceiling ---------------------------------------------------

CEILING="$(grep -o 'SHOULD_BE_VERB_CEILING: usize = [0-9]*' "$TEST" | grep -o '[0-9]*$' || true)"
[[ -n "$CEILING" ]] || { echo "FAIL: could not read SHOULD_BE_VERB_CEILING from $TEST" >&2; exit 1; }
COUNT="$(printf '%s\n' "$CRATE_ROWS" | awk '$2 == "should-be-verb"' | wc -l | tr -d ' ')"
if [[ "$COUNT" -gt "$CEILING" ]]; then
    fail "$COUNT crates are should-be-verb, more than the plan's $CEILING (C-1): write the verbs or list the crate internal with a reason"
fi

# --- service rows vs impress_service_impl! blocks ----------------------------

SERVICE_ROWS="$(block verb-coverage-services | awk -F'|' '/^\| `/ {
    name = $2; gsub(/[` ]/, "", name); print name }')"
[[ -n "$SERVICE_ROWS" ]] || { echo "FAIL: could not read the service table in $DOC" >&2; exit 1; }

# Blocks in real source only: the macro crate's module doc spells one for an
# EchoService that exists nowhere, so `//!` and `///` lines are dropped first.
BLOCK_SERVICES="$(grep -rh -A6 'impress_service_impl! *{' crates/*/src --include='*.rs' \
    | grep -v '^\s*//' | grep -o 'service = [A-Za-z0-9_]*' | awk '{ print $3 }' | sort -u)"
for svc in $BLOCK_SERVICES; do
    k="$(kebab "$svc")"
    in_list "$k" "$SERVICE_ROWS" || fail "service $svc ($k) has an impress_service_impl! block but no row in $DOC (run the census test's dump for the row)"
done
KEBABS="$(for svc in $BLOCK_SERVICES; do kebab "$svc"; done)"
for row in $SERVICE_ROWS; do
    in_list "$row" "$KEBABS" || fail "$DOC has a row for $row, but no impress_service_impl! block under crates/*/src names it; delete the row"
done

if [[ $status -eq 0 ]]; then
    echo "verb coverage: $(printf '%s\n' "$MEMBERS" | wc -l | tr -d ' ') crates with a verdict ($COUNT should-be-verb, ceiling $CEILING), $(printf '%s\n' "$SERVICE_ROWS" | wc -l | tr -d ' ') services with a row"
fi
exit "$status"
