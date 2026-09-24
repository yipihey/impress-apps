#!/bin/bash
# Kit package dependency lint (plan wave 6 W6; ADR-0033 D7).
#
# The layout + surface layer is a kit that can leave this repository: the
# Swift half is `packages/ImpressLayout` (the layout host, moved out of
# PublicationManagerCore) and `packages/ImpressSurface` (the surface
# renderer). Both may depend on the five kit-grade packages and on each
# other, and on nothing else:
#
#   ImpressRustCore   the UniFFI binding (SharedStore, SharedLayout, SharedSurface)
#   ImpressKeyboard   `.keyboardGuarded`, the h/l grammar
#   ImpressTheme      colour helpers
#   ImpressLogging    the three-point trace
#   ImpressSurface    (ImpressLayout only) the RenderTree renderer
#
# Not PublicationManagerCore, not ImpressAutomation (it pulls ImpressKit), not
# ImpressKit, MarkdownUI or an app core. A host that wants more hands it in:
# view-kind factories, `SurfaceHooks`, `LayoutHostServices`. The Rust half is
# pinned by `scripts/check-kit-deps.sh`; this is the same line in Swift.
#
# The pattern is `check-chassis-deps.sh`'s: every `.package(path:)` and
# `url:` in the manifest must be on the allowlist, and adding one is a
# reviewed edit to this file in the same PR.

set -euo pipefail
cd "$(dirname "$0")/.."

# Newline-delimited, not arrays: macOS ships bash 3.2 (see check-chassis-deps.sh).
KIT_GRADE="
    ../ImpressRustCore
    ../ImpressKeyboard
    ../ImpressTheme
    ../ImpressLogging
"

LAYOUT_MANIFEST="packages/ImpressLayout/Package.swift"
LAYOUT_ALLOWED_LOCAL="$KIT_GRADE
    ../ImpressSurface
"

SURFACE_MANIFEST="packages/ImpressSurface/Package.swift"
SURFACE_ALLOWED_LOCAL="$KIT_GRADE
    ../ImpressLayout
"

# No remote package is kit-grade today.
ALLOWED_REMOTE=""

fail=0

# check_manifest <label> <manifest> <allowed-local>
check_manifest() {
    label="$1"; manifest="$2"; allowed_local="$3"

    if [[ ! -f "$manifest" ]]; then
        echo "MISSING manifest for $label: $manifest"
        fail=1
        return
    fi

    # Declarations only: a comment that names a forbidden package (both
    # manifests explain what they do NOT depend on) is prose, not a dependency.
    decls=$(grep -v '^\s*//' "$manifest")

    actual_local=$(echo "$decls" | grep -o '\.package(path: "[^"]*"' | sed 's/.*path: "//; s/"$//' | sort || true)
    actual_remote=$(echo "$decls" | grep -o 'url: "[^"]*"' | sed 's/url: "//; s/"$//' | sort || true)

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
        for allowed in $ALLOWED_REMOTE; do
            [[ "$dep" == "$allowed" ]] && ok=1 && break
        done
        if [[ $ok -eq 0 ]]; then
            echo "DISALLOWED remote dependency in $label: $dep"
            fail=1
        fi
    done

    # A product or target dependency naming a package the manifest never
    # declared cannot resolve, so the package list above is the whole graph —
    # except for the one reach that would restore the cycle this kit exists
    # to break, which is worth naming on its own.
    if echo "$decls" | grep -q 'PublicationManagerCore'; then
        echo "$label must not depend on PublicationManagerCore — the arrow points"
        echo "the other way: PMC depends on the kit and registers its view kinds."
        fail=1
    fi

    n_local=$([[ -z "$actual_local" ]] && echo 0 || echo "$actual_local" | wc -l | tr -d ' ')
    n_remote=$([[ -z "$actual_remote" ]] && echo 0 || echo "$actual_remote" | wc -l | tr -d ' ')
    echo "  $label: $n_local local, $n_remote remote"
}

check_manifest "ImpressLayout" "$LAYOUT_MANIFEST" "$LAYOUT_ALLOWED_LOCAL"
check_manifest "ImpressSurface" "$SURFACE_MANIFEST" "$SURFACE_ALLOWED_LOCAL"

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "A kit package gained a dependency that is not kit-grade. The kit is"
    echo "ImpressRustCore, ImpressKeyboard, ImpressTheme, ImpressLogging and"
    echo "ImpressSurface (ADR-0033 D7). Invert the dependency (a closure or"
    echo "protocol the kit declares and the host supplies) or, if the package"
    echo "really is kit-grade, add it here in the same PR — the review gate."
    exit 1
fi

echo "kit packages OK"
