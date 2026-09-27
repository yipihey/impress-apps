#!/bin/bash
# B5 build budget (plan-verb-pipeline-and-transport.md § Build cost).
#
# `run-builds.sh` reduced to the three timed builds plus the llvm-lines loop,
# each divided by the strict verb count. Two halves:
#
#   deterministic — `cargo llvm-lines -p <svc> --lib` for every service crate,
#   summed and divided by the strict verb count. Reproducible for a given
#   toolchain: this is the half `build-budget.json` fails the PR on the day
#   it breaches, with no re-run.
#
#   measured — cold `cargo build -p impress-mcp --timings`, then an
#   imbib-service touch rebuild and an impress-service-core touch rebuild,
#   each divided by the verb count. Noisy (the plan measured ±6% run to run
#   on an idle desktop; a shared runner is worse), so `build-budget.json`
#   only fails a measured breach after one re-run.
#
# Must run with CARGO_TARGET_DIR outside the checkout, like the other CI
# lanes (workspace-rust.yml's persistent `~/ci-cargo-target/...` dirs). Never
# edits Cargo.toml; the two touch files are restored with `git checkout --`
# even on failure.
#
# Usage: CARGO_TARGET_DIR=/somewhere/outside scripts/build-cost.sh
#
# Prints exactly one JSON line to stdout:
#   {commit, toolchain, verbs, macro_lines_per_verb, total_lines_per_verb,
#    cold_ms_per_verb, incr_service_ms_per_verb, incr_core_ms_per_verb,
#    unit_time_sum_s}
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

: "${CARGO_TARGET_DIR:?CARGO_TARGET_DIR must be set, outside the checkout (see the other CI lanes)}"
export CARGO_TARGET_DIR
export CARGO_INCREMENTAL=0

SERVICE_TOUCH=crates/imbib-service/src/lib.rs
CORE_TOUCH=crates/impress-service-core/src/lib.rs

# Restore the touched files no matter how the script exits.
cleanup() {
    git checkout -- "$SERVICE_TOUCH" "$CORE_TOUCH" 2>/dev/null || true
}
trap cleanup EXIT

verbs=$(grep -rhE '^\s*#\[impress_method' crates/*-service/src | wc -l | tr -d ' ')
if [ "${verbs:-0}" -le 0 ]; then
    echo "build-cost.sh: strict verb grep (crates/*-service/src) found 0 verbs — is the tree checked out?" >&2
    exit 1
fi

commit=$(git rev-parse --short HEAD)
toolchain=$(rustc --version | awk '{print $2}')

# Wall time of "$@" in integer milliseconds. Runs to stderr so the timed
# command's own output does not pollute stdout (the one JSON line at the end
# is the only thing this script prints there).
timed_ms() {
    local start end rc
    start=$(date +%s%N)
    "$@" 1>&2
    rc=$?
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
    return "$rc"
}

echo "== build-cost: cold cargo build -p impress-mcp --timings ==" >&2
rm -rf "$CARGO_TARGET_DIR"
mkdir -p "$CARGO_TARGET_DIR"
cold_ms=$(timed_ms cargo build -p impress-mcp --timings) || { echo "cold build failed" >&2; exit 1; }

echo "== build-cost: imbib-service touch rebuild ==" >&2
printf '\n// build-cost probe\n' >> "$SERVICE_TOUCH"
incr_service_ms=$(timed_ms cargo build -p impress-mcp --timings) || { echo "service-touch build failed" >&2; exit 1; }
git checkout -- "$SERVICE_TOUCH"

echo "== build-cost: impress-service-core touch rebuild ==" >&2
printf '\n// build-cost probe\n' >> "$CORE_TOUCH"
incr_core_ms=$(timed_ms cargo build -p impress-mcp --timings) || { echo "core-touch build failed" >&2; exit 1; }
git checkout -- "$CORE_TOUCH"

# Sum the per-unit compile times from cargo's --timings report for the cold
# build. Stable cargo (no --timings=json) only writes the html report, which
# embeds the same data as a `UNIT_DATA = [...]` JS array; parse that instead
# of re-deriving it. Best-effort: a report with a different shape still lets
# the rest of the script run, at the cost of this one field.
unit_time_sum_s=0
timing_html=$(find "$CARGO_TARGET_DIR/cargo-timings" -name 'cargo-timing.html' 2>/dev/null | head -1)
if [ -n "${timing_html:-}" ] && [ -f "$timing_html" ]; then
    unit_time_sum_s=$(python3 -c "
import json, re, sys
try:
    html = open(sys.argv[1]).read()
    m = re.search(r'UNIT_DATA = (\[.*?\]);', html, re.S)
    units = json.loads(m.group(1))
    print(round(sum(u.get('duration', 0) for u in units), 1))
except Exception:
    print(0)
" "$timing_html")
fi

echo "== build-cost: cargo llvm-lines per service crate ==" >&2
command -v cargo-llvm-lines >/dev/null || cargo binstall -y cargo-llvm-lines

macro_lines_total=0
total_lines_total=0
for crate_dir in crates/*-service; do
    [ -f "$crate_dir/Cargo.toml" ] || continue
    crate=$(basename "$crate_dir")
    lines=$(cargo llvm-lines -p "$crate" --lib 2>/dev/null | awk '
        NR<=2 { next }
        # The first data row is llvm-lines own "(TOTAL)"; it is the crate
        # total, not a function, and must not be summed with the rows below.
        index($0, "(TOTAL)") { n = $1; gsub(/,/, "", n); total = n + 0; next }
        {
            n = $1
            gsub(/,/, "", n)
            if (n ~ /^[0-9]+$/) {
                if (index($0, "_invoke") || index($0, "__Impress_") || index($0, "Args")) {
                    macro += n
                }
            }
        }
        END { printf "%d %d\n", macro+0, total+0 }
    ')
    m=$(echo "$lines" | awk '{print $1}')
    t=$(echo "$lines" | awk '{print $2}')
    macro_lines_total=$(( macro_lines_total + m ))
    total_lines_total=$(( total_lines_total + t ))
done

macro_lines_per_verb=$(( macro_lines_total / verbs ))
total_lines_per_verb=$(( total_lines_total / verbs ))
cold_ms_per_verb=$(( cold_ms / verbs ))
incr_service_ms_per_verb=$(( incr_service_ms / verbs ))
incr_core_ms_per_verb=$(( incr_core_ms / verbs ))

printf '{"commit":"%s","toolchain":"%s","verbs":%d,"macro_lines_per_verb":%d,"total_lines_per_verb":%d,"cold_ms_per_verb":%d,"incr_service_ms_per_verb":%d,"incr_core_ms_per_verb":%d,"unit_time_sum_s":%s}\n' \
    "$commit" "$toolchain" "$verbs" "$macro_lines_per_verb" "$total_lines_per_verb" \
    "$cold_ms_per_verb" "$incr_service_ms_per_verb" "$incr_core_ms_per_verb" "$unit_time_sum_s"
