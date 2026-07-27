#!/bin/bash
# Chassis dependency lint (Stage-2 WP-X1, ADR-0021).
#
# PublicationManagerCore is the shared GUI chassis for every impress app —
# any dependency added here ships to ALL of them (blast radius + binary
# size; see the Typst/760MB note in ADR-0018). This lint makes growth a
# reviewed decision: adding a dependency requires editing the allowlist
# below in the same PR.
#
# Renderer hygiene (binding): no Metal/implore renderers, no WebKit-based
# transcript stacks — record "view" tabs render stored CAS artifacts or use
# system frameworks only; heavy surfaces are app-owned CustomSurfaces.

set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="apps/imbib/PublicationManagerCore/Package.swift"

ALLOWED_LOCAL=(
    ../../../packages/ImpressAI
    ../../../packages/ImpressAutomation
    ../../../packages/ImpressEmbeddings
    ../../../packages/ImpressFTUI
    ../../../packages/ImpressHelixCore
    ../../../packages/ImpressKeyboard
    ../../../packages/ImpressKit
    ../../../packages/ImpressLogging
    ../../../packages/ImpressMailStyle
    ../../../packages/ImpressOperationQueue
    ../../../packages/ImpressRustCore
    ../../../packages/ImpressScixCore
    ../../../packages/ImpressSidebar
    ../../../packages/ImpressSmartSearch
    ../../../packages/ImpressSpotlight
    ../../../packages/ImpressStoreKit
    ../../../packages/ImpressSyntaxHighlight
    ../../../packages/ImpressTheme
    ../../../packages/ImpressUndoHistory
    ../../imprint/Packages/ImprintCore
    ../ImbibRustCore
)

ALLOWED_REMOTE=(
    https://github.com/appstefan/HighlightSwift
    https://github.com/evgenyneu/keychain-swift
    https://github.com/gonzalezreal/swift-markdown-ui
    https://github.com/mgriebling/SwiftMath
)

fail=0

actual_local=$(grep -o '\.package(path: "[^"]*"' "$MANIFEST" | sed 's/.*path: "//; s/"$//' | sort)
actual_remote=$(grep -o 'url: "[^"]*"' "$MANIFEST" | sed 's/url: "//; s/"$//' | sort)

for dep in $actual_local; do
    ok=0
    for allowed in "${ALLOWED_LOCAL[@]}"; do
        [[ "$dep" == "$allowed" ]] && ok=1 && break
    done
    if [[ $ok -eq 0 ]]; then
        echo "DISALLOWED local chassis dependency: $dep"
        fail=1
    fi
done

for dep in $actual_remote; do
    ok=0
    for allowed in "${ALLOWED_REMOTE[@]}"; do
        [[ "$dep" == "$allowed" ]] && ok=1 && break
    done
    if [[ $ok -eq 0 ]]; then
        echo "DISALLOWED remote chassis dependency: $dep"
        fail=1
    fi
done

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "PublicationManagerCore gained a dependency not on the chassis"
    echo "allowlist. If intentional, update scripts/check-chassis-deps.sh in"
    echo "the same PR (this is the review gate, not a blocker by fiat)."
    exit 1
fi

echo "chassis deps OK ($(echo "$actual_local" | wc -l | tr -d ' ') local, $(echo "$actual_remote" | wc -l | tr -d ' ') remote)"
