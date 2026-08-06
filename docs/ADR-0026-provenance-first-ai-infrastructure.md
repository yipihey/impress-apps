# ADR-0026: Provenance-First AI Infrastructure

**Status:** Implemented through Phase 1G  
**Date:** 2026-08-03  
**Depends on:** ADR-0001 (Unified Items), ADR-0003 (Provenance), ADR-0005/0015 (Task Kernel), ADR-0007 (Sync)

## Context

The standalone `~/Projects/LocalModels` project proved a useful Rust-first
workflow around oMLX: model discovery, OpenAI-compatible streaming, a browser
client reachable through Tailscale, explicit-page/web augmentation, and shared
conversations. Its SQLite database stores one JSON snapshot per conversation.

That persistence model cannot become an Impress subsystem. It gives messages,
images, sources, tool calls, and model executions no stable item identities and
would create a second sync authority beside `impress.sqlite`. In particular, an
iPhone that cannot reach the laptop must still be able to create and read
messages through the existing CloudKit item sync.

## Decision

### D1. `impress-ai` is the Impress integration kernel

`crates/impress-ai` owns transport-neutral AI request types, the
`InferenceProvider` port, oMLX discovery and stream parsing, multimodal request
resolution, content-addressed blob storage, and the conversation-to-inference
orchestration boundary. It is usable by a daemon, HTTP/Tailscale adapter,
generated service adapter, or UniFFI frontend. `OmlxClient` is the first
provider implementation; the durable executor depends only on the port and
records the provider and endpoint identities supplied by it.

LocalModels and its browser interface may continue as a first-class frontend.
The boundary is capability ownership, not interface retirement: shared
business rules, execution, provenance, and Impress persistence live in the
Rust core; web and native clients remain deliberately thin.

The existing `impress-llm` crate remains temporarily for its current cloud
provider consumers. New local conversation infrastructure goes into
`impress-ai`; the two can be reconciled after the new provider port has at
least two working backends.

### D2. The shared item graph is the only conversation authority

The standalone `chats.sqlite3` snapshot store is not copied. Durable state is:

| Record | Purpose |
|---|---|
| `conversation@1.0.0` | Thread parent and per-conversation model/tool policy |
| `chat-message` | Human, assistant, system, or tool message; parent is the conversation |
| `content-blob@1.0.0` | Immutable content hash, MIME type, size, and byte-transport locator |
| `task@1.0.0` / `impress.ai.respond` | Offline-safe queued inference request |
| `agent-run@1.0.0` | Exact provider/model/request/usage execution provenance |
| `tool-invocation@1.0.0` | Arguments, result, timing, provider, and failure for one tool call |

Messages attach blobs with `Attaches`, replies use `InResponseTo`, model runs
use `DerivedFrom` edges to all input messages, and assistant messages carry
`produced_by = run_id`. This makes “why did the model say this?” a graph query.

### D3. Offline clients enqueue work; the model host executes it

```text
iPhone offline                  CloudKit item sync              Mac/server
--------------                  ------------------              ----------
write conversation ───────────► synced item
write user message ───────────► synced item
write pending task ───────────► synced task ──────────────────► impel-taskd
                                                                │
                                                                ▼
                                                          oMLX stream
                                                                │
assistant message ◄──────────── synced item ◄──────────────── run + result
```

`queue_user_turn` atomically inserts the user message and dispatchable task.
It does not require oMLX or an HTTP connection. `impel-taskd` registers
`AiTaskExecutor` (with the compatibility name `OmlxTaskExecutor`), observes the
task after it reaches the laptop/server, and
writes the run plus assistant result back to the graph. The existing 90-second
live-store startup guard still applies.

An online impart client may additionally use a direct HTTP stream for immediate
token presentation. That stream is presentation state; the graph result remains
authoritative and must converge with the streamed view by item id.

### D4. Large modality bytes do not live in item JSON

`content-blob` records are small syncable metadata. Bytes are immutable and
content-addressed by SHA-256 behind the `BlobStore` port. Phase 1 includes a
sharded local CAS (`FileBlobStore`). A CloudKit `CKAsset`/iCloud adapter will
implement the same port for cross-device bytes; until an asset is available on
a device, the metadata and message remain visible with an unavailable
attachment state.

Immediately before inference, `AiStore::prepare_request` verifies and resolves
the bytes into endpoint content parts:

- images → OpenAI `image_url` data URLs;
- audio → OpenAI `input_audio` parts;
- UTF-8 text/JSON → text parts;
- unsupported formats fail explicitly rather than silently dropping context.

This keeps CloudKit's `payload_json` below its record-size ceiling and retains
provenance even when a blob is temporarily unavailable.

### D5. Tool access is an allowlist attached to the conversation

