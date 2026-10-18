#!/usr/bin/env bash
# imbib's, imprint's and implore's App Intents are generated from the verb inventory (koine
# docs/plan-koine-trust.md TR-D14) and committed. Regenerate them and fail when
# the committed files are stale.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DIRS=(
    apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/VerbIntents
    apps/imprint/Shared/VerbIntents
    apps/implore/Implore/Sources/VerbIntents
)
cargo run --quiet -p impress-capabilities --bin gen-app-intents
if ! git diff --quiet -- "${DIRS[@]}" || [ -n "$(git status --porcelain -- "${DIRS[@]}")" ]; then
    echo "the generated App Intents are out of date:" >&2
    git status --porcelain -- "${DIRS[@]}" >&2
    echo "Run 'cargo run -p impress-capabilities --bin gen-app-intents' and commit the result." >&2
    exit 1
fi
echo "app intents: the generated files match the inventory"
