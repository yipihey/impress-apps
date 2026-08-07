#!/bin/bash
#
# Pre-push hook: the local mirror of the CI gates that have actually
# turned main red. Staged by cost, each stage path-filtered to the
# changes that can break it:
#
#   1. cargo fmt --all --check          (always; seconds)
#   2. schema-refs lint                 (any .swift/.rs/.json change; ~5-25s)
#   3. chassis dependency lint          (chassis manifests; instant)
#   4. chassis interlock tests          (chassis contract files; minutes —
#      the impel/impart/impress suites that pin visibleSections & URL
#      vocab, which stale-pinned and turned CI red after the Tags rollout)
#   5. dual-platform imbib build        (PMC/iOS/packages; Rule 1, ADR-023)
#
# Install:
#   ln -sf ../../apps/imbib/scripts/pre-push-dual-platform.sh \
#          .git/hooks/pre-push
#
# The hook runs quickly in the common case — a push that touches none of
# the trigger paths runs only the fmt gate.
#
# Escape hatches:
#   SKIP_DUAL_PLATFORM_CHECK=1 git push   # skip EVERYTHING (emergency only)
#   SKIP_INTERLOCK_TESTS=1 git push       # skip stage 4 only
#

set -e

if [ "${SKIP_DUAL_PLATFORM_CHECK:-0}" = "1" ]; then
    echo "pre-push: all checks skipped (SKIP_DUAL_PLATFORM_CHECK=1)"
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
IMBIB_DIR="$REPO_ROOT/apps/imbib/imbib"

# Rust formatting gate: every Rust CI workflow runs `cargo fmt --check`,
# and concurrent sessions pushing unformatted code have repeatedly turned
# main red on it. The check takes seconds; run it on every push.
if command -v cargo >/dev/null 2>&1; then
    echo "pre-push: cargo fmt --all --check"
    if ! (cd "$REPO_ROOT" && cargo fmt --all --check > /dev/null 2>&1); then
        echo "pre-push: BLOCKED — unformatted Rust code. Run: cargo fmt --all"
        exit 1
    fi
fi

# Detect changes since the upstream HEAD. If no upstream, diff against
# the local HEAD~1 as a best-effort fallback.
if git -C "$REPO_ROOT" rev-parse --abbrev-ref @{u} >/dev/null 2>&1; then
    BASE="@{u}"
else
    BASE="HEAD~1"
fi

CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only "$BASE" 2>/dev/null || echo "")

# Schema-refs lint: a reader spelling a ref differently from its writer
# returns zero rows forever, silently (shipped five times). CI runs this
# in the impress-app lane; catch it before it leaves the machine.
if echo "$CHANGED_FILES" | grep -qE '\.(swift|rs)$|^schema-refs\.json|^scripts/check-schema-refs\.sh'; then
    echo "pre-push: schema-refs lint"
    if ! (cd "$REPO_ROOT" && ./scripts/check-schema-refs.sh > /tmp/impress-schema-refs.log 2>&1); then
        cat /tmp/impress-schema-refs.log
        echo "pre-push: BLOCKED — schema-refs drift. Fix the ref spelling or"
        echo "update schema-refs.json in the same commit (root CLAUDE.md §"
        echo "Definition of done — schema refs)."
        exit 1
    fi
fi

# Chassis dependency lint: a dependency added to PMC/ImpressChassis ships
# to every app. CI runs this in the impress-app lane (it red-flagged the
# ImpressOCR addition for days); the manifests are two greps, so run it
# whenever they or the allowlist change.
if echo "$CHANGED_FILES" | grep -qE '^apps/imbib/PublicationManagerCore/Package\.swift|^packages/ImpressChassis/Package\.swift|^scripts/check-chassis-deps\.sh'; then
    echo "pre-push: chassis dependency lint"
    if ! (cd "$REPO_ROOT" && ./scripts/check-chassis-deps.sh); then
        echo "pre-push: BLOCKED — chassis manifest gained a dependency not on"
        echo "the allowlist. If intentional, update scripts/check-chassis-deps.sh"
        echo "in the same commit."
        exit 1
    fi
fi