`enabled_tools` stores stable capability ids such as `scix`, `impress-mcp`, and
`web`. This is the data model behind the future impart dropdown. The inference
layer intersects that policy with installed tool definitions; a disabled or
uninstalled capability is never sent to the model.

Every executed call becomes a `tool-invocation` item. Tool implementations will
adapt existing generated `#[impress_service]` inventory rather than define a
second handwritten MCP surface. The initial taskd registration exposes no tool
definitions until execution adapters are installed, so a model cannot request a
tool the daemon cannot execute.

### D6. Tailscale is transport, not identity or storage

The LocalModels browser/Tailscale adapter remains a useful deployment pattern:
bind an authenticated service to loopback and publish it privately with
Tailscale Serve. It will become a thin adapter over `impress-ai`. Tailscale
reachability never determines whether a message exists, and no Tailscale URL is
persisted as the canonical identity of a model host.

Run provenance records a non-secret logical `endpoint` id. Credentials and
access tokens stay in the platform keychain/environment and are never written
to the shared graph.

### D7. Frontends consume core-owned declarative projections

Native and web frontends do not decode dynamic item payloads and reproduce
conversation, task, attachment, or tool-policy rules. `impress-ai` shapes
display-ready conversation rows and a complete conversation-screen projection,
following imbib's `BibliographyRow` pattern. Frontends render those records and
send commands back to the same core.

This keeps SwiftUI/AppKit and the LocalModels web UI independently evolvable
without creating two implementations of AI behavior. Canonical graph JSON
remains available for agents, diagnostics, and generic integrations; it is not
the native presentation API.

## Phase plan

### Phase 1A — implemented in this change

- canonical conversation/blob/tool schemas and expanded model-run provenance;
- shared-store `AiStore` with offline turn queueing and conversation snapshots;
- content-addressed blob port and local filesystem implementation;
- multimodal oMLX discovery/request/stream types, including reasoning, usage,
  and tool-call deltas;
- crash-safe scheduler executor registered in `impel-taskd`, with running-run
  reuse and idempotent assistant-message commits;
- schema-ref and focused Rust regression tests.

### Phase 1B — infrastructure implemented

- LocalModels' bounded web retrieval is in `impress-ai` behind a
  `ResearchContextProvider` port and persist every source as an artifact;
- the generated Impress service inventory and SciX service are projected into
  policy-addressable tool adapters with an agentic tool loop;
- an authenticated Axum HTTP/NDJSON adapter supports impart and the existing
  Tailscale deployment;
- retries reuse identical URL/content captures for the same turn, and every
  model-invoked tool call records arguments, result/error, provider, and timing.
- `InferenceProvider` separates the durable executor from oMLX's concrete
  transport without splitting the execution or provenance path;
- `crates/impress-ai-service` defines one generated `ImpressAiService` surface
  for model discovery, conversation create/read/list, offline message queueing,
  tool-policy changes, task status, and task/run provenance;
- those methods are linked into `impress-mcp`, the `impress` CLI, and the
  grouped local-model adapter from the same generated inventory;
- indexed `produced_by` queries return complete run lineage without scanning
  the item graph.

### Phase 1C — platform bridge implemented

- `SharedAiStore` extends the suite's existing `impress-store-ffi` XCFramework;
  impart's async `ImpartAIStore` gateway exposes conversation, offline-turn,
  attachment, policy, progress, provenance, and explicit migration operations
  to both native platforms without opening another database;
- CloudKit attaches immutable bytes to the existing `ImpressItem` record for a
  `content-blob@1.0.0`, preserving the item outbox's confirmation semantics.
  Rust verifies the descriptor hash and length before a fetched `CKAsset` enters
  the CAS; availability is derived per device and never synced as shared truth;
- Impart macOS and iOS start the suite CloudKit engine through its existing
  120-second launch guard and carry the shared container entitlement, so graph
  messages continue to converge when the model laptop is unreachable;
- the LocalModels importer opens `chats.sqlite3` read-only and atomically writes
  each conversation, messages, source artifacts/blobs, synthetic completed
  task/run lineage, and `ai-import-ledger@1.0.0` receipt. Restart skips matching
  content hashes; a changed legacy row is reported for review, not duplicated;
- importing LocalModels history is optional and explicit. The LocalModels app,
  web interface, and database may remain in use; no code automatically deletes
  or retires them.

### Phase 1D — declarative presentation boundary implemented

- Rust shapes display-ready conversation list rows and complete conversation
  views, including ordered messages, attachment metadata, durable task state,
  and selectable tool options;
- UniFFI exports those projections as typed records, so Impart's gateway no
  longer asks native UI code to decode item-envelope JSON;
- `enabled_tools` is the canonical policy. The legacy `web_access` field is
  updated atomically as a compatibility mirror and can no longer silently
  re-enable web access after the user turns it off;
