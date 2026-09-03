#!/usr/bin/env bash
#
# Verifies that the codesigned + Full-Disk-Access-granted impress-mcp can
# actually read the protected group.com.impress.suite SQLite store.
#
# After signing (bash sign.sh) AND granting FDA in System Settings, run this.
# A pass means the MCP server can drive your real imbib library; a fail
# means TCC is still blocking.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINARY="$REPO_ROOT/target/release/impress-mcp"
# Interpolated into the guidance below, so it names the checkout you actually
# ran from rather than a path hardcoded to one machine.
BINARY_DIR="$REPO_ROOT/target/release"

if [ ! -x "$BINARY" ]; then
    echo "error: missing $BINARY — run sign.sh first" >&2
    exit 1
fi

echo "==> Probing for app-groups entitlement"
# Match the suffix only. macOS app groups carry the Team ID prefix
# (QG3MEYVHMS.com.impress.suite) — the profile's wildcard authorizes those, so
# they never prompt — while iOS keeps the group.* form. Grepping for either
# literal prefix silently fails after a migration; the suffix is stable.
codesign --display --entitlements - --xml "$BINARY" 2>/dev/null | grep -q "com\.impress\.suite" || {
    echo "  fail: app-groups entitlement not in signature. Re-run sign.sh." >&2
    exit 1
}
echo "  ok"

echo "==> Probing for Full Disk Access (will hit the protected dir)"
# IMBIB_BACKEND=sqlite is load-bearing. Left on "auto", the service traits
# install the HTTP backend whenever the imbib app happens to be running, the
# probe never touches the app-group store, and this script reports PASS without
# having tested Full Disk Access at all. FDA gates the store path, so the store
# path is what has to be exercised.
printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"imbib-library-service_count-publications","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"imbib-library-service_list-libraries","arguments":{}}}' \
    | IMBIB_BACKEND=sqlite "$BINARY" 2>/tmp/impress-mcp-stderr.log \
    | python3 -c "
import sys, json
# The server envelopes non-object results (MCP requires structuredContent to
# be an object): count-publications arrives as {'value': N} and
# list-libraries as {'items': [...]}. A FAILED call carries isError (and a
# transport error carries no structuredContent at all) — on this machine
# that is almost always TCC blocking the store open, so it routes to the
# same FDA guidance as an empty store.
count = None
libs  = None
blocked = False
for line in sys.stdin:
    msg = json.loads(line.strip())
    rid = msg.get('id')
    if rid not in (2, 3):
        continue
    result = msg.get('result') or {}
    sc = result.get('structuredContent')
    if result.get('isError') or not isinstance(sc, dict):
        blocked = True
        continue
    if rid == 2:
        count = sc.get('value')
    elif rid == 3:
        libs = sc.get('items', [])
print(f'count-publications: {count}')
print(f'list-libraries: {len(libs) if libs is not None else None} libraries')
if libs:
    for lib in libs[:5]:
        print(f'  - {lib[\"name\"]} ({lib[\"publication_count\"]} pubs, default={lib[\"is_default\"]}, inbox={lib[\"is_inbox\"]})')
# A response that never arrived (the server died mid-stream) is as blocked
# as an error result.
if count is None or libs is None:
    blocked = True
if blocked or (not libs and count == 0):
    print()
    print('FAIL — store is empty or unreachable.')
    print('Check /tmp/impress-mcp-stderr.log for the underlying error.')
    print('If you see \\\"unable to open database file\\\", grant Full Disk Access:')
    print('  1. System Settings → Privacy & Security → Full Disk Access')
    print('  2. Click the + button')
    print('  3. Press Cmd-Shift-G and paste: $BINARY_DIR')
    print('  4. Select: impress-mcp')
    print('  5. Re-run this script.')
    sys.exit(1)
print()
print('PASS — impress-mcp can read your real imbib library.')
"
