# Python runtime provider

`runtime-provider.py` is a stdlib-only P8 example. It registers one example-backed `python-reference-service_echo` verb with an Impress MCP host, then serves `GET /health` and `POST /verb/python-reference-service_echo` on its own loopback port. The provider needs no app port or default store.

Choose an unused loopback port and a workspace you own. Start the HTTP host with an explicit store and private host credential:

```sh
umask 077
OWNED_ROOT=$(mktemp -d)
mkdir -p "$OWNED_ROOT/workspace"
OWNED_STORE="$OWNED_ROOT/workspace/impress.sqlite"
OWNED_HOST_TOKEN_FILE="$OWNED_ROOT/host-token"
OWNED_PROVIDER_TOKEN_FILE="$OWNED_ROOT/provider-token"
OWNED_HOST_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 -c 'import secrets; print(secrets.token_urlsafe(48))' > "$OWNED_HOST_TOKEN_FILE"
IMPRESS_WORKSPACE="$OWNED_ROOT/workspace" \
  impress-mcp --http "127.0.0.1:$OWNED_HOST_PORT" \
  --token-file "$OWNED_HOST_TOKEN_FILE" --store-path "$OWNED_STORE"
```

In another shell, while that host is running, set the same `OWNED_ROOT`, `OWNED_STORE`, `OWNED_HOST_TOKEN_FILE`, `OWNED_PROVIDER_TOKEN_FILE`, and `OWNED_HOST_PORT` values, then register the provider against that exact host:

```sh
python3 examples/runtime-provider.py \
  --host "http://127.0.0.1:$OWNED_HOST_PORT" \
  --host-token-file "$OWNED_HOST_TOKEN_FILE" \
  --token-file "$OWNED_PROVIDER_TOKEN_FILE" \
  --port 0
```

Both token files must be private (`0600`). The host token authenticates registration; the host returns a new provider token, which the example saves atomically for invocation and re-registration. No token is printed. Registration refuses a non-loopback host URL. The provider exits if registration fails, and it never chooses a replacement credential itself. Keep `IMPRESS_WORKSPACE` set to the same directory for later CLI and documentation commands so they can restore the host-issued provider credential.

Health responses are limited to 4 KiB and verb JSON responses to 2 MiB, including
chunked responses. Exceeding either limit refuses the call without retaining the
response body. Provider authentication reads the current persisted registration,
so a token revoked by another host is rejected without waiting for a health poll.

The verb appears in MCP `tools/list`, the capability catalogue, and the generated CLI help. With this inventory its unique `echo` method uses the CLI short-name rule; a future method-name collision would make its CLI name `python-reference-service_echo` instead. The CLI is an agent caller, so an untrusted provider call returns `review-pending` and exits with status 3:

```sh
IMPRESS_WORKSPACE="$OWNED_ROOT/workspace" \
  impress --store-path "$OWNED_STORE" --help
IMPRESS_WORKSPACE="$OWNED_ROOT/workspace" \
  impress --store-path "$OWNED_STORE" echo --text hello
```

Review the provider's endpoint and verbs in Impress's generated provider form. Only the native Person action may invoke `provider-service_set-trusted`; a CLI, MCP client, provider credential, or registration request cannot grant trust. Once the person grants it, the same `echo --text hello` call returns `{"echo":"hello"}`. The provider's declared read-only safety then applies; stopping its process makes the retained verb unavailable by name.

Export the registered provider's reference page from the same store and workspace:

```sh
IMPRESS_WORKSPACE="$OWNED_ROOT/workspace" \
  impress-mcp --provider-docs "$OWNED_ROOT/provider-docs" \
  --store-path "$OWNED_STORE"
```

The page is `provider-docs/python-reference-service.md`. This export reads the local registration and writes documentation; it does not start the provider.

## Isolated native proof

After rebuilding this checkout's native frameworks with the supported arm64
slices, build a separate test app and the two host binaries:

```sh
cargo build -p impress-mcp -p impress-cli
xcodegen generate --spec apps/impress/project.yml
OWNED_DERIVED=$(mktemp -d /tmp/impress-p8-native.XXXXXX)
IMPRESS_SKIP_INSTALL=1 xcodebuild \
  -project apps/impress/impress.xcodeproj -scheme impress \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$OWNED_DERIVED" CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.impress.impress.codex.p8 build-for-testing
python3 scripts/test-runtime-provider-native.py \
  --derived-data "$OWNED_DERIVED" \
  --mcp "${CARGO_TARGET_DIR:-target}/debug/impress-mcp" \
  --cli "${CARGO_TARGET_DIR:-target}/debug/impress"
```

The runner chooses its own app and provider-host ports, device ID, and scratch
store. It refuses a build with the normal app bundle identifier and disables
sibling app backends. The hosted XCTest drives `SurfacePaneModel` dispatch:
agent trust is refused, the generated Person form grants trust, a separate CLI
reads that grant, and the generated provider form returns the real Python result.
After terminating only its own provider process, the same subscribed catalogue
pane shows the verb unavailable and a surface source reports its name. This is
a native model/bridge proof, not an assertion about a physical mouse click.
The printed scratch directory retains `proof.json`, logs, and the XCTest result
bundle. The test terminates and reaps only the child processes it starts.
