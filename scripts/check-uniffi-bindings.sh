#!/bin/bash
# UniFFI binding staleness lint — the guard against committed Swift bindings
# drifting behind the Rust they bind.
#
# Every app in the suite compiles against a COMMITTED copy of the Swift that
# uniffi-bindgen generates. Nothing regenerates it at build time: it is a
# checked-in source file, refreshed only when a human runs the crate's
# build-xcframework.sh. So a `#[uniffi::export]` added without that rebuild
# leaves the Rust and the Swift describing different APIs.
#
# That happened on 2026-09-07. Four commits (e2ad2f31, 7c86469b, 23765bc5,
# 29f99298) added 11 exports to crates/imbib-core without regenerating
# apps/imbib/ImbibRustCore/.../imbib_core.swift. PublicationManagerCore stopped
# compiling outright — `value of type 'ImbibStore' has no member
# 'countPublicationsWithLocalPdf'` — because a caller had already been written
# against the new Rust.
#
# Two distinct failure modes, worth keeping straight:
#   * Export ADDITIONS (the common case) only add checksum assertions, so the
#     app does not crash at launch — it fails to BUILD, and only once some
#     Swift actually calls the new function. Until then the drift is silent.
#   * Signature CHANGES to an existing export move its checksum, and that is
#     the launch-time "UniFFI API checksum mismatch" crash.
# This lint catches the first class, which is the one that accumulates quietly.
#
# What it does NOT do: rebuild anything. It is a name-level check —
# camelCase every exported `pub fn` and assert a matching `func` exists in the
# committed binding. That is deliberately cheap (well under a second, no cargo,
# no Xcode), because the full regenerate-and-diff guard in imbib-rust.yml runs
# only on `push: [main]` — the `pull_request` trigger was removed 2026-07-28
# since that lane is self-hosted and this repo is public. A post-merge detector
# structurally cannot block a branch; this can, on a dev machine and in any
# hosted lane.
#
# It will not notice a changed signature, a renamed type, or a removed export.
# For that, run the crate's build-xcframework.sh and diff. See also
# `--list`, which prints the export inventory it derived.
#
# Usage:
#   scripts/check-uniffi-bindings.sh            # all crates
#   scripts/check-uniffi-bindings.sh imbib-core # named crates only
#   scripts/check-uniffi-bindings.sh --list     # inventory, no assertions

set -euo pipefail
cd "$(dirname "$0")/.."

exec python3 - "$@" <<'PYTHON'
import os
import re
import sys

ROOT = os.getcwd()

# crate -> committed binding(s). A crate with two entries must keep them
# identical.
#
# imprint used to be such a crate — the same generated file in the app-local
# package AND in the SPM package — and the two drifted for six commits, so
# 95d4c69 deleted the copy under `Packages/ImprintCore` and made `ImprintCore`
# re-export `ImprintRustCore` instead. One committed binding, one place to
# regenerate. A second entry here would now demand back the duplicate that
# change removed.
BINDINGS = {
    "imbib-core": ["apps/imbib/ImbibRustCore/Sources/ImbibRustCore/imbib_core.swift"],
    "imprint-core": [
        "apps/imprint/ImprintRustCore/Sources/ImprintRustCore/imprint_core.swift",
    ],
    "implore-core": ["apps/implore/ImploreRustCore/Sources/ImploreRustCore/implore_core.swift"],
    "impel-tools": ["apps/impel/Packages/CounselEngine/Sources/ImpelToolsFFI/impel_tools.swift"],
    "impress-store-ffi": ["packages/ImpressRustCore/Sources/ImpressRustCore/impress_store_ffi.swift"],
    "scix-client-ffi": ["packages/ImpressScixCore/Sources/ImpressScixCore/scix_client_ffi.swift"],
    "impress-helix": ["packages/ImpressHelixCore/Sources/ImpressHelixCore/impress_helix.swift"],
    # impart-core builds an xcframework but commits no binding (it has no
    # exports yet). Listed so a future export is a KeyError here, not silence.
    "impart-core": [],
}

# Features under which the committed bindings are generated. An export gated on
# anything else (imprint's `compile_latex_tectonic` behind `tectonic-render`)
# is correctly absent from the committed file, so it is not a finding.
BINDING_FEATURES = {"native", "uniffi"}

EXPORT_RE = re.compile(r'#\[\s*(?:cfg_attr\s*\(\s*feature\s*=\s*"[^"]*"\s*,\s*)?uniffi::export\b')
CONSTRUCTOR_RE = re.compile(r'#\[\s*(?:cfg_attr\s*\(\s*feature\s*=\s*"[^"]*"\s*,\s*)?uniffi::constructor\b')
CFG_RE = re.compile(r'#\[\s*cfg\s*\(')
FEATURE_RE = re.compile(r'feature\s*=\s*"([^"]+)"')
IMPL_RE = re.compile(r'^\s*(?:unsafe\s+)?impl\b')
FN_RE = re.compile(r'^\s*pub\s+(?:async\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)')
ATTR_OR_DOC_RE = re.compile(r'^\s*(#\[|//|/\*|\*)')


def camel(name):
    """uniffi's snake_case -> lowerCamelCase for function names."""
    head, *rest = name.split("_")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)


def gating_features(lines, idx):
    """Features named by #[cfg(...)] attributes attached to the item at idx.

    Walks backwards over the contiguous attribute/doc-comment block above the
    export, which is where the gate sits (`#[cfg(...)]` then `#[uniffi::export]`).
    """
    feats = set()
    i = idx - 1
    while i >= 0 and ATTR_OR_DOC_RE.match(lines[i]):
        if CFG_RE.search(lines[i]):
            feats.update(FEATURE_RE.findall(lines[i]))
        i -= 1
    return feats


