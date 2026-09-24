#!/usr/bin/env bash
# scripts/check-kit-deps.sh: pins ADR-0033 D7's dependency line.
#
# D7: "no kit crate depends on impress-core's domain modules." The kit (the
# layout + surface layer) is meant to be able to leave this repository as its
# own package, and docs/kit-manifest.md says what that takes. This script is
# the dependency half of that claim. scripts/check-kit-standalone.sh is the
# compile half.
#
# The kit crate set is NOT listed here. It is read from the table between the
# `kit-crates` markers in docs/kit-manifest.md, so the document and the check
# cannot drift. Each crate has a tier:
#
#   pure   may reach no workspace crate outside the kit, impress-core included.
#   store  may also reach impress-core (the one allowed reach), with features
#          limited to the `kit-store-features` block (sqlite, required;
#          schema; collab). D7 allows this "until the store trait itself is
#          generic". cargo tree cannot tell a store import from a domain import
#          in the same crate, so this pins WHO may reach impress-core and WITH
#          WHAT FEATURES. Keeping the imports to the store is left to review.
#
# Trees are taken with `--target all`, so the answer is the same on a Linux
# runner as on a Mac: a platform-gated dependency counts everywhere.
#
# Any other workspace crate a kit crate reaches through normal dependencies is a
# failure, named with its `cargo tree -i` path. A reach into a domain core
# (imbib-*, imprint-*, implore-*, impart-*, impel-*) is reported as the
# plan's ask-first case. A reach listed under the manifest's
# `kit-open-findings` block prints KNOWN VIOLATION instead, and fails if it
# changes in either direction (grows, or goes stale). --strict fails on it too.
#
# Usage:
#   scripts/check-kit-deps.sh              the check
#   scripts/check-kit-deps.sh --strict     open findings fail as well
#   scripts/check-kit-deps.sh --self-test  feed the classifier known-bad trees
#                                          and assert it fails on each, so a
#                                          check that can no longer fail is caught
#
# Written for bash 3.2 (stock macOS): no namerefs, no associative arrays, and
# no "${empty[@]}" under `set -u`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# cargo tree builds nothing, but honour a caller's target dir and otherwise use
# the workspace's own. This used to default to /home/user/impress-apps/target,
# a Linux path, so on a Mac the script depended on the variable being set.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"

STRICT=0
SELF_TEST=0
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        --self-test) SELF_TEST=1 ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

MANIFEST="docs/kit-manifest.md"
REACH="impress-core"
DOMAIN_RE='^(imbib|imprint|implore|impart|impel)(-|$)'

manifest_block() {
    awk -v b="<!-- $1:begin -->" -v e="<!-- $1:end -->" \
        'index($0, b) { p = 1; next } index($0, e) { p = 0 } p' "$MANIFEST"
}

