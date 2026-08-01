#!/bin/bash
#
# archive-and-upload.sh — one-command over-the-air (TestFlight) delivery for the
# impress iOS apps. Motivated by 2026-07-24, when a ready build (tailnet
# remote-access feature, 1c706cf) could not reach the user's iPhone because they
# were away from the Mac and there was no cable-free path.
#
# What it does for each requested app:
#   1. (optional) rebuild the app's Rust XCFramework with iOS device slices
#   2. xcodegen generate      (keep the .xcodeproj in sync with project.yml)
#   3. xcodebuild archive     (-allowProvisioningUpdates, API-key auth)
#   4. xcodebuild -exportArchive  (method: app-store-connect → .ipa)
#   5. xcrun altool --upload-app  (→ TestFlight)
#
# The App Review queue is NEVER touched. This is internal TestFlight only.
#
# ─────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/archive-and-upload.sh                 # both apps, version from git tag
#   ./scripts/archive-and-upload.sh imbib           # just imbib-iOS
#   ./scripts/archive-and-upload.sh imprint v1.3.0  # imprint-iOS, explicit version
#   ./scripts/archive-and-upload.sh both v1.3.0
#
#   ./scripts/archive-and-upload.sh --setup         # store ASC creds in Keychain
#
# Flags:
#   --no-upload            archive + export only (produce .ipa, do not upload)
#   --validate            run `altool --validate-app` before uploading
#   --rebuild-frameworks  rebuild the app's Rust XCFramework(s) first (iOS slices)
#   --no-generate         skip `xcodegen generate` (use the project as-is)
#   --setup               interactive Keychain credential setup, then exit
#
# ─────────────────────────────────────────────────────────────────────────────
# Credentials (App Store Connect API key — https://appstoreconnect.apple.com/access/api)
#
# The key needs the "App Manager" (or "Admin") role. Resolution order for each value:
#
#   Key ID   : $ASC_KEY_ID    → Keychain(imbib-testflight/asc-key-id)
#                             → inferred from the single ~/.appstoreconnect/private_keys/AuthKey_*.p8
#   Issuer ID: $ASC_ISSUER_ID → Keychain(imbib-testflight/asc-issuer-id)
#   .p8 file : ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#   Team ID  : $ASC_TEAM_ID   → Keychain(imbib-release/team-id) → QG3MEYVHMS (default)
#
# `--setup` walks you through storing Key ID + Issuer ID in the Keychain so no
# subsequent build needs environment variables. The Keychain services are shared
# with imbib's existing scripts/ios-testflight.sh (imbib-testflight / imbib-release).
#
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
DEFAULT_TEAM_ID="QG3MEYVHMS"
KEYCHAIN_SERVICE="imbib-testflight"          # reused from scripts/ios-testflight.sh
KEYCHAIN_SERVICE_RELEASE="imbib-release"     # team-id lives here
PRIVATE_KEYS_DIR="$HOME/.appstoreconnect/private_keys"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$REPO_ROOT/build/ota"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}$*${NC}"; }
ok()    { echo -e "${GREEN}$*${NC}"; }
warn()  { echo -e "${YELLOW}$*${NC}"; }
die()   { echo -e "${RED}error: $*${NC}" >&2; exit 1; }

# ── Per-app configuration ────────────────────────────────────────────────────
# app_config <app> populates: PROJECT_DIR SCHEME XCODEPROJ BUNDLE_ID CORE_CRATE
app_config() {
    case "$1" in
        imbib)
            PROJECT_DIR="$REPO_ROOT/apps/imbib/imbib"
            SCHEME="imbib-iOS"
            XCODEPROJ="imbib.xcodeproj"
            BUNDLE_ID="com.impress.imbib"
            CORE_CRATE="imbib-core"
            ;;
        imprint)
            PROJECT_DIR="$REPO_ROOT/apps/imprint"
            SCHEME="imprint-iOS"
            XCODEPROJ="imprint.xcodeproj"
            BUNDLE_ID="com.imbib.imprint"
            CORE_CRATE="imprint-core"
            ;;
        *) die "unknown app '$1' (expected: imbib | imprint)";;
    esac
}

