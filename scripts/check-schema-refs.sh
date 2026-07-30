#!/bin/bash
# Schema-ref lint — the guard against the silent-empty-query bug class.
#
# The shared impress-core store matches `items.schema_ref` by EXACT EQUALITY
# (`crates/impress-core/src/sql_query.rs`: `conditions.push("schema_ref = ?")`).
# There is no fuzzy match, no version tolerance, no namespace fallback. So a
# reader that spells a ref differently from the writer returns ZERO ROWS, on
# every platform, forever, with no error and no log line. The feature simply
# looks empty, and looks empty in exactly the way "the user has no data yet"
# looks empty.
#
# This has shipped at least five times:
#   * iOS citation picker asked for `bibliography-entry`; imbib writes
#     `imbib/bibliography-entry`. Empty library, 100% of the time.
#   * `/api/manuscripts` read `manuscript-section` items instead of manuscripts.
#   * imprint read `manuscript-section@1.0.0`; both writers spell it bare.
#     Outline, `/api/manuscripts/{id}/sections` and cross-document search were
#     structurally empty regardless of data.
#   * `citation-usage@1.0.0` readers (x4, imprint AND imbib) against a bare
#     `citation-usage` writer.
#   * `crates/impel-taskd/examples/insert_entry.rs` writes
#     `bibliography-entry@1.0.0`, which nothing reads.
#
# Every one is a typo no compiler, test or type could catch, because the ref is
# an opaque string on both sides. So: one canonical spelling per record kind,
# declared once in `schema-refs.json`, and this lint fails on any schema-ref
# string literal anywhere in the tree that isn't one of them.
#
# Deliberately bash + python3 (no cargo, no swift): it must be cheap enough to
# gate every lane, including Swift-only ones that never build the Rust
# workspace. Runs in well under a second.

set -euo pipefail
cd "$(dirname "$0")/.."

exec python3 - "$@" <<'PYTHON'
import json
import os
import re
import sys

ROOT = os.getcwd()
MANIFEST = os.path.join(ROOT, "schema-refs.json")

with open(MANIFEST, encoding="utf-8") as fh:
    manifest = json.load(fh)

canonical = set(manifest["canonical"])
unwritten = manifest["registeredButUnwritten"]
allowlist = set(manifest["literalAllowlist"])
divergences = manifest["knownDivergences"]
diverging = {ref for d in divergences for ref in d["refs"]}

# Refs that may legally appear at a call site. Divergence refs are permitted
# but REPORTED on every run — they are real spellings in live data that
# disagree with each other, and burying them in `canonical` would be exactly
# the silence this lint exists to break.
permitted = canonical | allowlist | diverging

# ---------------------------------------------------------------- file walk

SKIP_DIR_PARTS = (
    "/target/", "/.build/", "/DerivedData/", "/.git/",
    # Sibling agents' git worktrees are separate checkouts of this same repo:
    # linting them reports every finding N+1 times against paths the developer
    # cannot act on.
    "/.claude/",
    # UniFFI-generated bindings are machine-written mirrors of Rust sources
    # that are themselves linted; linting the copies just doubles every hit.
    "/frameworks/", "/generated/",
)

SKIP_FILES = {
    # The manifest's own documentation, and this lint.
    "schema-refs.json",
    "check-schema-refs.sh",
}


def candidate_files():
    for base, dirs, files in os.walk(ROOT):
        rel = base[len(ROOT):] + "/"
        if any(part in rel for part in SKIP_DIR_PARTS):
            dirs[:] = []
            continue
        for name in files:
            if name in SKIP_FILES:
                continue
            if name.endswith((".rs", ".swift")):
                yield os.path.join(base, name)


# ------------------------------------------------------------- extraction
#
# Context-scoped on purpose. A blanket search for `schema: "…"` is WRONG: it
# hits `"schema": "manuscript-bundle-manifest@1.0.0"` inside JSON payloads,
# which is a document's self-describing version tag and never an
# `items.schema_ref`. The leading `(?<!")` on the bare-identifier patterns is
# what separates a Swift/Rust field name from a quoted JSON key.

