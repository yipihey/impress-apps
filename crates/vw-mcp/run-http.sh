#!/usr/bin/env bash
# LaunchAgent entry point for the authenticated VW Streamable HTTP MCP host.
# The bearer stays in the login keychain rather than a plist or process args.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOKEN="$(/usr/bin/security find-generic-password -w -s com.impress.vw-mcp-http)"
BINARY="${VW_MCP_BINARY:-$REPO_ROOT/target/release/vw-mcp}"

export IMPRESS_MCP_ACCESS_TOKEN="$TOKEN"

exec "$BINARY" \
    --store-path "${IMPRESS_STORE_PATH:?IMPRESS_STORE_PATH is required}" \
    --http-bind "${VW_MCP_BIND:-127.0.0.1:23126}"
