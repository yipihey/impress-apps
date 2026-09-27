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
#     checks cannot disagree;
#   * every `impress_service_impl!` block declares `effects = {` (ADR-0036
#     D1 — the macro refuses a block without one, but a hosted runner should
#     say so before a build does), docs/verb-effects.md lists exactly the
#     verbs docs/verb-safety.md lists (the two marker tables describe one
#     inventory), and every exception row there names a verb in its own
#     table. The effects test in crates/impress-capabilities/tests/effects.rs
#     checks the declarations themselves against the linked inventory.
#   * the internal binding-tell (G6, table 5/A5's rule): no `internal` crate
#     outside an `ffi`/`service-http` role, and not listed in the
#     verb-coverage-internal-bindings table, has a `#[uniffi::export]`,
#     `#[pyfunction]`/`#[pymodule]` or `.route(` under crates/<name>/src —
#     since a binding on an internal crate means its capability reaches an
#     agent already, and so should be a verb or a documented exception.
#
# Usage:
#   scripts/check-verb-coverage.sh
#   scripts/check-verb-coverage.sh --self-test   # feed the binding-tell known fixtures
#
# Written for bash 3.2 (stock macOS): no namerefs, no associative arrays.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DOC="docs/verb-coverage.md"
TEST="crates/impress-capabilities/tests/census.rs"
VERDICTS="verb-crate covered-through internal should-be-verb optional-feature"
BINDING_PATTERN='#\[uniffi::export\]|#\[pyfunction\]|#\[pymodule\]|\.route\('
SELF_TEST=0

for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        --self-test) SELF_TEST=1 ;;
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

# has_binding <src-dir>: true if a real (non-comment) line under <src-dir>
# matches the binding-tell pattern. Pure: the self-test drives it directly on
# fixture directories, not on crates/*/src.
has_binding() {
    [[ -d "$1" ]] || return 1
    grep -rnE "$BINDING_PATTERN" "$1" --include='*.rs' 2>/dev/null \
        | grep -v '^\s*[^:]*:[0-9]*:\s*//' | grep -q .
}

# is_binding_exempt <role> <crate> <allowlist>: true if a binding on this
# internal crate is already accounted for — its role is the binding itself
# (ffi, service-http), or it is named in the verb-coverage-internal-bindings
# table. Pure: the self-test drives it directly.
is_binding_exempt() {
    local role="$1" crate="$2" allowlist="$3"
    [[ "$role" == "ffi" || "$role" == "service-http" ]] && return 0
    in_list "$crate" "$allowlist"
}

if [[ $SELF_TEST -eq 1 ]]; then
    FIXTURES="$(mktemp -d "${TMPDIR:-/tmp}/verb-coverage-selftest.XXXXXX")"
    trap 'rm -rf "$FIXTURES"' EXIT

    mkdir -p "$FIXTURES/uniffi/src" "$FIXTURES/pyfunction/src" "$FIXTURES/route/src" \
        "$FIXTURES/comment-only/src" "$FIXTURES/clean/src"
    cat > "$FIXTURES/uniffi/src/lib.rs" <<'EOF'
#[uniffi::export]
pub fn do_thing() -> i32 { 1 }
EOF
    cat > "$FIXTURES/pyfunction/src/lib.rs" <<'EOF'