- the built-in SciX, Impress, and web choices are declared in Rust, while
  unknown host capabilities round-trip visibly for forward compatibility.

### Phase 1E — first native conversation surface implemented

- `AIConversationWorkspaceView` is one shared SwiftUI surface for macOS and
  iOS. It renders only typed Rust projections and sends mutations through
  `ImpartAIStore`;
- users can create a conversation, choose its model id, enable SciX, Impress
  MCP, or web capabilities, queue a turn without model-host reachability, and
  inspect durable task state in the transcript;
- message and run ids, provider/model identity, reasoning, and attachment MIME,
  size, and content hash remain visible provenance handles rather than being
  flattened into presentation-only state;
- macOS exposes the surface as a first-class impart chassis destination and iOS
  exposes the same view beside Mail. The LocalModels browser remains unchanged.

### Phase 1F — native local-model workflow implemented

- Rust's oMLX client normalizes both endpoint roots and OpenAI-compatible `/v1`
  settings, then projects reachability, loaded models, context windows, and
  modalities through UniFFI; the Swift surface performs no model-host HTTP;
- host reachability remains device-local and is never synced as conversation
  truth. Synced messages and pending tasks remain visible while the laptop is
  unreachable;
- discovered models drive new-conversation and per-conversation model menus.
  Changing the preference affects future turns while prior agent-run provenance
  retains the model actually used;
- the composer imports images, audio, text, JSON, and other files through the
  Rust CAS and queues attachment-only turns as well as text turns;
- Local AI participates in Impart's normal navigation grammar as the sixth
  view mode (`⌘6`), with conversation search, pull-to-refresh, automatic
  transcript positioning, and live durable-task refresh.

### Phase 1G — managed model worker implemented

- `impel-taskd` holds an exclusive kernel lease per workspace, preventing two
  daemon instances from racing the same trigger and scheduler passes;
- a versioned, atomic heartbeat in `workspace/runtime` reports starting,
  startup-settling, ready, stopping, and failure states plus cumulative pass
  outcomes. The heartbeat continues independently during long oMLX calls;
- worker health is device-local infrastructure state. Rust projects fresh,
  stale, unavailable, and incompatible states through UniFFI without writing
  any of them into the synced graph;
- Impart displays oMLX host health and model-worker health separately. macOS
  can launch the signed worker from its sandbox-approved Application Scripts
  directory; iOS remains an observer and continues to queue synced work;
- the signing script can deliberately stage the entitled worker for Impart
  with `INSTALL_FOR_IMPART=1`, while the daemon's existing 90-second mutation
  guard remains authoritative after process launch.

## Trade-offs and revisit points

- A queued task gives robust offline behavior but not live tokens. The first
  HTTP adapter streams authoritative task changes as NDJSON. Token deltas remain
  a platform presentation channel and must converge by task/run/message id;
  it does not become a second execution or storage authority.
- CloudKit carries CAS bytes as verified assets on content-blob item records.
  A metadata record without a locally readable asset remains useful and reports
  device-local `missing`; it never overwrites another device's availability.
- The executor exposes definitions only when a matching execution adapter is
  installed. It bounds the agentic loop to six rounds and records every call.
- Conversation preferences are mutable payload fields, so changes have
  operation provenance and CloudKit LWW behavior. Per-message request settings
  are frozen in `agent-run` for reproducibility.

## Acceptance criteria

1. A user turn can be created with oMLX offline and appears as a message plus a
   pending task in `impress.sqlite`.
2. A model host can resolve the task, run oMLX, and write an assistant message
   whose `produced_by` run traces to every input message.
3. Image/audio bytes are hash-verified and never stored inline in item JSON.
4. Model/provider/parameters/usage and tool calls are queryable records.
5. Tool policy is an explicit allowlist and disabled capabilities are absent
   from the model request.
6. All schema refs pass the suite-wide exact-spelling guard.
7. The AI management surface is generated once and present in MCP, CLI, and
   impel's local-model tool inventory.
8. Impart can queue/read graph conversations through UniFFI on macOS/iOS, and
   CloudKit sync transports both messages and hash-verified content assets.
9. Re-running LocalModels migration is idempotent per source conversation, and
   changed legacy content is surfaced without deleting or overwriting either DB.
10. The same native conversation surface compiles for macOS and iOS, renders
    typed Rust projections, and queues mutations only through `ImpartAIStore`.
11. Impart discovers the configured laptop/server through Rust, offers its
    advertised models without hand-entered ids, and accepts multimodal turns
    without creating a second message or blob store.
12. Exactly one task worker owns a workspace, reports fresh health while
    settling or executing, and can be started and observed from Impart without
    making worker reachability part of synced conversation state.
