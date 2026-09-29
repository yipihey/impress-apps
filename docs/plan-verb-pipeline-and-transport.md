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
| `check-schema-refs.sh` + 5 `schema_ref_manifest.rs` | every `schema_ref` literal is canonical; registries equal the manifest | Python regex walk (`:105-175`), serde set compare; CI `workspace-rust.yml:77` | **build.rs in `impress-core` reads `schema-refs.json` → `pub const IMBIB_LIBRARY: SchemaRef = SchemaRef::canonical("imbib/library")` + `ALL`; `SchemaRef` becomes `#[repr(transparent)] struct SchemaRef(Cow<'static, str>)` with no public constructor (today `pub type SchemaRef = String`, `schema.rs:6`); `query_by_schema`/`count_by_schema`/`QueryRequest.schema` take it → a misspelt literal does not compile.** Swift: the same build.rs emits a `#[derive(uniffi::Enum)] enum SchemaRef` through `impress-store-ffi` so Swift gets `.imbibLibrary` from the existing bindgen | ~40-line build.rs; 271 Rust literal sites in 65 files (54 are already `const`s; sed-able from the manifest); 116 Swift sites in 46 files optional; 7 bindings regenerated | Rust half: no. Swift half: yes until the enum is adopted; the JSON stays the source |
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
- **D-P9.** Schema refs as generated constants (271 Rust sites migrate; `SchemaRef` becomes a newtype). Tom accepted the private `Cow<'static, str>` refinement on 2026-09-28: canonical constants borrow static strings, exact `FromStr` validates construction, and explicit persistence/wire decoding owns opaque names so historical backups and newer-writer rows remain readable without leaking interned strings.
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
- B6: making embeddings opt-in for any binary changes what that binary can do. **Declined by Tom, 2026-09-26**: the binaries keep embeddings; B6 is not done. B4 (cargo-hakari) approved the same day.
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

- 2026-09-29 — **P5c2 library-list read parity.** The generated imbib
  `list-libraries` record now exposes collection counts derived from the local
  collection store and `can_edit` for local editable libraries, matching the
  native automation contract. The native HTTP mapper now reports the same
  per-library collection count instead of a zero placeholder. A hosted scratch
  fixture checks two persisted collections, the actual library metadata, and
  excludes a read-only SciX-schema record. The isolated native transport proof
  compares generated metadata with `/api/libraries` for two scratch
  collections. Root verification passed 75 Rust tests (zero failures, three
  ignored), all quick gates, and full supported arm64 slices for store-ffi,
  impel-tools and imbib-verbs-ffi. The four collection-read effect declarations
  and reference pages were regenerated from test dumps/the inventory.
  Logs: `/tmp/impress-p5c2-{tests,gates,frameworks}.log`. The isolated imbib proof
  passed its XCTest and eleven transport calls, including actual HTTP/generated
  collection counts and editability; native SQLite checks passed. Evidence:
  `/tmp/impress-p5b-transport-mg52mt2s/output/`. Owned PID 32003 exited. No user
  app, launcher or real store was touched.

