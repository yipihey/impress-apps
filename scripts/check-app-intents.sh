#!/usr/bin/env bash
# imbib's App Intents are generated from the verb inventory (koine
# docs/plan-koine-trust.md TR-D14) and committed. Regenerate them and fail when
# the committed files are stale.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DIR=apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Generated/AppIntents
cargo run --quiet -p impress-capabilities --bin gen-app-intents
if ! git diff --quiet -- "$DIR" || [ -n "$(git status --porcelain -- "$DIR")" ]; then
    echo "imbib's generated App Intents are out of date:" >&2
    git status --porcelain -- "$DIR" >&2
    echo "Run 'cargo run -p impress-capabilities --bin gen-app-intents' and commit the result." >&2
    exit 1
fi
echo "app intents: imbib's generated files match the inventory"
