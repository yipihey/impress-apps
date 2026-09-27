#!/usr/bin/env bash
# scripts/check-verb-docs.sh: docs/verbs/*.md is generated, never hand-edited.
#
# Regenerates every page with `cargo run -p impress-capabilities --bin
# gen-verb-docs` (plan-auto-gui-and-self-docs.md, work package G3; findings
# D-1, D-2) and fails when the working tree then differs from what is
# committed — the same "regenerate and diff" shape
# `scripts/check-uniffi-bindings.sh` uses for the Swift bindings.
#
# Usage:
#   scripts/check-verb-docs.sh
#
# CARGO_TARGET_DIR is honored so a caller sharing one build cache (the
# self-hosted lanes; kit.yml's other jobs) does not pay for a second cold
# build of the whole inventory.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Regenerating docs/verbs/ from the linked VerbDescriptor inventory..."
cargo run --quiet -p impress-capabilities --bin gen-verb-docs

if ! git diff --quiet -- docs/verbs; then
    echo
    echo "docs/verbs/ is out of date. Diff:" >&2
    git --no-pager diff -- docs/verbs >&2
    echo
    echo "Run 'cargo run -p impress-capabilities --bin gen-verb-docs' and commit the result." >&2
    exit 1
fi

if [ -n "$(git status --porcelain -- docs/verbs)" ]; then
    echo
    echo "docs/verbs/ has untracked files after regenerating:" >&2
    git status --porcelain -- docs/verbs >&2
    echo
    echo "Run 'cargo run -p impress-capabilities --bin gen-verb-docs', 'git add docs/verbs' and commit." >&2
    exit 1
fi

echo "docs/verbs/ is current."
