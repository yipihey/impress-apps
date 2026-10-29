#!/usr/bin/env bash
#
# Build "imbib Web.app" — imbib on koine's web frontend as a Mac app — and
# install it in ~/Applications.
#
#   bash crates/imbib-host/make-app.sh             # build, sign, install
#   bash crates/imbib-host/make-app.sh --no-install
#   bash crates/imbib-host/make-app.sh --agent     # also serve at login, no window
#   bash crates/imbib-host/make-app.sh --no-agent  # remove that login agent
#
# The app is imbib-host in a bundle: Contents/MacOS/imbib-host (release,
# signed with imbib-web.entitlements, the team's wildcard profile embedded —
# without both the store under ~/Library/Group Containers is unreadable) and the
# koine-web page in Contents/Resources/web, so it needs neither the koine
# checkout nor dx at run time. Opened from the Finder, Spotlight or the Dock
# it takes the bundle's arguments itself (src/bundle.rs): a native window on
# port 23127 (SiblingApp.Services.imbibWebPort), its log in
# ~/Library/Logs/Impress/imbib-web.log. Quitting the app stops the server.
#
# --agent installs a LaunchAgent that serves the same port at login with no
# window, for a browser or a phone over Tailscale. While it runs, the port is
# the agent's: open http://127.0.0.1:23127/ui/ rather than the app, which
# would fail to bind.
#
# The first launch asks once for the ADS/SciX keys in the keychain: a new
# bundle id and signature. Answer "Always Allow".

set -euo pipefail

INSTALL=1
AGENT=keep
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        --agent) AGENT=install ;;
        --no-agent) AGENT=remove ;;
        *) echo "make-app.sh: unknown argument $arg" >&2; exit 2 ;;
    esac
done

NAME="imbib Web"
BUNDLE_ID="com.impress.imbib-web"
PORT=23127
IDENTITY="${IDENTITY:-Apple Development: THOMAS G ABEL (E9NUL9QF47)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KOINE="${KOINE:-$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir | xargs dirname | xargs dirname)/koine}"
WEB_DIR="${WEB_DIR:-$KOINE/target/dx/koine-web/release/web/public}"
ENTITLEMENTS="$REPO_ROOT/crates/imbib-host/imbib-web.entitlements"
ICONS="$REPO_ROOT/apps/imbib/imbib/imbib/Resources/Assets.xcassets/AppIcon.appiconset"
DEST="$HOME/Applications/$NAME.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

if [ "$AGENT" = remove ]; then
    launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
    rm -f "$AGENT_PLIST"
    echo "==> Removed the login agent"
    exit 0
fi

if [ ! -f "$WEB_DIR/index.html" ]; then
    echo "==> Building the koine-web bundle in $KOINE"
    (cd "$KOINE/crates/koine-web" && CARGO_TARGET_DIR="$KOINE/target" dx build --platform web --release)
fi

cd "$REPO_ROOT"
echo "==> Building imbib-host (release)"
cargo build --release -p imbib-host
TARGET="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
VERSION="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(next(p["version"] for p in json.load(sys.stdin)["packages"] if p["name"]=="imbib-host"))')"

STAGE="$TARGET/imbib-web-app"
APP="$STAGE/$NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TARGET/release/imbib-host" "$APP/Contents/MacOS/imbib-host"
rsync -a --delete "$WEB_DIR/" "$APP/Contents/Resources/web/"

# The team's wildcard development profile, which backs the app-group grant
# inside a bundle (imbib-web.entitlements says why). Xcode keeps it; it is
# per team and device, so it is found by name, never committed.
PROFILE_NAME="Mac Team Provisioning Profile: *"
PROFILE=""
for candidate in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile; do
    [ -f "$candidate" ] || continue
    name="$(security cms -D -i "$candidate" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || true)"
    if [ "$name" = "$PROFILE_NAME" ]; then PROFILE="$candidate"; break; fi
done
if [ -z "$PROFILE" ]; then
    echo "make-app.sh: no \"$PROFILE_NAME\" in Xcode's profiles; build any suite app in Xcode once (automatic signing makes it)" >&2
    exit 1
fi
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# The icon: imbib's own, as an .icns.
ICONSET="$STAGE/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    cp "$ICONS/icon_${size}x${size}.png" "$ICONSET/"
    cp "$ICONS/icon_${size}x${size}@2x.png" "$ICONSET/"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>imbib-host</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- The window's page is the app's own server on 127.0.0.1, over http. -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

echo "==> Signing"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" \
    --options runtime --timestamp=none "$APP/Contents/MacOS/imbib-host"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" \
    --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ "$INSTALL" = 1 ]; then
    # Replace the binary of a running copy and it crashes at its next page
    # fault: quit it first.
    if pgrep -f "$DEST/Contents/MacOS/imbib-host" >/dev/null; then
        echo "==> Quitting the running $NAME"
        pkill -TERM -f "$DEST/Contents/MacOS/imbib-host" || true
        for _ in $(seq 1 20); do
            pgrep -f "$DEST/Contents/MacOS/imbib-host" >/dev/null || break
            sleep 0.5
        done
    fi
    echo "==> Installing $DEST"
    mkdir -p "$HOME/Applications"
    rsync -a --delete "$APP/" "$DEST/"
    # Tell LaunchServices about the new copy, so Spotlight opens this one.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
fi

if [ "$AGENT" = install ]; then
    [ "$INSTALL" = 1 ] || { echo "make-app.sh: --agent needs the installed copy" >&2; exit 2; }
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Impress"
    cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/imbib-host</string>
        <string>--port</string><string>$PORT</string>
        <string>--web-dir</string><string>$DEST/Contents/Resources/web</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>RUST_LOG</key><string>warn,koine-host=info,sources=info,feeds=info</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/Impress/imbib-web.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/Impress/imbib-web.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
    echo "==> Login agent serving http://127.0.0.1:$PORT/ui/"
fi

[ "$INSTALL" = 1 ] && echo "==> Done: open \"$DEST\"" || echo "==> Done: $APP"
