# Plan: the verb descriptor, the invoker pipeline, the lifecycle and one transport

**Status:** PROPOSED 2026-09-26 — an evaluation and a plan, no production code. Measured on a worktree of
main at 3222f573 (waves 7 and 8 merged); every number is from code, with the file:line beside it.
**Decision record:** [ADR-0034-verb-descriptor-pipeline-and-transport.md](ADR-0034-verb-descriptor-pipeline-and-transport.md).
**Depended on by:** [plan-auto-gui-and-self-docs.md](plan-auto-gui-and-self-docs.md) / [ADR-0035](ADR-0035-generated-verb-surfaces-and-docs.md)
(the generated GUI, reference docs and profiling). **Order:** this plan's P0 (security) first and
alone; then P1 (descriptor) and P2 (pipeline), which ADR-0035's every package consumes; P3 (lifecycle)
before ADR-0035 G4 makes every verb name public; P4 (jobs), P5 (transport), P6 (Python), P7 (rules
into construction) and P8 (runtime providers) are independent of ADR-0035 and of each other except
where a row says so.
**Input:** a critique of the pattern (Tom, 2026-09-26: "sound but held together more by vigilance than
by construction"), the three addenda, and the measurements below. Ids: `PL` (pipeline), `PO` (policy),
`LC` (lifecycle), `LR` (long-running), `TR` (transport), `PY` (Python), `RC` (rules into construction),
`RP` (runtime providers), `SEC` (security).

## Goal (Tom)

Make the invoker a pipeline every interface derives from; give verbs a policy and review layer, a
lifecycle, a job convention and one transport to the running apps; decide Python; turn the check-*
scripts into construction where a type or a generator can hold the rule; and let an out-of-process
provider in another language register verbs at runtime on equal terms.

## What "held together by construction" means (testable)

1. **One invoker, N interfaces.** Every path that runs a verb — MCP flat and grouped, the CLI, the surface
   runtime, the FFI verb host, impel-tools, the app-side HTTP route, mcp-host, impress-ai-tools and a
   runtime provider — calls one `Pipeline::invoke(descriptor, call)`; a test lists the entry paths from
   the code and fails when one calls `descriptor.handler` directly. Today: 9 paths call the handler
   themselves and 2 more bypass the invoker entirely (table PL1).
2. **A concern is written once.** Argument validation, reachability, policy, safety, spans, actor, audit
   and (later) undo are layers in that pipeline; adding one changes no entry path. Today: validation is in
   the macro (opt-in), reachability in three places with three rules, actor self-declared, audit in one
   path (table PL2).
3. **No caller runs a verb it may not.** A caller has an identity the pipeline established (person,
   named agent, app, web page — never from a request field); a destructive or external verb from an agent
   is queued as a review surface unless policy says otherwise. Today: none, and the automation servers
   admit any loopback caller with `Access-Control-Allow-Origin: *` (table SEC).
4. **A name can change.** A verb has `since`, can be `deprecated` with an `alias` that keeps the old
   name callable and counted, and a rename pass rewrites stored documents. Today: nothing (table LC).
5. **A long verb is a job.** One handle, progress events, cancel and result retrieval, the same over
   MCP, the CLI, a surface and the profiler. Today: request/response only; 53 verbs take seconds.
6. **One transport.** A verb reaches a running app by name over one route with the pipeline on both
   sides; the four hand-written adapters and their per-app Swift mirrors are gone. Today: 7,645 lines of
   adapter and client, 160 mirrored Swift routes, 8 dead routes (table TR).
7. **A rule is a type where it can be.** Schema refs are generated constants; an undocumented method
   does not compile; the scripts that remain check what construction cannot (table RC).
8. **A runtime provider is a first-class verb source.** Its verbs carry the same descriptor, pass the
   same pipeline, appear in the same catalogue, MCP, CLI and docs, and are held to the same coverage
   check; its safety claims are not taken on faith (§ Runtime providers).

9. **Build time per verb must not grow past the budget.** The macro's per-verb cost (generated
   lines, llvm-lines, seconds cold and incremental) is measured and a CI check fails when a change
   pushes it past the budget; the pipeline layers are the thin-shim opportunity (§ Build cost).

## Measurements

### Table PL1 — every path that runs a verb

The macro-generated invoker (`crates/impress-service-macros/src/lib.rs:512-521`) is exactly: parse the
args (strict only when `strict_args = true`, `:463-482`), construct the instance, call the trait method,
`serde_json::to_value`. It has no envelope, logging, timing, actor, policy or undo. The same fn is
registered twice (`McpToolDescriptor.handler` `:529`, `CliSubcommand.apply` `:540`).

| Path | Where the handler is called | Notes |
|---|---|---|
| (a) MCP flat `tools/call` | `impress-mcp/src/server.rs:642` → `inventory_bridge.rs:64` → `impress_capabilities::call` → `service-core/src/call.rs:55` | order inside: `render_pdf_page` bypass `:646`, grouped dispatch `:652`, legacy tools `:660`, reachability refusal `:675`, then the inventory |
| (b) MCP grouped | `impress-mcp/src/surface.rs:351` → `:421` → same as (a) | resolves only reachable tools `:194,:372-392` |
| (c) CLI (three binaries) | `service-core/src/cli.rs:264 dispatch_matches` → `:278 (descriptor.apply)` | `impress-cli/src/main.rs:167`, `imbib-cli:36`, `imprint-cli:39`; implore-only backend probe `impress-cli:121-131` |
| (d1) surface runtime, linked verb | `impress-surface-service/src/runtime.rs:65 call_verb` → `call.rs:62` | `call` effects and `verb` sources `runtime.rs:1286` |
| (d2) surface HTTP mirror | `service.rs:1227 call_verb_on` — **does not call the handler**: repeats `strict::args` (`:1244-1256`) then calls the trait method | from the FFI `SharedSurface::route` `store-ffi/src/surface.rs:898/977` |
| (e1) FFI verb host | `store-ffi/src/surface.rs:335 HostAdapter::call_verb` → Swift `ImpressVerbHost.swift:53` → (f) | |
| (e2) FFI layout apply | `store-ffi/src/layout.rs:590/599/950` — **does not call the handler**: `strict::args::<Verb>` (`:623,:1005`) then `DefaultLayoutService::apply_verb_as` | the GUI's every chord and `/api/layout/verb` |
| (f) impel-tools | `impel-tools/src/lib.rs:320 call_tool` → `:350` | probing `:130-202`, 60 s cooldown `:127` |
| (g) `*-service-http` | installs a backend only (`imbib-service-http/src/lib.rs:1623`); never calls a handler | called by impress-mcp `main.rs:84-94`, impel-tools, impress-cli |
| (h1) impress-mcp-host / vw-mcp | `impress-mcp-host/src/lib.rs:298` → `:323` | bearer + prefix allowlist `:63,:170-199` |
| (h2) impress-ai-tools | `impress-ai-tools/src/lib.rs:291` → `:323` | from `impress-ai/src/executor.rs:407`, hosted by impel-taskd |

Nine call sites of the handler, two bypasses, and no `Invoker`/`Dispatcher` trait or interceptor
anywhere. `call.rs:55/:62` is the natural single seat of a pipeline; (d2) and (e2) are the two places
a macro-level concern would silently miss.

### Table PL2 — concern × entry path today (A applied, P partial, S skipped)

| Concern | (a) MCP flat | (b) grouped | (c) CLI | (d1) surface linked / (d2) HTTP mirror | (e1) verb host / (e2) layout apply | (f) impel-tools | (h1) mcp-host | (h2) ai-tools |
|---|---|---|---|---|---|---|---|---|
| Argument validation | P (strict for 2 services) | P (+ `args` must be an object `surface.rs:404`) | P (clap types; strict for 2) | P / **A** (second strict pass `service.rs:1244`) | P / **A** (`strict::args::<Verb>` `layout.rs:623`) | P (JSON parse `:344`) | P | P (`:313-320`) |
| Reachability | A `reachability.rs`: 4 namespaces, probed once at startup, never re-probed | A `available()` | P (implore only) | S / host refuses `host-unavailable` | S / A via (f) | A: **every** `imbib-*`/`imprint-*` namespace, re-probed | S (prefix allowlist) | A: 4-namespace rule, refreshed 300 s |
| Actor | P: `actor` is a free argument; `actor_from` (`layout-service/src/authorship.rs:66-72`) maps `"human"` → Human — **an MCP client can claim to be the person** | same | same (`--actor human`) | surface verbs hard-code Agent (`service.rs:668,703,944,983`); `call` effects do not forward the dispatch actor (`runtime.rs:1286`) | A: Swift passes `human` (`LayoutController.swift:306`), HTTP passes `agent` | S | S | S |
| Result envelope | A (`split_mcp_content`, `envelope_structured_content`, `isError` from `ok:false` `server.rs:709-733`) | A | A (exit 0/3/1/2) | codes / HTTP status from `refusal::http_status` | `SharedLayoutError` | S: raw string; `ok:false` is not an error | A | S |
| Logging / audit | **S** — no per-call log, no logger installed | S | S | P (`log` target `surface` for effects) | A (`layout` target with actor) / — | S in Rust | S | **A**: `record_tool_invocation` store row with args, result, duration (`executor.rs:424-438`) — the only per-call audit anywhere |
| Policy | S | S | S | S | S | S | P (bearer + prefix) | P (`ToolPolicy` consulted only for `"web"` `executor.rs:227`) |
| Undo | verb-specific (layout rings, imbib `*_undoable`, neither partitioned by actor) | | | | | | | |
| Timing | S | S | S | S | S | S | S | A (`Instant` per call `executor.rs:406`) |