# Chassis interlock tests: impel/impart/impress pin the shared shell
# contract (visibleSections, URL vocabulary, descriptor capabilities) in
# their unit suites. A PMC-side contract change that forgets to update
# those pins compiles everywhere and fails only in each app's CI lane —
# the exact red the Tags rollout caused in impel-swift. Run the pinning
# suites when the contract files change.
CHASSIS_CONTRACT_RE='^apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Chassis/(AppShellConfiguration|CustomSurface)\.swift|^packages/ImpressChassis/Sources/'
if [ "${SKIP_INTERLOCK_TESTS:-0}" != "1" ] && \
   echo "$CHANGED_FILES" | grep -qE "$CHASSIS_CONTRACT_RE"; then
    echo "pre-push: chassis contract changed — running sibling interlock tests"
    for spec in \
        "impel:impelTests/ImpelChassisFlipTests" \
        "impart:impartTests/ImpartChassisFlipTests" \
        "impress:impressTests/ImpressShellTests"; do
        app="${spec%%:*}"
        only="${spec##*:}"
        app_dir="$REPO_ROOT/apps/$app"
        log="/tmp/impress-interlock-$app.log"
        echo "pre-push:   $only"
        if ! (cd "$app_dir" && xcodebuild \
            -derivedDataPath "$app_dir/.ci-derived" \
            test \
            -project "$app.xcodeproj" \
            -scheme "$app" \
            -configuration Debug \
            -destination 'platform=macOS' \
            -only-testing:"$only" \
            IMPRESS_SKIP_INSTALL=1 \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            > "$log" 2>&1); then
            echo ""
            echo "ERROR: $only failed. See $log"
            grep -E "Test Case.*failed|error:" "$log" | head -10
            echo ""
            echo "The chassis contract moved and $app's pinning suite disagrees."
            echo "Update the pin in apps/$app/Tests/ in the same commit (see"
            echo "docs/chassis-capability-matrix.md), or skip once with"
            echo "SKIP_INTERLOCK_TESTS=1 if the suite itself is what you're fixing."
            exit 1
        fi
    done
    echo "pre-push: interlock tests green"
fi

touches_shared=false
if echo "$CHANGED_FILES" | grep -qE \
    '^apps/imbib/PublicationManagerCore/|^apps/imbib/imbib/imbib-iOS/|^apps/imbib/imbib/project\.yml|^packages/|^apps/imbib/scripts/pre-push-dual-platform\.sh'; then
    touches_shared=true
fi

if [ "$touches_shared" = false ]; then
    echo "pre-push: no shared-core or iOS-target changes; skipping dual-platform build"
    exit 0
fi

echo "pre-push: building both platforms (Rule 1 of ADR-023)..."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "pre-push: xcodegen not installed; install with 'brew install xcodegen'"
    exit 1
fi

pushd "$IMBIB_DIR" >/dev/null

echo "pre-push: regenerating Xcode project"
xcodegen generate >/dev/null

echo "pre-push: building imbib (macOS)"
if ! xcodebuild build \
    -scheme imbib \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    >/tmp/imbib-macos-build.log 2>&1; then
    echo ""
    echo "ERROR: imbib (macOS) build failed. See /tmp/imbib-macos-build.log"
    tail -30 /tmp/imbib-macos-build.log
    popd >/dev/null
    exit 1
fi

echo "pre-push: building imbib-iOS (Simulator)"
if ! xcodebuild build \
    -scheme imbib-iOS \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    >/tmp/imbib-ios-build.log 2>&1; then
    echo ""
    echo "ERROR: imbib-iOS build failed. See /tmp/imbib-ios-build.log"
    echo ""
    echo "Rule 1 of the iOS/macOS parity protocol (ADR-023):"
    echo "  every commit that touches PublicationManagerCore must also"
    echo "  compile the iOS target. Fix the iOS build or add new broken"
    echo "  files to the 'iOS migration debt' excludes block in"
    echo "  apps/imbib/imbib/project.yml before pushing."
    echo ""
    tail -30 /tmp/imbib-ios-build.log
    popd >/dev/null
    exit 1
fi

popd >/dev/null

echo "pre-push: both platforms built successfully"
exit 0
