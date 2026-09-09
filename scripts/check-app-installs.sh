#!/usr/bin/env bash
# Which build of each impress app will actually launch?
#
# Every app self-installs its Debug build to ~/Applications so Spotlight opens
# the newest one. That only holds while ~/Applications is the ONLY copy
# Spotlight can find — and Xcode disagrees: it builds to a per-project HASHED
# DerivedData path, so each Xcode session leaves behind another app bundle
# Spotlight indexes and may rank first.
#
# That is not a cosmetic problem. On 2026-09-08 Spotlight was launching an
# ad-hoc-signed copy from the previous day: ad-hoc signing carries no
# provisioning profile, so the QG3MEYVHMS app-group entitlement was
# unauthorized and macOS prompted "would like to access data from other apps"
# on every launch — while the developer read a stale build's behaviour as the
# current code's.
#
# This reports what Spotlight can see, newest first, and flags the two things
# that actually bite: a copy newer than the installed one, and any ad-hoc
# signature.
#
# Usage: scripts/check-app-installs.sh [app ...]     (default: all six)

set -uo pipefail

APPS=("$@")
[ ${#APPS[@]} -eq 0 ] && APPS=(imbib imprint implore impel impart impress)

status=0

for app in "${APPS[@]}"; do
    echo "── $app"
    installed="$HOME/Applications/$app.app"
    # `while read`, not `mapfile`: macOS ships bash 3.2, where mapfile does
    # not exist, and this script has to run on the machine it diagnoses.
    copies=()
    while IFS= read -r line; do
        [ -n "$line" ] && copies+=("$line")
    done < <(mdfind "kMDItemFSName == '$app.app'" 2>/dev/null)

    if [ ${#copies[@]:-0} -eq 0 ]; then
        echo "   no copy Spotlight can find — it will not open from Spotlight at all"
        status=1
        continue
    fi

    newest_time=0
    newest_path=""
    installed_time=0
    for c in "${copies[@]}"; do
        bin="$c/Contents/MacOS/$app.debug.dylib"
        [ -f "$bin" ] || bin="$c/Contents/MacOS/$app"
        [ -f "$bin" ] || continue
        t=$(stat -f '%m' "$bin" 2>/dev/null || echo 0)
        sig="dev"
        codesign -dv "$c" 2>&1 | grep -q 'Signature=adhoc' && sig="AD-HOC"
        where="$(printf '%s' "$c" | sed "s|^$HOME|~|")"
        [ "$c" = "$installed" ] && where="~/Applications  (the install target)"
        printf "   %s  %-6s %s\n" "$(date -r "$t" '+%Y-%m-%d %H:%M')" "$sig" "$where"
        [ "$c" = "$installed" ] && installed_time=$t
        if [ "$t" -gt "$newest_time" ]; then newest_time=$t; newest_path=$c; fi
        if [ "$sig" = "AD-HOC" ]; then
            echo "     ^ ad-hoc signed: no provisioning profile, so its app-group"
            echo "       entitlement is unauthorized and macOS will prompt on launch"
            status=1
        fi
    done

    if [ ! -d "$installed" ]; then
        echo "   NOT installed to ~/Applications — build it with scripts/build-impress-app.sh"
        status=1
    elif [ "$newest_path" != "$installed" ] && [ -n "$newest_path" ] \
         && [ $(( newest_time - installed_time )) -gt 120 ]; then
        # 120s of slack: the install is a `ditto` of the DerivedData bundle
        # moments after it links, so the two differ by a second or two on
        # every healthy build. Flagging that would make the check cry wolf on
        # exactly the normal case.
        echo "   NEWER copy exists outside ~/Applications — Spotlight may open that one"
        echo "     newest: $(printf '%s' "$newest_path" | sed "s|^$HOME|~|")"
        status=1
    fi
done

cat <<'NOTE'

Xcode keeps creating these: it builds to a per-project hashed DerivedData path,
and every copy there is another app Spotlight can rank first. Two ways to stop
it for good, either is enough:

  * Exclude DerivedData from Spotlight — System Settings ▸ Siri & Spotlight ▸
    Spotlight Privacy… ▸ + ▸ ~/Library/Developer/Xcode/DerivedData
    This also PURGES what is already indexed, which a .metadata_never_index
    marker cannot do (it only stops future indexing).

  * Point Xcode at the same path the build script uses — Xcode ▸ Settings ▸
    Locations ▸ Derived Data ▸ Custom ▸ ~/Library/Developer/Xcode/DerivedData
    with "Build/Products" relative paths, so there is one copy rather than one
    per project.
NOTE

exit $status