Three different reachability rules, actor self-declared everywhere it exists, one audit record in one
path, `wire_version` added only by strict refusals and the layout/surface DTOs.

### Table SEC — the automation servers, as measured

| Finding | Evidence | One-line mitigation |
|---|---|---|
| **SEC-1** `Access-Control-Allow-Origin: *` on every response and on preflight | `packages/ImpressAutomation/.../HTTPResponse.swift:33-36`; `SharedAutomationRoutes.swift:164-175` | drop the header, or reflect an app-owned origin allow-list and require a custom request header so simple CORS requests fail preflight |
| **SEC-2** Loopback callers admitted with no token, unconditionally, on every route including mutating ones | `HTTPAuthPolicy.swift:46-48`; evaluated before routing `HTTPServer.swift:301-322` | a per-launch loopback token in a 0600 file in the app-group container, read by the Rust client, required on every non-GET |
| **SEC-3** No `Host`/`Origin` check anywhere → with SEC-1 and SEC-2, DNS rebinding lets any web page drive every route | grep of `HTTPRequest.swift`/`HTTPServer.swift` is empty | reject a `Host` not in `{localhost, 127.0.0.1, [::1], the bound address}` in `HTTPServer.processRequest` |
| **SEC-4** The bearer exists for non-loopback only, and **only imbib wires it**; the other five apps pass `allowNetworkAccess=false, authToken=nil` (`HTTPServer.swift:41-42`); the token is in `AutomationSettings`, not the keychain; the only client that sends one is `IMBIB_TOKEN` | `HTTPAuthPolicy.swift:55-82`, `HTTPAutomationServer.swift:82-104`, `AutomationSettings.swift:196-202` | build `HTTPServerConfiguration` from the shared `AutomationSettingsSection` in every app; one `IMPRESS_APP_TOKEN` in one shared client |
| **SEC-5** With network access on, the listener binds all interfaces (`HTTPServer.swift:91-98`), gated per request by the bearer | | bind the tailnet address explicitly; refuse network mode without a token |
| **SEC-6** Mutation on GET: impel `GET /agents/{id}/next-thread?auto_claim=true` claims a thread (`ImpelHTTPRouter.swift:585-610`); shared `GET /api/performance/reset`, `/api/store-timings/reset` (`SharedAutomationRoutes.swift:127-135`) | | claim becomes POST; the resets drop GET |
| **SEC-7** impress-ai-http (`crates/impress-ai-http`): bearer required except `/api/health`, `/api/pair` — correct — but `main.rs:17-18` defaults to `127.0.0.1:23125`, **impress's app port**, while `run.sh`, `docs/impress-ai-http.md:22` and `SiblingApp.Services.impressAIPort` say 8787 | | change the `main.rs` default to 8787 |
| **SEC-8** impel-server accepts any bearer starting `impel-` or equal to `system` and **fails open with no Authorization header** (`crates/impel-server/src/auth.rs:38-50`); `auth_middleware` is defined and never wired into the router | | delete the fail-open arm and the prefix check; validate registered agent tokens only; wire the middleware |

### Table LC — lifecycle: what a rename breaks today

Verified: no `since`, `deprecated` or `alias` anywhere in `impress-service-core` or the macro (grep: 0
hits); `WIRE_VERSION` (`wire.rs:10`) versions result shapes, not names; a verb's name is
`concat!(service_kebab, "_", kebab_name)` (`macro lib.rs:391,537`) with no rename hook; the only
remapping is `cli::effective_names` (`cli.rs:102`) for clap collisions; ADR-0024 D7's move of the four
legacy tools under a real namespace is the one planned rename and is outstanding.

| Where a verb or view kind is named as a string | References | Detail |
|---|---:|---|
| Stored surface specs — `sources.*.verb`, `call.verb`, `open.view_kind`, `params[].kind` (`impress-surface/src/spec.rs:62,93,292,336`) — **live store** | **0 rows** | the user's store (377 MB, copied and read with `?immutable=1`) has no `impress/ui/surface@1.0.0` row |
| Stored layouts and presets — `pane.view_kind`, `role`, `query.kinds` — **live store** | 9 layout rows / 28 panes; 10 preset rows / 32 panes | view kinds outline 19, list 19, info 14, pdf 3, source 4; all preset rows system-authored, version 2, re-seedable |
| Shipped example surfaces (3 files) | 7 verb refs, 5 distinct | `surface-demo-service_series/_histogram` ×2 each, `triage-service_set-starred/_set-flag/_add-tag` |
| Shipped presets (`presets.rs:205-228`, 14 incl. `for_impress`) | 44 panes | outline 14, list 14, info 9, pdf 4, source 3 |
| `docs/agent-surfaces.md` | 22 distinct names, 28 mentions | tested by `doc_wire.rs` |
| `crates/impress-mcp/src/guide.md` | 57 distinct, 87 mentions | untested |
| Swift string literals `"-service_…"` | **0** | dispatch is by-name pass-through (`ImpressVerbHost.swift:46-53`) |
| Other record kinds naming tools | `agent-run@1.0.0.tool_calls` (13 rows, all `web.research-context`), `tool-invocation@1.0.0` (13), `conversation.enabled_tools` (catalogue ids, not verbs) | none names a verb |

A verb rename breaks **zero** stored documents today and 15 documentation mentions; a view-kind rename
touches 60 panes in 19 re-seedable rows. Reusable machinery: `SHIPPED_FINGERPRINTS` /
`upgrade_if_untouched` (`presets.rs:370,1213`), `impress_core::task_schema_migration` (flagged,
reversible, ledgered), `quarantined_reason` for an undecodable row (`layout-service/src/store.rs:173`),
`ViewKindId::KNOWN` + `LEGACY` (`impress-layout/src/ids.rs:237-258`). Verb use is logged by name only
in Swift (`ImpressVerbHost.swift:54`, every surface-routed call) and impel's local GRDB
`counselToolExecution`; Rust logs refusals only. The window to add a lifecycle is now, before ADR-0035
G4 puts every name in a catalogue and a stored surface per verb.

### Table LR — long-running verbs today

53 verbs are `long_running` in the safety census; the 33 read in depth: none reports progress while it
runs, none can be cancelled by its caller, the only limits are timeouts, and two write a status row
(`project-build` a `manuscript-build@1.0.0` row `running → ok|failed`, `project_service.rs:2683-2795`;
the watched-folder scan its folder row, after the fact). MCP cannot carry anything asynchronous: the
server is a serial `for line in stdin.lines()` (`server.rs:20-75`), advertises `2024-11-05` with
`{tools, resources}`, drops every id-less message so `notifications/cancelled` is ignored (`:49-51`),
and has no `progressToken`; `handler: fn(Value) -> ServiceFuture` has no progress sink or cancel token,
so a long verb blocks the whole MCP session.

