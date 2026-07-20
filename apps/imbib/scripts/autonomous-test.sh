#!/bin/bash
#
# No-human regression gate for imbib.
#
# The default path avoids launching the app, simulating user input, or relying
# on Accessibility permissions. Use ui-smoke only when you explicitly want the
# slower XCUITest layer.

set -euo pipefail

MODE="${1:-quick}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
IMBIB_DIR="$REPO_ROOT/apps/imbib"
CORE_DIR="$IMBIB_DIR/PublicationManagerCore"
XCODE_DIR="$IMBIB_DIR/imbib"
XCODE_PROJECT="$XCODE_DIR/imbib.xcodeproj"

LOG_ROOT="${IMBIB_AUTONOMOUS_LOG_DIR:-/tmp/imbib-autonomous-tests}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$LOG_ROOT/$STAMP"
DERIVED_DATA="${IMBIB_AUTONOMOUS_DERIVED_DATA:-$RUN_DIR/DerivedData}"
SUMMARY_FILE="$RUN_DIR/summary.txt"

mkdir -p "$RUN_DIR" "$DERIVED_DATA"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$RUN_DIR/ModuleCache}"
export TMPDIR="${IMBIB_AUTONOMOUS_TMPDIR:-$RUN_DIR/tmp}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

FAILED_STEPS=()

usage() {
    cat <<'EOF'
Usage: apps/imbib/scripts/autonomous-test.sh [mode]

Modes:
  quick        Fast no-human Swift gate for search, automation, drag/drop, and perf smoke
  swift-core   Full PublicationManagerCore SwiftPM test suite
  rust-core    Rust imbib-core unit tests with native features
  build        Regenerate/build Xcode targets without launching the app
  performance  Run deterministic Swift perf smoke; opt into Criterion with IMBIB_AUTONOMOUS_RUN_CARGO_BENCH=1
  full         Full no-human gate: swift-core + rust-core + build
  ui-smoke     Runs the existing basic XCUITest smoke; launches the app
  ios          Boot a simulator, build+install imbib-iOS, launch smoke
  all          Full no-human gate plus ui-smoke + ios

Environment:
  IMBIB_AUTONOMOUS_LOG_DIR       Directory for per-step logs (default: /tmp/imbib-autonomous-tests)
  IMBIB_AUTONOMOUS_DERIVED_DATA  DerivedData directory for Xcode steps
  IMBIB_AUTONOMOUS_TMPDIR        Temporary directory for tests (default: inside the run log directory)
  CLANG_MODULE_CACHE_PATH        Module cache path (default: inside the run log directory)
  IMBIB_AUTONOMOUS_SKIP_RUST=1   Skip rust-core steps in full/all
  IMBIB_AUTONOMOUS_RUN_CARGO_BENCH=1
                                  Run Criterion BibTeX benchmark in performance mode
EOF
}

record_summary() {
    printf "%s\n" "$1" >> "$SUMMARY_FILE"
}

run_step() {
    local name="$1"
    local log_file="$2"
    shift 2

    printf "\n==> %s\n" "$name"
    record_summary "START $name"

    local started
    started="$(date +%s)"
    if "$@" >"$log_file" 2>&1; then
        local ended
        ended="$(date +%s)"
        printf "PASS %s (%ss)\n" "$name" "$((ended - started))"
        record_summary "PASS  $name $((ended - started))s"
    else
        local status=$?
        local ended
        ended="$(date +%s)"
        printf "FAIL %s (%ss, exit %s)\n" "$name" "$((ended - started))" "$status"
        printf "Log: %s\n" "$log_file"
        tail -80 "$log_file" || true
        record_summary "FAIL  $name $((ended - started))s exit=$status log=$log_file"
        FAILED_STEPS+=("$name")
    fi
}

run_step_in_dir() {
    local name="$1"
    local dir="$2"
    local log_file="$3"
    shift 3

    printf "\n==> %s\n" "$name"
    record_summary "START $name"

    local started
    started="$(date +%s)"
    if (cd "$dir" && "$@") >"$log_file" 2>&1; then
        local ended
        ended="$(date +%s)"
        printf "PASS %s (%ss)\n" "$name" "$((ended - started))"
        record_summary "PASS  $name $((ended - started))s"
    else
        local status=$?
        local ended
        ended="$(date +%s)"
        printf "FAIL %s (%ss, exit %s)\n" "$name" "$((ended - started))" "$status"
        printf "Log: %s\n" "$log_file"
        tail -80 "$log_file" || true
        record_summary "FAIL  $name $((ended - started))s exit=$status log=$log_file"
        FAILED_STEPS+=("$name")
    fi
}

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf "Missing required command: %s\n" "$command_name"
        exit 127
    fi
}