# ── Keychain helpers ─────────────────────────────────────────────────────────
kc_get() { security find-generic-password -a "$1" -s "$2" -w 2>/dev/null || true; }
kc_set() {
    security add-generic-password -U -a "$1" -s "$2" -w "$3" 2>/dev/null || \
    security add-generic-password    -a "$1" -s "$2" -w "$3"
}

setup_credentials() {
    echo "=== App Store Connect credential setup ==="
    echo
    echo "Create an API key (App Manager role) at:"
    echo "  https://appstoreconnect.apple.com/access/api"
    echo
    read -r -p "App Store Connect API Key ID: " k
    kc_set "asc-key-id" "$KEYCHAIN_SERVICE" "$k";   ok "✓ Key ID stored"
    echo
    echo "The Issuer ID is at the top of the Keys tab on that page."
    read -r -p "App Store Connect Issuer ID: " i
    kc_set "asc-issuer-id" "$KEYCHAIN_SERVICE" "$i"; ok "✓ Issuer ID stored"
    echo
    read -r -p "Team ID [$DEFAULT_TEAM_ID]: " t; t="${t:-$DEFAULT_TEAM_ID}"
    kc_set "team-id" "$KEYCHAIN_SERVICE_RELEASE" "$t"; ok "✓ Team ID stored"
    echo
    local p8="$PRIVATE_KEYS_DIR/AuthKey_${k}.p8"
    if [ -f "$p8" ]; then
        ok "✓ API key file found: $p8"
    else
        warn "⚠ API key file not found: $p8"
        echo "  Download the .p8 from App Store Connect and save it there:"
        echo "    mkdir -p $PRIVATE_KEYS_DIR"
        echo "    mv ~/Downloads/AuthKey_${k}.p8 $p8"
    fi
    echo
    ok "Setup complete. Now run:  ./scripts/archive-and-upload.sh both"
}

# ── Argument parsing ─────────────────────────────────────────────────────────
APPS_ARG=""; VERSION_ARG=""
DO_UPLOAD=1; DO_VALIDATE=0; REBUILD_FRAMEWORKS=0; DO_GENERATE=1
for arg in "$@"; do
    case "$arg" in
        --setup)              app_config imbib >/dev/null 2>&1 || true; setup_credentials; exit 0;;
        --no-upload)          DO_UPLOAD=0;;
        --validate)           DO_VALIDATE=1;;
        --rebuild-frameworks) REBUILD_FRAMEWORKS=1;;
        --no-generate)        DO_GENERATE=0;;
        -h|--help)            sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
        imbib|imprint|both)   APPS_ARG="$arg";;
        --*)                  die "unknown flag '$arg'";;
        *)                    VERSION_ARG="$arg";;
    esac
done

case "${APPS_ARG:-both}" in
    imbib)   APPS=(imbib);;
    imprint) APPS=(imprint);;
    both|"") APPS=(imbib imprint);;
esac

# ── Preconditions ────────────────────────────────────────────────────────────
[ "$(uname -m)" = "arm64" ] || die "iOS device archives require an Apple Silicon Mac"
command -v xcodegen >/dev/null 2>&1 || die "xcodegen required (brew install xcodegen)"
command -v xcodebuild >/dev/null 2>&1 || die "Xcode command line tools required"

# ── Resolve credentials (only needed when uploading/validating) ──────────────
ASC_KEY_ID="${ASC_KEY_ID:-$(kc_get asc-key-id "$KEYCHAIN_SERVICE")}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(kc_get asc-issuer-id "$KEYCHAIN_SERVICE")}"
ASC_TEAM_ID="${ASC_TEAM_ID:-$(kc_get team-id "$KEYCHAIN_SERVICE_RELEASE")}"
ASC_TEAM_ID="${ASC_TEAM_ID:-$DEFAULT_TEAM_ID}"