def exported_fns(path):
    """[(fn_name, line_no)] for every function this file exports over FFI."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    found = []
    for idx, line in enumerate(lines):
        if not EXPORT_RE.search(line):
            continue
        # `#[cfg_attr(feature = "native", uniffi::export)]` gates on its own
        # feature; a separate `#[cfg(...)]` above gates the whole item.
        feats = gating_features(lines, idx) | set(FEATURE_RE.findall(line))
        if feats - BINDING_FEATURES:
            continue  # e.g. tectonic-render: correctly absent from the binding

        # Skip forward past any remaining attributes/docs to the item itself.
        j = idx + 1
        while j < len(lines) and ATTR_OR_DOC_RE.match(lines[j]):
            j += 1
        if j >= len(lines):
            continue

        if IMPL_RE.match(lines[j]):
            found.extend(impl_block_fns(lines, j))
        else:
            m = FN_RE.match(lines[j])
            if m:
                found.append((m.group(1), j + 1))
    return found


def impl_block_fns(lines, start):
    """`pub fn`s declared directly in the impl block opening at `start`.

    Brace-depth tracked so nested items (a helper `fn` inside a method body)
    are not mistaken for methods. Constructors are skipped: uniffi surfaces
    them as Swift initializers, so `open` is `init(path:)`, never `func open`.
    """
    out = []
    depth = 0
    opened = False
    i = start
    while i < len(lines):
        line = lines[i]
        if opened and depth == 1:
            m = FN_RE.match(line)
            if m and not any(
                CONSTRUCTOR_RE.search(lines[k])
                for k in range(max(0, i - 6), i)
                if ATTR_OR_DOC_RE.match(lines[k])
            ):
                out.append((m.group(1), i + 1))
        # Strip line comments and string/char literals before counting braces.
        code = re.sub(r'//.*$', '', line)
        code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)
        code = re.sub(r"'(?:[^'\\]|\\.)'", "''", code)
        for ch in code:
            if ch == "{":
                depth += 1
                opened = True
            elif ch == "}":
                depth -= 1
                if opened and depth == 0:
                    return out
        i += 1
    return out


args = [a for a in sys.argv[1:] if not a.startswith("-")]
list_only = "--list" in sys.argv[1:]
crates = args or sorted(BINDINGS)

unknown = [c for c in crates if c not in BINDINGS]
if unknown:
    sys.exit(f"unknown crate(s): {', '.join(unknown)}\nknown: {', '.join(sorted(BINDINGS))}")

failures = []
checked = 0

for crate in crates:
    src = os.path.join(ROOT, "crates", crate, "src")
    if not os.path.isdir(src):
        failures.append(f"{crate}: crates/{crate}/src does not exist")
        continue

    exports = {}
    for dirpath, _, filenames in os.walk(src):
        for fn in sorted(filenames):
            if not fn.endswith(".rs"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, ROOT)
            for name, line in exported_fns(full):
                exports.setdefault(camel(name), (rel, line, name))

    paths = BINDINGS[crate]
    if not paths:
        if exports:
            failures.append(
                f"{crate}: has {len(exports)} uniffi export(s) but no committed binding is "
                f"registered in scripts/check-uniffi-bindings.sh. Add its path to BINDINGS "
                f"(and a sync step to crates/{crate}/build-xcframework.sh)."
            )
        continue

    if list_only:
        print(f"{crate}: {len(exports)} exported fn(s) -> {paths[0]}")
        for camel_name in sorted(exports):
            print(f"    {camel_name}")
        continue

    for path in paths:
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full):
            failures.append(f"{crate}: committed binding missing: {path}")
            continue
        with open(full, encoding="utf-8") as fh:
            swift = fh.read()
        declared = set(re.findall(r'\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)', swift))
        missing = sorted(set(exports) - declared)
        checked += 1
        if missing:
            detail = "\n".join(
                f"      {n}  (crates: {exports[n][0]}:{exports[n][1]} — pub fn {exports[n][2]})"
                for n in missing
            )
            failures.append(
                f"{crate}: {len(missing)} export(s) missing from {path}:\n{detail}"
            )

    # Two committed copies of one generated file must not diverge.
    if len(paths) > 1 and all(os.path.isfile(os.path.join(ROOT, p)) for p in paths):
        blobs = [open(os.path.join(ROOT, p), encoding="utf-8").read() for p in paths]
        if any(b != blobs[0] for b in blobs[1:]):
            failures.append(
                f"{crate}: committed copies differ from each other:\n      "
                + "\n      ".join(paths)
                + "\n      They are the same generated file and must stay byte-identical."
            )

if list_only:
    sys.exit(0)

if failures:
    print("UniFFI binding staleness lint FAILED\n", file=sys.stderr)
    for f in failures:
        print(f"  {f}\n", file=sys.stderr)
    print(
        "The committed Swift bindings are behind the Rust they bind. Regenerate:\n"
        "  crates/<crate>/build-xcframework.sh          # or, for a fast local pass:\n"
        "  ./scripts/build-xcframeworks.sh --fast <crate>\n"
        "then commit the refreshed .swift alongside the Rust change.\n"
        "\n"
        "NOTE: uniffi-bindgen auto-applies swiftformat when it is on PATH, which\n"
        "reformats the output (`if cond` vs `if (cond)`) away from the raw form CI\n"
        "compares against. If you have swiftformat installed, take it off PATH for\n"
        "the regeneration or expect a large whitespace-only diff.\n"
        "\n"
        "Judge the result by declarations gained and lost, not by diffstat:\n"
        "uniffi-bindgen reorders freely (the 2026-09-07 imbib catch-up was\n"
        "1,125 insertions / 166 deletions and lost zero declarations).",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"uniffi bindings: {checked} committed binding(s) match their crate's exports")
PYTHON