# "name tier" per line, from the table rows (first two backticked/plain cells).
KIT_TABLE="$(manifest_block kit-crates | awk -F'|' '/^\| `/ {
    name = $2; tier = $3
    gsub(/[` ]/, "", name); gsub(/ /, "", tier)
    print name, tier }')"
KIT_NAMES="$(printf '%s\n' "$KIT_TABLE" | awk '{ print $1 }')"
STORE_FEATURES="$(manifest_block kit-store-features | grep -o '`[a-z_-]*`' | tr -d '`' | tr '\n' ' ')"
REQUIRED_FEATURES="$(manifest_block kit-store-features | grep -o '`[a-z_-]*` (required)' | grep -o '`[a-z_-]*`' | tr -d '`' | tr '\n' ' ')"
# "crate dep dep ..." per line.
OPEN_FINDINGS="$(manifest_block kit-open-findings | awk '/^- `/ {
    line = $0; gsub(/[`:]/, "", line); sub(/^- /, "", line); print line }')"

if [[ -z "$KIT_NAMES" || -z "$STORE_FEATURES" ]]; then
    echo "FAIL: could not read the kit crate table or the store features from $MANIFEST" >&2
    exit 1
fi

# impress-core's declared features, so implicit optional-dependency names that
# cargo tree also prints (rusqlite, schemars) are not mistaken for features.
core_declared_features() {
    awk '/^\[features\]/ { p = 1; next } /^\[/ { p = 0 }
         p && /^[a-z_-]+ *=/ { sub(/ *=.*/, ""); print }' crates/impress-core/Cargo.toml | tr '\n' ' '
}
CORE_DECLARED="$(core_declared_features)"

in_list() { # in_list <word> <space/newline separated list>
    local w="$1" x
    for x in $2; do [[ "$x" == "$w" ]] && return 0; done
    return 1
}

findings_for() {
    printf '%s\n' "$OPEN_FINDINGS" | awk -v c="$1" '$1 == c { $1 = ""; print }'
}

# classify <crate> <tier> <deps> <open-findings>
#   <deps>: newline-separated "name|features" for every workspace-internal crate
#   in the crate's normal dependency tree.
# Prints one line per problem; sets OFFENDERS to the deps whose path should be
# shown; returns 1 on any failure. Pure: the self-test drives it directly.
OFFENDERS=""
classify() {
    local crate="$1" tier="$2" deps="$3" findings="$4"
    local status=0 name feats f seen_findings="" line
    OFFENDERS=""

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name="${line%%|*}"
        feats="${line#*|}"
        [[ "$name" == "$crate" ]] && continue
        in_list "$name" "$KIT_NAMES" && continue

        if [[ "$name" == "$REACH" && "$tier" == "store" ]]; then
            for f in $(printf '%s' "$feats" | tr ',' ' '); do
                [[ "$f" == "default" ]] && continue
                in_list "$f" "$CORE_DECLARED" || continue
                if ! in_list "$f" "$STORE_FEATURES"; then
                    echo "FAIL: $crate enables impress-core feature '$f'; a kit crate may enable only: $STORE_FEATURES(docs/kit-manifest.md)."
                    OFFENDERS="$OFFENDERS $name"
                    status=1
                fi
            done
            for f in $REQUIRED_FEATURES; do
                if ! in_list "$f" "$(printf '%s' "$feats" | tr ',' ' ')"; then
                    echo "FAIL: $crate reaches impress-core without its '$f' feature; the kit's one allowed reach is the store."
                    OFFENDERS="$OFFENDERS $name"
                    status=1
                fi
            done
            continue
        fi

        if in_list "$name" "$findings"; then
            seen_findings="$seen_findings $name"
            continue
        fi

        if [[ "$name" =~ $DOMAIN_RE ]]; then
            echo "FAIL: $crate reaches $name, a domain core. ASK FIRST (plan-wave-6 § Ask first: 'a kit crate on a domain core'); this is not a dependency to allowlist."
        elif [[ "$name" == "$REACH" ]]; then
            echo "FAIL: $crate reaches impress-core, but it is a pure-tier kit crate (ADR-0033 D7: only the store tier may, and only for the store)."
        else
            echo "FAIL: $crate reaches $name, which is outside the kit. Add it to the kit-crates table in docs/kit-manifest.md with a reason, or remove the dependency."
        fi
        OFFENDERS="$OFFENDERS $name"
        status=1
    done <<< "$deps"

    local want
    for want in $findings; do
        if ! in_list "$want" "$seen_findings"; then
            echo "FAIL: docs/kit-manifest.md lists $crate -> $want as an open finding, but $crate no longer reaches it. Remove the stale entry."
            status=1
        fi
    done
    if [[ -n "${seen_findings// /}" ]]; then
        echo "KNOWN VIOLATION (open finding, ask-first, docs/kit-manifest.md):$seen_findings reached by $crate"
        [[ $STRICT -eq 1 ]] && status=1
    fi
    return "$status"
}

# --- self-test ---------------------------------------------------------------

if [[ $SELF_TEST -eq 1 ]]; then
    CORE_DECLARED="default sqlite schema collab domain-extra"
    failures=0
    expect() { # expect <ok|fail> <label> <crate> <tier> <deps> [findings]
        local want="$1" label="$2" got
        if classify "$3" "$4" "$5" "${6:-}" > /dev/null; then got=ok; else got=fail; fi
        if [[ "$got" == "$want" ]]; then
            echo "self-test ok: $label ($got)"
        else
            echo "SELF-TEST FAILED: $label: expected $want, got $got" >&2
            failures=$((failures + 1))
        fi
    }
    expect ok   "pure crate inside the kit"          impress-layout pure "impress-pane-query|default"
    expect fail "pure crate reaching impress-core"   impress-layout pure "impress-core|default"
    expect ok   "store crate on the store"           impress-layout-service store "impress-core|default,rusqlite,schema,schemars,sqlite"
    expect fail "store crate without sqlite"         impress-layout-service store "impress-core|default,schema"
    expect fail "store crate, disallowed feature"    impress-layout-service store "impress-core|sqlite,domain-extra"
    expect fail "kit crate on a domain core"         impress-surface-service store "imbib-core|default"
    expect fail "kit crate on impel-*"               impress-surface pure "impel-core|"
    expect fail "kit crate on a non-kit crate"       impress-layout pure "impress-tags|"
    expect ok   "open finding, exact"                impress-store-ffi store "impress-ai|
impel-core|" "impress-ai impel-core"
    STRICT=1
    expect fail "open finding under --strict"        impress-store-ffi store "impress-ai|" "impress-ai"
    STRICT=0
    expect fail "open finding grew"                  impress-store-ffi store "impress-ai|
imbib-core|" "impress-ai"
    expect fail "open finding went stale"            impress-store-ffi store "impress-core|sqlite" "impress-ai"
    if [[ $failures -ne 0 ]]; then
        echo "kit-deps self-test: $failures case(s) did not behave" >&2
        exit 1
    fi
    echo "kit-deps self-test: every bad tree fails, every good tree passes"
    exit 0
fi

# --- the check ---------------------------------------------------------------

status=0
report_file="$(mktemp "${TMPDIR:-/tmp}/kit-deps.XXXXXX")"
trap 'rm -f "$report_file"' EXIT
echo "kit crates (docs/kit-manifest.md): $(printf '%s ' $KIT_NAMES)"
echo "allowed reach: $REACH, features: $STORE_FEATURES(required: $REQUIRED_FEATURES)"

while read -r crate tier; do
    [[ -z "$crate" ]] && continue
    if [[ ! -f "crates/$crate/Cargo.toml" ]]; then
        echo "FAIL: docs/kit-manifest.md lists $crate, but crates/$crate does not exist" >&2
        status=1
        continue
    fi
    if [[ "$tier" != "pure" && "$tier" != "store" ]]; then
        echo "FAIL: $crate has tier '$tier' in docs/kit-manifest.md; expected pure or store" >&2
        status=1
        continue
    fi

    tree_output="$(cargo -q tree -p "$crate" --target all -e normal --prefix none -f '{p}|{f}' 2>&1)" || {
        echo "FAIL: 'cargo tree -p $crate' errored:" >&2
        echo "$tree_output" >&2
        status=1
        continue
    }

    # Workspace-internal crates are the ones with a path under this checkout.
    deps="$(printf '%s\n' "$tree_output" | grep -F "($ROOT/" | sed 's/ (\*)$//' \
        | awk -F'|' '{ split($1, a, " "); print a[1] "|" $2 }' | sort -u)"

    if classify "$crate" "$tier" "$deps" "$(findings_for "$crate")" > "$report_file"; then
        cat "$report_file"
        note=""
        grep -q '^KNOWN VIOLATION' "$report_file" && note=", apart from the open finding above"
        reach=""
        if printf '%s\n' "$deps" | grep -q "^$REACH|"; then
            reach=" (reaches impress-core: $(printf '%s\n' "$deps" | grep "^$REACH|" | cut -d'|' -f2))"
        fi
        echo "ok: $crate [$tier]$reach$note"
    else
        cat "$report_file" >&2
        # Domain cores and impress-core first: a reach into imbib-core drags a
        # dozen crates behind it, and the one to fix is the first edge.
        offenders="$(printf '%s\n' $OFFENDERS | sort -u | awk -v re="$DOMAIN_RE" -v r="$REACH" \
            '{ k = ($0 ~ re || $0 == r) ? 0 : 1; print k, $0 }' | sort | cut -d' ' -f2)"
        shown=0
        for off in $offenders; do
            if [[ $shown -ge 3 ]]; then
                echo "  ($(( $(printf '%s\n' $offenders | wc -l) - shown )) more; cargo tree -e normal -p $crate -i <crate> for each)" >&2
                break
            fi
            echo "  path (cargo tree -e normal -p $crate -i $off):" >&2
            cargo -q tree --target all -e normal -p "$crate" -i "$off" 2>&1 | sed 's/^/    /' >&2 || true
            shown=$((shown + 1))
        done
        status=1
    fi
done <<< "$KIT_TABLE"

if [[ $status -ne 0 ]]; then
    echo
    echo "kit-deps check FAILED: a kit crate reaches past ADR-0033 D7's line (see docs/kit-manifest.md)." >&2
    exit 1
fi
echo "kit deps OK"