STR = r'"([^"\\\n]+)"'

SWIFT_PATTERNS = [
    re.compile(r'\bschemaRef:\s*' + STR),
    re.compile(r'\bschemaRef\s*(?:==|!=)\s*' + STR),
    # NOT `schemaRef = "…"`: the only things that assign it are field-NAME
    # constants (`static let schemaRef = "schema_ref"` in the CloudKit codec),
    # which are column names, not refs. Nothing assigns a real ref this way.
    re.compile(r'(?<!")\bschema:\s*' + STR),
    re.compile(r'\bqueryBySchema\(\s*' + STR),
    re.compile(r'\bcountBySchema\(\s*' + STR),
]

# `schemaRefs: ["a", "b"]` needs its own two-stage pass (one match, N refs).
SWIFT_REFS_ARRAY = re.compile(r'\bschemaRefs:\s*\[([^\]]*)\]')

RUST_PATTERNS = [
    re.compile(r'(?<!")\bschema:\s*Some\(\s*' + STR),
    re.compile(r'(?<!")\bschema:\s*' + STR),
    re.compile(r'\bschema\s*(?:==|!=)\s*' + STR),
    re.compile(r'\bschema_ref\s*=\s*' + STR),
    re.compile(r"\bschema_ref\s*=\s*'([^'\n]+)'"),   # SQL string literals
    re.compile(r'\bquery_by_schema\(\s*' + STR),
    re.compile(r'\bcount_by_schema\(\s*' + STR),
    # Named constants: require SCHEMA in the name, or `: &str = "…"` matches
    # every unrelated string constant in the workspace (it caught
    # `"ssh -o BatchMode=yes"` on the first dry run). `_KEY`/`_URI` suffixes
    # are excluded: `LEGACY_SCHEMA_REF_KEY = "legacy_schema_ref"` is a payload
    # KEY name and `STORE_SCHEMAS_URI = "impress://store/schemas"` is an MCP
    # resource URI — neither is a ref.
    re.compile(r'\b[A-Z_]*SCHEMA[A-Z_]*(?<!_KEY)(?<!_URI)\s*:\s*&str\s*=\s*' + STR),
]

QUOTED = re.compile(r'"([^"\\\n]+)"')

findings = []   # (path, lineno, ref)

for path in candidate_files():
    swift = path.endswith(".swift")
    patterns = SWIFT_PATTERNS if swift else RUST_PATTERNS
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except (UnicodeDecodeError, OSError):
        continue
    # Line-local escape hatch for NEGATIVE assertions — a test that proves a
    # wrong ref matches nothing has to name the wrong ref. Deliberately
    # per-line and not a manifest entry: putting `manuscript-section@1.0.0` in
    # a global allowlist would re-legalise the exact bug this lint exists to
    # catch, everywhere, forever. Honoured on the literal's own line or on the
    # comment block immediately above it, because the real call sites wrap.
    marker_armed = False

    for lineno, line in enumerate(lines, 1):
        stripped = line.lstrip()
        is_comment = stripped.startswith(("//", "///", "//!", "*", "#"))

        if "schema-ref-lint:allow" in line:
            marker_armed = True
            if is_comment:
                continue

        # Doc/comment lines describe schemas in prose (including their
        # `@version`), which is legitimate. Only executable text is linted,
        # and a comment does not consume an armed marker.
        if is_comment:
            continue

        if marker_armed:
            marker_armed = False
            continue
        for pattern in patterns:
            for match in pattern.finditer(line):
                findings.append((path, lineno, match.group(1)))
        if swift:
            for match in SWIFT_REFS_ARRAY.finditer(line):
                for ref in QUOTED.findall(match.group(1)):
                    findings.append((path, lineno, ref))

# ------------------------------------------------------------- manifest self-check

errors = []

def base_name(ref):
    return ref.split("@", 1)[0]

by_base = {}
for ref in canonical:
    by_base.setdefault(base_name(ref), []).append(ref)
