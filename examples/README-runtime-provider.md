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