# Infer Key ID from a lone .p8 if not otherwise set (portable to macOS bash 3.2).
if [ -z "$ASC_KEY_ID" ] && [ -d "$PRIVATE_KEYS_DIR" ]; then
    _p8_count=0; _p8_one=""
    for _p8 in "$PRIVATE_KEYS_DIR"/AuthKey_*.p8; do
        [ -f "$_p8" ] || continue
        _p8_count=$((_p8_count + 1)); _p8_one="$_p8"
    done
    if [ "$_p8_count" -eq 1 ]; then
        ASC_KEY_ID="$(basename "$_p8_one" .p8)"; ASC_KEY_ID="${ASC_KEY_ID#AuthKey_}"
    fi
fi
ASC_KEY_PATH="$PRIVATE_KEYS_DIR/AuthKey_${ASC_KEY_ID}.p8"

if [ "$DO_UPLOAD" -eq 1 ] || [ "$DO_VALIDATE" -eq 1 ]; then
    local_missing=()
    [ -n "$ASC_KEY_ID" ]    || local_missing+=("Key ID (\$ASC_KEY_ID)")
    [ -n "$ASC_ISSUER_ID" ] || local_missing+=("Issuer ID (\$ASC_ISSUER_ID)")
    [ -f "$ASC_KEY_PATH" ]  || local_missing+=(".p8 at $ASC_KEY_PATH")
    if [ "${#local_missing[@]}" -gt 0 ]; then
        warn "Missing App Store Connect credentials:"
        for m in "${local_missing[@]}"; do echo "  • $m"; done
        echo
        echo "Fix with:  ./scripts/archive-and-upload.sh --setup"
        echo "Or archive without uploading:  ... --no-upload"
        die "cannot upload without credentials"
    fi
fi

# ── Version / build number ───────────────────────────────────────────────────
cd "$REPO_ROOT"
VERSION="${VERSION_ARG:-$(git describe --tags --abbrev=0 2>/dev/null || echo "1.0.0")}"
SHORT_VERSION="${VERSION#v}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0).$(date +%y%m%d%H%M)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo
ok "=== impress OTA / TestFlight ==="
echo -e "Apps:    ${YELLOW}${APPS[*]}${NC}"
echo -e "Version: ${YELLOW}${SHORT_VERSION}${NC}   Build: ${YELLOW}${BUILD_NUMBER}${NC}   Commit: ${YELLOW}${COMMIT}${NC}"
echo -e "Team:    ${YELLOW}${ASC_TEAM_ID}${NC}"
if [ "$DO_UPLOAD" -eq 1 ]; then
    echo -e "Upload:  ${YELLOW}TestFlight (Key ${ASC_KEY_ID}, Issuer ${ASC_ISSUER_ID:0:8}…)${NC}"
else
    echo -e "Upload:  ${YELLOW}disabled (--no-upload)${NC}"
fi