prepare_xcode_project() {
    if command -v xcodegen >/dev/null 2>&1; then
        run_step_in_dir "Regenerate Xcode project" "$XCODE_DIR" "$RUN_DIR/xcodegen.log" xcodegen generate
    elif [ -d "$XCODE_PROJECT" ]; then
        printf "\n==> Regenerate Xcode project\n"
        printf "SKIP xcodegen is not installed; using existing project at %s\n" "$XCODE_PROJECT"
        record_summary "SKIP  Regenerate Xcode project xcodegen not installed"
    else
        printf "Missing xcodegen and no generated project exists at %s\n" "$XCODE_PROJECT"
        exit 127
    fi
}

swift_quick_filter() {
    printf "%s" "URLCommandParserTests|URLSchemeHandlerSearchActionTests|ImbibSearchActionTests|ImbibSearchPresenterTests|DragDropTypesTests|AutonomousPerformanceSmokeTests"
}

run_quick() {
    require_command swift
    run_step \
        "PublicationManagerCore quick autonomous tests" \
        "$RUN_DIR/swift-quick.log" \
        swift test \
        --disable-sandbox \
        --package-path "$CORE_DIR" \
        --filter "$(swift_quick_filter)"
}

run_swift_core() {
    require_command swift
    run_step \
        "PublicationManagerCore full SwiftPM tests" \
        "$RUN_DIR/swift-core.log" \
        swift test \
        --disable-sandbox \
        --package-path "$CORE_DIR"
}

run_rust_core() {
    if [ "${IMBIB_AUTONOMOUS_SKIP_RUST:-0}" = "1" ]; then
        printf "\n==> Rust imbib-core unit tests\n"
        printf "SKIP IMBIB_AUTONOMOUS_SKIP_RUST=1\n"
        record_summary "SKIP  Rust imbib-core unit tests"
        return
    fi

    require_command cargo
    run_step \
        "Rust imbib-core unit tests" \
        "$RUN_DIR/rust-core.log" \
        cargo test \
        -p imbib-core \
        --features native
}

run_build() {
    require_command xcodebuild
    prepare_xcode_project

    local xcode_home="$RUN_DIR/xcode-home"
    local source_packages="$RUN_DIR/SourcePackages"
    mkdir -p "$xcode_home" "$source_packages"

    run_step \
        "imbib macOS build-for-testing" \
        "$RUN_DIR/xcode-macos-build-for-testing.log" \
        env \
        HOME="$xcode_home" \
        CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
        TMPDIR="$TMPDIR" \
        xcodebuild build-for-testing \
        -project "$XCODE_PROJECT" \
        -scheme imbib \
        -destination "platform=macOS" \
        -derivedDataPath "$DERIVED_DATA/macos" \
        -clonedSourcePackagesDirPath "$source_packages" \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO

    run_step \
        "imbib iOS simulator build" \
        "$RUN_DIR/xcode-ios-build.log" \
        env \
        HOME="$xcode_home" \
        CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
        TMPDIR="$TMPDIR" \
        xcodebuild build \
        -project "$XCODE_PROJECT" \
        -scheme imbib-iOS \
        -destination "generic/platform=iOS Simulator" \
        -derivedDataPath "$DERIVED_DATA/ios" \
        -clonedSourcePackagesDirPath "$source_packages" \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO
}