- 2026-09-29 — **P5c6 RIS domain export.** Added the generated
  `imbib-library-service_export-ris` selection verb with the existing BibTeX
  UUID/cite-key resolution and ordering semantics. Its named compatibility
  adapter reuses Rust's shared RIS types and formatter while matching the
  current PublicationManagerCore tag order; existing Rust RIS conversion stays
  unchanged for its other callers. The legacy HTTP route now uses its existing
  Swift parser/converter/exporter path, with isolated transport parity coverage
  and a Tier A representative record. Builds and tests remain in the parent
  verification lane.

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
- 2026-09-26 — **P0 Loopback and CORS landed** (branch `claude/pipeline-p0-loopback-cors`, from main
  at 701a2573, merged with main at b5218fb4). SEC-1..8 closed as the table's mitigation column says,
  with three narrowings recorded here: the loopback token file is keyed by the **bound port**
  (`loopback-<port>.token`), not the app name, because a second instance under test
  (`-httpAutomationPort 23261`) would otherwise overwrite the user's running app's token and a Tier B
  runner that knows only a base URL could not find the file; network mode now needs a **bind
  address** as well as a token (SEC-5's "explicitly" — the listener no longer binds every interface
  behind the bearer alone; imbib's iOS pane picks it from the device's addresses); and impel-server's
  `CorsLayer::permissive()` went with SEC-8, since a bearer-only loopback API has no browser origin
  to admit (and `POST /agents` now mints and returns the agent's token once, which the wired
  middleware needs to be usable at all). `IMBIB_TOKEN` is gone; `IMPRESS_APP_TOKEN` is the one
  client variable. The contract is `impress_core::loopback_token`, exported over UniFFI; the binding
  was regenerated (+3 functions, +1 record, nothing lost). **Proof** (impress built with its own
  `IMPRESS_DERIVED`, launched with `-httpAutomationPort 23261 -ApplePersistenceIgnoreState YES`,
  `IMPRESS_DEVICE_ID=p0-proof`, quit afterwards; the user's impress on its default port untouched):
  `curl -H 'Origin: https://evil.example' -i …/api/status` → `200`, headers `Content-Length`,
  `Connection: close`, `Content-Type` and nothing else (no `Access-Control-*`);
  `POST /api/performance/reset` with no token → `401 Unauthorized`, `WWW-Authenticate: Bearer`;
  `-H 'Host: attacker'` → `400 Bad Request`; the token file
  `~/Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/automation/loopback-23261.token`
  → `-rw-------`, 64 hex chars; the same POST with `Authorization: Bearer $(cat …)` → `200`
  `{"reset": true, "status": "ok"}`; `GET /api/performance/reset` → `405`;
  `IMPRESS_LAYOUT_SELFTEST_BASE_URL=http://127.0.0.1:23261 impress layout-selftest-service_run-selftest --tier b`
  (the runner reading the token file itself, no env set) → `"passed": 14, "failed": 0, "skipped": 0,
  "total": 14, "ok": true`. **Gates:** ImpressAutomation `swift test` 19 XCTest + 72 Swift Testing,
  0 failures (new: the policy matrix, the Host parser, a real-socket gate test that proves the four
  curls on a free port); PublicationManagerCore `swift test` 2159 XCTest (2 skipped) + 112 Swift
  Testing, 0 failures; `rust-gate.sh fmt` and `clippy auto` (`rest`) clean; `cargo test -p
  impress-ai-http -p impel-server -p impress-app-client -p impress-core --lib` green (impel-server
  6 incl. the middleware driven with `tower::oneshot`: no header 401, `system`/`impel-` prefix 401,
  registered token 200, `/status` open); `check-kit-deps --strict`, `check-schema-refs` (387 sites),
  `check-chassis-deps`, `check-uniffi-bindings` (7/7) OK. Not run: Tier B on imprint, implore, impel
  and impart from isolated builds (time); their servers share `HTTPServer`, whose gate the socket
  test and the impress run prove, and each client reads the token through the one Rust function.
  Noticed on main, not touched: b5218fb4 committed `target-standalone/` (3,021 cargo incremental
  files).
- 2026-09-26 — **B1 test binaries shipped** (branch `claude/bc-b1-test-binaries`, from main at
  701a2573, merged with b5218fb4). The 12 crates with more than one `tests/*.rs` (imbib-core 24
  files + `common`; impress-core 9; imprint-core 7; impress-surface, impress-surface-service and
  impress-layout 6 each; impress-layout-service 5; imprint-service and impress-sources 4;
  surface-demo-service, impress-mcp and impel-core 2) each get a `tests/main.rs` that declares a
  `mod` per former file, with `autotests = false` and one `[[test]] name = "main"` in the manifest;
  test names keep the file as their module path. Reconciled: `mod common;` is declared once
  (`use crate::common::…`); `#![cfg(feature = …)]`, `#[path]` and `include_str!`/`include_bytes!`
  resolve relative to the file and needed no change; insta names a snapshot by full module path,
  so imbib-core's 21 `.snap` files gained the `main__` prefix (contents unchanged);
  imprint-tectonic.yml's warm-up filter names its test through the module; `check-kit-standalone.sh`
  unlists just the `mod` lines whose module uses a dropped dev-dependency instead of skipping the
  whole binary (surface-demo-service's `plot_shape` over imprint-core). One exception was forced by
  process-global state: impress-layout-service's `fallback_store` pins the store path to a missing
  directory while `contract` sets a real one, so it stays its own `[[test]]` beside `main` — 93
  files → 13 test binaries (12 `main` + that one). Workspace test count: main 4030 (4010 pass, 20
  ignored); branch 4020 (4000 pass, 0 fail, 20 ignored) = 4030 − 18 + 8, the 18 being the 3
  `common::fixtures::tests` unit tests that ran in each of imbib-core's 7 binaries that declared
  `mod common` and now run once, the 8 being main's G0/G1 tests merged in; every other test name
  is the same. **Measured, not as BC-4 estimated:** a clean `cargo test -p imbib-core --features
  native --no-run` (deps warm, worktree-local `CARGO_TARGET_DIR`, 18-core impress-mac at load
  48–75 from a neighbouring `swift-test`) goes from 25 executables at 68 CPU-s (55 user + 14 sys),
  13–17 s wall, to 2 executables at 46 CPU-s (42 + 4), 24–40 s wall. The unit-time saving is
  real (≈ 22 s, a third) but the wall time got *longer* on this machine: one binary is one
  single-threaded rustc front end on the critical path, where 24 small binaries filled the cores.
  The wall estimate in BC-4 (≈ 8 s saved) assumed the link steps were on the critical path; they
  were not. The gain lands on CI's smaller runners and on unit-time budgets (B5), not on a warm
  18-core desktop. Gates: fmt, clippy `imprint` and `rest` (both run explicitly; `auto` diffs
  against `@{u}` and picks one shard on a branch that has not been pushed), workspace test,
  check-kit-standalone (13 crates OK), check-schema-refs (387 call sites) — all green. Noticed
  while merging: 3f743650 (G1) committed `target-standalone/` (3,021 build-product files) to main;
  not touched here.
- 2026-09-26 — **B3 dependency graph** (branch `claude/bc-b3-dependency-graph`, from main at
  701a2573). Three commits, Cargo.toml/Cargo.lock only plus the six source lines the bumps forced:
  `thiserror` 2 everywhere ours (two imprint-core error messages named their extra format argument);
  `quick-xml` 0.31→0.38 and `dirs` 5→6 (`trim_text` onto `config_mut()`, `unescape()`→`xml_content()`
  in the arXiv/PubMed parsers); 42 unused dependency lines dropped after grepping each and building
  `--all-targets`, among them the two sole users (`tokio-tungstenite`, `tui-textarea`) and two BC-7
  had not counted as sole (`mail-parser`, `petgraph`, impel-core's alone), so seven lock entries left.
  Multi-version packages in `cargo tree -d --features native`: 55 → 52 (`dirs`, `dirs-sys`,
  `quick-xml` gone). What BC-6 named as ours and is not: every `itertools` copy (0.12 tantivy, 0.13
  ratatui, 0.14 rav1e/tokenizers, 0.15 automerge/pdfium) and `toml` 0.5 (uniffi_bindgen) reach the
  graph only through upstream crates; `thiserror` 1 stays through uniffi's cargo_metadata, tantivy,
  russh and scix-client. Left alone on purpose: `nom` 7 (askama/imap/tantivy keep it), `png` 0.17
  (krilla/typst keep it), `darling` 0.20 (derive_builder keeps it), the ICU/zerovec/rand/rustix
  pairs. The 28 machete hits kept are the inventory links, the `schemars::`/`serde_json::` paths
  the service macro expands to, and feature-gated optionals; no tokio feature list changed (BC-8).
  Gates: fmt, clippy rest, clippy imprint, `cargo test --workspace --features native` (232 suites,
  4010 passed, 0 failed, 20 ignored), check-kit-deps --strict, check-kit-standalone,
  check-chassis-deps, check-uniffi-bindings — all clean.
- 2026-09-26 — **B4 workspace-hack** (branch `claude/bc-b4-workspace-hack`, from main at ce225b75).
  cargo-hakari 0.9.39 (`cargo binstall`, into `~/.cargo/bin`, which the four self-hosted runners
  share). `crates/impress-workspace-hack` is generated and checked in: 418 lines of Cargo.toml,
  no code, the union of every third-party feature any lane turns on for the five Apple triples
  the xcframework scripts build (`.config/hakari.toml`; no lane compiles on Linux). Every member
  depends on it (`impress-workspace-hack.workspace = true`, 76 manifests); `uniffi-bindgen` is
  left out of the unification so uniffi's `cli` stays out of the facade, as the root Cargo.toml
  and `rust-gate.sh` already intend. CI: `cargo hakari generate --diff` in workspace-rust.yml's
  guards job and in kit.yml's deps job (hosted, blocks the PR). Kit: the hack crate joins the
  kit-crates table as a pure crate (every kit crate reaches it; it reaches nothing), and
  `check-kit-standalone.sh` copies it as the stub hakari prescribes for a crate that leaves
  (generated section emptied), because the real section names the whole suite's dependencies.
  **The switch, measured** (`cargo check` shard `rest` cold, then shard `imprint`, one
  worktree-local target dir, M5 Max, dependencies in `~/.cargo`): before, `rest` 187 s then
  `imprint` 89 s compiling 308 crates (259 third-party); after, `rest` 150 s then `imprint` 64 s
  compiling 184 crates (131 third-party). The 128 third-party crates that no longer recompile
  are BC-5's feature-set rebuild; the 131 that remain are the Typst tree `rest` never builds.
  Two things BC-5 did not say: cargo keeps both feature variants in one target dir, so the
  switch back (`imprint` → `rest`) was 2 s before as well as after — the cost is paid on the
  first entry to each set and again after every lock change, not on every alternation; and a
  per-app `cargo test -p` now compiles the hack crate's whole set the first time (a one-off
  cost, then the same cache every other lane shares). Not measured: the xcframework release
  builds and CI-runner timings. Gates: fmt, clippy rest, clippy imprint, `cargo test
  --workspace --features native` (171 suites, 4000 passed, 0 failed, 20 ignored; the census
  test needed a `docs/verb-coverage.md` row for the new crate), check-kit-deps --strict (13 kit
  crates, self-test), check-kit-standalone --strict (14 crates), check-chassis-deps,
  check-uniffi-bindings (7 match), check-verb-coverage, `cargo hakari verify` — all clean.
- 2026-09-26 — **P1 descriptor** (branch `claude/pipeline-p1-descriptor`, from main at 197ee48e).
  One `VerbDescriptor` per verb in `impress-service-core::descriptor` (name, service, method,
  description, input and output schema, `safety {class, idempotent}`, `since`, `deprecated`,
  `aliases`, `examples`, `strict`, `source`, handler); `McpToolDescriptor` and `CliSubcommand` are
  `const fn of(&'static VerbDescriptor)` projections keeping their fields plus a `verb` pointer, so
  the 40 files that read them compile unchanged and `VerbDescriptor::iter()` is the map over the MCP
  collection. Declared: `safety =` and `since =` are required keys of `impress_service_impl!` (38
  services), `#[impress_method(safety = …, idempotent = …)]` the per-method exception (146), and
  `#[impress_example(name, args, expect)]` the storage G3 fills — all captured by
  `#[impress_service]` into a `__IMPRESS_SERVICE_METHODS_<Trait>` static that replaces the docs
  const. Derived: `output_schema = schema_for!(Ret)`, which forced the G2 derive half — 58
  `JsonSchema` derive attributes across impress-ai-service, impel-service, smart-search, parsers,
  imprint-selftest, imprint-service (handlers.rs, sections.rs) and their nested DTOs (a `schema`
  feature on impress-ai and imprint-core, `uuid1` on schemars, `impress_core::Item` fields as
  free-form JSON). Checks: `docs/verb-safety.md` (kit-manifest-style marker table seeded from
  appendix A1's classes and A4's evidence: 172 read-only, 126 mutating, 32 destructive, 103
  external) and `crates/impress-capabilities/tests/descriptor.rs` (class agrees with the table both
  ways, `since` is a version, both schemas are objects, `delete-*`/`prune-*`/`forget` is destructive
  or external, name is `<service>_<method>`, annotations follow the class; `dump` prints the table).
  MCP `annotations` (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) are
  emitted from the descriptor in impress-mcp's flat and grouped listings and in impress-mcp-host,
  pinned by `mcp_surface_parity`, inventory_bridge, surface.rs and the host's tests; external reads
  conservatively (`destructiveHint` and `openWorldHint` both true). Narrowed: idempotency has no
  per-verb table in the plan (only the 372 total), so it defaults from the class (read-only ⇒ true)
  and is declared per method where it departs; `long_running` and `needs_app` wait for P2's
  reachability layer; the four legacy MCP tools stay outside the inventory until P3. Build cost:
  surface-demo-service 25,207 → 25,693 LLVM lines (+1.9 %), macro-attributed 2,967 → 2,991
  (+12 lines/verb); the rest is `schema_for!` on return types, one instantiation per type.
  Gates: fmt, clippy rest, clippy imprint, `cargo test --workspace --features native --no-fail-fast` (233 suites, 4035 passed, 20 ignored; two
  load-only failures in untouched crates — `impel-service` `retention_report_…` on a zero-day
  window boundary and `impress-core` `collab::large_body_commit_stays_fast` at 10.1 s against an
  8 s wall-clock budget with 233 suites in flight — each passing 3/3 in isolation),
  check-kit-deps --strict, check-kit-standalone, check-schema-refs (387 sites), check-verb-coverage
  (38 services, marker tables unchanged), check-uniffi-bindings (7 match; no export changed).
- 2026-09-26 — **P4 Jobs landed** (branch `claude/pipeline-p4-jobs`, on main at b5218fb4/197ee48e).
  The convention as D6 states it: `task-event@1.0.0` is a new record kind (D-P4) — a per-task ring
  with the surface ring's semantics, registered beside `task@1.0.0` in impress-core and written only
  by `impress_core::job`; the task schema gained `cancel_requested`, `verb`, `args`, `result`,
  `runner`. A job row is born `running` and assigned to its runner (`inline:<pid>@<host>`), so the
  scheduler never acquires it. `impress-service-core::job::JobStarted` is the one wire shape;
  `impress-store-service::job::start_inline` is the inline runner (shared service runtime, cancel
  poller, a panic is a failed job, `wait` with the cursor rule, `cli_finish` for `--wait`/drain).
  `impel-service` gained `job_status / job_events / job_wait / job_cancel / job_result`;
  `cancel_task` on a running task sets the flag instead of refusing, and the scheduler honours the
  flag on its resume pass. The first gate (LR-1's three one-liners): `get-page-image`'s osascript
  under a 60 s deadline, `compile-typst`/`project-compile` under `spawn_blocking`, `search-all`
  bounded to the newest 5,000 rows. `imprint-core`'s `RunnerHost` gained cancel/step hooks
  (`ObservedHost`), `build()` stops at a step boundary and `ProcessRunnerHost::with_cancel` kills the
  step — and, found by the live proof, kills its whole process group: `kill()` on a `sh -c` left the
  grandchild holding the pipes, so a cancelled 45 s step still took 45 s (the timeout path had the
  same latent hang). **Converted (D-P5):** `imprint-project-service_project-build` — the proof set;
  every Rust caller (integration tests, Tier A `project.build_records`) goes through `await_build`;
  no Swift or HTTP mirror called the verb (the app's ⌘B runs `project_build_tree` through the FFI).
  **Kept synchronous, deliberately:** the other 52 long-running verbs. 26 run inside a running app
  over the `*-service-http` adapters and will move with P5's transport (a job wrapping an HTTP call
  in the MCP process is the wrong seat); `surface-wait`/`-render`/`-dispatch` are the surface loop
  itself (the wait is the primitive; a source needs its value); the 5 AI probes are cached and
  bounded; `get-page-image`/`get-figure-image` return `_mcp_content` image blocks a caller wants
  inline (now bounded); the imports, backups, e-ink verbs, `compile-*`, `run-selftest` ×3 and
  `search-all` return counts/reports their CLI, Swift or Tier B callers read at once — each is a
  result-shape change with callers to migrate and is one `start_inline` call away once its caller
  is ready. The machinery does not care which verb; the migration is per caller.
  Docs: `docs/agent-surfaces.md` § Jobs, the MCP guide's "Long-running verbs are jobs", the matrix
  row, `docs/verb-coverage.md` counts (438 verbs), the job-monitor example surface, `schema-refs.json`.
  **Proof (impress-mcp on a scratch store, flat tools, debug build, this Mac under three concurrent
  release framework builds):** `project-build` handle in 26.6 ms cold (28–34 ms across runs) and
  2–17 ms warm; `scheduler-status` answered in 2.9 ms while the job ran (the serial loop was never
  held); `job_wait` streamed `build` → `step running` in 0.7/100 ms, then timed out at 2 s with the
  cursor unchanged; `job_cancel` answered in 2.1 ms and the job read `cancelled` 210 ms later with
  the `sh figures/slow.sh` process gone and the `manuscript-build` row `cancelled`; `job_result`
  answered the old `ProjectBuildResult`. CLI: `impress project-build … --wait` streamed
  `[1] build … [4] finished {"ok":true,"state":"done"}` to stderr and printed `{ok, job, result}`.
  Surface: the job-monitor surface rendered the status bound to the job, a dispatched Cancel click
  called `job-cancel` and emitted `job-cancel-requested`, which `surface_wait` returned in 0.7 ms;
  the job ended `cancelled`; a Refresh click re-read the source (`cancelled: cancelled`) — a verb
  source re-runs only on refresh, as documented. Not done, on purpose: MCP `notifications/progress`
  (the loop is polled through `job_wait`); a heartbeat for a job whose process died (its row stays
  `running` — the CLI drains for that reason).
  Gates: fmt, clippy imprint + rest, `cargo test` on every touched crate plus impel-taskd,
  impress-mcp, impress-cli, imprint-cli (all green), check-schema-refs (81 canonical refs),
  check-kit-deps --strict, check-kit-standalone (13 crates), check-uniffi-bindings (7 match, no
  export changed), check-verb-coverage and the census. Tier A imprint 25/25. Tier B on imprint 8/8 (built into this worktree's own DerivedData and its own
  xcframeworks, launched with `-httpAutomationPort 23271`, quit afterwards; the user's imprint on
  23121 and their impel-taskd were never touched — the CLI/MCP proof ran on a scratch store).
- 2026-09-26 — **P2 pipeline landed** (branch `claude/pipeline-p2-pipeline`, from main at
  c0277c7e; a previous agent on this branch had already merged main and written the chain,
  identity, strict args, reachability, policy, span, audit and every entry path rewired to it —
  this session picked up from "run the bench alone" and closed it out). Layers and order as
  designed: identity → strict args → reachability → policy → span → invoke → envelope → audit,
  one `Vec<Box<dyn Layer>>` in `impress-service-core::pipeline`, no `Service`/`Layer` trait to
  satisfy at any of the nine entry paths (a call-site test enumerates them and fails on a
  `descriptor.handler`/`.apply` call outside the pipeline or the bench baseline). Entry paths
  rewired: MCP flat and grouped, CLI, surface runtime, surface HTTP mirror, FFI layout `apply`,
  impel-tools, impress-mcp-host, impress-ai-tools, and `call.rs`'s shared seat — all now call
  `pipeline::invoke`/`invoke_blocking`/`invoke_sync_with`/`invoke_on`, not a descriptor's handler
  directly. Overhead bench (`impress-capabilities/tests/pipeline_bench.rs`, release, alone,
  ROUNDS=2000): `imbib-text-service_decode-latex` 11.88 → 13.06 µs (+1.18), `surface-demo-
  service_series` 0.89 → 2.64 µs (+1.75), `layout-service_get-layout` 6.40 → 9.09 µs (+2.69),
  `layout-service_get-pane` 5.38 → 8.46 µs (+3.09), `store-query-service_list-items` 7.75 → 9.29 µs
  (+1.54); worst overhead 3.09 µs per call, well inside the ≤5 µs span budget and every chain
  total inside the ~20 µs read-only budget. Gates: fmt, clippy rest, clippy imprint, `cargo test
  --workspace --features native` (175 suites, ~4087 passed, 0 failed), check-schema-refs (392
  call sites, 82 canonical refs, 0 divergences), check-kit-deps --strict (13 kit crates),
  check-kit-standalone (14 crates), check-verb-coverage (75 crates verdicted, 38 services with a
  row), check-uniffi-bindings (7 match, no export changed) — all clean. `cargo hakari verify`
  fails on this branch, but the identical `impress-workspace-hack didn't work correctly` /
  `cc@1.2.54` mismatch reproduces on a clean checkout of main at c0277c7e too (confirmed with a
  throwaway `CARGO_TARGET_DIR`); pre-existing, not introduced here, left for whoever owns hakari
  drift next. Narrowed, found live: `impress_store_service::audit::flush()` exists specifically
  "for a test or a CLI that exits right after a mutating verb" (its own doc comment), but neither
  `impress-cli` nor `imprint-cli` called it before `std::process::exit` — a one-shot CLI process
  raced the audit sink's writer thread and could drop the `core/verb-call` row it just queued;
  reproduced live (`impress create --binding generic …` against a scratch store left no
  verb-call row), fixed by calling `flush()` before exit in both binaries, re-verified. `imbib-
  cli` is untouched: `imbib-service` doesn't link `impress-store-service` at all, so it has no
  sink to flush — its mutating verbs are counted in `audit::dropped()` by the documented design
  for a process that doesn't link the store services, which is a separate, pre-existing gap this
  branch did not create and did not close. Live proof: built `impress` Debug with
  `IMPRESS_SKIP_INSTALL=1` into its own `IMPRESS_DERIVED` (`impress-p2-proof.noindex`, own
  xcframeworks copied in from the main checkout plus a freshly built `impress-store-ffi` one,
  `IMPRESS_SKIP_X86=1`), launched with `-httpAutomationPort 23281 -ApplePersistenceIgnoreState
  YES` and `IMPRESS_DEVICE_ID=p2-proof`. Tier B 14/14. The audit proof: `impress --store-path
  <scratch> create --binding generic --name p2-proof --kind-scope any` then `rename` on the
  created collection left exactly one `core/verb-call@1.0.0` row per call and one `items` row
  with `op_target_id` set and `batch_id` equal to the rename's call-row id — the `batch_id` join
  D-R2 promises, shown against a live build rather than only the in-process unit test. The app
  launched for the proof was quit afterwards. One thing left undone: this session's build of
  `impress` updated the `~/MyApplications/impress.app` launcher symlink (an unconditional step in
  `scripts/build-impress-app.sh`, independent of `IMPRESS_SKIP_INSTALL`) to point at
  `impress-p2-proof.noindex` instead of the shared `impress-suite` DerivedData; restoring it was
  blocked by this session's own sandbox as a destructive filesystem write, so it still points at
  the proof build and needs a manual `ln -sfn` back to `~/Library/Developer/Xcode/DerivedData/
  impress-suite/Build/Products/Debug/impress.app`.
- 2026-09-26 — **B5 (build budget in CI) finished** on a worktree of main at c0277c7e, branch
  `claude/bc-b5-build-budget`. `scripts/build-cost.sh`, `scripts/check-build-budget.py`,
  `build-budget.json` and the `build-cost` job in `workspace-rust.yml` reviewed against this
  section and matched it (two halves, one job, ledger artifact, re-run-once on a measured
  breach only). Ran end to end on this Mac, heavily loaded by other concurrent builds
  (`uptime` load average 13.67 at start, 28.31 by the time the touch rebuilds and llvm-lines
  loop finished — roughly double, from other agents' builds on the same machine, not this
  script): `CARGO_TARGET_DIR=$PWD/target-b5 scripts/build-cost.sh` printed
  `{"commit":"c0277c7e","toolchain":"1.98.1","verbs":438,"macro_lines_per_verb":1641,"total_lines_per_verb":11361,"cold_ms_per_verb":228,"incr_service_ms_per_verb":20,"incr_core_ms_per_verb":38,"unit_time_sum_s":36.1}`.
  Piped through `check-build-budget.py` against the committed `build-budget.json`:
  `DET_FAIL=total_lines_per_verb=11361>6000`, `MEASURED_FAIL=cold_ms_per_verb=228>150|incr_service_ms_per_verb=20>12|incr_core_ms_per_verb=38>20`.
  Budgets were **not** weakened. The measured half's numbers are plausibly load-inflated (a
  literally 2×'d load average mid-run, this Mac shared with other agents' builds, is far
  outside the ±6% the plan measured on an idle desktop) and the job's own re-run-once logic is
  exactly the mechanism for that. The deterministic half is a different story:
  `macro_lines_per_verb` (1641) is still under its 2,000 budget, but `total_lines_per_verb`
  (11,361) is more than double the 6,000 budget and is not something load can explain —
  `cargo llvm-lines` IR-line counts do not depend on machine load. `verbs=438` here is close to
  the "catalogue of 433 verbs" the Recommendation section anticipates, so the grep and verb
  count look right; the honest read is that total per-verb IR has grown well past the
  `measured_baseline` (5,123) recorded against `baseline_commit: 3222f573`, sometime across
  B1–B4 or otherwise since planning, and the check is correctly catching that rather than
  malfunctioning. Left as a finding for whoever re-baselines next (ask-first, § Build cost):
  merging this job as-is will make `build-cost` fail red on `main` immediately, which is the
  job doing its one job — a re-measure-and-rebaseline PR (or a first look at what grew) should
  follow, not a same-PR fix folded into B5's own scope.
  Validated: `.github/workflows/workspace-rust.yml` parses as YAML; `bash -n scripts/build-cost.sh`
  is clean; `shellcheck` is not installed on this Mac and was skipped; `./scripts/rust-gate.sh fmt`
  passed clean. Removed a stray `target-b5/` left by the prior agent's interrupted run before
  measuring (build artefacts, gitignored, not committed).
- 2026-09-26 — **B5 correction** (orchestrator): the first B5 run's `total_lines_per_verb` of 11,361 was a
  counting bug, not growth — `cargo llvm-lines` prints its own `(TOTAL)` row first and the script summed it
  with the per-function rows, doubling every crate. Fixed (the TOTAL row is the crate total; macro lines are
  summed from the function rows only). Re-measured on c0277c7e: 438 verbs, **1,641 macro lines/verb, 5,680
  total lines/verb** — both under budget (2,000 / 6,000); +11 % total over the 5,123 baseline, which is P1's
  output schemas and P4's job verbs. The measured half (228 / 20 / 38 ms per verb) was taken at load 14–28
  and is not a baseline; the impress-mac job sets it.
- 2026-09-26 — **P3b (rename pass) landed** on a worktree of main at 9aaf8544, branch
  `claude/pipeline-p3b-rename-pass`. The table: `impress_service_core::lifecycle::RenameTable`
  (verb renames + view-kind renames, `SHIPPED_RENAMES` starts empty) — put in `impress-service-core`
  rather than `impress-core` or either tree crate because both rename passes already depend on it
  and it is a fact about verb identity, the same tier `Deprecation`/`Source::Alias` will live at.
  `RenameVisitor` is the H-P3-1 extension point (plan-self-reflective-layer.md): a thin trait naming
  a document kind for logs, deliberately not unifying the two passes' error types, so a later
  workflow/scenario visitor adds a third implementation in whichever crate owns that kind without
  this trait or the table changing. Machinery reused: `SqliteItemStore::apply_operation` (every
  rewrite is an attributed, `Durable` + `Editorial` write, so the previous value stays in the
  operation log exactly like every other edit these services make — no separate "keep the original"
  mechanism was needed); two small additions, `SqliteItemStore::get_store_metadata`/
  `set_store_metadata` onto the existing `store_metadata` table (`origin_id`,
  `task_schema_migration`'s marker), the widening `impress-layout-service/src/device.rs` had already
  named as the right move when it was needed. **Passes:** `impress-layout-service::rename::RenamePass`
  rewrites `pane.view_kind` in every stored layout and preset row (both store their tree under the
  same `layout` payload field, so one code path visits either; Table LC found no verb name in either
  kind, so this pass only touches view kinds). `impress-surface-service::rename::RenamePass` rewrites
  `sources.*.verb`/`call.verb`/`open.view_kind` by walking the stored spec's own JSON (those keys
  appear only at those sites in the vocabulary, so a blind recursive match finds all of them without a
  second, mutable tree-walker beside `impress_surface::spec`'s read-only ones) and writes back through
  `SurfaceStore::update`. System-seeded and user-edited rows are rewritten the same way — a rename
  does not ask whether a row still matches what the suite shipped, unlike `upgrade_if_untouched`,
  because an old name must stop working in a user's own row too. **Wiring:** each service's store
  accessor (`DefaultLayoutService::resolved_store`, `DefaultImpressSurfaceService::store_arc`) calls
  `RenamePass::run_if_needed` once per process (`OnceLock`-gated), which records the highest applied
  `RenameTable::version` in `store_metadata` so a later launch does not redo it; the shipped table is
  empty, so today this is one branch and zero store I/O. **Tests** (a test-only `RenameTable`, never
  the shipped one): a seeded surface naming verb `a` is rewritten to `b`; an edited layout naming an
  old view kind is rewritten and logged; an untouched seeded preset is upgraded; running twice is a
  no-op; an empty table is a no-op; a surface naming neither old verb is left alone. **Gates:**
  `./scripts/rust-gate.sh fmt`/`clippy rest`/`clippy imprint` clean; `cargo test -p impress-layout -p
  impress-layout-service -p impress-surface -p impress-surface-service -p impress-store-ffi` — every
  test passed (one `impress-store-ffi` burst-timing test was flaky under this Mac's load, confirmed
  by re-running alone; unrelated to this change, not touched); `check-schema-refs.sh` (no new schema
  ref — the marker rides the existing `store_metadata` table, not a new record kind),
  `check-kit-deps.sh --strict`, `check-kit-standalone.sh`, `check-uniffi-bindings.sh` (no FFI surface
  touched) and `cargo hakari generate --diff` all clean. No real verb or view kind was renamed;
  `SHIPPED_RENAMES` stays empty for P3a to append the first entry (ADR-0024 D7's four legacy tools).
- 2026-09-26 — **P3a Lifecycle mechanism landed** (branch `claude/pipeline-p3-lifecycle`, from main at
  9aaf8544). `since`/`deprecated`/`aliases` on `VerbDescriptor` (the fields existed, empty, since P1; P3a
  fills them): `#[impress_method(deprecated(since = "…", note = "…"), aliases = ["old-name", …])]` — the
  macro refuses `aliases` without `deprecated` on the same method (a rename implies deprecating the old
  name). No `Source::Alias` second descriptor (the design note's own sketch): a canonical verb simply
  carries its retired names in `aliases`, and `impress_service_core::call::find`/`call_as`/`call_async_as`
  resolve an unmatched name against every linked verb's `aliases` before answering unknown — one dispatch
  path, no second inventory to drift. The pipeline (`Call::requested_name`, a plain `Option<String>`, not
  `&'static` — the caller-given name is not one) records the requested name as a span field
  (`requested_name`) and a field on `core/verb-call`'s audit row (P2's record had room: an additive column,
  no migration), so a retired name's traffic is counted under the name that was actually asked for. The
  additive `"deprecated": {since, use, note}` envelope field lands on object results only (array/scalar/error
  results are unchanged) and only where it is true: a direct call to a verb that declares `aliases` is NOT
  deprecated (`VerbDescriptor::deprecation_notice`) — only a call that arrived via one of those aliases is
  (`alias_deprecation_notice`); a verb deprecated with no rename (empty `aliases`) is deprecated on its own
  canonical name. `cargo run -p impress-capabilities --bin gen-verb-docs` now prints a verb's aliases and
  its own deprecation on its reference page (inert today: no linked verb declares either yet). Tests: macro
  unit tests for the new attribute (capture, and the aliases-without-deprecated compile error);
  `impress-service-core::descriptor`/`pipeline`/`call` unit tests cover both envelope cases end to end
  against a real `inventory::submit!`-registered descriptor (not just a fixture struct) — direct call, no
  notice; alias call, additive notice; array result, untouched.

  **The four legacy MCP tools were NOT moved** (ADR-0024 D7's other half of this row), and that is reported
  rather than quietly dropped. Built `imbib-semantic-service` (a real `#[impress_service]` trait wrapping
  `search_papers`/`get_paper_chunks`/`list_indexed_papers` with `aliases` under their old flat names) and
  wired it into `impress-mcp`; it worked end to end (a call to `search_papers` reached the inventory verb
  and answered with the deprecation note) but `scripts/check-verb-coverage.sh` requires every
  `impress_service_impl!` block under `crates/*/src` to have a row, and `crates/impress-capabilities`'s
  census test requires that row's service to be **linked** in the `full` feature every other consumer
  builds — CLI and `impel-tools` among them. `impress-mcp/Cargo.toml`'s own comment records a prior,
  deliberate decision that the embedding stack behind these three tools (`impress-embeddings` with
  `embedder` — fastembed, a model load that may reach the network) stays out of the shared inventory
  precisely so CLI and impel-tools do not pay for it. Joining `full` would reverse that decision silently;
  the two checks together assume no service crate sits outside it, so there is no smaller fix on the
  table (an `unlinked` verdict for the coverage script, or a `semantic-search` feature carved out of
  `full` for just this service, is itself a decision to ask about, not a mechanical patch). Reverted
  cleanly rather than forced through; `render_pdf_page` (the fourth) was going to stay hand-written
  regardless — it answers with rasterised image bytes ahead of any dispatch decision, which the additive
  `deprecated` object field cannot reach. Left for P3b or an explicit ask-first decision on the coverage
  check's scope.

  Gates: `rust-gate.sh fmt` and `clippy rest`/`clippy imprint` clean; `cargo test -p impress-service-core
  -p impress-service-macros -p impress-capabilities -p impress-mcp -p impress-mcp-host -p impress-cli` all
  green; `check-verb-coverage.sh`, `check-verb-docs.sh` (no diff — no linked verb uses the new fields yet),
  `check-kit-deps.sh --strict`, `check-kit-standalone.sh`, `check-schema-refs.sh`, `check-uniffi-bindings.sh`
  and `cargo hakari generate --diff` all clean.
- 2026-09-26 — **P5a transport (first half)** on a worktree of main at ad9a0796, branch
  `claude/pipeline-p5a-transport`. **Client side:** new `crates/impress-app-transport` —
  `call(app, verb, args) -> Result<Value, Refusal>` over `POST http://127.0.0.1:<port>/api/verb/<name>`,
  the P0 loopback token attached (`impress_core::loopback_token::client_token_for_url`), a
  `traceparent` header carried on every call (hook H-P5-1), and one probe-with-60 s-cooldown
  (`impress-app-transport::is_reachable`, the same rule impel-tools used) replacing the four copies
  TR-3 found. `impress-app-transport::ports` is the Rust side's port table, pinned to
  `SiblingApp.descriptors` (Swift's one authoritative table, CLAUDE.md) by a test that greps the
  Swift file for each literal port. **Server side:** `impress_service_core::dispatch::dispatch` —
  one generic lookup-and-invoke (`VerbDescriptor::find` → `pipeline::invoke_blocking` → the wire
  envelope), added to `impress-service-core` rather than `impress-store-ffi` so it can be shared by
  a kit crate and a non-kit one (below); `impress-store-ffi::verb::dispatch_verb` is its UniFFI
  wrapper (`#[uniffi::export] fn dispatch_verb(name, args_json, caller_json) -> SharedVerbDispatchResult`),
  and `packages/ImpressAutomation/Sources/ImpressAutomation/VerbAutomation.swift` is `POST
  /api/verb/<name>`, mounted in `SharedAutomationRoutes` one door down from `/api/layout/*` and
  `/api/surface/*` — a direct call into `ImpressRustCore` (this package already links it for
  `LoopbackToken`), not a registered host, since a verb dispatch needs only the process-wide store
  to be open. Caller identity is `CallerIdentity::App(<bundle-id's last component>)` (ADR-0034 D3);
  `traceparent`, when present, becomes `caller_json.trace_id`, which the pipeline joins as the call's
  trace (H-P5-1's own line: "one id joins a surface click, its verb, the job it started").
  **Narrowed live, and why:** the plan's own alternative to a per-app UniFFI target — "the store FFI
  linking the app's services behind features" — was tried first (`implore-service` as an
  unconditional dependency of `impress-store-ffi`) and caught live by
  `scripts/check-kit-deps.sh --strict`: "impress-store-ffi reaches implore-core, a domain core. ASK
  FIRST … this is not a dependency to allowlist." `impress-store-ffi` is a kit crate
  (`docs/kit-manifest.md`); the check does not offer a manifest-only fix for a domain-core reach, by
  design. So P5a builds the plan's *other* alternative instead — the per-app UniFFI target the § P5
  design section names first ("App side: a per-app UniFFI target … linking the app's own `*-service`
  crate") — as a new, non-kit crate `crates/implore-verbs-ffi`: it links `implore-service` directly
  (cycle-free — `implore-service` itself has no edge back to `impress-app-client`, unlike
  `implore-service-http`), force-links its inventory the same way `impress-store-ffi::force_link_kit`
  does for the kit crates it cannot reach by name, and re-exports the same `dispatch_verb` shape over
  its own `dispatch_verb` UniFFI function calling the shared `impress_service_core::dispatch::dispatch`.
  `./scripts/check-kit-deps.sh --strict` is clean again with `implore-service` removed from
  `impress-store-ffi`. **What is finished and proven, and what is not:** `implore-verbs-ffi` compiles,
  is unit-tested (its own tests assert the five previously-dead verbs — `plot-series`,
  `plot-histogram`, `rg-statistics`, `rg-slice-raw`, `rg-slice-png` — are no longer `not-found`), and
  the parity test below drives it through the full transport. What it does **not** yet have is its
  own xcframework, a `Package.swift` and Xcode wiring into `apps/implore` so a *running* implore's
  `/api/verb/<name>` route actually calls into it — today that route only calls
  `impress-store-ffi`'s kit dispatch, so a live implore still answers `not-found` for these five
  until that packaging lands (P5b). This is the plan's own escape valve ("implement it for one app;
  say what remains") landing exactly there: the per-app *Rust* target is real and proven; the
  per-app *xcframework* is not yet built. **Parity test**
  (`crates/impress-app-transport/tests/implore_parity.rs`): a stub axum server whose one route calls
  `implore_verbs_ffi::dispatch_verb` directly — the same function a real `/api/verb/<name>` would
  call once P5b's packaging lands — proves `impress-app-transport::call("implore", …)` reaches three
  previously-live verbs (`status`, `list-datasets`, `list-figures`) and all five previously-dead ones
  without a `not-found`, and that an unknown verb name still refuses `not-found` through the same
  path. Not yet deleted (P5b's to do, per D-P7): the four `*-service-http` crates,
  `impress-app-client`, the 160 mirrored Swift arms. **Live proof on implore:** not run this session
  — the escape valve above ("implement it for one app; say what remains") is exactly why: the
  packaging that would make implore's *running* HTTP route answer through `implore-verbs-ffi` is
  the part left for P5b, so a live curl against a built implore would show its existing behaviour
  (the five routes still 404, `impress-store-ffi`'s kit verbs answering through `/api/verb/<name>`
  for every app) rather than anything this session's Rust-side work changed on the wire; running the
  build-and-launch cycle to prove that negative was not worth the machine time this session had.
  **Gates:** `./scripts/rust-gate.sh fmt` clean (after one `cargo fmt` pass); `clippy rest`,
  `cargo test -p impress-app-transport -p impress-store-ffi -p impress-service-core -p
  implore-verbs-ffi -p impress-capabilities`, `check-uniffi-bindings.sh`, `check-kit-deps.sh
  --strict`, `check-kit-standalone.sh`, `check-kit-packages.sh`, `check-chassis-deps.sh`,
  `check-schema-refs.sh`, `check-verb-coverage.sh` (two new verdict rows: `impress-app-transport`
  internal, `implore-verbs-ffi` ffi/internal), `cargo hakari manage-deps && cargo hakari generate`
  (no changes), `swift test` in `ImpressAutomation` and `PublicationManagerCore` — see the PR for the
  actual run's numbers, taken on a Mac shared with other agents' builds. **What remains for P5b:**
  the `implore-verbs-ffi` xcframework, its `Package.swift`, wiring it into `apps/implore`'s Xcode
  project, and a Swift-side fallback in `VerbAutomationRoutes` (or a registered second host) so
  `/api/verb/<name>` tries implore's own dispatch when the kit's says `not-found`; the same per-app
  split for imbib/imprint/impart (each currently has no domain verbs behind `/api/verb` beyond the
  kit's); migrating the actual entry paths (impress-mcp, impress-cli, impel-tools,
  impress-ai-tools) onto `impress-app-transport::call` and deleting the four adapters +
  `impress-app-client` + the 160 mirrored Swift arms (D-P7).
- 2026-09-27 — **P3c step 1: `imbib-semantic-service` given real lifecycle** (branch
  `claude/pipeline-p3c-semantic-search`, from main at 6a464881, which carries P3a #101). Tom's decision on
  ADR-0024 D7's other half, taken up after the P3a session log reported the reverted spike: a
  `semantic-search` feature beside `full` in `impress-capabilities`, so the three legacy tools get a real
  `#[impress_service]` trait without joining the shared inventory `impress-cli` and `impel-tools` link.
  New crate `crates/imbib-semantic-service` (workspace member, `imbib-semantic-service` workspace-deps
  alias): one trait `ImbibSemanticService` with `search_papers`, `get_paper_chunks`, `list_indexed_papers`
  — arguments and logic copied from `crates/impress-mcp/src/tools.rs` (deleted) and `store.rs` (deleted,
  copied verbatim as `imbib-semantic-service::store`). Each method's canonical name is the kebab form
  (`search-papers`, `get-paper-chunks`, `list-indexed-papers`); each declares
  `aliases = ["search_papers"]` (etc., the old flat snake_case name) and `deprecated(since = "0.1.0", note
  = "use <canonical>")`, `safety = read_only`, and an `effects(reads = [any(...)])` — `any(...)` rather than
  a schema ref, because the embeddings sidecar is a separate SQLite file with no `schema_ref` in
  `schema-refs.json`. Each method returns a JSON **object** (`{"ok", "results"|"chunks"|"papers"}` or
  `{"ok": false, "message"}`), not a bare array or string: P3a's additive `deprecated` envelope field only
  attaches to object results (`apply_deprecation_notice`), and a scalar/array return would silently drop it
  for exactly the alias calls this step exists to keep answering correctly. State (the lazily-built
  embedding stack and the shared-store connection) lives in `SemanticState`, mirroring the original
  `ToolContext` but `Send + Sync` throughout (`#[impress_service]` requires it): `OnceLock` for the
  embedding stack, a `Mutex<Option<Connection>>` for the main store (`rusqlite::Connection` is `Send` but
  not `Sync`), reached through a closure (`with_main_store`) rather than a returned reference so no borrow
  can outlive the lock guard.

  `impress-capabilities`'s new `semantic-search` feature (`imbib-semantic-service = { optional = true }`,
  force-linked in `lib.rs` behind `#[cfg(feature = "semantic-search")]`) is **not** part of `full` and not
  part of `impress-capabilities-kit` (this is a domain-service force-link, not the ADR-0033 D7 standalone
  kit slice). Only `impress-mcp` enables it (`features = ["full", "semantic-search"]`); `impress-cli` and
  `impel-tools` build unchanged. `impress-mcp`'s own `imbib-core`/`impress-embeddings` direct dependencies
  and its `store.rs`/`tools.rs` are gone — it now reaches the three verbs the same way it reaches every
  other `#[impress_service]` verb, through `inventory_bridge`; `render_pdf_page` is the one tool that stays
  hand-written (it answers with rasterised image bytes ahead of any dispatch decision, which the additive
  `deprecated` field cannot reach). `--embeddings-path` is retired: the service picks its own default via
  `SemanticState::default_embeddings_path`, matching the CLI's previous default; `--store-path` is
  unchanged.

  **Proof** (both required by the task spec, run from a clean `CARGO_TARGET_DIR=$PWD/target-p3c`):
  ```
  $ cargo tree -p impress-cli -e normal -i fastembed
  fastembed v4.9.1
  └── impress-embeddings v0.1.0 (…)
      └── imbib-core v0.1.0 (…)
          └── impress-memory-service v0.1.0 (…)
              └── impress-cli v0.1.0 (…)
  ```
  This is **not** a regression from this step: `impress-cli`'s own `Cargo.toml` already enables
  `impress-memory-service` with `features = ["vector-embedder"]` (its comment: "`impress-capabilities`'s
  `memory` feature deliberately does NOT enable `vector-embedder` … so this binary enables it itself to
  keep the vector tier it always had") — a pre-existing, independent decision that also enables
  `impress-embeddings/embedder`. `cargo tree -p impress-cli -e normal -i imbib-semantic-service` confirms
  the new crate itself is not reachable at all (`error: package ID specification did not match any
  packages`), which is the actual claim this step makes: P3c added no new fastembed edge to `impress-cli`.
  ```
  $ cargo tree -p impress-mcp -e normal -i fastembed
  fastembed v4.9.1
  └── impress-embeddings v0.1.0 (…)
      ├── imbib-core v0.1.0 (…) [multiple paths, incl. via imbib-semantic-service]
      ├── imbib-semantic-service v0.1.0 (…)
      │   └── impress-capabilities v0.1.0 (…)
      │       └── impress-mcp v0.1.0 (…)
      └── impress-memory-service v0.1.0 (…)
          └── impress-mcp v0.1.0 (…)
  ```
  (Full outputs are in the PR description / session transcript.)

  **Proof test**: `impress-mcp`'s `server::tests::search_papers_alias_reaches_the_inventory_verb_with_a_deprecated_notice`
  drives `tools/call` end to end with `"name": "search_papers"` and asserts `structuredContent.deprecated ==
  {"since": "0.1.0", "use": "imbib-semantic-service_search-papers", "note": "…"}` — the alias reaches the
  canonical inventory verb and carries the additive notice; a direct call to `imbib-semantic-service_search-papers`
  would not.

  **Not done, as specified**: `scripts/check-verb-coverage.sh` fails, exactly as anticipated —
  ```
  FAIL: workspace member imbib-semantic-service has no verdict in docs/verb-coverage.md
  FAIL: service ImbibSemanticService (imbib-semantic-service) has an impress_service_impl! block but no row in docs/verb-coverage.md (run the census test's dump for the row)
  ```
  Left for P3c step 2, along with `crates/impress-capabilities/tests/census.rs` and
  `docs/verb-coverage.md`/`verb-safety.md`/`verb-effects.md`, none of which were touched.

  Gates: `rust-gate.sh fmt`, `clippy rest`, `clippy imprint` all clean; `cargo test -p imbib-semantic-service
  -p impress-mcp -p impress-service-core -p impress-cli` all green (8 + 40 + 7 + 78 + doctests passed,
  0 failed); `check-kit-deps.sh --strict`, `check-schema-refs.sh`, `check-uniffi-bindings.sh`, and `cargo
  hakari generate --diff` all clean (`cargo hakari manage-deps` reported no operations to perform).
- 2026-09-27 — **P3c step 2: an `optional-feature` verdict for the coverage machinery** (same branch,
  merged with `origin/main` first — the merge brought in `capabilities-service`/`impact` (independent, kept
  both sides in `impress-capabilities/Cargo.toml`) and regenerated `Cargo.lock` rather than hand-resolving
  the conflict). Tom's decision: a workspace crate can carry the verdict `optional-feature` in
  `docs/verb-coverage.md`'s crate table, with the feature name in its *Reason* column —
  `imbib-semantic-service` | verb-crate | optional-feature | `semantic-search` … | is the first.
  `scripts/check-verb-coverage.sh`'s `VERDICTS` list gained it; the script does no verb-crate-vs-block
  cross-check itself (that lives in `census.rs`), so this was the only script edit needed.

  `crates/impress-capabilities/tests/census.rs`, `descriptor.rs` and `effects.rs` needed to both *see* the
  semantic verbs (so their rows can be checked for real) and *not choke* when they are absent, since
  `impress-capabilities`'s default features do not include `semantic-search` and `cargo test -p
  impress-capabilities` must stay green either way. Chose the second of the two options the step offered
  (teach the tests to accept a service linked only under a named optional feature) over gating the test
  *targets* on `required-features = ["semantic-search"]`: the latter would make `census`/`descriptor`/`effects`
  not run at all — silently, no failure, just absent from the default `cargo test -p impress-capabilities`
  output — which is a worse floor than "these three rows are exempt right now." Mechanism: `census.rs` reads
  each crate's verdict from the doc (`crate_verdicts`) and skips the usual "row present but not linked;
  delete it" / "is_verb_crate but verdict isn't `verb-crate`" complaints when the row names a service whose
  crate is `optional-feature`; `descriptor.rs` and `effects.rs`, which only ever see the verb by its
  qualified name once unlinked (no `VerbDescriptor` to look a crate up from), instead carry a small
  `OPTIONAL_FEATURE_VERB_PREFIXES`/`is_optional_feature_verb` const naming the qualified-name prefix
  (`"imbib-semantic-service_"`) and skip the same "not a linked verb; delete the row" complaint for it. The
  Total row and the argument-shape histogram in `census.rs` are recorded, per the doc's own stated
  convention ("Counted from `McpToolDescriptor::iter()` with every feature on"), for a
  `--features semantic-search` build — so those two specific assertions are behind `cfg!(feature =
  "semantic-search")` rather than exempted row-by-row; everything else in all three files (safety class,
  schema, effects declarations, naming lint) still checks every linked verb exactly, feature on or off.

  Also fixed, found while running `descriptor.rs` with the feature on: its
  `names_and_groups_are_derived_from_the_identifiers` test still asserted `v.aliases.is_empty()` for every
  verb — true before this step because nothing linked in `full` used P3-lifecycle's `aliases` field yet
  (main's `#[impress_method(aliases = …)]`, merged via #101, landed with zero adopters). `imbib-semantic-service`
  is the first, so the assertion became `v.aliases.is_empty() || v.deprecated.is_some()` — the pairing the
  macro actually requires (aliases needs `deprecated(…)` alongside it), not a blanket ban that stopped being
  true when the feature is on.

  **Regenerated** (never hand-typed) from the tests' own `dump`, each run as `-- --nocapture
  --test-threads=1 dump` with `--features semantic-search` so `imbib-semantic-service` shows up:
  `docs/verb-coverage.md`'s services table (18 crates, 40 services, 442 verbs, was 17/39/439) and
  argument-shape histogram (`scalar` 915, was 911); `docs/verb-safety.md`'s per-verb table (+3
  `imbib-semantic-service_*` rows, all `read_only`) and its "Counts today" line (178/128/33/103 — 442
  verbs with the feature on, 439 without — both numbers recorded since the doc is read by both builds);
  `docs/verb-effects.md`'s verb table (+3 rows, each `any(...)` reads, no writes, no external reach) and
  exception table (+3 `no example` rows — none of the three ships an `#[impress_example]` yet). Moved
  `EXCEPTION_CEILING` in `effects.rs` from 277 to 280 for exactly those three, with a comment saying so.
  `docs/verb-coverage.md`'s "Crates" section gained an `optional-feature` bullet in the verdict list and the
  `imbib-semantic-service` crate row (`verb-crate` role, `optional-feature` verdict, reason naming
  `semantic-search`).

  **`docs/verbs/` regenerated without the feature** (`cargo run -p impress-capabilities --bin gen-verb-docs`,
  no `--features`): `scripts/check-verb-docs.sh` invokes the generator unconditionally, and changing that
  script was out of this step's scope — so `imbib-semantic-service`'s pages are deliberately not part of the
  committed `docs/verbs/` tree yet. Also picked up `docs/verbs/capabilities-service.md` (new) and a
  `docs/verbs/README.md` diff from the `origin/main` merge (P3-impact's `capabilities-service`, unrelated to
  this step).

  **kit.yml**: not touched. Its own comment says the per-service counts "are checked by `cargo test -p
  impress-capabilities` instead" — `kit.yml` never runs `census`/`effects`/`descriptor` itself, so the
  step's conditional ("if the kit workflow runs them, exercise the feature once") does not apply. Where
  those tests *do* run in CI is `workspace-rust.yml`'s `test`/`rest` shard
  (`./scripts/rust-gate.sh test rest`, `cargo test --workspace --exclude imprint-* --features native`);
  because `impress-mcp` (in the `imprint` shard, not `rest`) declares `impress-capabilities = { features =
  ["full", "semantic-search"] }` unconditionally, and Cargo unifies a dependency's features across every
  target requested in one invocation, a `--workspace` run already compiles `impress-capabilities` — and
  therefore its `census`/`descriptor`/`effects` test binaries — with `semantic-search` on, even though no
  shard passes the flag explicitly. Confirmed by running `cargo test -p impress-capabilities` alone (isolated,
  no unification with `impress-mcp`) both with and without `--features semantic-search`, per the gates below.

  Gates (serial, `CARGO_TARGET_DIR=$PWD/target-p3c`): `rust-gate.sh fmt`, `clippy rest`, `clippy imprint` all
  clean; `cargo test -p impress-capabilities` green both with and without `--features semantic-search`;
  `cargo test -p imbib-semantic-service -p impress-mcp` green (40 + 7 passed, 2 ignored — the fastembed-init
  stdio smoke tests, as always); `check-verb-coverage.sh`, `check-verb-docs.sh`, `check-kit-deps.sh --strict`,
  `check-kit-standalone.sh`, `check-schema-refs.sh`, `check-uniffi-bindings.sh` and `cargo hakari generate
  --diff` all clean.
- 2026-09-27 — **P6 Python landed** (branch `claude/pipeline-p6-python`, worktree of main). One new
  crate, `crates/impress-py` (D-P8): a Python module `impress` with `list_verbs()` and `call(verb,
  args, app=None)`, **no path of its own** — `list_verbs()` reads
  `impress_service_core::descriptor::VerbDescriptor::iter` (the same linked inventory `impress-cli`
  and `impress-mcp` read, force-linked with `impress_capabilities::force_link()`, `full` feature);
  `call` with no `app` goes through `impress_service_core::dispatch::dispatch` — the FFI verb host's
  own by-name dispatch — with `CallerIdentity::App("python")` (the honest identity: this module speaks
  for the process that imported it, the same relationship the FFI host has to its caller, not an
  agent's sandboxed "the model asked for this"); `call(verb, args, app="impress")` goes over
  `impress_app_transport::call`, unchanged. The pyo3 wrappers are `mod py` behind the `python` feature
  (`im-bibtex`'s and `im-identifiers`' own gating pattern); the underlying Rust (`list_verb_infos`,
  `call_local`, `call_remote`) has no `pyo3` in its signature and is exercised directly in
  `tests/dispatch.rs` — no Python interpreter needed for `cargo test`. `maturin` was not available on
  this machine to build the wheel; the build command is `maturin build --release --features python -m
  crates/impress-py/Cargo.toml` (documented in the crate's module doc), and `cargo check -p impress-py
  --features python` was run in its place to prove the pyo3 half compiles. `docs/verb-coverage.md`
  gained one `internal` row (`impress-py`, no capability of its own). Retiring `im-bibtex`'s and
  `im-identifiers`' own MCP servers (PY-1's other half) was left alone — their functions are not yet
  verbs, which is the row's own should-be-verb finding, not this package's — and is **what remains**.
  **Proof:** `cargo test -p impress-py` — `call_local` runs `imbib-text-service_decode-latex` through
  the pipeline (`Caf\'{e}` → `Café`, the plan's own proof verb) and refuses an unknown verb by name;
  `list_verb_infos` finds it in the inventory with a non-empty description and an object input schema.
  **Gates:** `rust-gate.sh fmt` (one `cargo fmt` pass), `clippy rest` and `clippy imprint` clean;
  `cargo test -p impress-py` (3/3) and `-p impress-capabilities` (full suite) green; `check-verb-
  coverage.sh` (84 crates verdicted, should-be-verb still 20/20, unchanged), `check-kit-deps.sh
  --strict`, `check-kit-standalone.sh` (17-crate scratch build), `check-schema-refs.sh` (396 sites, 0
  divergences) all OK — `impress-py` is not a kit crate, so none of the three moved; `cargo hakari
  manage-deps` (no operations) and `cargo hakari generate --diff` (no changes) — the new crate needed
  no `workspace-hack` entry of its own beyond the existing `pyo3`/`pythonize` lines.

- 2026-09-27 — **P5b started after G5 #124.** Worktree `p5b-transport`, branch
  `claude/pipeline-p5b-transport`, starts at `85cf0520`. Source inspection confirmed that the
  implore/impart service defaults refuse or return empty values while live domain state remains
  in Swift. Their per-app FFIs therefore need async native state callbacks, not just inventory
  linking. Shared `dispatch_async`, namespace-selected Swift dispatch and task-local native
  refusal reporting are in `05e14e9c`: a callback failure replaces a typed placeholder before
  envelope/audit, preserving existing verb signatures. Isolated core tests passed 91 and shared
  Swift route tests passed 7. Native domain bridge implementation and the client router are
  in progress; no P5b native app has launched and no adapter deletion is yet accepted.
  Impart decisions retain the existing process-local ProvenanceService semantics; no new schema
  or invented message record is being introduced to imply durable decision storage.

- 2026-09-28 — **P5b verification in progress.** Shared native dispatch and
  exact store selection are implemented in `claude/pipeline-p5b-transport`.
  Initial touched-crate tests passed 2,293 (5 ignored), and both clippy shards
  passed. The 185 actual adapter methods pass mock forwarding/refusal parity;
  this is wire coverage, not a claim of native semantic parity.
  A hosted imprint startup crash exposed four separately bundled SQLite
  implementations in its Mach-O images. All twelve native framework scripts now
  select the platform library, leaving headless Cargo's bundled feature alone;
  wrapper packages link sqlite3. All full arm64 builds passed, and 672 core
  tests passed using the platform library. Both hosted proof runners reject a
  bundle with any `_sqlite3_open_v2` definition before launching it.
  Rebuilt imbib, impart, implore and impel proofs passed on their own device IDs,
  ephemeral ports, distinct bundles and PID-owned stores. Evidence roots:
  `/tmp/impress-p5b-transport-k050kncx`, `ewotapuq`, `78o6z3xd`, and `nxuwp68r`
  (all use the same `/tmp/impress-p5b-transport-` prefix). Imprint's owned proof
  `qpw7yjve` passed the 78-image SQLite check, then exposed the missing Tokio
  reactor at async FFI and placeholder manuscript handlers; fixes are pending.
  No user's app or store was used. Remaining distinct REST contracts are
  documented in `docs/p5b-retained-http-endpoints.md`; their retirement needs
  the caller/contract decision already requested from Tom. Final native proofs,
  adapter retirement and gates are still required; no P5b PR is open yet.

- 2026-09-28 — **P5b native transport verified; retirement narrowed by actual contracts.**
  The four typed HTTP adapter crates and `impress-app-client` are removed;
  their 185 actual trait methods retain a mock forwarding/refusal parity test.
  Four app-owned FFIs dispatch the same service inventories with native Swift
  callbacks where GUI state is required. Foreign async entry runs on the shared
  Tokio runtime and aborts a cancelled dispatch future. Imprint manuscript
  metadata reads now use the exact shared store; export uses the native handler,
  and invalid/missing IDs remain refusals. Native writes install a per-image
  audit sink bound to the GUI database, rather than relying on a different
  framework's globals or an environment fallback.
  A real imprint proof found that dyld interposed Rust implementation symbols
  across SwiftPM frameworks: one image wrote its refusal while another read it.
  All 11 native wrapper manifests and the six app projects now keep Rust
  implementation symbols private while preserving the public UniFFI C ABI.
  The prelaunch bundle checker rejects those exports and bundled SQLite;
  four checker fixtures and a 78-image imprint scan passed. All twelve full
  arm64 xcframework builds passed with swiftformat absent and no fast builds.
  Impart's archive builder now leaves generated bindings beside its archive
  while ImpartRustCore remains a placeholder without a binary target.
  Final isolated native proofs: imbib `90w2ucgr` (PID 94153, 8 HTTP calls),
  imprint `l4gp9bcz` (90768, 14), impart `iglcruqj` (92934, 8), implore `y2bb5seh`
  (90202, 5 plus its dedicated RG/figure proof), and impel `zryomkul` (91283, 2).
  Each root has prefix `/tmp/impress-p5b-transport-`. The four domain proofs
  verify committed writes and exact supplied trace, parent-call and caller in
  their own store's verb-call row. Imprint also proves real PDF compilation,
  native edits, pending human buffer preservation, UTF-16 comments, three
  export formats and failed-ID refusals. All launched proof processes exited.
  Strict-argument proofs also passed on all five shells: five stored scenarios,
  15 surface catalogue cases, 56 layout catalogue cases and zero skips;
  `/tmp/impress-p5b-final-strict-summary.json` records their roots and PIDs.
  Final native tests across 27 touched crates (including capabilities) passed
  3,052 with 19 ignored in 82 groups. Both clippy shards, fmt, coverage/docs,
  strict kit dependencies, 21 standalone kit crates, 11 bindings, schema refs
  (410 sites, 85 refs), and hakari diff passed. Tables were regenerated from
  the census/descriptor/effects dumps with semantic-search enabled: 477 verbs,
  84 example-verified, 93 catalogue-verified, 300 exceptions. Reference pages
  use the default feature inventory.
  Thirty-four equivalent Swift route registrations are retired. The original
  estimate of 160 mirrored arms conflated several richer REST contracts with
  the narrower verb signatures. `docs/p5b-retained-http-endpoints.md` records
  retained data, arguments and active callers; further retirement requires the
  caller/contract decision already requested from Tom. No verb arguments,
  schemas or record kinds were changed to invent that equivalence. [PR #126](https://github.com/yipihey/impress-apps/pull/126) is ready. The normal
  pre-push hook passed macOS and arm64 iOS simulator builds after its chassis
  allowlist caught PMC's now-explicit edge to ImprintRustCore (already transitive
  through ImprintCore; no new archive). Push log: `/tmp/impress-p5b-push-r2.log`.
  No P5b merge is claimed by this entry.


- 2026-09-28 — **P5b native transport merged as #126 (`e7cf88a4`).** Fresh fetch
  and `git merge-base --is-ancestor origin/main HEAD` passed before the authorized
  merge. The normal pre-push macOS/iOS builds and all local gates were green;
  hosted jobs remained queued. On merged main, the isolated native workspace
  suite passed **4,341 tests, 0 failures, 23 ignored** in 217 result groups
  (`/tmp/impress-after-p5b-main-workspace.log`). The retained REST contract decision
  is still open; this merge does not claim all of the estimated 160 arms retired.

- 2026-09-28 — **P5c retained-route contract proposal only.** Added
  [`p5c-contract-proposal.md`](p5c-contract-proposal.md), based on the P5b route
  inventory and local checks of the current service signatures and active Swift
  callers. Follow-up review made cite-key resolution use the existing exact
  `find-by-cite-key`, required per-result search hydration, avoided changing
  `list-collections`, classified collection/membership/library-delete/tag
  routes, and kept UI-registry queue operations as platform routes instead of
  proposing duplicate queue verbs. Additive contracts remain subject to Tom's
  review. No service signature or route changed; this proposal is not approval
  to implement or retire any route.

- 2026-09-28 — **P7 implemented and verified; draft #127 awaits the representation decision.**
  Worktree `p7-construction`, branch `claude/pipeline-p7-construction`, starts at
  `e7cf88a4`. One shared build-time manifest reader generates 85 typed core refs,
  string metadata for crates below the store, and the additive UniFFI Swift enum.
  Rust schema queries and collection bindings take the private type; Swift's
  custom UniFFI string alias preserves existing callers. The literal backstop
  reports 0 Rust / 120 Swift sites, with no new record kinds or spellings.
  All 86 crates inherit workspace lints. Clippy cannot ban `String` only in a
  schema position: the typed API/private constructor supplies that boundary,
  while the SQL/wire lint remains a backstop. Strict standalone kit builds now
  run the existing dependency/feature classifier and carry the manifest input.

  Cheaper workers implemented the macro errors, exhaustive sidebar matrix and
  exact self-test evidence mapping. Review caught stale macro-artifact selection
  in the compile-fail harness (now built by Cargo in its own target) and blanket
  service-wide catalogue credit. Credit now requires the exact passing,
  non-skipped capability ID; focused Tier A fixtures close 18 unsupported claims
  without raising the 300-exception ceiling. Headless native-export and disabled
  compiler contracts are labelled as refusals, not positive native operation.
  The aggregate store-spy check is separate. An extra post-uncollect readback
  exposed the existing wildcard observation for an empty schema-less membership
  query; the collect/uncollect fixture now asserts the actual persisted collection
  edges, without weakening the spy or broadening production effects.

  Final isolated native workspace tests passed **4,351 / 0 / 23 ignored** in 218
  groups (`/tmp/impress-p7-workspace-native.log`, owned workspace
  `/tmp/impress-cargo-tests.8xMfF8/workspace`). Separate core/FFI tests passed 792;
  nine Swift schema/sidebar tests passed, including real native enum/string
  query round trips. Both clippy shards, fmt, coverage, docs, strict kit deps and
  standalone (21 crates), bindings, schema refs and hakari diff passed. All twelve
  native framework scripts passed with every supported arm64 slice, swiftformat
  off PATH and no fast mode. The normal pre-push macOS and iOS builds passed
  (`/tmp/impress-p7-push-final.log`). Census/descriptor/effects tables were
  regenerated from semantic-search-enabled dumps and stayed byte-identical;
  default-feature reference pages remain current. No user's app or real store was
  used. The only cleanup removed this session's obsolete P5b temporary build
  products, retaining proof logs and workspaces.

  **Not merged:** the requested refinement is private `Cow<'static, str>` instead
  of table RC's `&'static str`. Canonical constants stay static and `FromStr` is
  exact; explicit persistence/Swift-wire decoding owns opaque names to preserve
  old backups and newer-writer rows without leaking interned strings. Tom's answer
  remains pending. PR: https://github.com/yipihey/impress-apps/pull/127. After that
  decision, fetch/merge current main, recheck ancestry and gates, mark ready and
  merge. P8, R3, G3's remainder and the scenario-interpreter gaps are not started;
  P5b's richer REST contract retirement also remains open as recorded above.

- 2026-09-28 — **P7 representation decision resolved; hosted build repair in progress.**
  Tom accepted the recommended private `Cow<'static, str>` representation. Table RC
  and D-P9 now record the refinement: canonical constants allocate nothing, while
  explicit persistence/wire decoding retains unknown names in owned storage.
  PR #127 contains current main (`78d89f10`), with the final local gates recorded
  above. The hosted impart app build exposed an omitted `ImpartVerbsFfi` framework
  step in CI (run `36444031435`); the workflow repair and its verification are
  required before marking the PR ready and merging.

  The CI repair (`8c6c86bf`) adds the missing impart, imprint and implore verb
  frameworks to their app jobs and the shared action's cache/output inventory.
  `schema-refs.json` now invalidates both cache-key paths. All changed YAML parsed,
  the seven required job/framework edges passed, and the parent executed the
  action's metadata step for all three new entries against the rebuilt artifacts:
  every required output exists. Isolated impart app builds and the new hosted run
  remain the final checks. The release-lane audit also found older debt outside
  this fix: implore's release workflow names a missing `apps/implore/build-rust.sh`,
  and imprint/implore release lanes do not build their full older sibling graph.

- 2026-09-28 — **P8 runtime providers, integration checkpoint** (branch
  `claude/pipeline-p8-providers`, based on reviewed P7 while #127 finishes hosted CI).
  Added owned runtime descriptors behind the shared inventory; strict provider
  registration, local private credentials and the approved `provider@1.0.0` row;
  authenticated MCP HTTP registration/deregistration; host-only JSON Schema
  validation and loopback transport; Person-only generated trust action; and
  runtime readers for MCP, CLI, Python, impel/AI tools, surfaces and reference docs.
  No kit dependency was added: the JSON Schema engine stays in non-kit
  `impress-app-transport`, with native raw callbacks through ImpelToolsFFI.
  Provider writes use guarded store clocks, cross-process trust is refreshed
  before policy, and successful results must match the declared output schema.
  Native health changes now invalidate catalogue/provider source caches, retaining
  unavailable descriptors by name. Tables were regenerated from semantic-search
  test dumps; the effects exception ceiling remains 300, with a durable Person
  trust capability proving the successful path. The real isolated Python Tier B
  lifecycle passed; local unit/integration tests are green so far. Full P8 gates,
  regenerated native bindings/cohort, native proof, PR and merge are still pending
  at this checkpoint. No running user app, launcher or real store was used.

- 2026-09-28 — **P7 merged as #127 (`9d7ee7a4`).** The repaired hosted impart
  job (`36460078624` / `109056163908`) passed both the macOS build and the iOS
  simulator install smoke; all eight PR checks were green. A fresh fetch and
  main-ancestry check passed before the authorized normal merge. Main was fast
  forwarded, and P8 merged that main. The next full native workspace run belongs
  to the P7/P8 merge batch. Tom's accepted `Cow<'static, str>` refinement remains
  recorded in D-P9; no representation decision is outstanding.

- 2026-09-28 — **P8 implementation and local verification complete; push/PR next.**
  Parent review and the isolated native proof found and fixed three integration
  failures: the native metadata host was missing the capabilities inventory;
  independent Rust-image health/trust refreshes needed both revision numbers to
  invalidate catalogue sources; and a structured provider refusal needed to fail
  a surface source/action rather than become successful JSON data. The runtime
  retains the resolved handle through the pipeline, preserves linked contracts,
  and reports the refused provider verb by name. History, scenarios and lifecycle
  reporting now include owned descriptors; dropped references are reported without
  modifying user documents. Seventeen negative examples complete the default
  linked example runner's existing gaps without changing verb arguments.

  A cheaper worker's bounded security review also caught stale cross-host token
  acceptance and unbounded response reads. HTTP provider identity now refreshes
  the persisted row off the reactor and fails closed; health bodies are bounded
  to 4 KiB and verb JSON to 2 MiB while streaming. Two-host rotation/read-failure
  and chunked-body tests pass. Registration clocks, private immutable credentials,
  pre-policy refresh and output-schema validation were reviewed. No kit dependency
  was added, and only the previously approved provider schema was introduced.

  The final isolated 18-crate run, including capabilities, passed **1,424 tests,
  0 failures, 6 ignored** in 58 groups (`/tmp/impress-p8-verified-touched-tests-green.log`,
  workspace `/tmp/impress-cargo-tests.QPc9O7/workspace`). Both clippy shards, fmt,
  coverage/docs, strict kit deps/standalone (21 crates), Swift kit boundaries,
  bindings, schema refs and hakari diff passed. Seven verb tables were regenerated
  from semantic-search test dumps; default reference pages are current (45 services).
  All twelve native framework scripts passed with every supported arm64 slice,
  swiftformat off PATH and no fast mode (`/tmp/impress-p8-verified-native-<crate>.log`).
  The real Python Tier B lifecycle passed again; the existing debug CLI/MCP linker
  `__eh_frame` size warning also occurs in P7 and is not new.

  The opt-in native proof passed on its own unsigned bundle, derived-data path,
  ports, device ID and PID-owned store. It proves agent trust refusal, the generated
  Person trust action, a separate CLI's persisted trust read, generated provider
  form invocation, the same subscribed catalogue's offline update, and a named
  source refusal after stopping its own Python child. Evidence:
  `/private/tmp/impress-p8-proof-9y64dfo5/output/host-60903/proof.json`; native symbol
  checks pass and `/api/logs` returned 200. The app and both children exited; no
  user app, launcher or real store was used. This is SurfacePaneModel dispatch,
  not a claimed physical click. Reproduce with the checked-in
  `scripts/test-runtime-provider-native.py` and the example README.
  P8 contains merged main `9d7ee7a4`; normal pre-push, PR and merge remain next.


- 2026-09-29 — **P5c contract decisions authorized.** Tom explicitly overrode
  the ask-first rule and delegated remaining implementation decisions, including
  verb argument changes. The retained-route contract document now records the
  implementation baseline. Begin with small read-contract packages for imprint
  document metadata, imbib library metadata and implore figure metadata, then
  complete the remaining domain contracts and migrate callers after native
  parity. Queued UI operations, live editor/viewer and hardware routes retain
  their recorded platform ownership. This authorization record changes no
  runtime behavior and does not claim the implementation or parity complete.

## P5c1 — imprint document read contract (2026-09-29)

The generated `imprint-manuscript-service_list-documents` and `get-document`
results now project authors, status, word count, timestamps, and linked imbib
IDs from the same manuscript rows as imprint's existing `/api/documents`
routes. Missing fields in older serialized summaries retain safe defaults;
list reads preserve the route's created-time fallback for modified time, while
detail reads preserve its optional modified time. Missing or invalid formats
use the same `impress_core` format detector that backs Swift's
`DocumentFormat.detect`; the native decoder now accepts both whole-second and
fractional RFC 3339 dates before the routes normalize them to whole-second UTC.
The native verb backend already delegates these reads to the shared-store
implementation, so it needs no separate metadata source.

Focused Rust contract coverage checks list/detail projection, exact stored
timestamps and links, body-derived word count, and legacy deserialization.
The isolated hosted XCTest compares legacy HTTP list/detail metadata against
the generated verb responses on its PID-owned scratch store. Root verification
passed 130 Rust tests (zero failures, three ignored), every quick gate, and all
supported arm64 slices of store-ffi, impel-tools and imprint-verbs-ffi with
swiftformat off PATH. Seven verb tables were regenerated from semantic-search
test dumps and were unchanged. Logs: `/tmp/impress-p5c1-{tests,gates,frameworks}.log`.

The hosted proof passed both XCTest cases and fourteen shared transport calls:
`/tmp/impress-p5b-transport-uipdhngz/output/`. Native SQLite symbol checks passed;
PID 86745 exited. The first proof exposed a test comparing NSArray descriptions
containing allocation addresses; value equality fixes that test without changing
production results. Failed evidence remains at
`/tmp/impress-p5b-transport-fi4dwz5b/`. No user app, launcher or real store was used.
The existing debug linker unwind-size warning remains unchanged.

- 2026-09-29 — **P5c3 implore figure read DTO parity.** `FigureRecord` now
  decodes the full legacy figure dictionary: type, dimensions, optional axis
  columns/title, timestamps, tags and folder ID. The current handler omits
  `datasetName` and `viewState`; their optional DTO fields preserve absence and
  accept null, while a Rust fixture exercises populated values from an enriched
  host. The `custom` type fallback and HTTP 800×600 dimension defaults remain
  intact. Native adapter and headless refusal tests cover the mapping, and the
  isolated native proof compares generated list/get output with actual HTTP
  fields and absent keys. Root verification passed 56 Rust tests (zero failures,
  three ignored) and every quick gate after integrating merged library reads.
  Store-ffi, impel-tools and implore-verbs-ffi were rebuilt for all supported
  arm64 slices with swiftformat off PATH. Seven semantic-search dump tables
  were regenerated unchanged. Both hosted XCTest cases and five shared
  transport calls passed at `/tmp/impress-p5b-transport-xaasbfub/output/`;
  SQLite symbol checks passed and owned PID 50195 exited. Logs are
  `/tmp/impress-p5c3-final-{tests,gates}.log`,
  `/tmp/impress-p5c3-frameworks.log` and `/tmp/impress-p5c3-native-proof.log`.

## P5c4 — impart conversation read contract (2026-09-29)

Conversation summaries now carry the route's participants, tags, parent ID,
last activity and summary text; detail reads also carry ordered messages and
the repository's computed statistics. List reads retain the route's most
recent-first ordering, archived filter, total-before-pagination and page
count. The baseline omitted the route envelope's `count` and applied
`include_archived` value, so both are present in `ConversationList` alongside
offset/limit. The delegated optional `query` is an additive case-insensitive
title/summary filter (the existing HTTP route has no text-query parameter); its
filtered total is computed before pagination and the query is echoed.

Native callback tests exercise the new list/detail projection and an isolated
hosted proof compares the actual legacy routes with generated Rust verbs on
one in-memory Core Data fixture. No route or caller migration is part of this
package. Root verification passed 46 Rust tests (zero failures, three ignored),
all quick gates and all supported arm64 slices of store-ffi, impel-tools and
impart-verbs-ffi. Three isolated Swift tests passed, including actual HTTP vs
generated list/detail paging, archive filtering, messages and statistics. The
native host proof passed one XCTest and eight shared transport calls, with
SQLite symbol verification: `/tmp/impress-p5b-transport-uc2k9anm/output/`.
Owned PID 78083 exited. Root fixed the list mapper's default-argument closure
and the test diagnostic's Swift Testing comment before the successful runs.
Logs: `/tmp/impress-p5c4-{tests,gates,frameworks,native-proof}.log` and
`/tmp/impress-p5c4-swift-tests-verified.log`. Existing Swift concurrency/Core
Data warnings remain; no persistence schema was changed.

## P5c15 — imbib library deletion contract (2026-09-29)

Extended single library deletion with `delete_files` and added validated batch
deletion. The store preflights every batch UUID and existing library before
file cleanup or row mutation; `delete_files: false` remains a store-only unlink,
while `true` reaches the running app's shared + legacy container cleanup. File
cleanup errors now refuse the store deletion and disclose if earlier containers
in that batch were already removed. The generated methods do not return store
undo snapshots, and an undo cannot recreate deleted filesystem bytes.

Rust coverage checks the single/batch argument schemas and proves a valid first
ID plus a missing later ID leaves the first library intact. Native scratch
coverage checks unlink-only file preservation and the callback's exact
container cleanup. Root owns builds, tests and native framework verification;
this package ran static formatting and diff checks only.

- 2026-09-29 — **P5c5 binary figure export implementation.** Added generated
  `implore-service_export-figure-data` with fractional width/height,
  scale and optional view-state arguments. The native callback reuses the HTTP
  export handler and `ImploreStoreAdapter.exportFigure`, then returns the
  renderer's path/hash/MIME plus the rendered file bytes decoded from the HTTP
  base64 envelope. It verifies byte count and SHA-256 against the renderer
  result before replying, so a concurrent or stale file cannot be reported as
  the requested render. Legacy `export-figure(figure_id, format)` remains
  unchanged. Evidence refinement: the route and verb both accept fractional
  `f64` dimensions; zero, negative, and non-finite overrides fall back to the
  current logical size via the renderer's existing `positive_or` rule. Hosted
  proof compares generated PNG/SVG bytes, including a fractional-size case,
  with the actual route. Rust callback tests cover fractional argument
  forwarding, decoding, malformed data and HTTP refusal. Root verification is
  pending; no caller or route was migrated.

- 2026-09-29 — **P5c5 verified.** Root passed 59 Rust tests (zero failures,
  three ignored), every quick gate and all supported arm64 slices of store-ffi,
  impel-tools and implore-verbs-ffi. The hosted proof passed both XCTest cases,
  five shared transport calls and PNG/SVG byte-for-byte parity, including
  fractional dimensions; SQLite symbols passed and owned PID 10562 exited.
  Evidence: `/tmp/impress-p5b-transport-9jpsnn14/output/` and
  `/tmp/impress-p5c5-{tests-final,gates,frameworks,native-proof}.log`.
  Tables and reference pages were regenerated. The new renderer verb increases
  the documented headless exception ceiling from 145 to 146: its positive
  evidence requires the native app, and a refusal is not claimed as byte
  coverage. Root corrected a merged test fixture's moved JSON value before
  verification. No user app, launcher or real store was used.

- 2026-09-29 — **P5c6 verified.** Root passed 1,053 Rust tests (zero failures,
  three ignored), every quick gate, and full supported arm64 builds of
  ImbibCore, store-ffi, impel-tools and imbib-verbs-ffi. Final linked native
  proof passed one XCTest and 13 shared transport calls, including RIS parity
  against the retained route; SQLite symbol checks passed and owned PID 77670
  exited. Evidence: `/tmp/impress-p5b-transport-m3ixws5a/output/` and
  `/tmp/impress-p5c6-final-{tests,gates,frameworks,native-proof}.log`.
  Tables and reference pages were regenerated. Root corrected the seeded
  bibliography fixture, a module-qualified test helper and converter lint
  findings before these runs. No user store or running app was touched.

## P5c7 — imprint threaded comment metadata (2026-09-29)

Extended `imprint-app-service_list-comments` with optional route-compatible
`filter` and `author_agent_id`, and `create-comment` with optional parent,
suggestion, agent identity, and display name. `CommentRecord` now retains the
actual route fields: author identifier, duplicate `content`/`body`, live
UTF-16 range, modified time, resolved/suggestion flags, parent, proposed text,
and agent identity. These are existing `Comment` values, not synthesized
metadata. Native create continues to call `CommentService.addComment`; anchors
are located in the current source and converted from UTF-16 to the store's
UTF-8 anchor through the existing comment store, while replies inherit their
parent's current range. A malformed or cross-document parent is refused.

The route source showed that its documented `mine` filter currently falls
through to the unfiltered result; this package preserves the handler's actual
behavior and does not silently change a retained HTTP route. Unknown filters
also retain that existing all-comments behavior. Accept/reject remain separate
actions; update-comment still only accepts open/resolved status.

Rust record coverage checks all newly projected fields and route camel-case
aliases. The hosted `ImprintNativeVerbProofTests.testNativeGenericRouteAndAppRefusalUseTheScratchWorkspace`
compares a direct legacy suggestion/read and a generated filtered read on the
same PID-owned scratch manuscript, then creates a generated threaded suggestion
and verifies parent identity and inherited UTF-16 offsets. Root owns running
the Rust/native verification and regenerating any generated assets.

## P5c8 — implore figure mutation contracts (2026-09-29)

Extended `implore-service_create-figure` with HTTP-compatible integer
`width`/`height`, separate plot `title`/`color_column`, and an optional raw
JSON `view_state`; explicit create fields overlay corresponding fields in that
view state. Added generated `update-figure` and `delete-figure` callbacks that
reuse `handleUpdateFigure`/`handleDeleteFigure` and `LibraryManager`'s existing
store, rerender, rollback, export cleanup, and content-blob reference logic.
Update accepts only the fields PATCH actually mutates; it deliberately has no
`dataset_id` because the HTTP handler does not change a figure's dataset.
Update returns a structured `{ok, error?, figure?, artifact?}` result and
refused native responses remain refusals; delete keeps the approved `bool`
result. Create/update/delete declare figure-record effects and app reach.

Rust coverage checks generated schemas, effects, callback argument mapping,
render/update and missing/delete failures. Hosted proof compares verb and HTTP
create/update hashes on isolated figures, confirms a changed non-empty PNG,
and tests shared-blob retention through update and the last delete. Root owns
verification; no tests/builds, caller migrations, route removals, or real-store
operations were performed here.

## P5c9 — imbib publication search contract (2026-09-29)

Extended `imbib-library-service_search-publications` with optional offset and
the approved read/collection/library/tags/flag/added-after/added-before
filters. The generated service evaluates membership and metadata filters on
the complete ordered match set before applying pagination; exact library and
collection UUID membership comes from the existing store queries, not names
or a capped result page. Empty queries retain the default-library scope unless
an explicit library or collection selects its own scope.

Inspection found that the legacy `GET /api/search` parsed library and
collection UUIDs but `AutomationService.applyFilters` explicitly skipped both
filters. This package fixes that parity gap without changing the route shape:
empty-query container selection now uses the selected container; exact
library membership uses the existing store query, and exact collection
membership uses the existing detail relationship before pagination. Focused
Rust coverage checks same-named libraries, collection/library intersection,
read/tag/flag filters, post-filter offset behavior and strict date boundaries.
The hosted transport fixture compares generated and legacy IDs/order for
library/read, collection (including empty-query selection), and offset cases on
its isolated papers. Verification remains pending with root; no builds/tests
were run in this package.

## P5c10 — imprint suggestion actions (2026-09-29)

Added generated accept/reject suggestion actions by routing the native callback
through the retained HTTP handlers. Inspection found `DocumentRegistry` has no
imprint operation consumer after the editor migration; the old accept handler
queued `replaceRange` but therefore did not apply or save it. Acceptance now
validates the comment and proposed text, replaces the comment's UTF-16 range in
the live editor session through the existing native save/readback path, registers
and returns a completed operation ID, refreshes comment anchors against the new
source, and then resolves only that comment. Rejection resolves without editing
the manuscript. Failures remain explicit: malformed IDs are bad requests,
missing comments are not found, non-suggestions cannot be accepted, and a failed
live edit leaves the comment unresolved. `update-comment` still refuses
accepted/rejected status values.

`SuggestionApplyResult` retains the route's accepted flag, comment/document IDs,
and operation ID. Rust coverage checks its route-response aliases. The hosted
proof exercises direct HTTP and generated acceptance, verifies live-buffer and
store readback at the expected UTF-16 replacement, and checks rejection leaves
source unchanged. Root owns builds, tests, framework/binding regeneration, and
final native verification.

- 2026-09-29 — **P5c10 review refinement.** Accepting a suggestion captures
  its synchronized range and source together. The edit checks that source
  again on MainActor before applying the range, returning conflict if typing
  intervened. A native fixture covers a stale range that remains numerically
  valid, preserving both the live edits and the previously saved manuscript.


## P5c11 — imbib citation resolution (2026-09-29)

Added `imbib-app-service_resolve-citation` with optional free-text, BibTeX,
structured citation, target library, and PDF-download inputs. Its native
callback dispatches to the existing `handleResolvePaper`, preserving the
legacy identifier/local-search/external-search cascade and the structured ADS
resolution path. The output preserves `via`, open paper/candidate objects,
ranked confidence, and reason without flattening the distinct HTTP candidate
shapes. Citation text, BibTeX, and structured citation arguments are marked
private in generated call audit metadata. The headless backend explicitly
returns `via: unavailable` rather than reporting a false miss. `ExternalPaper`
now carries the HTTP candidate's selected import `identifier`, including its
title fallback when no DOI, arXiv ID, or bibcode is present.

Focused Rust fixtures cover HTTP-compatible structured input conversion,
callback argument forwarding, candidate order/confidence/reason preservation,
external import identifiers, generated private-field schema, and honest
headless refusal. The hosted transport proof now resolves a paper it imported
into its PID-owned scratch library through both `/api/papers/resolve` and the
generated verb, compares the local-search `via` and paper identity/content, and
checks missing-input refusals on both surfaces. External search identifier
mapping is covered by the deterministic Rust native-response fixture; no live
source credentials or network search are required. No builds/tests, route
removal, or caller migration were performed in this package.

## P5c12 — imbib identifier import contract (2026-09-29)

Added `imbib-library-service_import-identifiers` as the generated library
capability while keeping identifier resolution, default-library selection,
collection membership, duplicate lookup, recent-add activity and optional
background PDF acquisition on the existing `AutomationService.addPapers`
path. A private app-service callback seam lets the library verb reach that
running-app behavior without creating a second public verb. The legacy paper
dictionaries in `added` remain lossless JSON; `duplicates` and `failed` retain
their exact per-identifier results. With imbib closed, the default callback
reports `host-unavailable` instead of claiming that imports succeeded.

The native XCTest fixture covers an already-local cite key and an unsupported
identifier in a scratch library/collection; Rust schema/callback tests cover
full added-row fields and optional target/PDF arguments. Build and test
verification is owned by the root integrator; this package did not run builds,
tests or framework generation.

## P5c13 — imbib collection membership (2026-09-29)

Added `imbib-library-service_update-collection-members(collection_id,
identifiers, action)` with ordered `assigned` and `not_found` outcomes for
`add`/`remove`. Resolution follows `PaperIdentifier.fromString` for local UUID,
citation key, DOI, arXiv, bibcode and PMID lookups; recognized external-only
Semantic Scholar/OpenAlex identifiers remain misses, with no fuzzy search.
Generated writes use the library service's store-backed mutation path and its
declared collection write effect, so the imbib domain dispatcher posts its
normal store-mutation/display refresh after success.

Route review found both retained membership paths could report papers as
assigned even when a valid UUID named no collection: `AutomationService` ignored
the adapter's logged `addToCollection`/`removeFromCollection` failure. The
shared collection operations now perform exact existing-collection lookup
before membership work, making both routes return their existing 404 mapping;
the generated verb refuses the same missing target. Tests cover ordered local
identifier outcomes, add/remove persisted edges, invalid action/missing target,
and an isolated route-versus-generated callback fixture. Root owns tests and
native verification; no callers or routes are removed here.


## P5c14 — imbib tag-count reads (2026-09-29)

Extended `imbib-tags-service_list-tags-with-counts` with optional case-
insensitive `prefix` and optional `limit` (default 100), applied after the
shared store's full hierarchical count projection and preserving its existing
order. `TagWithCount` now includes `id = path` and the parent path derived from
the last `/`. The native HTTP `/api/tags` projection now returns this stable
path as `id`; this intentionally replaces the old freshly-generated UUID,
which changed on every read and could not identify a tag across calls. Existing
name/path/count, prefix, hierarchy and `/tags/tree` behavior remain intact.

Scratch Rust fixtures cover nested counts, case-insensitive prefix filtering,
no-match behavior, limit/order and stable hierarchy identity. The opt-in hosted
transport proof compares generated and HTTP rows for a nested path, count,
case-insensitive prefix and limit using only the PID-owned scratch library.
No builds/tests, route removal or caller migration were performed here.

- 2026-09-29 — **P5c16 metadata read consumers.** Imprint bridge list/detail now
  uses the manuscript list/get and app get-content verbs, composing metadata
  and source for word count and artifact preview while retaining absent dates
  and linked imbib IDs. Implore bridge list/detail maps `FigureRecord` into its
  public result, leaving HTTP-absent dataset name/format and null timestamps
  absent; empty tags match the route's omission. Impart bridge now maps paged
  conversations and detailed messages/statistics, retaining count, total,
  offset, limit and filter query. Counsel's existing figure/conversation list
  residue reads now use those generated result mappings. ArtifactResolver reads
  document artifacts through ImprintBridge and retains metadata absence. The
  current Counsel registry has no figure/conversation detail tool cases, so
  this package adds no new agent tools. Route arms, binary export, writes and
  imbib remain for their separate packages. Focused DTO decoding and canonical
  transport fixtures were added; static review only, root verification pending.

- 2026-09-29 — **P5c22 imprint domain-route retirement.** Removed only the
  public `GET /api/documents`, `GET /api/documents/{id}`, and comment
  list/create/update/delete/accept/reject registrations. P5c16 moved the
  production document list/detail readers, including impart's ArtifactResolver,
  to generated manuscript/content verbs; the comments caller audit found no
  production Swift, CLI or scenario consumer. The hosted proof now expects
  those old URLs to return 404 and exercises the same seeded reads, threaded
  comments and suggestion effects through generated verbs. The earlier P5c7
  and P5c10 entries record route parity before retirement, not current HTTP
  availability. Private comment handlers remain reachable from native verb
  callbacks. The manual `apps/imprint/test-imprint-api.sh` harness now uses the
  generated document create/list/detail contracts, keeps checks for distinct
  platform routes, and requires explicit isolated-host opt-in plus the
  loopback bearer. It had no comment-route requests to migrate. Queued document
  edits, metadata, caret citation, status/logs, compile, and other approved
  platform routes remain registered.
- 2026-09-29 — **P5c6 verified.** Root passed 1,053 Rust tests (zero failures,
  three ignored), every quick gate, and full supported arm64 builds of
  ImbibCore, store-ffi, impel-tools and imbib-verbs-ffi. Final linked native
  proof passed one XCTest and 13 shared transport calls, including RIS parity
  against the retained route; SQLite symbol checks passed and owned PID 77670
  exited. Evidence: `/tmp/impress-p5b-transport-m3ixws5a/output/` and
  `/tmp/impress-p5c6-final-{tests,gates,frameworks,native-proof}.log`.
  Tables and reference pages were regenerated. Root corrected the seeded
  bibliography fixture, a module-qualified test helper and converter lint
  findings before these runs. No user store or running app was touched.

- 2026-09-29 — **P5c7 verified.** Root passed 132 Rust tests (zero failures,
  three ignored), all quick gates and full supported arm64 builds of store-ffi,
  impel-tools and imprint-verbs-ffi, alongside the final RIS archives.
  The isolated native run passed both XCTest cases and 14 shared transport
  calls, including threaded suggestion metadata/range parity and invalid-parent
  and unsupported-status refusals. SQLite checks passed; owned PID 21487 exited.
  Evidence: `/tmp/impress-p5b-transport-0kkhokqi/output/` and
  `/tmp/impress-p5c7-{final-tests,gates,final-frameworks,native-proof-final}.log`.
  The first native run caught an old snapshot taken before two successful
  thread writes; the final test snapshots immediately before the refusal and
  still requires equality of every stored comment afterward. Generated project
  identifier/path churn was discarded. No real store or user app was touched.

## P5c17 — ImpressKit imbib read and RIS consumers (2026-09-29)

Migrated `ImbibBridge.searchLibrary` to the generated publication search verb
and added optional offset plus the finalized local read/collection/library/tag/
flag/date filters. The bridge hydrates each summary through exact publication
detail and BibTeX export verbs, retaining its existing `[ImbibPaper]` result
shape. `getPaper(citeKey:)` now uses exact `imbib-search-service_find-by-cite-key`
followed by the same hydration path, so misses remain `nil` without fuzzy
search. Added `exportRIS(citeKeys:)` over the generated RIS export verb. The
transport fixtures verify filter wire names, exact lookup, summary/detail field
mapping, result ordering under concurrent hydration, and RIS forwarding. HTTP
routes and other callers remain in place until hosted parity and root
verification.

- 2026-09-29 — **P5c18 implore figure export consumer.** The ImpressKit bridge
  now calls `implore-service_export-figure-data` for image bytes and metadata
  while keeping `exportFigure(id:format:) -> Data`; the richer method retains
  renderer path, SHA-256, MIME type and byte count. The previous implementation
  returned the HTTP route's JSON envelope as `Data`, despite the method's image
  export contract. A repository-wide Swift caller audit found no consumers, so
  the canonical result now returns the rendered bytes. Create/update/delete
  routes also have no Swift callers; leave them without parallel bridge methods
  and consider them eligible for retirement after their native/HTTP contract
  proof. Counsel has only a figure-list tool, owned by the metadata consumer
  package. Added mocked generated-verb transport and DTO fixtures. Static
  review only; root verification pending.

## P5c23 — retire migrated figure and conversation reads (2026-09-29)

Caller audit found Counsel's figure-list and conversation-list cases now use
the generated bridge methods introduced in P5c16; no application caller remains
for the former HTTP figure list/detail/export/create/update/delete routes or
conversation list/detail routes. Removed those router registrations and API
info entries while retaining implore's private figure handlers reachable from
its native callback switch. Raw RG/plot viewer routes and all impart queued
conversation writes remain registered. Native proof fixtures now expect 404
from the retired routes and still check seeded generated list/detail/export,
mutation and conversation results. Before retirement, the hosted figure proof
compared generated list/detail fields and export bytes with the old routes and
checked shared-artifact update/delete behavior; the conversation proof compared
page/archived results plus detail messages and statistics. Those historical
parity checks remain recorded here alongside the P5c8/P5c16 entries. No
builds/tests were run; root owns verification.
## P5c20 — imbib container consumers (2026-09-29)

Caller inventory found `ImprintIntegrationService.listDestinations()` as the
only cross-app consumer of library/collection listing and its existing
`createLibrary` call already uses `imbib-library-service_create-library`.
Migrated list-library reads to `list-libraries` and all-library collection
reads to the generated per-library `list-collections`, composing results in
the same library then collection order as the retained route and preserving
the bridge's DTO shape and library names. No cross-app callers currently use
collection creation/membership/member reads, tag read/create, or library and
collection deletion; no unused bridge methods were added. Counsel's direct
store and event paths are outside this caller inventory. Static diff review
only; root owns build and test verification.

- 2026-09-29 — **P5c21 imbib external search/import/resolve callers.** The
  shared `ImbibBridge` now uses generated `search-sources`,
  `import-identifiers`, and `resolve-citation` verbs for the existing imprint
  citation picker, identifier importer and structured `CitationClient` flow.
  It preserves source/limit, library/collection and PDF defaults, per-identifier
  added/duplicate/failure outcomes, ranked candidate order/confidence, and open
  paper/candidate dictionaries alongside the existing typed Swift convenience
  models. Audited `apps/imprint/macOS/Services/ImbibIntegrationService.swift`
  and `CitationClient.swift`; no ArtifactResolver/Counsel external-search,
  identifier-import or citation-resolve caller exists. Counsel's separate
  artifact capture route is unrelated and remains out of scope. The HTTP
  `resolve-citation` free-text/BibTeX branches likewise have no cross-app
  caller; no overload was added. Internal imbib route/MCP and smart-search
  behavior remains unchanged. Root verification pending.
