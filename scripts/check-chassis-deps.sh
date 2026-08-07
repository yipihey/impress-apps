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
#
# TWO MANIFESTS, since Stage 3 item C5 (ADR-0021 D5). The chassis extraction
# began: `packages/ImpressChassis` stopped being a façade over PMC and became
# a real target that PMC depends on and re-exports. So there are now two
# manifests to police, and they are policed to DIFFERENT standards:
#
#   * PMC keeps the historical allowlist. It is imbib's package and carries
#     imbib's stack — Rust cores, Typst, keychain, markdown.
#   * ImpressChassis is allowed NOTHING. It holds the part of the chassis
#     contract that is pure data, and the argument for keeping it that way is
#     the same blast-radius argument above, only sharper: a dependency added
#     to the deepest shared package ships to every app with no app able to
#     opt out. Nothing in it needs more than Foundation and SwiftUI today.
#     If that changes, the allowlist below is where the decision gets made —
#     and "just add it to PMC instead" is usually the right answer, because
#     PMC is one layer up and already carries the weight.

set -euo pipefail
cd "$(dirname "$0")/.."

# --- PublicationManagerCore -------------------------------------------------

PMC_MANIFEST="apps/imbib/PublicationManagerCore/Package.swift"

# Allowlists are newline-delimited strings, not arrays: macOS ships bash 3.2,
# which has no `local -n` nameref, and this lint must run on a stock mac as
# cheaply as it runs in CI.
PMC_ALLOWED_LOCAL="
    ../../../packages/ImpressAI
    ../../../packages/ImpressAutomation
    ../../../packages/ImpressChassis
    ../../../packages/ImpressEmbeddings
    ../../../packages/ImpressFTUI
    ../../../packages/ImpressHelixCore
    ../../../packages/ImpressKeyboard
    ../../../packages/ImpressKit
    ../../../packages/ImpressLogging
    ../../../packages/ImpressMailStyle
    ../../../packages/ImpressOCR
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
"

PMC_ALLOWED_REMOTE="
    https://github.com/appstefan/HighlightSwift
    https://github.com/evgenyneu/keychain-swift
    https://github.com/gonzalezreal/swift-markdown-ui
    https://github.com/mgriebling/SwiftMath
"

# --- ImpressChassis ---------------------------------------------------------

CHASSIS_MANIFEST="packages/ImpressChassis/Package.swift"

# Deliberately empty. See the header.
CHASSIS_ALLOWED_LOCAL=""
CHASSIS_ALLOWED_REMOTE=""

# The extracted package must not depend BACK on PMC — that is the whole point
# of the reversal in C5, and it is the one mistake that would silently restore
# the cycle-shaped façade this replaced (SwiftPM would reject a true cycle, but
# a dependency added here plus the re-export removed from PMC would compile and
# quietly undo the layering).
FORBIDDEN_CHASSIS_SUBSTRINGS="PublicationManagerCore"

fail=0

# check_manifest <label> <manifest> <allowed-local> <allowed-remote>
check_manifest() {
    label="$1"; manifest="$2"; allowed_local="$3"; allowed_remote="$4"

    actual_local=$(grep -o '\.package(path: "[^"]*"' "$manifest" | sed 's/.*path: "//; s/"$//' | sort || true)
    actual_remote=$(grep -o 'url: "[^"]*"' "$manifest" | sed 's/url: "//; s/"$//' | sort || true)

    for dep in $actual_local; do
        ok=0
        for allowed in $allowed_local; do
            [[ "$dep" == "$allowed" ]] && ok=1 && break
        done
        if [[ $ok -eq 0 ]]; then
            echo "DISALLOWED local dependency in $label: $dep"
            fail=1
        fi
    done

    for dep in $actual_remote; do
        ok=0
        for allowed in $allowed_remote; do
            [[ "$dep" == "$allowed" ]] && ok=1 && break
        done
        if [[ $ok -eq 0 ]]; then
            echo "DISALLOWED remote dependency in $label: $dep"
            fail=1
        fi
    done

    n_local=$([[ -z "$actual_local" ]] && echo 0 || echo "$actual_local" | wc -l | tr -d ' ')
    n_remote=$([[ -z "$actual_remote" ]] && echo 0 || echo "$actual_remote" | wc -l | tr -d ' ')
    echo "  $label: $n_local local, $n_remote remote"
}

check_manifest "PublicationManagerCore" "$PMC_MANIFEST" "$PMC_ALLOWED_LOCAL" "$PMC_ALLOWED_REMOTE"
check_manifest "ImpressChassis" "$CHASSIS_MANIFEST" "$CHASSIS_ALLOWED_LOCAL" "$CHASSIS_ALLOWED_REMOTE"

# Declarations only — the manifest's header comment names PMC on purpose (it
# explains which way the arrow points), and a lint that cannot tell prose from
# a dependency is a lint people delete.
chassis_decls=$(grep -v '^\s*//' "$CHASSIS_MANIFEST" | grep -E '\.package\(|\.product\(|dependencies:' || true)

for forbidden in $FORBIDDEN_CHASSIS_SUBSTRINGS; do
    if echo "$chassis_decls" | grep -q "$forbidden"; then
        echo "ImpressChassis must not depend on $forbidden — the arrow points"
        echo "the other way (ADR-0021 D5 / C5): PMC depends on ImpressChassis"
        echo "and re-exports it."
        fail=1
    fi
done

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "A chassis package gained a dependency not on its allowlist. If"
    echo "intentional, update scripts/check-chassis-deps.sh in the same PR"
    echo "(this is the review gate, not a blocker by fiat)."
    exit 1
fi

echo "chassis deps OK"