# iOS install-smoke: build for a booted simulator, install, launch, verify
# the process is alive. A plain `build` never installs, so it cannot catch
# appex/Info.plist install rejections (the class of bug that broke
# imprint-iOS install). Device selectable via IMBIB_IOS_SIM_NAME.
run_ios() {
    require_command xcodebuild
    require_command xcrun
    prepare_xcode_project

    local sim_name="${IMBIB_IOS_SIM_NAME:-iPad Pro}"
    local udid
    udid="$(xcrun simctl list devices available \
        | grep -F "$sim_name" | grep -oE '[0-9A-F-]{36}' | head -1)"
    if [ -z "$udid" ]; then
        udid="$(xcrun simctl list devices available \
            | grep -oE '[0-9A-F-]{36}' | head -1)"
    fi
    if [ -z "$udid" ]; then
        printf "FAIL no iOS simulator available\n"
        record_summary "FAIL  ios no simulator available"
        FAILED_STEPS+=("imbib iOS install smoke")
        return
    fi
    printf "iOS simulator: %s (%s)\n" "$sim_name" "$udid"
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true

    local source_packages="$RUN_DIR/SourcePackages"
    local xcode_home="$RUN_DIR/xcode-home"
    mkdir -p "$source_packages" "$xcode_home"

    run_step \
        "imbib iOS build (device sim)" \
        "$RUN_DIR/xcode-ios-devicesim-build.log" \
        env HOME="$xcode_home" TMPDIR="$TMPDIR" \
        xcodebuild build \
        -project "$XCODE_PROJECT" \
        -scheme imbib-iOS \
        -destination "id=$udid" \
        -derivedDataPath "$DERIVED_DATA/ios-sim" \
        -clonedSourcePackagesDirPath "$source_packages" \
        CODE_SIGNING_ALLOWED=NO

    local app
    app="$(find "$DERIVED_DATA/ios-sim/Build/Products/Debug-iphonesimulator" \
        -maxdepth 1 -name 'imbib.app' 2>/dev/null | head -1)"
    if [ -z "$app" ]; then
        printf "FAIL imbib.app not produced — skipping install smoke\n"
        record_summary "FAIL  ios build produced no app"
        FAILED_STEPS+=("imbib iOS install smoke")
        return
    fi

    run_step \
        "imbib iOS install + launch smoke" \
        "$RUN_DIR/ios-install-smoke.log" \
        bash -c "
            set -eo pipefail
            xcrun simctl install '$udid' '$app'
            xcrun simctl launch '$udid' com.impress.imbib
            sleep 5
            xcrun simctl spawn '$udid' launchctl list 2>/dev/null | grep -q com.impress.imbib
        "
}

run_performance() {
    require_command swift
    run_step \
        "Swift autonomous performance smoke" \
        "$RUN_DIR/swift-performance-smoke.log" \
        swift test \
        --disable-sandbox \
        --package-path "$CORE_DIR" \
        --filter "AutonomousPerformanceSmokeTests"

    if [ "${IMBIB_AUTONOMOUS_RUN_CARGO_BENCH:-0}" = "1" ]; then
        require_command cargo
        run_step \
            "Criterion BibTeX benchmark" \
            "$RUN_DIR/cargo-bibtex-benchmark.log" \
            cargo bench \
            -p imbib-core \
            --bench bibtex_benchmark \
            -- \
            --sample-size 10
    else
        record_summary "SKIP  Criterion BibTeX benchmark IMBIB_AUTONOMOUS_RUN_CARGO_BENCH not set"
    fi
}

run_ui_smoke() {
    require_command xcodebuild
    run_step_in_dir \
        "imbib basic UI smoke" \
        "$XCODE_DIR" \
        "$RUN_DIR/ui-smoke.log" \
        "$XCODE_DIR/fast_test.sh" \
        basic \
        NO
}

case "$MODE" in
    -h|--help|help)
        usage
        exit 0
        ;;
    quick)
        run_quick
        ;;
    swift-core)
        run_swift_core
        ;;
    rust-core)
        run_rust_core
        ;;
    build)
        run_build
        ;;
    performance)
        run_performance
        ;;
    full)
        run_swift_core
        run_rust_core
        run_build
        ;;
    ui-smoke)
        run_ui_smoke
        ;;
    ios)
        run_ios
        ;;
    all)
        run_swift_core
        run_rust_core
        run_build
        run_ui_smoke
        run_ios
        ;;
    *)
        printf "Unknown mode: %s\n\n" "$MODE"
        usage
        exit 2
        ;;
esac

printf "\nLogs: %s\n" "$RUN_DIR"
printf "Summary: %s\n" "$SUMMARY_FILE"

if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
    printf "\nFailed steps:\n"
    for step in "${FAILED_STEPS[@]}"; do
        printf "  - %s\n" "$step"
    done
    exit 1
fi

printf "\nAll selected autonomous checks passed.\n"