| Why long | Verbs | Progress today | Cancel today |
|---|---:|---|---|
| network or a sibling app (30 s client timeout, no retries) | 26 | log lines in the app; `isLoading` flag for `rg-load` | the client timeout; the app keeps working (`rg-batch`) |
| reMarkable over USB | 7 | none | none |
| compile (Typst in-process, no `spawn_blocking` for `compile-typst`/`project-compile`; Tectonic and builds under `spawn_blocking`) | 7 | `compile_ms` in the result; `project-build`'s status row | `project-build`'s runner kills a step at 600 s (`runner.rs:240-249`); `cancelled` is declared (`manuscript_build.rs:24`) and never written |
| AI provider / daemon probes (up to 3 × 5 s, cached 60 s) | 4 | none | per-probe timeout |
| subprocess (`osascript` PDFKit render — a blocking `Command::output()` inside an async fn with **no timeout**, `source_assets.rs:242`; `security`; veusz) | 4 | none | none |
| self-test tier b | 3 | one report at the end | per-request timeouts |
| batch over rows (`import-directory`, `search-all`'s unbounded scan `bridges lib.rs:641-663`) | 2 | counts in the result | none |
| long-poll (`surface-wait`) | 1 | the events are the progress | the deadline |

Job-like machinery that exists, and what each lacks:

| Mechanism | Handle | Lifecycle | Progress | Cancel | Result |
|---|---|---|---|---|---|
| impel kernel `task@1.0.0` (8,027 rows live) — `task_spawn.rs:102`, `impress-core/src/task.rs:15,74` | item UUID, durable, synced | pending/running/done/failed/cancelled, retry 45 s×3ⁿ, review suspension | **none per task** (a pass report and a 5 s heartbeat file) | **pending only**, cascades; running refused (`impel-service/src/lib.rs:642`); 20-min timeout | output items + `agent-run` via `ProducedBy` |
| impress-ai `queue_message` — a `task@1.0.0` of kind `impress.ai.respond` (`store.rs:27`) | `{conversation_id, message_id, task_id}` | task state + run status | one preview; `GET /api/tasks/{id}/events` is NDJSON from a 500 ms server poll (`impress-ai-http/src/lib.rs:777-839`) | none | message `produced_by` run |
| surface event ring `impress/ui/surface-event@1.0.0` | `(surface, host, seq)` | — | 200-row ring, `surface_wait` ≤ 55 s, `gap` flag, cursor unchanged on timeout | — | events / `into` state |
| `manuscript-build@1.0.0` | row id, after the fact | running/ok/failed | none | none | blobs + diagnostics |
| Swift CounselEngine (impel app, GRDB) | task id | queued/running/completed/failed/cancelled | sequenced in-memory event log, `GET /api/tasks/{id}/stream` long-poll ≤ 30 s | queued **and running**, cooperative | `/result` |

The kernel has the spine (durable handle, validated lifecycle, retry, review, provenance, three
consumers); the surface ring has the progress transport (cursor, bounded ring, gap, long-poll with the
cursor unchanged on timeout); CounselEngine has the right shape and is in the wrong language.

### Table TR — the transport to the running apps

| Adapter (`*-service-http` + its client) | Lines | Trait methods | Distinct routes | Beyond forwarding |
|---|---:|---:|---:|---|
| imbib (`imbib-service-http` + `impress-app-client/src/imbib`) | 1,686 + 2,818 | 117 | 98 | probe + `BackendSlot` (`lib.rs:1623-1686`, `IMBIB_BACKEND`, `IMBIB_HTTP_URL` + legacy `IMBIB_BASE_URL`); 1 s probe, 30 s timeout; **the only client with a bearer** (`IMBIB_TOKEN`); a UUID→cite-key LRU; envelope decode; `sidebar_view` bypasses HTTP and reads the store (`lib.rs:65-79`); `library_size: null` over HTTP; **every method swallows `Err` into empty/default** (`lib.rs:36-47`) |
| imprint (`imprint-service-http` + `impress-app-client/src/imprint`) | 606 + 1,108 | 37 | 36 | probe; no token; export-format parsing; `compile_typst` parks PDF bytes to a path (`lib.rs:203-215`) |
| implore (client embedded) | 723 | 32 | 22 | probe, private tokio runtime; no token; create-figure body renames; 400 → `refused`; `rg_*` return raw JSON strings |
| impart (client embedded) | 383 | 14 | 11 | probe; no token; unknown method → POST silently (`lib.rs:56-59`) |
| **total** | **7,645** | **200** | **167** | no retries anywhere; four copies of the probe loop (impress-mcp `main.rs:84-93`, impel-tools, impress-ai-tools `lib.rs:114-124`, impress-cli `:129`) |

| Swift router | Lines | Route arms | Mirror of an adapter | App-only | Generic dispatcher |
|---|---:|---:|---:|---:|---|
| imbib `HTTPAutomationRouter.swift` | 5,497 | 158 | 97 | ~57 (reMarkable, eink, backups, layout/appearance/commands, plot, participants, tags/tree, PDFs) | 4 `/api/surface` mounts + the shared group |
| imprint `ImprintHTTPRouter.swift` | 3,636 | 73 | 33 | ~40 (tasks, templates, citation-usages, veusz, comments accept/reject, insert-citation…) | shared mount |
| implore `ImploreHTTPRouter.swift` | 1,189 | 22 | 20 | 2 | shared mount |
| impart `ImpartHTTPRouter.swift` | 1,185 | 17 | 10 | 7 (accounts, mailboxes, messages, send) | shared mount |
| impel `ImpelHTTPRouter.swift` | 1,384 | 41 | 0 (no adapter exists) | 41 (threads, personas, escalations, tasks) | shared mount |
| impress `ImpressHTTPServer.swift` | 110 | 1 | 0 | 1 | shared mount |
| `packages/ImpressAutomation` | 1,842 | 6 + 4 layout + `/api/surface*` | — | — | **two real generic dispatchers already**: `POST /api/layout/verb` (`LayoutAutomation.swift:23-29,201-216`) and `/api/surface/*` → Rust's own route table (`SurfaceAutomation.swift:20-27,110-115`) |
| **totals** | **14,843** | **312** | **160** | **~148** | **no `/api/verb/<name>` anywhere** |

Dead routes (8): implore `plot-series`, `plot-histogram`, `rg-statistics`, `rg-slice-raw`,
`rg-slice-png` (Rust POSTs, Swift serves GET and reads `queryParams`, so the body would be ignored
even if the method matched — `implore-service-http/src/lib.rs:324-393`, `ImploreHTTPRouter.swift:126-145`);
imprint `POST /api/documents` (Swift has only `/create` and `/from-template`), `POST
/api/documents/{id}/metadata` (Swift is PUT, so `update_metadata` always returns `false`), `POST
/api/outline` (no such route; the client falls back on 404, a wasted round trip). imbib's 98 and
impart's 11 routes all match. In-process inventories: only `impress-store-ffi` (kit: store, layout,
surface, demo) and `impel-tools` (imbib + imprint services with HTTP backends) carry
`uniffi::setup_scaffolding`; **imbib, imprint, implore and impart do not link their own `*-service`
crate in-process**, so a generic verb route in imbib needs a per-app FFI target linking `imbib-service`
with its default store backend (dispatching through impel-tools inside imbib would loop back over HTTP
to itself).

### Table RC — rules into construction

| Check / rule | Invariant | Mechanism today | By construction | Cost | Script still needed? |
|---|---|---|---|---|---|
| `check-schema-refs.sh` + 5 `schema_ref_manifest.rs` | every `schema_ref` literal is canonical; registries equal the manifest | Python regex walk (`:105-175`), serde set compare; CI `workspace-rust.yml:77` | **build.rs in `impress-core` reads `schema-refs.json` → `pub const IMBIB_LIBRARY: SchemaRef = SchemaRef("imbib/library")` + `ALL`; `SchemaRef` becomes `#[repr(transparent)] struct SchemaRef(&'static str)` with no public constructor (today `pub type SchemaRef = String`, `schema.rs:6`); `query_by_schema`/`count_by_schema`/`QueryRequest.schema` take it → a misspelt literal does not compile.** Swift: the same build.rs emits a `#[derive(uniffi::Enum)] enum SchemaRef` through `impress-store-ffi` so Swift gets `.imbibLibrary` from the existing bindgen | ~40-line build.rs; 271 Rust literal sites in 65 files (54 are already `const`s; sed-able from the manifest); 116 Swift sites in 46 files optional; 7 bindings regenerated | Rust half: no. Swift half: yes until the enum is adopted; the JSON stays the source |
| `check-uniffi-bindings.sh` | every `#[uniffi::export]` appears in the committed Swift; copies identical | regex export inventory vs `func` names (`:97-238`); the real regen-and-diff runs only post-merge (`imbib-rust.yml:116-147`) | a per-crate test that runs `uniffi_bindgen` into a temp dir and byte-compares the committed file, at PR time | dev-dep + cdylib build in 7 crates | yes as the sub-second Swift-lane guard, unless the test runs everywhere |
| `check-kit-deps.sh` | 12 kit crates reach only the kit / `impress-core`'s store features | `cargo tree` + a bash classifier (`:113-176`, `--self-test`) | none in Cargo (no cross-crate visibility); subsumed by a real workspace split | large | yes — fast, names the edge |
| `check-kit-standalone.sh` | the kit + `impress-core` builds alone | scratch workspace via `git ls-files`, `cargo check` (`:213-390`) | make the kit its own Cargo workspace | medium–large (two lockfiles, shards, rust-analyzer) | no, if split |
| `check-kit-packages.sh`, `check-chassis-deps.sh` | `Package.swift` deps on an allowlist | grep over `Package.swift` | SwiftPM has no rule; an XCTest parsing `Package.swift` is the same check | none gained | yes |
| `no-typescript.yml` | zero tracked `.ts`/`.tsx` | `git ls-files` (`:66-95`) | already by construction upstream (the macro generates the tools); `*.ts` in `.gitignore` as a local guard | trivial | yes, as the backstop |
| `rust-gate.sh` | fmt / clippy `-D warnings` / test per shard | one script owns the shards (`:24-63`) | `[workspace.lints]` + `[lints] workspace = true` in 73 crates; `clippy.toml` `disallowed-types` for `String` schema refs — **neither exists today** | 73 `Cargo.toml` lines, possible new warnings | yes for sharding |
| DoD — UI surface / capability matrix (`CLAUDE.md:249`) | every node kind has a matrix row and a `capabilities(of:)` case | **prose only** — no script, no test walks node kinds | a `switch` with no `default` over the enum + a golden test rendering the matrix from the enum, as `ViewKindId::KNOWN` already does for view kinds | a Swift refactor + one golden | — |
| DoD — features / self-test (`CLAUDE.md:250`) | every feature has a Tier A/B capability or a test | **prose only** | a test walking the linked inventory asserting each verb is named by some capability (ADR-0035 G3 makes this the examples check) | one test | — |
| `#[impress_method]` documentation | every method has a description | **not enforced** (`collect_doc` returns `""`, `macro lib.rs:87,300`) — 54 fallbacks shipped | the macro emits `syn::Error` on an empty doc | ~5 lines | no |
| DoD — Rust changes, UniFFI exports, schema refs (`CLAUDE.md:252-291`) | run the gate; regenerate bindings; keep the manifest true | the scripts above, plus the pre-push hook | as above | | |