#[pyfunction]
fn do_thing(_py: Python<'_>) -> PyResult<i32> { Ok(1) }
EOF
    cat > "$FIXTURES/route/src/lib.rs" <<'EOF'
fn router() -> Router { Router::new().route("/api/thing", get(handler)) }
EOF
    cat > "$FIXTURES/comment-only/src/lib.rs" <<'EOF'
//! Swift bindings are hand-written `#[uniffi::export]` items in the FFI crate.
pub fn do_thing() -> i32 { 1 }
EOF
    cat > "$FIXTURES/clean/src/lib.rs" <<'EOF'
pub fn do_thing() -> i32 { 1 }
EOF

    failures=0
    expect_binding() { # expect_binding <yes|no> <label> <fixture>
        local want="$1" label="$2" got
        if has_binding "$FIXTURES/$3/src"; then got=yes; else got=no; fi
        if [[ "$got" == "$want" ]]; then
            echo "self-test ok: $label ($got)"
        else
            echo "SELF-TEST FAILED: $label: expected $want, got $got" >&2
            failures=$((failures + 1))
        fi
    }
    expect_binding yes "a #[uniffi::export] item is a binding" uniffi
    expect_binding yes "a #[pyfunction] item is a binding" pyfunction
    expect_binding yes "an axum .route( registration is a binding" route
    expect_binding no  "a doc comment naming the attribute is not a binding" comment-only
    expect_binding no  "a plain pub fn is not a binding" clean

    expect_exempt() { # expect_exempt <yes|no> <label> <role> <crate> <allowlist>
        local want="$1" label="$2" got
        if is_binding_exempt "$3" "$4" "$5"; then got=yes; else got=no; fi
        if [[ "$got" == "$want" ]]; then
            echo "self-test ok: $label ($got)"
        else
            echo "SELF-TEST FAILED: $label: expected $want, got $got" >&2
            failures=$((failures + 1))
        fi
    }
    expect_exempt yes "an ffi crate's binding is its role"          ffi           impress-bibtex     ""
    expect_exempt yes "a service-http crate's binding is its role"  service-http  imbib-service-http ""
    expect_exempt yes "a library crate in the allowlist is exempt"  library       impress-helix       "impress-helix impel-tools"
    expect_exempt no  "a library crate NOT in the allowlist fails"  library       impress-newthing    "impress-helix impel-tools"
    expect_exempt no  "a binary crate with an empty allowlist fails" binary      impress-ai-http      ""

    # End-to-end: an internal crate with a real binding and no exemption
    # must fail; the same crate exempted by role must pass.
    if is_binding_exempt library gap-crate "" && has_binding "$FIXTURES/uniffi/src"; then
        echo "SELF-TEST FAILED: end-to-end: an unexempted binding should fail" >&2
        failures=$((failures + 1))
    else
        echo "self-test ok: end-to-end unexempted binding fails (yes)"
    fi
    if is_binding_exempt ffi gap-crate "" && has_binding "$FIXTURES/uniffi/src"; then
        echo "self-test ok: end-to-end ffi-role binding passes (yes)"
    else
        echo "SELF-TEST FAILED: end-to-end: an ffi-role binding should pass" >&2
        failures=$((failures + 1))
    fi

    if [[ $failures -ne 0 ]]; then
        echo "verb-coverage self-test: $failures case(s) did not behave" >&2
        exit 1
    fi
    echo "verb-coverage self-test: every bad binding fails, every exempt one passes"
    exit 0
fi

status=0
fail() { echo "FAIL: $*"; status=1; }

# --- crate rows vs workspace members -----------------------------------------

MEMBERS="$(awk '/^members = \[/ { p = 1; next } p && /^\]/ { p = 0 } p' Cargo.toml \
    | grep -o '"[^"]*"' | tr -d '"' | awk -F/ '{ print $NF }')"
CRATE_ROWS="$(block verb-coverage-crates | awk -F'|' '/^\| `/ {
    name = $2; role = $3; verdict = $4
    gsub(/[` ]/, "", name); gsub(/^ +| +$/, "", role); gsub(/ /, "", verdict)
    print name, role, verdict }')"

[[ -n "$MEMBERS" && -n "$CRATE_ROWS" ]] || { echo "FAIL: could not read the workspace members or the crate table in $DOC" >&2; exit 1; }

ROW_NAMES="$(printf '%s\n' "$CRATE_ROWS" | awk '{ print $1 }')"
for m in $MEMBERS; do
    in_list "$m" "$ROW_NAMES" || fail "workspace member $m has no verdict in $DOC"
done
while read -r name role verdict; do
    [[ -z "$name" ]] && continue
    in_list "$name" "$MEMBERS" || fail "$DOC lists $name, which is not a workspace member; delete the row"
    in_list "$verdict" "$VERDICTS" || fail "$name has verdict '$verdict'; one of: $VERDICTS"
done <<< "$CRATE_ROWS"

# --- should-be-verb ceiling ---------------------------------------------------

CEILING="$(grep -o 'SHOULD_BE_VERB_CEILING: usize = [0-9]*' "$TEST" | grep -o '[0-9]*$' || true)"
[[ -n "$CEILING" ]] || { echo "FAIL: could not read SHOULD_BE_VERB_CEILING from $TEST" >&2; exit 1; }
COUNT="$(printf '%s\n' "$CRATE_ROWS" | awk '$3 == "should-be-verb"' | wc -l | tr -d ' ')"
if [[ "$COUNT" -gt "$CEILING" ]]; then
    fail "$COUNT crates are should-be-verb, more than the plan's $CEILING (C-1): write the verbs or list the crate internal with a reason"
fi

# --- internal binding-tell (G6) ------------------------------------------------

BINDING_ALLOWLIST="$(block verb-coverage-internal-bindings | awk -F'|' '/^\| `/ {
    name = $2; gsub(/[` ]/, "", name); print name }')"
while read -r name role verdict; do
    [[ -z "$name" || "$verdict" != "internal" ]] && continue
    is_binding_exempt "$role" "$name" "$BINDING_ALLOWLIST" && continue
    src="crates/$name/src"
    has_binding "$src" && fail "$name is internal but $src has a #[uniffi::export], #[pyfunction]/#[pymodule] or .route( binding (G6: the tell of table 5/A5) — write the verb, change the verdict, or add $name to $DOC's verb-coverage-internal-bindings table with a reason"
done <<< "$CRATE_ROWS"

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

# --- effects: every block declares, and the two verb tables agree ---------------

EFFECTS_DOC="docs/verb-effects.md"
SAFETY_DOC="docs/verb-safety.md"
doc_block() { # doc_block <file> <marker>
    awk -v b="<!-- $2:begin -->" -v e="<!-- $2:end -->" \
        'index($0, b) { p = 1; next } index($0, e) { p = 0 } p' "$1"
}
verbs_in() { # verbs_in <file> <marker>: the first cell of every row
    doc_block "$1" "$2" | awk -F'|' '/^\| `/ { v = $2; gsub(/[` ]/, "", v); print v }' | sort
}

BLOCK_COUNT="$(grep -rh 'impress_service_impl! *{' crates/*/src --include='*.rs' | grep -vc '^\s*//' || true)"
EFFECTS_COUNT="$(grep -rh -A40 'impress_service_impl! *{' crates/*/src --include='*.rs' | grep -v '^\s*//' | grep -c 'effects = {' || true)"
if [[ "$BLOCK_COUNT" -ne "$EFFECTS_COUNT" ]]; then
    fail "$BLOCK_COUNT impress_service_impl! blocks but $EFFECTS_COUNT declare effects = { … }; every service declares what it touches (ADR-0036 D1)"
fi

SAFETY_VERBS="$(verbs_in "$SAFETY_DOC" verb-safety)"
EFFECTS_VERBS="$(verbs_in "$EFFECTS_DOC" verb-effects)"
[[ -n "$EFFECTS_VERBS" ]] || { echo "FAIL: could not read the verb table in $EFFECTS_DOC" >&2; exit 1; }
for v in $(comm -23 <(printf '%s\n' "$SAFETY_VERBS") <(printf '%s\n' "$EFFECTS_VERBS")); do
    fail "$SAFETY_DOC lists $v but $EFFECTS_DOC has no row for it (run the effects test's dump for the row)"
done
for v in $(comm -13 <(printf '%s\n' "$SAFETY_VERBS") <(printf '%s\n' "$EFFECTS_VERBS")); do
    fail "$EFFECTS_DOC lists $v, which $SAFETY_DOC does not; delete the row or add the verb to both"
done
for v in $(verbs_in "$EFFECTS_DOC" verb-effects-exceptions); do
    in_list "$v" "$EFFECTS_VERBS" || fail "$EFFECTS_DOC's exception table names $v, which its verb table does not"
done
for v in $EFFECTS_VERBS; do
    in_list "${v%%_*}" "$KEBABS" || fail "$EFFECTS_DOC row $v names service ${v%%_*}, which has no impress_service_impl! block"
done

if [[ $status -eq 0 ]]; then
    echo "verb effects: $BLOCK_COUNT services declare, $(printf '%s\n' "$EFFECTS_VERBS" | wc -l | tr -d ' ') verbs in $EFFECTS_DOC ($(verbs_in "$EFFECTS_DOC" verb-effects-exceptions | wc -l | tr -d ' ') exceptions)"
    echo "verb coverage: $(printf '%s\n' "$MEMBERS" | wc -l | tr -d ' ') crates with a verdict ($COUNT should-be-verb, ceiling $CEILING), $(printf '%s\n' "$SERVICE_ROWS" | wc -l | tr -d ' ') services with a row"
fi
exit "$status"