# ── Per-app pipeline ─────────────────────────────────────────────────────────
archive_and_upload_one() {
    local app="$1"
    app_config "$app"
    local out="$BUILD_ROOT/$app"
    rm -rf "$out"; mkdir -p "$out"
    local archive="$out/$SCHEME.xcarchive"
    local export_dir="$out/export"
    local opts="$out/ExportOptions.plist"

    echo; info "──────── $app ($SCHEME → $BUNDLE_ID) ────────"

    # 1. Rust frameworks (optional; iOS device slices are normally already built)
    if [ "$REBUILD_FRAMEWORKS" -eq 1 ]; then
        info "[$app 1/5] Rebuilding Rust XCFramework ($CORE_CRATE, iOS slices)…"
        "$REPO_ROOT/scripts/build-xcframeworks.sh" "$CORE_CRATE"
    else
        echo "  (skipping framework rebuild — pass --rebuild-frameworks to force)"
    fi

    # 2. xcodegen
    if [ "$DO_GENERATE" -eq 1 ]; then
        info "[$app 2/5] xcodegen generate…"
        ( cd "$PROJECT_DIR" && xcodegen generate >/dev/null )
    fi
    [ -d "$PROJECT_DIR/$XCODEPROJ" ] || die "$XCODEPROJ not found in $PROJECT_DIR (run without --no-generate)"

    # Auth flags let -allowProvisioningUpdates talk to the portal via the API key
    # (no interactive Apple ID sign-in — essential when running unattended).
    local auth=()
    if [ -f "$ASC_KEY_PATH" ] && [ -n "$ASC_ISSUER_ID" ]; then
        auth=(-authenticationKeyPath "$ASC_KEY_PATH"
              -authenticationKeyID "$ASC_KEY_ID"
              -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    fi

    # 3. Archive
    info "[$app 3/5] Archiving (Release, generic/platform=iOS)…"
    xcodebuild archive \
        -project "$PROJECT_DIR/$XCODEPROJ" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$archive" \
        -allowProvisioningUpdates \
        ${auth[@]+"${auth[@]}"} \
        DEVELOPMENT_TEAM="$ASC_TEAM_ID" \
        CODE_SIGN_STYLE=Automatic \
        MARKETING_VERSION="$SHORT_VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        | grep -E '^(=== |Archive|CodeSign|error:|warning: )' || true
    [ -d "$archive" ] || die "archive failed for $app (see full log above)"
    ok "  ✓ archived: $archive"

    # 4. Export .ipa (App Store Connect distribution)
    cat > "$opts" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>                        <string>app-store-connect</string>
    <key>teamID</key>                        <string>$ASC_TEAM_ID</string>
    <key>signingStyle</key>                  <string>automatic</string>
    <key>destination</key>                   <string>export</string>
    <key>uploadSymbols</key>                 <true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
    info "[$app 4/5] Exporting .ipa (method app-store-connect)…"
    xcodebuild -exportArchive \
        -archivePath "$archive" \
        -exportPath "$export_dir" \
        -exportOptionsPlist "$opts" \
        -allowProvisioningUpdates \
        ${auth[@]+"${auth[@]}"} \
        | grep -E '^(Exported|error:|warning: )' || true
    local ipa
    ipa="$(find "$export_dir" -maxdepth 1 -name '*.ipa' | head -1)"
    [ -n "$ipa" ] && [ -f "$ipa" ] || die "IPA export failed for $app (check $export_dir)"
    ok "  ✓ exported: $ipa"

    # 5. Upload / validate
    if [ "$DO_VALIDATE" -eq 1 ]; then
        info "[$app 5/5] Validating with App Store Connect…"
        xcrun altool --validate-app --type ios --file "$ipa" \
            --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
        ok "  ✓ validation passed"
    fi
    if [ "$DO_UPLOAD" -eq 1 ]; then
        info "[$app 5/5] Uploading to TestFlight…"
        xcrun altool --upload-app --type ios --file "$ipa" \
            --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
        ok "  ✓ $app uploaded — build $BUILD_NUMBER is now processing on App Store Connect"
    else
        warn "  (upload skipped) IPA ready at: $ipa"
    fi
}

for app in "${APPS[@]}"; do
    archive_and_upload_one "$app"
done

echo
ok "=== Done ==="
if [ "$DO_UPLOAD" -eq 1 ]; then
    cat <<NEXT

TestFlight next steps (per app, first time only — see docs/testflight-ota.md):
  1. Wait ~5–20 min for App Store Connect to finish "Processing".
  2. App Store Connect → your app → TestFlight → add the build to an
     Internal Testing group that includes your Apple ID (tabel@stanford.edu).
  3. Install/refresh via the TestFlight app on the iPhone — no cable needed.

  https://appstoreconnect.apple.com/apps
NEXT
fi