Redundant pairs: `check-kit-deps` ⊂ `check-kit-standalone --strict` (except the `impress-core` feature
restriction, which only kit-deps holds); `canonical_has_one_spelling_per_base_name` duplicates
`check-schema-refs.sh:188-197`; the uniffi name check ⊂ the post-merge regen-and-diff, which runs too
late. No `[workspace.lints]`, no `clippy.toml`; `build.rs` exists only as one-line `rerun-if-changed`
pins in four crates.

### Table PY — Python today

Two crates carry hand-written pyo3 modules and their own MCP servers outside the inventory:
`im_bibtex` (8 functions + 4 classes; verbs exist for 2 — `decode_latex`, `expand_journal_macro`) and
`im_identifiers` (19 functions; verbs exist for 4). The macro's module doc (`lib.rs:43`) promises
per-method pyo3 shims it does not emit. A per-method shim generator would be ~433 functions × a pyo3
signature each, a Python package per service crate, a wheel build in CI and a maintenance surface equal
to the CLI's; a generic binding is one function.

### Duplicate inventories (recorded, not planned)

Three force-link lists name service crates: `crates/impress-capabilities/src/lib.rs:58-93` (13
entries, feature-gated), `crates/impress-capabilities-kit/src/lib.rs:62-69` (4, the kit slice, needed
because `impress-store-ffi` cannot depend on `impress-capabilities` without a package cycle through
`impress-bridges-service → imprint-service → impress-app-client → imbib-service-http →
impress-store-ffi`), and `crates/impress-ai-tools/src/lib.rs:15-32` (10, its own copy, ungated). The
kit list can go away when the cycle does — i.e. when P5 deletes the `*-service-http` adapters and
`impress-app-client`, the edge `imbib-service-http → impress-store-ffi` disappears and
`impress-capabilities` can be the one list with a `kit` feature. `impress-ai-tools`'s list can go
today: it should depend on `impress-capabilities` with the features it wants (finding **PL-6**).
`impel-tools` is a fourth, smaller inventory (imbib + imprint + memory) with UniFFI on top; it goes
when the app-side generic route (P5) gives impress and impel the full inventory over the transport.

### Build cost