for base, refs in sorted(by_base.items()):
    if len(refs) > 1 and not set(refs) <= diverging:
        errors.append(
            "manifest: %d spellings of %r (%s) — a kind gets ONE canonical ref, "
            "or the pair goes in knownDivergences with a reason"
            % (len(refs), base, ", ".join(sorted(refs))))

overlap = canonical & set(unwritten)
if overlap:
    errors.append("manifest: %s is in both canonical and registeredButUnwritten"
                  % ", ".join(sorted(overlap)))

# The allowlist must not shadow a real kind. `figure-collection@1.0.0` sitting
# in a global allowlist would let ANY call site query the versioned spelling of
# a real ref and pass — which is the bug, re-legalised. Literals that collide
# with a canonical base name must use the line-local `schema-ref-lint:allow`
# marker instead, so the exemption is visible at the site it applies to.
canonical_bases = {base_name(c) for c in canonical}
for literal in sorted(allowlist):
    if literal not in canonical and base_name(literal) in canonical_bases:
        errors.append(
            "manifest: literalAllowlist entry %r shares a base name with a "
            "canonical ref — a global exemption here would re-legalise the "
            "bug. Delete it and put `schema-ref-lint:allow` on the line "
            "instead." % literal)

# Every registered id must be accounted for as either a usable ref or an
# explicitly-dead one. Without this, adding a schema to `registries` (to keep a
# crate's parity test green) would silently widen nothing and the new kind
# would still trip the call-site check with no hint why.
declared = canonical | set(unwritten)
for crate, ids in sorted(manifest["registries"].items()):
    missing = sorted(set(ids) - declared)
    if missing:
        errors.append(
            "manifest: %s registers %s, absent from both canonical and "
            "registeredButUnwritten" % (crate, ", ".join(missing)))

budget = manifest["knownDivergenceBudget"]
if len(divergences) > budget:
    errors.append(
        "manifest: knownDivergences grew to %d (budget %d). This list is a "
        "RATCHET — it may shrink as divergences are fixed, never grow."
        % (len(divergences), budget))

# ------------------------------------------------------------- call-site check

unknown = [f for f in findings if f[2] not in permitted]

for path, lineno, ref in sorted(unknown):
    rel = os.path.relpath(path, ROOT)
    if ref in unwritten:
        errors.append(
            "%s:%d  schema ref %r is REGISTERED BUT NOTHING WRITES IT — a "
            "query for it returns zero rows forever. %s"
            % (rel, lineno, ref, unwritten[ref]))
    else:
        near = sorted(c for c in permitted if base_name(c) == base_name(ref))
        hint = (" — did you mean %r?" % near[0]) if near else ""
        errors.append("%s:%d  unknown schema ref %r%s" % (rel, lineno, ref, hint))

if errors:
    print("Schema-ref lint FAILED\n")
    for err in errors:
        print("  " + err)
    print("""
The store matches `schema_ref` by EXACT EQUALITY. A ref that is not in
schema-refs.json matches no rows — the surface goes silently empty rather
than erroring, which is why this class of bug survives code review and CI.

To fix:
  * A TYPO (a version suffix the writer doesn't use, a missing `imbib/`
    prefix): correct the literal to the canonical spelling above.
  * A GENUINELY NEW record kind: add it to `canonical` in schema-refs.json,
    in the same PR, naming its writer. The Rust parity tests
    (`crates/*/tests/schema_ref_manifest.rs`) will hold you to the registry.
  * A deliberate NEGATIVE FIXTURE (a test asserting a bad ref is rejected):
    put `schema-ref-lint:allow` on that line (or the comment directly
    above it), or — if the literal cannot be confused with a real ref —
    add it to `literalAllowlist` with the reason.""")
    sys.exit(1)

if divergences:
    print("Known schema-ref divergences (%d/%d budget) — real, unfixed, "
          "and deliberately noisy:" % (len(divergences), budget))
    for d in divergences:
        print("  %-22s %s" % (d["id"], " vs ".join(d["refs"])))
        print("  %-22s %s" % ("", d["why"]))
    print()

print("schema refs OK (%d call sites, %d canonical refs, %d known divergences)"
      % (len(findings), len(canonical), len(divergences)))
PYTHON
