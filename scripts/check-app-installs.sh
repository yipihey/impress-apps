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
        # Capture, never pipe. `grep -q` exits at the first match, the
        # producer takes SIGPIPE, and `set -o pipefail` reports that 141 as a
        # FAILED pipeline — so a successful match reads as no match. It made
        # this very check call an ad-hoc imprint.app "dev" on 2026-09-09.
        sig="dev"
        case "$(codesign -dv "$c" 2>&1)" in *Signature=adhoc*) sig="AD-HOC" ;; esac
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

    # The OTHER launch route. ~/MyApplications/<app>.app is a symlink straight
    # into DerivedData/<app>/Build/Products/Debug, refreshed by
    # build-impress-app.sh — whereas ~/Applications is a copy made by the
    # target's post-build phase from whatever $BUILT_PRODUCTS_DIR happened to
    # be. A GUI build moves the copy and not the symlink, so the two can point
    # at different builds while both look fine on their own.
    alias_link="$HOME/MyApplications/$app.app"
    if [ -L "$alias_link" ]; then
        if [ ! -e "$alias_link" ]; then
            echo "   ~/MyApplications alias is DANGLING → $(readlink "$alias_link" | sed "s|^$HOME|~|")"
            echo "     rebuild with scripts/build-impress-app.sh $app to restore it"
            status=1
        else
            ab="$(readlink "$alias_link")/Contents/MacOS/$app.debug.dylib"
            [ -f "$ab" ] || ab="$(readlink "$alias_link")/Contents/MacOS/$app"
            at=$(stat -f '%m' "$ab" 2>/dev/null || echo 0)
            if [ "$at" != 0 ] && [ "$installed_time" != 0 ]; then
                skew=$(( at > installed_time ? at - installed_time : installed_time - at ))
                if [ "$skew" -gt 120 ]; then
                    echo "   ~/MyApplications alias and ~/Applications are DIFFERENT builds"
                    echo "     alias:  $(date -r "$at" '+%Y-%m-%d %H:%M')  (DerivedData, via build-impress-app.sh)"
                    echo "     copy:   $(date -r "$installed_time" '+%Y-%m-%d %H:%M')  (installed by the post-build phase)"
                    echo "     whichever Spotlight offers you is a coin toss — rebuild with the script"
                    status=1
                fi
            fi
        fi
    fi

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
and every copy there is another app Spotlight can rank first. To stop it:

  * Exclude them from Spotlight — System Settings ▸ Siri & Spotlight ▸
    Spotlight Privacy… ▸ + ▸ add BOTH of:
        ~/Library/Developer/Xcode/DerivedData
        ~/Library/Developer/Xcode/Archives
    (⇧⌘G in the picker to type a path; ~/Library is hidden.)
    Purges the copies already indexed AND blocks future ones, in one step,
    without touching the build cache. The list is root-owned and
    SIP-protected, so it cannot be scripted — this click is the whole fix.

    Archives matter as much as DerivedData: every .xcarchive holds a full
    .app, and five of imbib's Spotlight-visible copies were January archives.
    Any listed above that sits OUTSIDE those two folders — a ~/Desktop
    archive, a DerivedData inside a checkout — needs deleting or excluding on
    its own; nothing here can reach it.

Two things that look like fixes and are not:

  * `.metadata_never_index` at the DerivedData root. Tested here: with the
    marker in place, an indexed bundle deleted and restored was re-indexed
    immediately. It changes nothing.
  * A single shared DerivedData path instead of per-project hashed ones. That
    leaves ONE stale copy rather than sixty, and one is all it takes to
    out-rank ~/Applications. Fewer wrong answers is not a right answer.

The mechanism that does work without the GUI is a DerivedData root ending in
`.noindex` (Xcode's own convention for Build/Intermediates.noindex): verified
0 mdfind hits inside one vs 1 for an identical copy beside it. It orphans the
whole build cache, which is why the Privacy list is the better trade here.
NOTE

exit $status
