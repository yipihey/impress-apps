#!/usr/bin/env bash
# LaunchAgent entry point. The bearer remains in the login keychain rather
# than being copied into a plist or process argument.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOKEN="$(/usr/bin/security find-generic-password -w -s com.impress.ai-http)"
BINARY="${IMPRESS_AI_SERVER_BINARY:-$HOME/Library/Application Support/Impress/ImpartServices.app/Contents/MacOS/impress-ai-server}"

export IMPRESS_AI_ACCESS_TOKEN="$TOKEN"
export IMPRESS_AI_BIND="${IMPRESS_AI_BIND:-127.0.0.1:8787}"
export IMPRESS_OMLX_URL="${IMPRESS_OMLX_URL:-http://127.0.0.1:8000}"
export IMPRESS_STORE_PATH="${IMPRESS_STORE_PATH:-$HOME/Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite}"

if [ ! -x "$BINARY" ]; then
    # Development fallback before the profiled service bundle is installed.
    BINARY="$REPO_ROOT/target/release/impress-ai-server"
fi

exec "$BINARY"
