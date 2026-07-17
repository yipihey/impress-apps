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

if [ ! -x "$BINARY" ]; then
    echo "error: missing $BINARY — run sign.sh first" >&2
    exit 1
fi

echo "==> Probing for app-groups entitlement"
codesign --display --entitlements - --xml "$BINARY" 2>/dev/null | grep -q "group.com.impress.suite" || {
    echo "  fail: app-groups entitlement not in signature. Re-run sign.sh." >&2
    exit 1
}
echo "  ok"

echo "==> Probing for Full Disk Access (will hit the protected dir)"
printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"imbib-library-service_count-publications","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"imbib-library-service_list-libraries","arguments":{}}}' \
    | "$BINARY" 2>/tmp/impress-mcp-stderr.log \
    | python3 -c "
import sys, json
count = None
libs  = None
for line in sys.stdin:
    msg = json.loads(line.strip())
    rid = msg.get('id')
    if rid == 2:
        count = msg['result']['structuredContent']
    elif rid == 3:
        libs = msg['result']['structuredContent']
print(f'count-publications: {count}')
print(f'list-libraries: {len(libs) if libs is not None else None} libraries')
if libs:
    for lib in libs[:5]:
        print(f'  - {lib[\"name\"]} ({lib[\"publication_count\"]} pubs, default={lib[\"is_default\"]}, inbox={lib[\"is_inbox\"]})')
if not libs and count == 0:
    print()
    print('FAIL — store is empty or unreachable.')
    print('Check /tmp/impress-mcp-stderr.log for the underlying error.')
    print('If you see \\\"unable to open database file\\\", grant Full Disk Access:')
    print('  1. System Settings → Privacy & Security → Full Disk Access')
    print('  2. Click the + button')
    print('  3. Navigate to: /Users/tabel/Projects/impress-apps/target/release/')
    print('  4. Select: impress-mcp')
    print('  5. Re-run this script.')
    sys.exit(1)
print()
print('PASS — impress-mcp can read your real imbib library.')
"