Measured separately (Tom's fourth addendum): `cargo --timings` cold and incremental, llvm-lines per
`#[impress_method]`, build time per verb, and an evaluation of thin shims, one test binary per crate,
sccache, feature trimming / hakari and `build-override` opt-level, with a CI budget check. The measured
section is § Build cost as a measured budget below (findings `BC-*`, work packages B1–B6); the raw
record is [`plan-verb-pipeline-build-cost.json`](plan-verb-pipeline-build-cost.json). Headline: a cold
workspace build is 54.9 s wall (127 ms per verb), macro output is 33 % of the service crates' LLVM IR
(1,713 lines per verb) but the service crates are 5.5 % of cold unit-time, so verb count is not the
scaling limit; dependencies are 78 %.

## Findings

- **PL-1** The invoker is one strict check and nothing else; nine paths call the handler and two bypass
  the invoker (`call_verb_on`, FFI layout `apply`), so no macro-level concern reaches the GUI. *Fix:* P2's
  `Pipeline` seated in `call.rs`, with the two bypasses routed through it.
- **PL-2** Three reachability rules (impress-mcp: 4 namespaces once at startup; impel-tools: every
  `imbib-*`/`imprint-*`, re-probed; impress-ai-tools: 4 namespaces every 300 s). *Fix:* one
  reachability layer reading the descriptor's `needs_app` and one probe.
- **PL-3** Actor is self-declared: `actor: "human"` over MCP or the CLI is believed
  (`authorship.rs:66-72`). *Fix:* the policy layer derives the actor from the caller identity and
  refuses a claimed one.
- **PL-4** One audit record exists, in impress-ai-tools only (`record_tool_invocation`, with argument
  values). *Fix:* the audit layer writes one attributed operation per non-read verb, sizes and ids
  only, for every path.
- **PL-5** `ok: false` is not an error on the impel-tools and ai-tools paths (raw `Value`). *Fix:* the
  envelope layer.
- **PL-6** `impress-ai-tools` keeps its own force-link list. *Fix:* depend on `impress-capabilities`.
- **PO-1..8 = SEC-1..8** above. SEC-1..3 together are the finding that makes P0 first.
- **LC-1** No lifecycle; names are Rust identifiers; the four legacy tools' rename (ADR-0024 D7) has no
  mechanism to land on. *Fix:* P3.
- **LC-2** Verb use is logged by name only in Swift and impel's GRDB. *Fix:* the span/audit layer counts
  calls by name, which is what a deprecated alias needs.
- **LR-1** No verb reports progress or accepts a cancel; `get-page-image` runs `osascript` with no
  timeout on the executor thread; `compile-typst` and `project-compile` compile in-process without
  `spawn_blocking`; `search-all` scans every row unbounded. *Fix:* P4 for the convention; the three
  one-liners (`tokio::time::timeout`, `spawn_blocking`, a limit) are P4's first gate.
- **LR-2** MCP cannot carry progress or cancel (serial loop, protocol 2024-11-05, id-less messages
  dropped). *Fix:* P4's job verbs make long verbs return in milliseconds; MCP progress notifications are
  an additive follow-on once the server reads `progressToken`.
- **TR-1** 7,645 lines of adapter forward 200 methods over 167 routes to 160 hand-written Swift mirrors;
  8 routes are dead; errors are swallowed into empty results (`imbib-service-http lib.rs:36-47`), so a
  dead route looks like "no data". *Fix:* P5.
- **TR-2** imbib, imprint, implore and impart link no in-process inventory; only impress-store-ffi and
  impel-tools do. *Fix:* P5's per-app FFI target.
- **TR-3** The probe loop exists four times. *Fix:* one, in the transport.
- **PY-1** The macro claims shims it does not emit; two crates ship private MCP servers. *Fix:* P6.
- **RC-1** `SchemaRef` is a `String` alias; 271 Rust and 116 Swift literals are checked by a script.
  *Fix:* P7.
- **RC-2** The macro accepts an undocumented method. *Fix:* P7 (also ADR-0035 G1).
- **RC-3** Two Definition-of-done bullets are prose only. *Fix:* P7's golden tests.
- **RP-1** A runtime verb cannot be a `McpToolDescriptor`: its fields are `&'static` and its handler a
  `fn` pointer with no captured state; 12 files iterate `McpToolDescriptor::iter()` directly (10 not
  through `call.rs`). *Fix:* P1's descriptor is `Arc<dyn>`-friendly and P8's registry sits behind
  `descriptors()`/`find()`, which every reader then uses.

## Design

### P1 — the descriptor

One `VerbDescriptor` in `impress-service-core`; `McpToolDescriptor` and `CliSubcommand` become
projections (kept as types so the 30 readers compile, each a `From<&VerbDescriptor>`):

```
VerbDescriptor {
  name, qualified_name, description, group, surface,         // today's + ADR-0024 D3
  input_schema: fn() -> Value, output_schema: fn() -> Value, // derived
  safety: Safety { class, idempotent, long_running, needs_app },
  examples: &'static [Example], since: &'static str,
  deprecated: Option<Deprecation { since, alias_of, note }>,
  budget_ms: Option<u32>, source: Source::Linked | Source::Provider(id),
  handler: Handler,                                          // fn ptr for linked, Arc<dyn> for providers
}
```

Derived where possible (output schema from the return type; group from the crate; `needs_app` from
the service's `BackendSlot`), declared otherwise (`impress_service_impl! { safety = read_only, since =
"0.9" }` per service, `#[impress_method(safety = destructive)]` per exception, `#[impress_example]`).
Every declared field has a test that walks the linked inventory and fails when it is missing or
disagrees with the committed tables (ADR-0035 § Descriptor shape has the field-by-field checks).

### P2 — the invoker as a pipeline

`Pipeline::invoke(descriptor, Call { args, caller: CallerIdentity, trace: Option<TraceParent> })`
runs an ordered chain, each layer written once in `impress-service-core`:

1. **identity** — establish `CallerIdentity` from the transport (a UniFFI call from the app is
   `Person`; MCP stdio is `Agent(name from initialize)`; the app-side HTTP route is whatever its token
   says; a provider is `Provider(id)`); never from an argument. The `actor` argument the layout verbs
   take today becomes read-only-derived from it (PL-3).
2. **strict args** — the schema check, for every verb (ADR-0035 D-G1).
3. **reachability** — `needs_app` and one probe with one rule (PL-2).
4. **policy** — `(identity, safety.class, verb) → Allow | Review | Deny`; `Review` for a destructive or
   external verb from an agent creates the review surface (ADR-0035 § Safety in the GUI) and returns
   `{ok: false, code: "review-pending", surface_id}`; the person's later confirm re-enters the pipeline as
   `Person`.
5. **span** — `tracing` span `verb{name, ok, code, arg_bytes, result_bytes, ids}`; the I/O seams nest
   under it.
6. **invoke** — the generated handler, or the provider transport.
7. **envelope** — `ok`/`code` read from the result, `wire_version` stamped, `_mcp_content` split by the
   MCP projection only; `ok:false` is an error on every path (PL-5).
8. **audit** — one attributed operation row for every non-read-only verb (`core/operation`, existing
   kind; author `<kind>:<name>`), sizes and ids only (PL-4).
9. **undo** (later) — the layout rings and imbib's snapshots register through one hook here, per actor.

Ordering rule: nothing that can refuse runs after something that has side effects; identity before
policy; span outside invoke and envelope so the span sees `ok`; audit after envelope so it records the
code. **Hand-rolled chain, not tower.** tower's `Service`/`Layer` fits an axum route and is already a
workspace dependency, but the pipeline must also wrap the two non-HTTP bypasses (FFI layout `apply`,
`call_verb_on`) and the store hot path that never carries a `Request`; a `Vec<Box<dyn Layer>>` over
`(descriptor, Call) -> Future<Result>` is 60 lines, has no `Service` trait to satisfy at 12 call sites,
and is what mcp-host's inline bearer + allowlist and impress-ai-http's `from_fn` middleware would both
collapse into. If the app-side generic route (P5) lands on axum, its handler calls the same chain.
Cost: the invoker span measured ≤ 5 µs; strict parse is already paid by 51 verbs; identity, policy and
envelope are map lookups; audit is one store write per mutating verb, the cost of which is the write
that verb already makes — ADR-0035 P2 is the benchmark to re-run after P2 lands.

### P3 — lifecycle

`since` and `deprecated { since, alias_of, note }` on the descriptor (declared; a test fails a
descriptor with no `since` once P3 lands). An alias is a second `VerbDescriptor` with
`Source::Alias(target)` that the pipeline resolves at step 6 and counts in the span/audit under the old
name, so removal is a measured decision. `cli::effective_names` keeps its collision rule. Stored
documents: a `rename_pass` in `impress-surface-service` and `impress-layout-service` rewrites
`sources.*.verb`, `call.verb`, `open.view_kind` and `pane.view_kind` from the alias table, flagged and
ledgered like `task_schema_migration`, and leaves an untouched row alone like `upgrade_if_untouched`;
today it has 0 surface rows and 60 panes to visit. The four legacy MCP tools (ADR-0024 D7) are the
first aliases. View kinds get the same `LEGACY`-slot treatment they already half-have
(`ViewKindId::LEGACY`).

### P4 — long-running work

The convention: a `long_running` verb returns in milliseconds with `{ok, job: {id, kind, state}}` where
`id` is a `task@1.0.0` row (the kernel's handle, lifecycle, retry and review); progress is a per-job
event ring `task-event@1.0.0` — the surface ring's `seq`/prune/`wait` code lifted into
`impress-service-core::report` — read by `job_events {id, after_seq}` and `job_wait {id, after_seq,
timeout_ms}` (the surface `wait` semantics: cursor unchanged on timeout, `gap` flag); `job_cancel {id}`
sets `cancel_requested` on the row, which executors poll (running → cancelled is already a legal
transition, `task.rs:82`), and the kernel's refusal of running cancels goes away; the result is the
job's `agent-run` / output items, read by `job_result {id}`. Mapping: MCP — the job verbs are ordinary
tools, and once the server reads `progressToken` the pipeline's span layer emits
`notifications/progress` from the same ring; the CLI — `--wait` on any long verb polls `job_wait` and
streams events to stderr; surfaces — a `status` widget bound to a `job_events` source and a cancel
`button` calling `job_cancel`, so `surface_wait` already carries it; the profiler — the job's span is
the parent of each executor step. Local execution: the pipeline runs the job inline under
`spawn_blocking` when no daemon is registered for its kind, writing the same rows, so an MCP process
with no impel-taskd still gets the handle. Ask-first: a new record kind `task-event@1.0.0` (D-P4) and
the return-shape change for 53 verbs (D-P5).

### P5 — one transport

`POST /api/verb/<name>` on every app's automation server, JSON in, the verb's own result out,
refusals as `{ok, code, message, wire_version}` — exactly what `/api/layout/verb` and `/api/surface/*`
already are. Rust side: one `AppTransport` in a new `impress-app-transport` crate (the probe with one
rule and one cooldown, one port table exported from `SiblingApp.descriptors` and pinned by a test,
`IMPRESS_APP_TOKEN` bearer on every request, 1 s probe / 30 s call / no retries, `traceparent`), which
the pipeline's invoke step uses when the descriptor's `needs_app` names an app that is running and the
verb is not linked locally. App side: a per-app UniFFI target (`imbib-verbs-ffi` etc.) linking the
app's own `*-service` crate with its default store backend, so the route dispatches through the same
pipeline in-process. What each adapter does beyond forwarding, and where it goes: probing → the
transport; base-URL discovery → the port table; auth → the bearer; shape conversion → disappears (the
wire is the verb's schema); error swallowing → ends (a dead route is `not-found`); app-only
computations hidden in adapters (`sidebar_view` store-direct, `library_size`, cite-key resolution, PDF
parking, export-format parsing) → the `*-service` default impl the app runs. Deleted when done: the
four adapters, `impress-app-client`, the 160 mirrored Swift arms, and the kit/full inventory split
(§ Duplicate inventories). Kept in Swift: the ~148 app-only arms that are platform state (window,
selection, reMarkable USB, veusz) — and of those, imprint's tasks/templates/citation-usages, impart's
accounts/mailboxes/messages and impel's 41 (threads, personas, escalations, tasks) are
`#[impress_method]` candidates recorded in ADR-0035's coverage table. The layout routes in
`ImpressAutomation` stay as they are: they are already the generic form.

### P6 — Python

**One generic binding, and the claim removed.** `impress` Python module with `list_verbs()` and
`call(verb: str, args: dict) -> dict`, over the same `AppTransport` (so the process needs no linked
inventory: it talks to a running app, or to `impress-mcp` in HTTP mode) and therefore through the same
pipeline with `CallerIdentity::Agent("python")`. Cost: one pyo3 crate of ~150 lines and a wheel; the
per-method alternative is ~433 signatures kept in step. The two private MCP servers in `im-bibtex` and
`im-identifiers` are retired once their functions are verbs (ADR-0035 table 5). The macro's line 43
goes in P7.

### P7 — rules into construction

In order of value: (1) schema refs as generated constants (table RC row 1; the script keeps the Swift
half); (2) the macro rejects an undocumented method and an undeclared `safety`/`since`; (3)
`[workspace.lints]` + `clippy.toml` `disallowed-types = ["String" as a schema ref]` so the newtype
cannot be bypassed; (4) golden tests for the two prose-only DoDs; (5) `check-kit-deps` folded into
`check-kit-standalone --strict` with the feature restriction moved there. Not by construction: the
Swift package allowlists, the TypeScript backstop, the shard selection.

### P8 — runtime providers (Julia)

**Announce.** A provider is a process that speaks the P5 transport in reverse: it `POST`s
`/api/providers/register {provider: {id, language, version, endpoint, token}, verbs: [VerbDescriptor as
JSON]}` to a host (an app or `impress-mcp` in HTTP mode), and answers `POST <endpoint>/verb/<name>` with
the verb's result and `GET <endpoint>/health`. The descriptor JSON is the same shape P1 defines (name,
description, input and output schema, safety, examples, since); the host validates it with the same
tests the linked inventory passes (a schema is a valid JSON Schema; the name matches
`<provider>-service_<verb>`; every argument described; ≥ 1 example; a safety class present) and refuses
the registration naming the failure, exactly as `surface_validate` names a spec's.

**One inventory.** The linked `inventory` collection stays the compile-time source; a `Registry` in
`impress-service-core` holds provider descriptors at runtime; `descriptors()` and `find()` iterate the
union, and the 10 files that read `McpToolDescriptor::iter()` directly move onto them (RP-1). The
linked set wins on a name collision (the rule the surface runtime already applies to `SharedVerbHost`),
and a collision is logged. Nothing else lists verbs, so there is no second inventory to drift.

**Transport.** The provider's verbs are `Source::Provider(id)` and the pipeline's invoke step calls
the provider over `AppTransport` — the same client, bearer and `traceparent` as an app. A provider is
therefore just another app to the transport, which is why P5 comes first.

**Lifecycle.** A provider that goes away (health fails, or it deregisters) has its verbs marked
`unavailable` in the registry, not removed: a stored surface naming them fails in the source by name
(`host-unavailable`), the catalogue shows them greyed, and the coverage check still counts them. A
provider that comes back re-registers and its `since` must not go backwards; a verb it drops is
`deprecated` with no alias, and the rename pass (P3) reports the stored references.

**Trust.** A provider's `safety` claim is a floor, not a fact: the host records `safety.declared` and
`safety.effective`, where effective is the provider's default class (`external`, since every call
leaves the process) unless the person has trusted the provider (a `provider@1.0.0` row with `trusted:
true`, ask-first D-P6), in which case the declared class applies. A provider's caller identity is
`Provider(id)`; it cannot claim `Person` or an agent name, and its token is issued by the host at
registration and rotated on re-registration. A provider's verbs pass every pipeline layer, including
policy and audit, so a destructive claim from an untrusted provider is a review point.

**Equal terms, measured:** the same coverage test that walks the linked inventory walks the registry;
the same example runner runs a provider's examples in Tier B against the running provider; the
generated form and reference page come from the same descriptor. What a provider cannot get: Tier A
(no in-process handler) and the kit's standalone guarantee.

## Decisions needed from Tom (ask-first)

**All approved by Tom on 2026-09-26** (D-G5 as "make them undoable, keep the names"; D-P6 as recommended: a provider's safety claim is a floor until trusted). The list is kept as the record of what was asked.

- **D-P1.** P0's mitigations change the automation servers' contract for every local caller (a token on
  non-GET from loopback). Approve the token file mechanism and the `Host` check.
- **D-P2.** Actor becomes derived from caller identity; the `actor` argument on 24 layout verbs becomes
  ignored-and-warned, then removed (an argument change).
- **D-P3.** Audit writes one `core/operation` row per mutating verb on every path (a write the CLI and
  MCP do not make today).
- **D-P4.** New record kinds: `task-event@1.0.0` (job progress ring), `provider@1.0.0` (registered
  providers and trust).
- **D-P5.** 53 long-running verbs return a job handle instead of blocking (a result-shape change).
- **D-P6.** A provider's declared safety applies only once the person trusts the provider.
- **D-P7.** The four `*-service-http` crates, `impress-app-client` and 160 Swift route arms are deleted
  after P5; per-app FFI targets are added (7 → up to 11 tracked bindings).
- **D-P8.** Python: the generic binding, and the macro's shim claim deleted.
- **D-P9.** Schema refs as generated constants (271 Rust sites migrate; `SchemaRef` becomes a newtype).
- **D-P10.** `log` → `tracing` for the Rust half (shared with ADR-0035 D-P1).

## Work packages

| WP | Owns | Closes | Proof | Gates | Parallel with |
|---|---|---|---|---|---|
| **P0 Loopback and CORS** (standalone, first) | `packages/ImpressAutomation` (`HTTPResponse.swift`, `HTTPAuthPolicy.swift`, `HTTPServer.swift`, `SharedAutomationRoutes.swift`), every app's `HTTPServerConfiguration`, `impress-app-client`'s token, `crates/impress-ai-http/src/main.rs`, `crates/impel-server/src/auth.rs` + router, impel's `next-thread` route | SEC-1..8 | a `curl` with `Origin: https://evil.example` gets no ACAO header; a loopback `POST` with no token is 401; a request with `Host: attacker` is 400; every app's Tier B passes with the token set; impress-ai-http starts on 8787; impel-server refuses a missing bearer | ImpressAutomation `swift test`, Tier B ×5, `cargo test -p impress-ai-http -p impel-server` | nothing — lands alone |
| **P1 Descriptor** | `crates/impress-service-core` (`VerbDescriptor`, projections), `crates/impress-service-macros` (`safety`, `since`, `#[impress_example]`, output schema bound), the 36 result-type derives, the two marker tables | PL-1's data half, RC-2, RP-1's shape | every descriptor in the linked inventory has every field or the test names the verb; MCP `annotations` emitted | full gate; `mcp_surface_parity` | P0 |
| **P2 Pipeline** | `impress-service-core::pipeline`, `call.rs`, the two bypasses (`call_verb_on`, FFI layout `apply`), the 9 entry paths, `reachability.rs` → the layer, `authorship.rs` actor derivation, `impress-ai-tools` deps | PL-1..6, PO (policy layer), completeness 1–3 | a test enumerates every `descriptor.handler`/trait-direct call site and fails on one outside the pipeline; `actor: "human"` over MCP is refused; a destructive verb from an agent returns `review-pending` and a surface id; the bench stays ≤ 5 µs + the audit write | full gate; Tier B ×5; kit checks | — (after P1) |
| **P3 Lifecycle** | the descriptor's `since`/`deprecated`, `Source::Alias`, the rename passes in layout- and surface-service, the four legacy MCP tools as the first aliases | LC-1, LC-2, ADR-0024 D7 | calling `search_papers` works, is logged under its old name and answers with a deprecation note; the rename pass rewrites a seeded surface and leaves an edited preset alone | `cargo test`; the live-store dry run reports 0 surface rows and 60 panes | P4, P5 |
| **P4 Jobs** | `task-event@1.0.0`, `job_*` verbs in `impel-service`, `cancel_requested`, the inline runner, the CLI `--wait`, the surface `status` binding; first gate: the three one-liners in LR-1 | LR-1, LR-2, completeness 5 | `project-build` returns a handle in < 50 ms; `job_wait` streams its steps; `job_cancel` kills the veusz step; `surface_wait` sees the same events; MCP's serial loop is never held longer than a job verb takes | `cargo test -p impel-service -p imprint-service`; Tier B on imprint | P3, P5 |
| **P5 Transport** | new `crates/impress-app-transport`, `POST /api/verb/<name>` in `ImpressAutomation`, per-app FFI targets, deletion of the four adapters, `impress-app-client` and the mirrored arms, the kit/full inventory merge | TR-1..3, the 8 dead routes, the inventory duplication | every verb that reached an app before reaches it after (a parity test over the 200 methods); the five implore verbs answer; `cargo tree` shows one force-link list; `check-uniffi-bindings` counts the new bindings | full gate; Tier B ×5; kit checks (`impress-capabilities-kit` retired from the manifest) | P3, P4 |
| **P6 Python** | `crates/impress-py` (pyo3, `list_verbs`, `call`), the macro doc line, retiring `im-bibtex`/`im-identifiers`' MCP servers once their verbs exist | PY-1 | `python -c "import impress; impress.call('imbib-text-service_decode-latex', {...})"` against a running app; the wheel builds in CI | a new CI lane | P5 (needs the transport) |
| **P7 Rules into construction** | `impress-core/build.rs` + `SchemaRef` newtype, `[workspace.lints]`, `clippy.toml`, the macro's doc/safety/since errors, the two golden tests, `check-kit-deps` fold | RC-1..3 | a misspelt schema ref fails to compile; an undocumented method fails to compile; `check-schema-refs.sh` reports 0 Rust literals | full gate; the scripts | P3, P4, P5 |
| **P8 Runtime providers** | `impress-service-core::registry`, `POST /api/providers/register`, `provider@1.0.0`, the trust rule, the 10 direct inventory readers, a reference provider in the repo (a 40-line Julia or Python script registering one verb) | RP-1, completeness 8 | the reference provider's verb appears in `tools/list`, the CLI, the catalogue and `docs/verbs/`; its example runs in Tier B; killing the provider greys the verb and a surface naming it fails by name; an untrusted provider's `read-only` claim is effective `external` | full gate; a Tier B lane that starts the provider | after P5 |

## Build cost as a measured budget

**Measured:** 2026-09-26 on main at `3222f573`, a fresh worktree, nothing else building.
**Raw numbers and every command:** [`plan-verb-pipeline-plan-verb-pipeline-build-cost.json`](plan-verb-pipeline-plan-verb-pipeline-build-cost.json) (this section quotes it; the JSON is the
record). **Verb count:** 433 `#[impress_method]` in `crates/*-service/src` across 15 service
crates (38 services, 16 linked crates — the inventory count). The naive
`grep -rc "#\[impress_method" crates --include=*.rs` says 458: it also counts 22 doc-comment
mentions, imprint-selftest's one verb and the two in `impress-service-core/examples/echo_demo.rs`.
vw-service's 15 verbs expand inside `vw-impress-adapter`, where its `impress_service_impl!` lives.

### Baseline

| | Value |
|---|---|
| Machine | Mac17,6, Apple M5 Max, 18 cores (6P + 12E), 128 GB, macOS 26.7 (25G229); cargo `jobs=18` |
| Toolchain | `rust-toolchain.toml` pin 1.98.1; `rustc 1.98.1 (48a229cea 2026-09-01)`, `cargo 1.98.1` |
| Profile | `[profile.dev] debug = "line-tables-only"`, `[profile.dev.package."*"] debug = false` (as committed) |
| Target dir | `CARGO_TARGET_DIR=$HOME/.cache/impress-build-cost-target/<run>`, one fresh dir per cold run; no sccache, no rustc-wrapper |
| Tools added | `cargo binstall -y cargo-llvm-lines cargo-machete cargo-expand` into `~/.cargo/bin` (binaries, not compiled) |
| Scripts | the measurement scripts were not committed; every command and its wall time is in the JSON (`commands`, `wall_s`) |

Cold = `rm -rf` the target dir, then `cargo build … --timings`. Incremental = append
`// build-cost probe` to one `lib.rs`, rebuild the same target, `git checkout --` the file. Every
build ran serially. Two cold workspace runs differed by 6 % (54.9 s / 58.4 s); quote the first,
treat ±6 % as noise.

| Build (`--timings`) | Wall | Unit-time sum | Units | Critical path |
|---|---|---|---|---|
| `cargo build --workspace` cold | **54.9 s** (run 2: 58.4 s) | 714.8 s | 1034 | 42.2 s |
| `cargo check --workspace` cold | 40.0 s | 520.1 s | 1089 | 28.8 s |
| `cargo build -p impress-mcp` cold | **48.6 s** | 597.0 s | 925 | 35.2 s |
| `cargo build -p impress-cli` cold | 40.6 s | 465.1 s | 761 | 42.2 s |
| `cargo build -p impel-tools` cold | 32.2 s | 313.5 s | 549 | 34.8 s |
| workspace, no-op rebuild | 0.5 s | — | 0 dirty | — |
| workspace, touch `imbib-service/src/lib.rs` | **4.5 s** | 16.2 s | 12 dirty | 4.4 s |
| workspace, touch `impress-service-core/src/lib.rs` | **7.2 s** | 27.6 s | 40 dirty | 8.0 s |
| impress-mcp, touch imbib-service / service-core | 3.2 s / 5.7 s | 5.3 s / 14.4 s | | 3.2 s / 6.4 s |
| impress-cli, touch imbib-service / service-core | 2.5 s / 4.7 s | 3.1 s / 11.2 s | | |
| impel-tools, touch imbib-service / service-core | 1.6 s / 3.3 s | 1.8 s / 5.7 s | | |

Where the cold workspace build goes (unit-time, 714.8 s): dependencies 561 s (78 %), workspace
crates 153.5 s (21 %), of which the 15 service crates 39.2 s (5.5 %). Slowest units: `zstd-sys`
build script 13.8 s, `typst-library` 13.2 s, `onig_sys` build script 10.9 s,
`impress-store-service` 8.6 s, `imbib-core` 8.4 s, `impress-layout-service` 7.4 s, `automerge`
7.1 s, `impress-core` 6.8 s. The critical path (42.2 s of the 54.9 s wall) is one chain:
`libc → cc → onig_sys` build script (10.9 s) `→ tokenizers → fastembed → impress-embeddings →
imbib-core` (8.4 s) `→ imbib-service → impress-app-client → imbib-service-http →
impress-ai-tools → impel-taskd`. fastembed/onig reach every binary through `imbib-core`'s
default `impress-embeddings` dependency, not through the `embedder` feature.

The incremental paths are the ones the pipeline work will hit:
- Service touch (4.5 s): `imbib-service` 1.0 s, then five binaries relink in parallel at
  1.9–2.1 s each (`impress-mcp`, `impel-taskd`, `impress-cli`, `imprint-cli`, `imprint-selftest`).
  Link time is the floor, not the service crate.
- `impress-service-core` touch (7.2 s): a 10-hop serial chain, `service-core → store-service
  1.1 → layout-service 0.9 → surface-service 0.6 → capabilities-kit → store-ffi 0.4 →
  imprint-service 1.0 → app-client 0.5 → imprint-selftest 0.7 → capabilities → impress-mcp 2.1`.
  Depth of the crate graph is the cost here, not verb count.

### Per verb

| Number (433 verbs) | ms / verb |
|---|---|
| Cold workspace wall | **127** (run 2: 135) |
| Cold workspace unit-time | 1651 |
| Cold `impress-mcp` wall | 112 |
| Cold `impress-cli` / `impel-tools` wall | 94 / 74 |
| Incremental, service touched, workspace / `impress-mcp` | **10.4** / 7.4 |
| Incremental, service-core touched, workspace / `impress-mcp` | **16.6** / 13.2 |
| Service crates' own cold unit-time (39.2 s) | 91 |

Per service crate the cold lib compile ranges from 29 ms/verb (`imbib-service`, 150 verbs,
4.3 s) to 210 ms/verb (`impress-surface-service`, 16 verbs, 4.0 s): the crates that are
expensive are expensive for their domain code (`impress-store-service` 8.6 s,
`impress-layout-service` 7.4 s, both > 10 k source lines), not for their verb count.

### Macro output (`cargo llvm-lines`, 14 service crates, 418 verbs)

| | Lines of LLVM IR | Per verb |
|---|---|---|
| Total across the 14 crates | 2,141,268 | 5,123 |
| Attributable to `#[impress_method]` expansion | **716,103 (33.4 %)** | **1,713** |
| · derived `Deserialize` for `__Impress_*_Args` (Visitor, `__Field`) | 389,337 | 931 |
| · derived `JsonSchema` for the Args struct | 148,561 | 355 |
| · `__impress_*_invoke` and its boxed async closure | 139,781 | 334 |
| · `__impress_*_schema`, drop glue, other | 38,424 | 92 |

Share per crate: 62 % in `impress-bridges-service`, 58 % `imbib-service`, 44–49 %
`impart`/`ai`/`smart-search`, 21 % `store`/`layout`, 14 % `surface`, 12 % `surface-demo`.
`cargo expand -p surface-demo-service` turns 577 source lines into 2,743; one method is
361 expanded lines (Args struct + the two derives + schema fn + invoker + two
`inventory::submit!`). Return-type `to_value` instantiations are on domain DTOs and not
counted as macro output.

Codegen is the smaller half of a service crate's compile: `imbib-service` 3.8 s frontend /
0.5 s codegen, `imprint-service` 4.0 / 0.6, `impress-store-service` 4.7 / 3.9,
`impress-layout-service` 5.3 / 2.1. The IR share therefore overstates the time share.

### Findings

- **BC-1 (verified)** Verb count is not the scaling limit today. The 433 verbs cost 39.2 s of
  715 s cold unit-time and 1.0 s of a 4.5 s incremental; 78 % of a cold build is
  dependencies, and the incremental floor is binary link time (five binaries × ~2 s) plus the
  ten-hop chain under `impress-service-core`. Doubling the verb count would add ≈ 40 s
  unit-time (≈ 2–3 s wall on 18 cores) to a cold build and ≈ 1 s to a service-touch rebuild.
- **BC-2 (verified)** Macro output is 33 % of the service crates' IR, 1,713 lines/verb, and
  over half of it (931) is the derived `Deserialize` for each Args struct, not the invoker
  (334). A thin shim that keeps `#[derive(Deserialize, JsonSchema)]` removes at most the
  invoker's ~20 % of macro output (≈ 7 % of service-crate IR). Removing the derives means
  the shim deserialises fields itself from `serde_json::Value` through per-primitive-type
  shared instantiations — that is what makes it "non-generic". Expected saving, bounded by
  codegen time: ≤ 0.5 s unit-time for `imbib-service`, < 1 s wall for the workspace. Do it
  for the invoker pipeline's sake (one runtime function to instrument), not for build time.
- **BC-3 (verified)** `[profile.dev.build-override] opt-level = 3` is a loss: cold workspace
  79.2 s (+21–24 s; `syn` 19.3 s, `uniffi_macros` 16.4 s, `darling_core` 14.1 s,
  `serde_derive` 13.0 s, `async-trait` 12.5 s now sit on the critical path, 68.7 s), and the
  service-touch incremental is unchanged (4.6 s vs 4.5 s). Measured with
  `CARGO_PROFILE_DEV_BUILD_OVERRIDE_OPT_LEVEL=3`; `Cargo.toml` was never edited. Rejected;
  `opt-level = 1` was not tried (the incremental shows nothing to gain).
- **BC-4 (verified)** One test binary per `tests/*.rs`: 93 files in 24 crates; `imbib-core`
  has 26 files → 24 integration binaries (two are helper modules). `cargo test -p imbib-core
  --features native --no-run` after `cargo clean -p imbib-core`: 11.4 s wall, 70.1 s
  unit-time, of which the 24 integration binaries are 52.5 s (2.2 s each, compile + link
  against the whole `imbib-core` closure) against 10.7 s for the lib test target and 6.5 s
  for the lib. One binary per crate (`tests/main.rs` with `mod` lines) would cut that to one
  compile + one link: save ≈ 45 s unit-time / ≈ 8 s wall per `imbib-core` test build, and
  proportionally across the other 23 crates. Note `cargo test -p imbib-core --no-run` without
  `--features native` does not compile (166 errors) — the gate's spelling is the only one.
- **BC-5 (verified, feature sets; saving estimated)** The two `rust-gate.sh` shards resolve 56
  external crates with different feature sets (41.7 s of direct cold unit-time; they include
  `serde_core`, `serde_json`, `indexmap`, `tracing`, `regex-automata`, `hashbrown`, so
  everything above them rebuilds too — in effect a full dependency rebuild, ≈ 560 s
  unit-time, ≈ 35–40 s wall). Plain `cargo build --workspace` differs from `rest` by 42
  crates and from `imprint` by 26; `impress-mcp` from `impress-cli` by 32; a per-app lane
  (`cargo test --features native` from `crates/imbib-core`) from `rest` by 53. CI already
  keeps one persistent target dir per lane, so lanes do not thrash each other; the cost is
  paid once per lane per dependency bump and on every developer who alternates a per-crate
  command with the gate in one `target/`. A cargo-hakari workspace-hack crate pins one
  feature set for every lane; expected saving is the dependency rebuild on each such switch.
- **BC-6 (verified)** Duplicate dependency versions: 54 crates present in two or more versions
  (`itertools` ×4, `getrandom`/`rand`/`hashbrown`/`rustix`/`sha2` ×3, `thiserror` 1+2,
  `toml` 0.5+0.8, `strum`, `zerovec`/`icu_*` …); the extra copies cost 26.5 s cold unit-time
  (3.7 %). `thiserror` 1→2, `itertools` and `toml` 0.5 are ours to fix; the ICU/zerovec pairs
  come from `url`/`idna` vs typst and are not.
- **BC-7 (verified)** `cargo machete`: 70 unused-dependency hits in 40 crates, but only 2 are
  the sole user of the crate (`impel-server`→`tokio-tungstenite`, `impel-tui`→`tui-textarea`,
  0.4 s together); the rest stay in the graph through another member. Several are false
  positives (`pyo3`/`uniffi` behind features in `impress-service-core`, `darling` in the
  macros crate). Worth a hygiene pass, worth nothing for build time.
- **BC-8 (verified)** tokio `"full"` is inherited by 44 crates (`tokio = { workspace = true }`),
  not 26; tokio itself is 3.4 s of cold unit-time and compiles once, because cargo unifies
  features across the workspace. Trimming per-crate feature lists saves nothing in any
  workspace or binary build while one member needs `full` (`impel-server`, `impel-taskd` do);
  it only matters for `clippy-each-crate.sh` (each crate alone) and the kit standalone check.
- **BC-9 (estimated)** sccache: dependencies are 561 s of the 715 s cold unit-time, identical
  bytes across every agent worktree and the four self-hosted runners' `~/ci-cargo-target/*`
  dirs on one Mac. With a warm local disk cache a cold workspace build drops to roughly the
  workspace-crate chain (≈ 25–30 s wall; `imbib-core` 8.4 s → `imbib-service` → … is what
  remains) and the per-lane dependency rebuild in BC-5 becomes a cache hit. Not measured;
  `.cargo/config.toml` already says where the wrapper belongs (`~/.cargo/config.toml`, never
  the repo, because the GitHub-hosted release runners lack the binary).
- **BC-10 (verified)** `ort-sys`/fastembed did not need a network download on this machine
  and did not block; `onig_sys`'s 10.9 s C build (via `tokenizers`) is on the critical path of
  every binary through `imbib-core → impress-embeddings` (default feature, not `embedder`).

### Work packages

| WP | Wave | Owns | Does | Expected saving |
|---|---|---|---|---|
| **B1 Test binaries** | A | `crates/*/tests/` (start with `imbib-core`, `impress-core`, `imprint-core`, `impress-layout`, `impress-surface*`, `impress-layout-service`) | one `tests/main.rs` per crate with `mod` per former file; test names keep their module path | ≈ 45 s unit-time / ≈ 8 s wall per `imbib-core` test build; 93 → 24 link steps workspace-wide (BC-4) |
| **B2 Local compile cache** | A | `~/.cargo/config.toml` on impress-mac and in the agent-worktree briefing; `docs/` note | install sccache, `[build] rustc-wrapper` in the *user* config only; verify the four runners share the cache dir; record hit rate after one week | dependency share of every cold lane and worktree, ≈ 78 % of cold unit-time (BC-9); measure before/after with `run-builds.sh` |
| **B3 Dependency graph** | A | `Cargo.toml` (workspace + members), `Cargo.lock` | `thiserror` 1→2, `itertools` to one version, `toml` 0.8, the 2 sole-user machete hits, and the ~60 hygiene hits; do not touch tokio features (BC-8) | 26.5 s unit-time of duplicate copies (BC-6), minus the pairs that are upstream's |
| **B4 Workspace-hack** | B | new `crates/impress-workspace-hack` (cargo-hakari), `rust-gate.sh`, `workspace-rust.yml`, `check-kit-standalone.sh` | one feature set for the two shards, the per-app lanes and plain `--workspace`; hakari's generated crate is checked in and verified in CI | the per-lane dependency rebuild on feature-set switch (BC-5); no change to a warm lane |
| **B5 Build budget in CI** | B | `scripts/build-cost.sh`, `build-budget.json`, one job in `workspace-rust.yml` | see below | prevents regression; saves nothing itself |
| **B6 Embeddings off the spine** | C | `crates/imbib-core/Cargo.toml`, `impress-embeddings` features, the store FFI | make `impress-embeddings`'s fastembed/`tokenizers` path opt-in for the binaries that never embed (`impress-cli`, `impel-tools`, `imprint-*`), or split the crate | up to 10.9 s (`onig_sys`) + `tokenizers` 3.7 s off the critical path of every binary (BC-10); ask-first, it changes what a binary can do |

Order: B1 ∥ B2 ∥ B3 (disjoint files), then B4 (needs B3's lock to settle), then B5 with the
budget re-measured after B1–B4. B6 is behaviour, not build hygiene, and goes through the
verb-pipeline plan's ask-first list. The thin-shim rewrite is **not** a build-cost package:
it is the invoker pipeline's own work, and BC-2 says to expect < 1 s from it.

### The CI check (B5)

A timing job is noisy (±6 % run to run here; more on a shared runner), so the budget has two
halves: a deterministic one that fails the PR, and a measured one that records and fails
only on a large step.

1. **Deterministic, fails the PR** — `cargo llvm-lines -p <svc> --lib` for each service crate,
   summed and divided by the strict verb count (`grep -rhE '^\s*#\[impress_method'
   crates/*-service/src | wc -l`). Budget: macro-attributed lines ≤ 2,000/verb and total
   service-crate IR ≤ 6,000/verb (today 1,713 and 5,123). `cargo llvm-lines` is
   reproducible for a given toolchain, so this catches a heavier expansion the day it lands.
2. **Measured, records; fails at +25 %** — on the `impress-mac` runner, in its own persistent
   target dir: cold `cargo build -p impress-mcp --timings`, then the imbib-service touch and
   the service-core touch, each divided by the verb count. Budgets from this baseline with
   headroom for the runner: cold ≤ 150 ms/verb, service touch ≤ 12 ms/verb, service-core
   touch ≤ 20 ms/verb. The job appends `{commit, verbs, cold_ms_per_verb, incr_service,
   incr_core, unit_time_sum}` to a ledger artifact so the trend is visible; a single run
   over budget re-runs once before failing.
3. The budget file names the toolchain it was measured with. A toolchain bump re-baselines
   in the same PR (ask-first, below), which keeps "the compiler got slower" separate from
   "we generated more".

`scripts/build-cost.sh` is `run-builds.sh` reduced to those three builds plus the llvm-lines
loop; it must run with `CARGO_TARGET_DIR` outside the checkout like the other lanes.

### Ask first

- Changing the `rust-toolchain.toml` pin, or adopting any nightly-only flag (`-Zthreads`,
  `-Zshare-generics` on stable are not options; the parallel frontend is nightly).
- B6: making embeddings opt-in for any binary changes what that binary can do.
- B4: cargo-hakari adds a generated crate every member depends on; it changes every
  `Cargo.toml` and the kit manifest (`check-kit-deps.sh --strict` must learn it).
- sccache's cache directory location and size on the shared runner Mac (B2).

### Not measured

- A full `cargo test --workspace --no-run` link-time inventory (only `imbib-core`'s).
- sccache and hakari themselves (estimated from the timings and feature diffs, as briefed).
- `build-override opt-level = 1`; and release-profile builds (the xcframework scripts) —
  everything here is `dev`.
- CI-runner timings: all numbers are this M5 Max; the `impress-mac` runners need their own
  baseline before B5's measured budget is set.
- The seven target dirs left under `~/.cache/impress-build-cost-target` total ≈ 50 GB and
  can be deleted.

## Recommendation

**Go, with P0 first and alone.** The critique is right: one strict check in the invoker, nine entry
paths, two bypasses, three reachability rules and a self-declared actor are held together by people
remembering. The measured facts make the order clear: the security exposure is live today and costs a
day to close; the descriptor and pipeline are the foundation ADR-0035's every package consumes and
should land before a catalogue of 433 verbs is generated; the lifecycle must land before that
catalogue makes names public, and today it has zero stored documents to migrate — the cheapest it will
ever be. The transport is the largest package (7,645 lines deleted, per-app FFI targets added) and the
one with the clearest payoff (eight dead routes, four probe loops and three inventories go away), and
it is what Python and runtime providers both ride on. **First work package: P0.**

## Session log (append-only)

- 2026-09-26 — Planned on a worktree of main at 3222f573, branch `claude/plan-auto-gui-self-docs`, from
  Tom's second and third addenda. Measured: the nine handler call sites and two bypasses; the concern ×
  path matrix; the automation servers' auth and CORS (`Access-Control-Allow-Origin: *`, loopback
  token-free, no `Host` check, imbib the only app with a bearer, impress-ai-http defaulting to impress's
  port, impel-server failing open); the lifecycle blast radius against a read-only copy of the live store
  (0 surface rows, 60 panes); 33 long-running verbs' progress and cancel paths and the six job-like
  mechanisms; the four adapters (7,645 lines, 200 methods, 167 routes, 8 dead) and six Swift routers
  (312 arms, 160 mirrors); the check-* scripts and DoD rules against by-construction alternatives (271
  Rust and 116 Swift schema-ref literals); the descriptor's `&'static`/`fn`-pointer shape against runtime
  registration. Every subagent number used here was spot-checked against source. Split from the GUI plan
  per the addendum; ADR-0034 is this plan's, ADR-0035 the GUI plan's.
- 2026-09-26 — **Build cost added** (orchestrator, from the fourth addendum's measurement agent): the
  § Build cost section and its JSON record; the GUI plan's verb-count row now states the strict grep
  that reproduces 433. Both agent worktrees' measurements were re-checked against the JSON before
  the section was inserted (every quoted number matches).
