# Impress AI HTTP adapter

`impress-ai-server` is the authenticated native/Tailscale transport for the
provenance-first AI graph. It never owns a conversation database: message
mutations write `impress.sqlite`, and `impel-taskd` consumes the resulting
`impress.ai.respond` task.

The adapter depends on the same `InferenceProvider` port as the task executor;
the standalone binary installs `OmlxClient`. Model discovery therefore has no
adapter-specific oMLX path to keep in step with the durable executor.

## Start locally

```zsh
export IMPRESS_AI_ACCESS_TOKEN='replace-with-a-keychain-managed-random-token'
cargo run -p impress-ai-http --bin impress-ai-server
```

Configuration:

- `IMPRESS_AI_ACCESS_TOKEN` — required, at least 24 characters;
- `IMPRESS_AI_BIND` — defaults to `127.0.0.1:23125`;
- `IMPRESS_STORE_PATH` — defaults to the suite group-container store;
- `IMPRESS_OMLX_URL` — defaults to `http://127.0.0.1:8000`;
- `IMPRESS_OMLX_API_KEY` — optional oMLX bearer token;
- `IMPRESS_LOCALMODELS_IMPORT` — optional explicit path to a legacy
  `chats.sqlite3`. Startup imports it idempotently into the shared graph before
  serving requests; omit it after the migration has succeeded.
- `IMPRESS_LOCALMODELS_IMPORT_ONLY=1` — perform that import and exit before
  binding the HTTP listener.

Keep the server bound to loopback and publish it privately with Tailscale
Serve. Do not use Tailscale Funnel: the API exposes the researcher's shared
conversation graph. The bearer token remains required over Tailscale.

On macOS, package the server and `impel-taskd` with Impart's development
profile so App Sandbox can validate their shared app-group entitlement:

```zsh
IMPART_PROFILE_PATH=/path/to/com.imbib.impart.provisionprofile \
  bash crates/impress-ai-http/build-service-bundle.sh
```

The resulting `target/release/ImpartServices.app` and
`target/release/ImpartTaskWorker.app` are background-only. Each executable is
the declared main binary of its own profiled bundle, which macOS requires when
validating app-group access. Both helpers must receive an explicit
`IMPRESS_STORE_PATH` when started outside the GUI app because App Sandbox
rewrites its notion of the home directory.

## API

Every request uses `Authorization: Bearer $IMPRESS_AI_ACCESS_TOKEN`.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/status` | Adapter health and storage authority |
| `GET` | `/api/models` | oMLX model discovery/status |
| `POST` | `/api/pairing-tickets` | Mint an authenticated, single-use browser pairing ticket |
| `POST` | `/api/pair` | Redeem one pairing ticket (the only unauthenticated API route) |
| `GET/POST` | `/api/conversations` | List or create durable conversations |
| `GET` | `/api/conversations/{id}` | Conversation, messages, pending tasks |
| `PATCH` | `/api/conversations/{id}` | Rename a conversation or update its model/tools |
| `POST` | `/api/conversations/{id}/messages` | Queue an offline-safe user turn |
| `POST` | `/api/conversations/{id}/title-suggestion` | Queue a local-model title suggestion |
| `POST` | `/api/blobs` | Upload an attachment; MIME in `Content-Type` |
| `GET` | `/api/tasks/{id}` | Current durable task/run/result state |
| `GET` | `/api/tasks/{id}/events` | NDJSON stream of changed durable task state |

The server also serves the retained LocalModels browser frontend at `/`. Its
chat list and composer use these same endpoints, so browser conversations are
native Impart Local AI threads rather than snapshots in a second database.
The `/vw` route reuses the same frontend with a VW-specific system instruction,
mobile copy, manifest, and the isolated `vw` tool-policy bucket. See
[VWWebGuide.md](VWWebGuide.md) for connected deployment and phone pairing.
For phone pairing, it accepts the bearer once as either `?token=...` or,
preferably, `#token=...`. A fragment never enters HTTP request logs; the
frontend moves it into session storage and immediately removes it from the
visible address.

Remote pairing should use a single-use ticket instead of transferring the
long-lived bearer. An authenticated client mints a ticket with
`POST /api/pairing-tickets`, then opens `/#pair=TICKET` on the new device. The
256-bit ticket lives only in memory, expires after 15 minutes, is carried in a
URL fragment so it does not enter request logs, and is atomically deleted on
first redemption. `POST /api/pair` then transfers the existing browser bearer
over the private HTTPS connection; replay and expired tickets return 401.

The NDJSON stream intentionally reports graph convergence rather than ephemeral
token deltas. An iOS client can disconnect at any time and recover the same
message through normal item-store sync.

Title suggestions are durable `impress.ai.suggest-title` tasks executed by the
same selected local oMLX model as the conversation. A completed assistant turn
queues one automatically while the title is still a placeholder; clients can
also request one explicitly. The model run records its input-message
derivations and execution provenance, but never appears as a chat message. The
task captures the title it expects to replace, so a human rename made while the
model is working always wins.

The non-streaming management operations are also exposed by the generated
`ImpressAiService`. Its one trait definition supplies MCP tools, `impress` CLI
commands, and impel's grouped `impress` tool; HTTP remains the authenticated
native/Tailscale transport and is not a second capability definition.
