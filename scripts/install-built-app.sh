#!/bin/bash
# Install a finished Debug build into ~/Applications, so Spotlight and the
# Dock open the newest build and never a DerivedData copy.
#
# Run as each app scheme's build POST-ACTION (project.yml `postActions`,
# settingsTarget = the app), which Xcode and `xcodebuild -scheme` both run
# after the whole build: compile, App Intents extraction and the final
# codesign. It used to be a build PHASE, and phases run before Xcode
# extracts the App Intents metadata (Xcode 27.1): the phase copied the
# previous build's Metadata.appintents, so every installed app's intents
# lagged one build behind, and implore, impel and impart, which had never had
# one, shipped none at all (2026-10-18). A phase also ran before signing and
# had to re-sign the copy itself; the post-action copies the signed product
# as it is.
#
# Guards (each one has bitten):
#   * Debug, macOS only.
#   * IMPRESS_SKIP_INSTALL=1 opts out: worktree and CI builds must not
#     replace the copy a developer is using.
#   * Only a build signed by the team. An ad-hoc build (CODE_SIGNING_ALLOWED=NO)
#     has no entitlements; installing it over the signed copy strips the
#     app-group grant and macOS prompts on every launch for the suite's
#     group container.
#   * Only a bundle that verifies. A post-action also runs after a failed
#     build; then the product is the previous one or half-written.
#   * Only a bundle carrying its App Intents metadata, the failure above.
#
# Xcode does not show a post-action's output, so every run appends to
# ~/Library/Logs/Impress/install-built-app.log. Run by hand with the built
# app's path: scripts/install-built-app.sh path/to/imbib.app
set -uo pipefail

LOG_DIR="$HOME/Library/Logs/Impress"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/install-built-app.log"
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

if [ $# -ge 1 ]; then
    SRC="${1%/}"
else
    if [ "${CONFIGURATION:-}" != "Debug" ] || [ "${PLATFORM_NAME:-}" != "macosx" ]; then
        exit 0
    fi
    SRC="${BUILT_PRODUCTS_DIR:?}/${FULL_PRODUCT_NAME:?}"
fi
NAME="$(basename "$SRC")"
if [ -n "${IMPRESS_SKIP_INSTALL:-}" ]; then
    say "$NAME: skipped (IMPRESS_SKIP_INSTALL)"
    exit 0
fi
if [ ! -d "$SRC" ]; then
    say "$NAME: skipped, no build at $SRC"
    exit 0
fi

SIG="$(/usr/bin/codesign -dv "$SRC" 2>&1)"
TEAM="$(printf '%s\n' "$SIG" | sed -n 's/^TeamIdentifier=//p')"
if [ -z "$TEAM" ] || [ "$TEAM" = "not set" ] || printf '%s\n' "$SIG" | grep -q '^Signature=adhoc'; then
    say "$NAME: skipped, not signed by a team (ad-hoc or unsigned); the installed copy is kept"
    exit 0
fi
if ! /usr/bin/codesign --verify --deep --strict "$SRC" 2>>"$LOG"; then
    say "$NAME: skipped, the build does not verify (a failed or partial build?)"
    exit 0
fi
if [ ! -f "$SRC/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
    say "$NAME: skipped, the build has no App Intents metadata"
    exit 0
fi

DEST="$HOME/Applications"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
mkdir -p "$DEST"
rm -rf "${DEST:?}/$NAME"
# APFS clone: 0.2 s for imbib's 910 MB, against 0.6 s for a copy.
/usr/bin/ditto --clone "$SRC" "$DEST/$NAME"
# ditto carries the hidden flag the DerivedData copy gets below.
/usr/bin/chflags nohidden "$DEST/$NAME"
"$LSREG" -f "$DEST/$NAME" || true
# Keep the DerivedData copy out of Launch Services and Spotlight, so
# ~/Applications is the only hit.
"$LSREG" -u "$SRC" 2>/dev/null || true
/usr/bin/chflags hidden "$SRC" || true
/usr/bin/mdimport "$DEST/$NAME" 2>/dev/null || true
say "$NAME: installed to $DEST (team $TEAM)"
echo "note: installed $NAME to $DEST"
