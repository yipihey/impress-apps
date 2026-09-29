# Plan: the self-reflective layer — declared effects, the verb call log, workflows, scenarios and registries

**Status:** PROPOSED 2026-09-26 — an evaluation and a plan, no production code. Measured on a
worktree of main at 60833ea1 (P0, G0, G1, B1, B3 merged), with the in-flight P1 (`claude/pipeline-p1-descriptor`
at bdddeb14) and P4 (`claude/pipeline-p4-jobs` at 87f4b9c4) branches read for the shapes they add;
every number is from code, with the file:line or the command beside it.
**Decision record:** [ADR-0036-self-reflective-layer.md](ADR-0036-self-reflective-layer.md).
**Builds on:** [ADR-0034](ADR-0034-verb-descriptor-pipeline-and-transport.md) / [plan-verb-pipeline-and-transport.md](plan-verb-pipeline-and-transport.md)
(the one descriptor, the one pipeline, jobs, transport) and [ADR-0035](ADR-0035-generated-verb-surfaces-and-docs.md) /
[plan-auto-gui-and-self-docs.md](plan-auto-gui-and-self-docs.md) (examples as tests, the generated form,
the census). Nothing here designs a second descriptor or a second pipeline: effects are fields on P1's
`VerbDescriptor`, the call log is P2's audit layer, and § Hooks says exactly what this plan needs from each.
**Order:** E (effects) → L (call log) → S (scenarios) → W (workflows); R (registries) runs beside them and
needs the Mac. E1 can start on P1's branch the day it merges; L needs P2; S needs P2 and the examples
of G3; W needs P4's jobs and L.
**Ids:** `EF` (effects), `CL` (call log), `WF` (workflows), `SC` (scenarios), `RG` (registries).

## Goal (Tom)

Make the environment able to say what each action touches, what happened and why, what will happen,
and whether it is still right — by turning five things still written as code (a verb's effects, the
record of a call, a background service, a Tier B test, a setting or a chord) into declared or stored
documents that pure Rust interprets and anyone can test headlessly, the way ADR-0033 did for GUIs.

## What "self-reflective" means (testable)

1. **Every verb says what it touches.** Every `#[impress_method]` in the linked inventory carries an
   effect set — the record kinds it reads, the kinds it writes, and whether it reaches outside the
   process — and a test that runs the verb's examples under a store spy fails on any kind the verb
   touched but did not declare. Today: nothing is declared; the static census (table EF-1) names kinds
   on the call path of 241 of 433 verbs and can say nothing certain about the rest.
2. **A verb source refreshes when what it reads changes.** A surface `verb` source re-runs when a write
   names a kind in the verb's declared reads (review finding RS-S2, narrowed in wave 7, closed here).
   Today: `runtime.rs:960-966` — "what a verb reads is not declared anywhere".
3. **Every mutating call is on the record, joined to its operations.** A call record with caller, trace,
   argument summary, outcome, duration and the observed effect set; every `core/operation` row written
   during the call carries the call's id as its `batch_id`; "why did this item change" is one query.
   Today: `batch_id` is set only by the batch APIs and multi-mutation updates, never from a verb
   (table CL-2); the one audit row (`tool-invocation@1.0.0`) links to nothing it wrote.
4. **A background service is a stored document with a trigger.** A workflow is validated, dry-run and
   run by a pure planner; the 90-second startup rule is the runtime's `start_delay`, not a Swift
   convention. Today: 31 Swift services, 20 gated, 11 not, 3 of those mutating the store (table WF-1);
   the Rust daemon has no schedule trigger (table WF-2).
5. **A test is data.** A scenario — seed, calls and human events, expectations — runs headlessly against
   a scratch store (Tier A) or a running app (Tier B) from the same document, and a recorded session
   becomes one. Today: 79 Tier A and 25 Tier B entries, all Rust closures; the runner is copied three
   times (table SC-1).
6. **A setting or a chord is declared once.** Rust owns the registry; the settings UI, CLI/MCP access
   and the docs are projections; a test proves every GUI action has a chord or a palette entry, and no
   two chords collide in one context. Today: tables RG-S and RG-K.
7. **It fails loudly.** An undeclared effect fails CI; a call the log could not write is counted and
   shown, never silently dropped; a workflow whose verb is gone is refused by name at validation and
   at run; a scenario whose expectation is unmet names the step and the path.
8. **Nothing is measured twice.** The effect set is the one place a verb's footprint is described; the
   spy, the invalidation, the conflict check, the impact analysis and the safety consistency test all
   read it. The call log is the one record of a call; the span (ADR-0035 D5) carries timing and the
   log carries provenance, and the two share the trace id.

## Measurements

### How

The verb inventory was read from source with the same strict grep G0 pins
(`grep -rhE '^\s*#\[impress_method' crates/*-service/src | wc -l` = **433**; `docs/verb-coverage.md`
says the same for the linked `full` inventory). Effects were measured by a throwaway static walker
(`effects_census.py`, not committed — § Table EF-1 says why): it finds each verb's default
implementation in the `impl <Trait> for <Impl>` block, then follows every call it can resolve by name
into workspace crates (the `*-service-http` adapters, clients and binaries excluded), to three hops,
and collects the canonical schema refs (constants and literals from `schema-refs.json`) named on that
path, the store-API markers (`query`/`count`/`get_*` vs `insert`/`update`/`delete`/`apply_operation`/
`update_with_undo`/…) and the reach markers (`reqwest`, `BackendSlot`, `std::fs`, `Command::new`,
reMarkable). The result is joined to P1's `docs/verb-safety.md` (433 = 433, no unmatched). The
operation log, the background services, the catalogues, the settings keys and the chords were each
measured by a read-only subagent over this worktree with the commands recorded in its section, and
every headline number was re-run by the author before use (the session log lists the checks).

### Re-verified starting facts

| Fact in the brief | Measured 2026-09-26 on 60833ea1 | Where |
|---|---|---|
| Descriptors carry name, description, input_schema, handler; 467 `#[impress_method]`s in 20 crates | On main, yes. On P1 (bdddeb14) `VerbDescriptor` carries `name, service, method, description, input_schema, output_schema, safety {class, idempotent}, since, deprecated, aliases, examples, strict, source, handler` and `McpToolDescriptor`/`CliSubcommand` are projections with a `verb` pointer. **433** verbs, 38 services, 16 crates; 467 is a loose grep | `crates/impress-service-core/src/descriptor.rs` (P1 branch); `docs/verb-coverage.md` |
| RS-S2 open: a `verb` source declares nothing it reads | Confirmed: `SurfaceRuntime::query_refs` collects refs from `Source::Query` only; `invalidate_sources` leaves `verb` and `value` sources alone | `crates/impress-surface-service/src/runtime.rs:948-966` |
| The store keeps an operation log with intent, batch_id, author, retention, time travel | Confirmed, with one correction: there is **no `operations` table** — an operation is an `items` row with `schema_ref = 'core/operation'` and `op_target_id` set (`sqlite_store.rs:2221-2244`); the join index is `idx_items_op_target (op_target_id, logical_clock)` and `idx_items_batch (batch_id)` (`:866-867`) | table CL-1 |
| `batch_id` may be the natural join key | It is the only candidate: set today only by `apply_operation_batch`/`apply_operations_if_clock` (fresh Uuid), by `update`/`update_with_undo` when one call carries > 1 mutation, `undo_batch` and `memory_ops.rs:635`; ~170 call sites pass `None`. Nothing sets it from a verb | table CL-2 |
| Wave 7 results carry ok/code/message, wire_version 1, actor | Confirmed (51 layout/surface verbs); the P2 envelope layer makes it universal (D-G6 approved) | `plan-auto-gui-and-self-docs.md` R-2 |
| Action vocabulary and reducer in `impress-surface`; runtime in `impress-surface-service` | Confirmed: `Action::{Set, Call{each}, Publish, Emit{each}, Open, Refresh}`, `Source::{Value, Verb, Query}`, `EventKind::{Change, Click, Select, Submit}` | `crates/impress-surface/src/spec.rs:88,272,366` |
| Tier A/B catalogues exist; Tier B entries hand-coded | **3 catalogues, 79 Tier A, 25 Tier B**, every entry a Rust closure; no imbib/impel/implore/impart catalogue | table SC-1 |
| Swift: 86 UserDefaults keys, 85 @AppStorage keys | table RG-S | |
| 81 Swift files declare `keyboardShortcut` | table RG-K | |
| 39 Swift files reference the startup gate or scheduled runs | **Does not reproduce as one pattern**: `performAutomatic` 9 files (6 non-test), `StartupGate` 19 (11), `startupGrace|startupDelay` 21 (12); the union is 27 non-test files, 38 with `seconds(90)`/`= 90` lines (which include a rotation angle and a `threeMonths = 90`). The count that matters is **31 background services** (table WF-1) | `rg -l` over `apps packages`, per pattern |
| impel has task records and a task daemon | Confirmed: `task@1.0.0`, five states, `SchedulerConfig { start_delay: 90 s, poll_interval: 5 s }`, retry 45 s·3ⁿ; triggers are store-change only (three hard-coded spawn rules), **no schedule trigger** | table WF-2 |
| AI preferences are the precedent for a Rust-owned file | Confirmed: `PreferencesStore::open(workspace).load()/save()` over `<workspace>/ai/preferences.json` with an `fs_lock`; Swift reads it through `SharedAiRegistry::open(workspace_path)` (`impress-store-ffi/src/ai_registry.rs:845`) | `crates/impress-ai/src/preferences.rs:24-27,161-217` |

### Table EF-1 — effects, as far as source can say (static, ≤ 3 hops)

| A4 class (P1 `docs/verb-safety.md`) | ≥ 1 kind named on the call path | Store markers, no kind resolved ("dynamic") | Reach markers only | Nothing found | Total |
|---|---:|---:|---:|---:|---:|
| `read_only` | 104 | 34 | 3 | 31 | 172 |
| `mutating` | 90 | 31 | 0 | 5 | 126 |
| `destructive` | 24 | 7 | 1 | 0 | 32 |
| `external` | 23 | 4 | 1 | 75 | 103 |
| **Total** | **241** | **76** | **5** | **111** | **433** |

Per service (verbs / with a kind / kinds named): `collection-service` 12/12 (10 kinds), `docs-import`
10/10, `imbib-annotations` 9/9, `imbib-app` 17/**0** (every verb is an HTTP backend call),
`imbib-artifacts` 9/5, `imbib-backup` 6/0 (files), `imbib-eink` 22/21, `imbib-library` 44/38,
`imbib-manuscripts` 7/0 (HTTP), `imbib-scix` 7/6, `imbib-search` 10/10, `imbib-tags` 10/10,
`imbib-text` 5/0 (pure), `imbib-undo` 3/3, `impart` 10/0 (HTTP), `impel` 6/6, `implore` 20/0 (HTTP),
`impress-ai` 16/0 (the walker did not find the impl body; by reading: `conversation@1.0.0`,
`chat-message`, `task@1.0.0`, the preferences file, the provider), `impress-bridges` 18/10,
`impress-surface` 15/11, `imprint-app` 15/0 (HTTP), `imprint-manuscript` 17/3, `imprint-project`
30/28, `imprint-text` 5/0 (pure), `imprint-throughline` 9/7, `layout` 36/14, `manuscript-collab` 4/4,
`memory` 7/7, `parsers` 6/0 (pure), `smart-search` 10/0 (index files), `source` 9/9, `store-query`
4/2, `surface-demo` 2/0, `triage` 5/5, `vw-diagnostic` 15/8. Reach markers: fs 142, network 37,
subprocess 25, device 24. Kinds named by any verb: **66 of the 80** canonical refs; never named on a
verb path: `annotation`, `dataset`, `git-project`, `imbib/activity-record`, `imbib/assignment`,
`imbib/recommendation-profile`, `mail-account`, `mail-folder`, `manuscript-submission`, `review`,
`revision-note`, `tool-invocation@1.0.0`, `veusz-plot`, `vw/knowledge-pack@1.0.0` (Swift-only writers,
or written by daemons rather than verbs). Appendix A has the row for every verb.

What the table proves, and what it cannot:

- **The kind a verb touches is often not in its code.** `triage-service_set-starred` is
  `store.update(parse_id(id)?, vec![FieldMutation::SetStarred(starred)])` (`impress-core/src/triage_ops.rs:41-43`):
  it writes *the kind of whatever `id` names*. 76 verbs are like this (store markers, no kind): their
  effect is **dynamic** — a function of an argument — and no static declaration can be a list of
  literals. This is the first design decision (§ Effects: `writes: [target(id)]`).
- **Name resolution over- and under-approximates.** At one hop the walker finds a kind for 113
  verbs; at three hops 241, but `collection-service_delete` then "reads" six kinds because
  `collection_ops` shares helpers with the sidebar, and `triage-service` "touches"
  `impress/ui/surface@1.0.0` because `.update(` also resolves to the surface store. A static tool
  can seed the declarations (appendix A is that seed) and cannot verify them. **The measurement
  that counts is the spy** (§ Effects), which is why the walker is not committed.
- **83 verbs (`needs_app`) and most `external` verbs cannot be spied in Tier A** — their default
  implementation refuses or forwards. Their effects are declared from the app-side implementation
  and verified where the call actually runs: by the call log's observed effect set (§ Call log),
  which is the same check made at run time on every path.

### Table CL-1 — the operation log, as it is

| Question | Answer | Evidence |
|---|---|---|
| Where operations live | `items` rows, `schema_ref = 'core/operation'`, `op_target_id` NOT NULL FK → `items` **ON DELETE CASCADE**; payload `{target_id, intent, reason?, op_type, op_data, prev?}`; `author`, `author_kind ∈ {human, agent, system}`, `logical_clock` (HLC), `origin`, `batch_id`, `retention ∈ {durable, compactable, ephemeral}`; `produced_by` always NULL | `sqlite_store.rs:799-824,2221-2244`; `operation.rs:113-123,348-372` |
| Indexes for a join | `idx_items_op_target (op_target_id, logical_clock)`, `idx_items_batch (batch_id) WHERE batch_id IS NOT NULL`, `idx_items_schema_created (schema_ref, created)`; **none on `author`** | `sqlite_store.rs:863-899` |
| What writes an operation row | `update` (one Compactable Routine op per non-noop mutation, `:5111`), `update_with_undo` (Durable, `:4218`), `update_with_retention`, the four `apply_operation*` (`:1994,2016,2069,2294`), `undo_*` | table below |
| What does **not** | `insert`/`insert_batch` (`:5041,5059`), `delete` (`:5142` — writes a tombstone and **deletes the target's existing ops**), `set_origin`, `set_canonical_id`, `record_recent`, `sweep_terminal_tasks`, the migrations, sync apply (op rows never sync: `sync.rs:347`) | `sqlite_store.rs` |
| Transactions | `apply_operation` runs in autocommit — op row, clock and field UPDATE are separate commits; only the `_if_clock` and `_batch` variants are one `BEGIN IMMEDIATE` | `:1994-2014` vs `:2016,2069,2294` |
| Prod callers of `apply_operation*` | impress-core 13, impel-core 4, impress-layout-service 5, impress-surface-service 2, impress-store-ffi 1, imbib-core 1 (`store_api.rs:440`), impel-service 1, impel-taskd 3; `update_with_undo` imbib-core 12 | `grep -rn` split prod/test |
| Retention and compaction | `compact_operations(window_days)` folds compactable/ephemeral ops older than the window into a durable `custom:snapshot` op per target and deletes the range; `compact_undo_history(keep)`; `demote_routine_operations` (one-time); run **only by the impress-ai-http daemon**: demote every 300 s, compaction every 24 h with `IMPRESS_COMPACT_WINDOW_DAYS` (default 30), an op-rate warning at `IMPRESS_OPS_RATE_BUDGET` (default 100 k/day) | `sqlite_store.rs:4836-4999,5765,488-516`; `impress-ai-http/src/main.rs:89,130,165-217,360` |
| The 23 M-row backlog | Commit `0238eb0a` (2026-08-06): store 16.8 GB (13.5 GB WAL), **23.0 M `core/operation` rows** against ~50 MB of content, every one a durable `system:local` routine op minted by mechanical re-upserts of unchanged fields; one dangling `op_target_id` aborted every compaction. Fixes: `filter_noop_mutations`, `update` mints Compactable, demotion, the orphan sweep, WAL checkpoint; `79868ede` made `citation-usage` ops Ephemeral and added the rate telemetry. Recovery: 19,961,462 ops compacted, 2.5 GB | `git show 0238eb0a`; `sqlite_store.rs:5115-5118` |
| Time travel | `effective_state(id, StateAsOf::{Current, LogicalClock, Timestamp})` replays ops by `(logical_clock, created, id)` from the newest snapshot; `EffectiveState` holds tags, flag, read, starred, priority, visibility, payload, parent; `patch_payload` and references are **not** replayed | `sqlite_store.rs:3139,3213,3563`; `operation.rs:128-148` |
| The one per-call audit row today | `tool-invocation@1.0.0` (`impress-ai/src/store.rs:1247`): `tool, provider, state, arguments (full values), result?, result_summary?, error?, started_at, finished_at (both = now at record time), duration_ms?`; parent/produced_by = run; **links to none of the ops it caused** | `impress-core/src/schemas/ai.rs:76-99` |
| Trace ids | None in the store or the verb path. `correlation_id` exists on impel events (own `events` table) and impart provenance; `items.batch_id` and `items.produced_by` are the only columns that could carry one | `grep -rn 'trace_id\|traceparent\|correlation'` |

### Table CL-2 — `batch_id` today: who sets it

| Site | Value | Meaning |
|---|---|---|
| `apply_operation_batch` (`:2306`), `apply_operations_if_clock` (`:2105`) | fresh `Uuid` per call | "these ops came from one store call" |
| `update`, `update_with_undo`, `update_with_retention` (`:5120,4224,5017`) | fresh `Uuid` **only when > 1 non-noop mutation** | same |
| `undo_batch` (`:2542`), `memory_ops.rs:635` | the batch undone / a sweep id | |
| ~170 `batch_id: None` literals across 18 crates (63 in impress-core) | NULL | nothing |

No caller passes an externally meaningful id. A verb that makes three store calls leaves three
unrelated (or NULL) batch ids. The join upward does not exist; the column and its index do.

### Table WF-1 — background, scheduled and triggered work in Swift (31 services)

Gate: Y = 90 s, Y120 = 120 s, N = none. Rust: writes through UniFFI into the shared store, or pure Swift.

| # | Service | App | Trigger | Interval | Gate | Mutates | Rust |
|---|---|---|---|---|---|---|---|
| 1 | `FeedScheduler` (`PMC/Inbox/FeedScheduler.swift:194-207`, started by `InboxCoordinator.start` `:57,82-87`) | imbib | interval | 60 s check, per-feed due | Y (+ `BackgroundOperationQueue` grace) | publications, smart-search `last_executed` via `performAutomatic` | UniFFI |
| 2 | `InboxScheduler` (`Inbox/InboxScheduler.swift:190-201`) | imbib | interval | 60 s | Y | as 1 | deprecated, not started (`InboxCoordinator.swift:40`) |
| 3 | `GroupFeedRefreshService` (`:177,230`) | imbib | user event, 2 s stagger | — | via queue | publications (`importBibTeX` `:419`) | UniFFI |
| 4 | **`RetentionCleanupService`** (`Inbox/RetentionCleanupService.swift:54-97`, from `InboxCoordinator.swift:97`) | imbib | startup, once per process | once | Y (`EInkStartupGate`) | deletes inbox, exploration and feed publications (`store.deleteItem`) | UniFFI |
| 5 | Enrichment `BackgroundScheduler` (`Enrichment/BackgroundScheduler.swift:215-237`) | imbib | interval | 3600 s | Y120 | publication fields (doi, arxiv_id, citation_count, abstract) | UniFFI; stands down when impel is the authority (`EnrichmentCoordinator.swift:118-127`) |
| 6 | Watched folders `FolderWatchService` (`Chassis/WatchedFolders/FolderWatchService.swift:331-361`) + ingest coordinator | imbib | FSEvents + startup gather | event | Y (`FolderWatchStartupGate`) | publications, `watched-folder@1.0.0` rows | UniFFI |
| 7 | Exploration cleanup, macOS (`apps/imbib/imbib/imbib/imbibApp.swift:580,620-631` → `Library/LibraryManager.swift:485-515`) | imbib | startup | once | **N on macOS** (Y on iOS `imbib-iOS/imbibApp.swift:164,175`) | deletes exploration collections and their publications | UniFFI; **duplicates #4's `cleanupExplorations`** |
| 8 | `EInkSyncCoordinator` (`EInk/EInkSyncCoordinator.swift:167-224`) | imbib | notification, connection events | event | Y | `imbib/eink-mirror`, `imbib/eink-device` | UniFFI (planner/executor in `imbib-core/src/eink`) |
| 9 | `EInkSourceFetcher` (`:96-140`) | imbib | store change + launch sweep | event | Y | PDF fetch, `einkNoteSourceError` | UniFFI |
| 10 | `EInkOCRPass` (`:53-105`) | imbib | startup sweep | once | Y | `einkCompleteOCR` | UniFFI (Vision) |
| 11 | `EInkConnectionMonitor` (`:65-229`) | imbib | interval | 25 s → 300 s | N (reads) | none | reads |
| 12 | `SidebarSnapshotMaintainer` (`Persistence/…:54-93`) | imbib | store change | 2 s throttle | N | in-memory | reads |
| 13 | `StoreMutationObserver` (`Persistence/StoreMutationObserver.swift:35-77`) | imbib | Darwin `com.impress.suite.store.mutated` | 0.75 s coalesce | Y (first refresh) | `dataVersion` | pure |
| 14 | `CloudSyncEngine` (`Sync/CloudSyncEngine.swift:436-475`) | imbib | startup, store events, timer | 60 s | Y120 | sync metadata, pulled rows | UniFFI; flagged off |
| 15 | PDF health check (`imbibApp.swift:583-587`) | imbib | startup | once | Y | reads | reads |
| 16 | Spotlight sync (`imbibApp.swift:597-620`; imprint `ImprintApp.swift:232`; impart `:62`; implore `:92`) | 4 apps | startup + store events | event | Y | Spotlight index | reads |
| 17 | `EmbeddingService` observers (`Recommendation/EmbeddingService.swift:724-737`) | imbib | `.rustStoreDidMutate` | event | N | in-memory stale flag | pure |
| 18 | `LibraryFilesMigrationRunner` (`Files/…:36-50`) | imbib | startup | once | N | files | pure |
| 19 | Heartbeat loops (`imbibApp.swift:676`, `ImploreApp.swift:84`, `ImpressApp.swift:57`, `ImpelApp.swift:357`) | all | interval | 25 s | N | none | pure |
| 20 | `ImpartStoreBackfill` (`MessageManagerCore/…/ImpartStoreBackfill.swift:56-83`) | impart | startup, resumable | once | Y | mail records from Core Data | UniFFI |
| 21 | `StoreMirrorKernel` buffer (`packages/ImpressStoreKit/…:303-324`) | impart | write-behind | one flush | Y | mail records | UniFFI |
| 22 | `GitSyncCoordinator` (`packages/ImpressGit/…:33,199-225`) | imprint | interval | per project | Y | git pull | pure |
| 23 | `EMLFolderWatcher` (`apps/impel/Packages/CounselEngine/…:40-60`) | impel | DispatchSource + poll | 30 s | **N** | GRDB message store | pure |
| 24 | `StandingOrderScheduler` (`…/StandingOrders/StandingOrderScheduler.swift:21-30`) | impel | interval | 60 s | **N** | counsel loop, GRDB | pure; **no caller found** |
| 25 | `JournalPipeline` (`…/CounselEngine/JournalPipeline.swift:100-162`) | impel | Darwin `manuscriptStatusChanged` | event | 60 s | manuscript snapshots | mixed |
| 26 | impel status poll (`ImpelApp.swift:423-431`, `ImpelCore.swift:361-366`) | impel | interval | 2 s | N | UI state | pure |
| 27 | `AIAvailability` (`packages/ImpressAI/…:165-171`) | all | interval | 60 s | N | none | reads |
| 28 | `SyncStatusModel` (`Sync/…:211-216`) | imbib | interval while pane open | 5 s | N | none | reads |
| 29 | `CollaborationService` (`apps/imprint/macOS/Services/…:186`) | imprint | timer | 5 s | N | presence | pure |
| 30 | `BackgroundOperationQueue` (`packages/ImpressStoreKit/…:172-225`) | shared | queue; refuses work in grace | — | Y (`:182`) | what it wraps | infrastructure |
| 31 | Layout grace (`packages/ImpressLayout/…/LayoutTreeRuntime.swift:61`, `LayoutController.swift:385`) | shared | invalidation feed | — | Y | render guard | UniFFI |

Counts: 31 services; **20 gated** (≥ 60 s), **11 not**; ungated *and* mutating the store: **3**
(#7 exploration cleanup on macOS, #23, #24). `performAutomatic` wraps 5 (#1, #3, #6, #8, #11).
The 90-second rule is remembered per service in Swift; it has no single owner, and #7 shows what
that costs (a duplicate of #4 with the gate forgotten on one platform). On macOS
`InboxCoordinator.start` runs at t≈0 (`imbibApp.swift:538`) and relies on every inner gate; on iOS
the whole start is inside one 90 s block (`imbib-iOS/imbibApp.swift:164-171`).

### Table WF-2 — the Rust task model, and what a trigger can be today

| Piece | What exists | Evidence |
|---|---|---|
| Task record | `task@1.0.0`; states `pending/running/done/failed/cancelled` (+ `queued/completed` compat); transitions `pending → running \| cancelled`, `running → done \| failed \| cancelled \| pending`; `transition_op` is the one legal writer | `impress-core/src/task.rs:15-46,74-146,179` |
| Creation | a `SpawnRule` names a `trigger_schema()` and returns `TaskSpec`s; `create_task_dag_from` writes `pending` rows with `task_kind`, `DependsOn`/`OperatesOn` edges, `spawned_by` | `impel-core/src/task_spawn.rs:43-72,102,160` |
| Task kinds | `metadata-resolve`, `keyword-tag` (impel-enrichment), `throughline-sync` (impel-throughline), `impress.ai.respond`, `impress.ai.suggest-title` (impress-ai), `impress.memory.embed`/`.consolidate` (impel-memory, env-gated); registered in `impel-taskd/src/main.rs:825-948`. P4 adds jobs: a task row created `running` with `verb`, `args`, `result`, `cancel_requested`, `runner` (`impress-core/src/job.rs` on the P4 branch) and `task-event@1.0.0` (200-row ring per task) | |
| Scheduler | `SchedulerConfig { batch 8, start_delay 90 s, poll_interval 5 s, retry base 45 s }`; `run_once`: re-pend orphans → resume own `running` (unless behind a `review-request@1.0.0`) → `ready_tasks` (pending, deps done, past `next_attempt_at`, per-kind `readiness()` with a 60 s negative cache) → `acquire_task` (state, `assigned_to`, `attempts+1` in one transaction) → run under a 20-min timeout; retry `45 s·3ⁿ⁻¹` capped 30 min, else `failed` with Escalation | `impel-core/src/task_scheduler.rs:28-52,123-197,269-320`; `task_store.rs:136` |
| Daemon loop | every `--poll` s (5): `max_rowid()` moved? + drain `ItemEvent::Created` → page `items_arrived_after(bibliography-entry, cursor)` into `EnrichmentSpawnRule`; keyset scans of sections/throughlines into two more rules; `plan_memory_tasks` sweep; **hard-coded hourly** review expiry; then `scheduler.run_once()`. Cursors persisted (`impel-taskd.cursors.v1`). Started by launchd `com.impress.impel-taskd` or from the app sandbox (`ImpressModelWorkerController.swift:74`) | `impel-taskd/src/main.rs:87,351,965-1305,1362` |
| Trigger kinds today | **store change** (created via event bus + rowid cursor; modified via keyset scan) — three rules, all hand-written in `main.rs`; **schedule: none** (no cron, no `next_run`, no recurring record; the memory sweeps are "recurring sweeps with no trigger", `impel-memory/src/spawn.rs:13`); **job finished: none** (a task's `done` produces no event beyond `ItemEvent::OperationApplied`); **message arrived: none** in Rust (impel's `EMLFolderWatcher` is Swift) | |
| The store's own signals | in-process `subscribe_mutations` / `subscribe(query)` (`sqlite_store.rs:5356-5381`); cross-process a throttled payload-free Darwin note `com.impress.suite.store.mutated` (`:31,90-119`) and `PRAGMA data_version` polled every 250 ms by the FFI feed (`ui_feed.rs:42-45,101-223`) | |

What the workflow idea already has: a durable, retried, reviewable task with an executor registry,
a daemon with the 90-second `start_delay` built in, store-change detection with persisted cursors, and
(P4) a job handle with progress and cancel. What it lacks: a **trigger as data** (the three rules are
code), a **schedule** trigger, a **job-finished** trigger, a **step language** (each executor is
Rust), and any way for the apps to run the same thing when no daemon is present.

### Table SC-1 — the self-test catalogues

| Catalogue | Entry type | Tier A | Tier B | Runner | Report |
|---|---|---:|---:|---|---|
| imprint (`crates/imprint-selftest/src/{lib,report,service,tier_a,tier_b}.rs`) | `CapabilityResult {id, description, tier, pass, detail, duration_ms, skipped}` (`report.rs:22-35`, its own copy) | 25 | 8 | `check(id, desc, tier, \|\| async {…})` + `skipped()` (`lib.rs:34-68`); `skipped` sets `pass: true` | `SelfTestReport` without `ok` |
| layout (`crates/impress-layout-service/src/{selftest,tier_a,tier_b}.rs`) | shared `impress_service_core::report` | 39 | 14 (13 in `CATALOGUE` + `layout.restored`) | the same closure pattern, copied (`lib.rs:91-127`); `skipped` sets `pass: false` | `ok = failed == 0 && skipped == 0 && total > 0` |
| surface (`crates/impress-surface-service/src/{selftest,tier_a,tier_b}.rs`) | shared | 15 | 3 | copied again (`lib.rs:64-101`); one table-driven block (`tier_b.rs:168-211`) | shared |
| **Total** | | **79** | **25** | 3 copies of `check`/`skipped`, of `run_selftest`, of the Tier B HTTP client, of the base-URL rule, of the skip-all path | tier strings parsed three ways |

Every Tier B entry, classified (the full table with calls and assertions is in appendix B):
**(i) a pure sequence of calls and assertions: 20** (11 need a value captured from a previous
response; #18 and #20 need "wait for a log line"); **(ii) a human/GUI event: 1**
(`layout.outline_collection_row` — calls `outline_row_verbs_json` in-process to stand in for a
click, then asserts on rendering through `/api/logs`); **(iii) app state a verb could set: 1**
(`manuscripts.detail_and_history` — needs real manuscripts, skips if none); **(iv) platform: 3**
(`store.wal_health` reads another daemon's health; `layout.reading_pdf_pane` and `layout.reading_preset`
read the live store in-process for a paper with a PDF on disk). Tier A: 41 of 79 are pure verb
sequences today (imprint 15, layout 11, surface 15); 32 more fit with a seed-fixture step (5) or a
"read the persisted row" step (27); 6 do not fit (FFI-direct, blob store, typst package cache).
Already data: a human surface event is `impress_surface::Event {widget, kind, value}` dispatched by
`surface_dispatch` and recorded with its actor (`spec.rs:351-371`, `docs/agent-surfaces.md:233-237`);
a human layout gesture is a serde-tagged `impress_layout::Verb` applied by `SharedLayout.apply(verb_json,
actor)` (`impress-store-ffi/src/layout.rs:590-600`); the imbib golden corpus is JSON `scenarios[{name,
inputs}]` (`imbib-core/tests/golden_parity.rs:19-28`). No recorder, macro or session concept exists.
One constraint for Tier A as data: the generic `call_async(name, args)` (`service-core/src/call.rs:55-66`)
dispatches against the process-wide store, set once (`impress-store-service/src/store.rs:42-57`,
`IMPRESS_STORE_PATH`); Tier A entries inject a scratch store through `with_store`.

### Table RG-S — settings in Swift (production code, tests excluded)

Method: an extractor over the 1,738 `.swift` files under `apps/` and `packages/` (`.build`,
`DerivedData`, checkouts excluded) that strips comments, matches every `<receiver>.<get|set>(…
forKey: EXPR)` with balanced parentheses, keeps the call when the receiver is a `UserDefaults`
(`standard`, a suite, `forCurrentEnvironment`, `localStore`), routes `SyncedSettingsStore` receivers
to the iCloud-KVS column, reads `register(defaults:)` dictionaries, and resolves `EXPR` through
same-file constants, globally unique constants and a hand-built table for the parameterised stores
(`ReadingPositionStore`, `ListViewStateStore`, `WatchedFolderBookmarkStore`, `EInkSettingsMigration.legacyKeys`,
`SharedDefaults` …). A prefix key (`reading_position_<uuid>`) counts once. Cross-check:
`rg -n '(?i)(defaults|standard|suite|localStore)\??\.\w+\(.*forKey'` found 0 call sites the
extractor missed; `rg -o '@AppStorage\("([^"]+)"'` finds 83 distinct literal keys (the other 4 are
keys spelled through a constant).

| Unit | `UserDefaults` keys | `@AppStorage` keys | In both | Union |
|---|---:|---:|---:|---:|
| imbib (app) | 12 | 8 | 0 | 20 |
| imbib/PublicationManagerCore (linked by **all six apps**) | 88 | 26 | 6 | 108 |
| imprint | 18 | 33 | 4 | 47 |
| imprint/ImprintCore | 1 | 0 | 0 | 1 |
| impel | 7 | 10 | 0 | 17 |
| impel/CounselEngine | 3 | 0 | 0 | 3 |
| impart | 10 | 5 | 2 | 13 |
| impart/MessageManagerCore | 2 | 0 | 0 | 2 |
| implore | 1 | 5 | 0 | 6 |
| impress | 3 | 1 | 0 | 4 |
| ImpressAI | 7 | 0 | 0 | 7 |
| ImpressAutomation | 6 | 6 | 6 | 6 |
| ImpressGit | 1 | 3 | 0 | 4 |
| ImpressHelixCore | 3 | 0 | 0 | 3 |
| ImpressKit | 3 | 0 | 0 | 3 |
| ImpressProgress | 3 | 0 | 0 | 3 |
| ImpressSidebar | 9 | 0 | 0 | 9 |
| ImpressSpotlight | 1 | 0 | 0 | 1 |
| ImpressTheme | 0 | 1 | 0 | 1 |
| **Distinct across units** | **159** | **87** | **22** | **224** |

Plus a **third store**: iCloud KVS through `SyncedSettingsStore` (`PMC/Settings/SyncedSettingsStore.swift:13-71`),
**29 `sync.*` keys** (28 live; `sync.recommendation.engineType` is declared and never saved,
`RecommendationSettings.swift:280`), not in the 224. Call sites: 339 `UserDefaults` in production
(58 in tests), 112 KVS, 120 `@AppStorage` declarations. **No `@AppStorage` names a `store:`**, so every
one lives in the per-app standard domain — and because PMC is linked by all six apps, each of its 108
keys exists six times, once per app domain.

| Finding | Evidence |
|---|---|
| The brief's 86 / 85 (overlapping) is a literal count; resolved through constants it is 159 / 87, 22 overlapping, 224 distinct, plus 29 KVS | above |
| 24 keys are read by more than one unit, each copy in its own domain: `httpAutomationEnabled`/`Port` in five units (each `register(defaults:)` with its own port, `ImpelApp.swift:26`, `ImprintApp.swift:366`, `ImpressApp.swift:28`, `ImpartApp.swift:27`), and `SimpleAutomationSettingsView` declares `@AppStorage(… port) = 23100` (`AutomationSettingsView.swift:141`) — a port literal outside `SiblingApp.descriptors`; `appearanceMode` in five units; `NSQuitAlwaysKeepsWindows` in three; `editorAppearance` in PMC and imprint; 15 imbib↔PMC and 3 impel↔CounselEngine pairs | |
| Four app-group suites are in use: `QG3MEYVHMS.com.impress.suite` (`SharedDefaults.suite`, git projects, impel/impart widgets, share extensions), `group.com.imbib.app` (imbib widgets, Safari), `QG3MEYVHMS.com.impress.imbib` (`ShareExtensionService.swift:35`), `QG3MEYVHMS.com.impress.shared` (a container) | |
| Helix/modal editing is stored under three unrelated keys: `modalEditing.isEnabled` (`ModalEditingSettings.swift:39`), `helixModeEnabled` (`NotesTab.swift:341`), `imprint.helix.isEnabled` (`SourceEditorView.swift:37`) | |
| **Split brain in imbib import settings:** the settings UI writes `@AppStorage("autoGenerateCiteKeys")`, `"defaultEntryType"`, `"exportPreserveRawBibTeX"` (`SettingsView.swift:1440-1442`, `IOSImportExportSettingsView.swift:16-18`) while `ImportExportSettingsStore` reads the KVS keys `sync.import.*`/`sync.export.*` (`:106-108`); no production code reads the plain keys (only `FirstRunManager.swift:149` removes them); `SyncedSettingsStore.migrateFromUserDefaults` (`:422`) has no callers | |
| Group keys with a missing half: `widget.impel.*`, `widget.impart.*`, `widget.suite.<id>.running` are read (`CounselActivityWidget.swift:48-51`, `SuiteStatusWidget.swift:51`, `UnreadMessagesWidget.swift:48-51`) and written by nothing; `share.imprint.pending*`/`share.impart.pending*` are written (`ShareViewController.swift:61-72`, `:70-90`) and read by nothing | |
| Legacy keys still live: `remarkable.*` still declared as `@AppStorage` (`RemarkableSettingsStore.swift:35-79`) while `EInkSettingsMigration` deletes the same names (`:38-52`); `AITaskCategoryStorage` still writes `impressai.taskCategoryAssignments` (`AITaskCategoryManager.swift:237-270`, tests only) | |
| The precedent works as described: `PreferencesStore` re-parses on mtime/length change, writes temp + `fsync` + rename under a flock, refuses a newer or corrupt file, has `changed_since(ms)`, and a one-time `import_legacy_swift`; Swift never opens the JSON — `RustAIBridge` calls `SharedAiRegistry.open(workspacePath: SharedWorkspace.workspaceDirectory)` and changes propagate in-process by `Notification.impressAIPreferencesDidChange`; **`preferencesChanged(since:)` has no callers, so there is no cross-process watch** | `preferences.rs`; `RustAIBridge.swift:22,43`; `AIProviderManager.swift:199,508`; `AIPreferencesMigration.swift:33-107` |
| Existing tests freeze `@AppStorage` literals per pane by source scan (`ImprintSettingsPersistenceTests` 5, `Phase2SettingsPersistenceTests` 9, `ImpressThemeTests:44`, `KeyboardShortcutCatalogParityTests`); nothing enumerates keys across apps or checks overlap | |

### Table RG-K — keybindings in Swift

Method: `rg -l --type swift '\.keyboardShortcut\(' apps packages` = 79 files, 303 hits; minus 2 files
and 4 lines that match only in comments (`PaneLayoutCommandsTests.swift`, `ImprintIOSApp.swift:435`)
= **77 files, 299 call sites** (the brief's 81 is not reproduced by any counting rule; 80 counts a
markdown file, 90 counts every mention of the word). Each site was walked back ≤ 25 lines to its
`Button` label and the first call in its closure; handlers were resolved through their `handleKey`
helpers; the mapping gap was classified against the 419 distinct `#[impress_method]` names
(`rg -A4 '#\[impress_method' crates | rg -o 'fn \w+'`; 433 verbs, 14 names shared across services).

| App / package | Files | `.keyboardShortcut(` sites | `.keyboardGuarded` | `.onKeyPress` | Palette commands |
|---|---:|---:|---:|---:|---|
| imbib | 42 | 172 | 8 | 33 | 50 `CommandRegistry.register(…)`, 46 with a chord |
| imprint | 15 | 65 | 0 | 0 | 0 |
| impart | 9 | 25 | 0 | 0 | 0 |
| implore | 3 | 17 | 2 | 0 | 0 |
| impel | 2 | 8 | 2 | 0 | 0 |
| impress | 1 | 2 | 0 | 0 | 0 |
| ImpressGit / ImpressLogging | 4 / 1 | 9 / 1 | 0 | 0 | — |
| ImpressLayout / ImpressSurface / ImpressFTUI / ImpressCommandPalette / ImpressKeyboard | 0 | 0 | 1 / 1 / 0 / 0 / (def.) | 3 / 2 / 10 / 4 / 1 | — |
| **Total** | **77** | **299** | **14** | **53** | |

| Class of site | Sites | Meaning |
|---|---:|---|
| D — dialog, sheet, form keys (`.cancelAction`, `.defaultAction`, ⏎, Esc) | 117 | not commands |
| E — standard Cut/Copy/Paste/Select All | 16 | system |
| A — routed to a Rust verb today | 4 (≈ 12 chords per app after `ForEach`) | only `PaneLayoutChordRouter` → `LayoutController.apply(.setCollapsed / .applyLayout)` (`PaneLayoutCommands.swift:137,216-226`, `LayoutController.swift:846`); imbib's pre-chassis window hits Swift `PaneLayoutState` instead; **no chord goes through `ImpressVerbHost`** |
| B — a verb exists, not routed (name-level match) | ≈ 44 (imbib 26, imprint 17, implore 1) | Toggle Read → `set_read`, Dismiss → `dismiss_paper`, collections → `add_to_collection`/`remove_from_collection`, Delete → `delete_publications_undoable`, Import/Export → `import_bibtex`/`export_bibtex`, Mirror → `eink_mark`, annotate → `create_annotation`, Copy as Citation → `get_citation`, Undo History → `recent_undo_groups`; imprint Compile → `compile_manuscript`, Build → `project_build`, Insert Citation → `compose_citation`, Papers → `open_manuscript_papers`, Comment → `create_comment`, Headings → `compose_heading`, Commit → `project_checkin`, Export PDF → `export_document`; implore Export Figure → `export_figure` |
| C — Swift-only (window, selection, view mode, navigation) | ≈ 118 | no verb |

Of the 166 command-level sites, **2 % are verb-routed, 27 % have a verb they could route to, 71 % are
Swift-only.** Three chord lists exist for imbib alone — the menu (`imbibApp.swift`), `CommandRegistry`
(the live palette; `packages/ImpressCommandPalette` is **linked by no app** — `import
ImpressCommandPalette` appears only in its own tests — and has no registry type) and the Settings
table (`ShortcutCatalog.resolve(profile)` → `KeyboardShortcutsStore`, `KeyboardShortcutsSettings.swift:410`),
and they have drifted:

| Finding | Evidence |
|---|---|
| **imbib ⇧⌘F has three claimants on macOS**: Paper ▸ Share… (`imbibApp.swift:1300`), the hidden Filter button (`ContentView.swift:293`), the store-search command (`FindCoordinator.swift:114`, not mounted by imbib); the docs say "Focus search" (`keyboard-grammar.md:25`) and Share (`:96`) | the live collision is Share vs Filter |
| imbib ⌘S is registered twice for the same action (`imbibApp.swift:1106`, `ContentView.swift:287`) | |
| **The collision test scans `imbibApp.swift` only** (`PaneLayoutCommandsTests.swift:260`, a regex over one file); it cannot see `ContentView.swift`'s hidden buttons | |
| iOS and macOS disagree: ⌘5/⌘6 are BibTeX/Notes on iOS (`IOSContentView.swift:1113-1125`) and Notes/BibTeX on macOS (`imbibApp.swift:1152-1162`); ⇧⌘R is Refresh Metadata on iOS, Open References on macOS; **`CommandRegistry` still says ⌘5 BibTeX / ⌘6 Notes** while the menu and `keyboard-grammar.md:69-71` say the reverse — the parity test checks the Settings table, not the registry | |
| Console: impart and impress bind both ⌃⌘C (menu) and ⇧⌘C (the `Window` scene, `ImpartApp.swift:305,325`, `ImpressApp.swift:70,115`); imprint uses ⇧⌘C only (`ImprintApp.swift:980`) while the docs say ⌃⌘C "as in impress and impart" (`keyboard-grammar.md:110-113`); imbib removed the scene chord for this reason | |
| Rule-4 exposures (unverified live): Shift-only menu equivalents ⇧P/⇧N/⇧I/⇧B/⇧F (`imbibApp.swift:1496-1516`); `HelpBrowserView.swift:134` binds `"/"` with no modifiers and `:84` an unguarded `.onKeyPress("/")`; triage `.onKeyPress("s")`/`("*")` gated on `isInputOverlayActive` not `TextFieldFocusDetection` (`UnifiedPublicationListWrapper.swift:2114-2119`) | |
| `imbib/api/commands` (`HTTPAutomationRouter.swift:1766`) serves `KeyboardShortcutsSettings.defaults`, not `CommandRegistry`, so an agent's view of the palette is a fourth list | |
| **No Rust crate declares a GUI chord.** `implore-core/src/input.rs:517 default_shortcuts()` is a real key→command table that is dead (tests only, no export) and disagrees with Swift (⌘D SelectNone vs ⇧⌘A; binds unmodified R F O A G C M L); `impress-helix/src/keymap.rs` is the editor keytrie (exported), not app chords; `TriageKeyGrammar.swift:52-61` (j k n s e d o / h l) is the one shared single-key grammar and `ShortcutCatalogTests` pins it | |

Findings from the two tables:

- **RG-1** 224 distinct keys in three stores (standard, four group suites, KVS), PMC's 108 written
  into six domains, 24 keys read by more than one unit, none declared anywhere but at a call site.
  *Fix:* R1's registry; the census table is the migration list.
- **RG-2** imbib's import settings are written to keys nothing reads (split brain); `migrateFromUserDefaults`
  has no callers. *Fix:* R1 declares the three keys once with both legacy spellings; the split
  ends when the UI reads the registry.
- **RG-3** The precedent has no cross-process watch (`preferencesChanged(since:)` unused). *Fix:* R1's
  `SharedSettings` feed rides the FFI's 250 ms poll (mtime), so a CLI `set` reaches the pane.
- **RG-4** Chords are declared in three lists for imbib and none for the other apps; the collision
  test reads one file; the lists disagree (⌘5/⌘6, ⇧⌘F ×3, ⌘S ×2, the console chord). *Fix:* R2's
  registry and the coverage test over the registry, not over a source file.
- **RG-5** 2 % of command chords reach Rust; 44 could today. *Fix:* R2 binds `Verb(name, args)` where
  the verb exists (the first 44 are the list above) and `Command(id)` otherwise; the test holds that
  every command has a chord or a palette entry either way.
- **RG-6** A dead Rust chord table (`implore-core/src/input.rs:517`) disagrees with Swift. *Fix:*
  R2 replaces it with the registry (implore in R3) or deletes it; recorded so it is not copied.

## Findings

- **EF-1** No verb declares what it touches; the descriptor (P1) has safety and no effect set. *Fix:*
  E1 adds `effects` to `VerbDescriptor` and the macro; appendix A seeds the declarations.
- **EF-2** 76 verbs' effects are dynamic — the kind of an argument's target (`triage_ops.rs:41`,
  `collection_ops`, `update_with_undo` sites). A literal list cannot describe them. *Fix:* the effect
  vocabulary has `target(arg)`; the spy resolves it the same way the verb does.
- **EF-3** A static walker cannot verify a declaration (table EF-1's over-approximation). *Fix:* E2's
  store spy over the examples in Tier A, and L2's observed effect set on every path at run time.
- **EF-4** RS-S2 is open because `query_refs()` reads only `Source::Query` (`runtime.rs:948`). *Fix:*
  E3 folds the declared reads of each `verb` source in.
- **EF-5** 14 canonical kinds are touched by no verb path; they are written by Swift or daemons. *Fix:*
  recorded in the coverage table (G6) as `swift-only-writer`; not this plan's to close.
- **CL-1** A verb leaves no record: `batch_id` is a store-call id, never a call id (table CL-2);
  `produced_by` on op rows is always NULL. *Fix:* L1 — the pipeline's audit layer sets a call context
  the store reads to stamp `batch_id`.
- **CL-2** `insert`, `insert_batch` and `delete` write no op row, so a verb that creates or deletes
  records is invisible to time travel and to any join. *Fix:* L1 records the call's observed
  `inserted`/`deleted` ids on the call row (the mutation feed already reports them), so the call log
  covers what the op log does not; making `insert`/`delete` mint ops is ask-first D-R7.
- **CL-3** `ItemStore::delete` cascades the target's op history (`:5230`), so "why did this item
  change" cannot be asked about a deleted item. *Fix:* the call row survives (it is not an op of the
  target); L1 records the tombstone id.
- **CL-4** `apply_operation` is not transactional (`:1994-2014`). *Fix:* not this plan's; recorded
  for the store owner (a call's ops can be partially written on crash; the call row is written last).
- **CL-5** The only audit row stores full argument values and `started_at = finished_at`
  (`impress-ai/src/store.rs:1271-1273`). *Fix:* L1's privacy rule and real timestamps; `tool-invocation@1.0.0`
  becomes a projection of the call record for AI runs (D-R4).
- **CL-6** Compaction deletes op rows after 30 days; a call row that outlives its ops joins to
  nothing. *Fix:* the call row carries the op ids' count and the kinds written, so the answer degrades
  from "these operations" to "this call wrote N ops to these kinds"; call rows follow the same window.
- **WF-1** 11 of 31 background services have no startup gate; 3 of those mutate the store; one is a
  platform-forgotten duplicate (#7). *Fix:* W3 migrates #4 and deletes #7; the rule becomes
  `start_delay` in one runtime.
- **WF-2** The daemon has no schedule trigger and no job-finished trigger; its three store-change rules
  are code. *Fix:* W1's trigger vocabulary and W2's planner in `impel-taskd`.
- **WF-3** The apps have no way to run a trigger when the daemon is absent (the daemon is opt-in,
  `install-services.sh`). *Fix:* W2 runs the same planner inline in the app under the same
  `start_delay` (P4's inline runner is the precedent).
- **SC-1** 25 Tier B entries and 79 Tier A entries are closures; three copies of the runner disagree on
  what `skipped` means and how `tier` is parsed. *Fix:* S1's `impress-scenario` interpreter and one
  runner; the three catalogues keep their ids.
- **SC-2** A data-driven Tier A needs a store per scenario and the pipeline dispatches against the
  process-wide store. *Fix:* hook H-P2-3 (a per-call store override) or a subprocess per scenario;
  decision D-R9.
- **SC-3** Nothing records a session. *Fix:* the call log is the recorder; S3 turns a trace range into a
  scenario.
- **RG-1..6** are stated under tables RG-S and RG-K.

## Design

### Hooks: what this plan needs from P1, P2, P4, P5 and G3 (and nothing else)

| Id | Owner | Hook | Why |
|---|---|---|---|
| H-P1-1 | P1 (in flight) | `VerbDescriptor.effects: Effects` and `MethodMeta.effects: Option<Effects>`; `impress_service_impl! { effects = … }` service default and `#[impress_method(effects(reads = […], writes = […], reach = […]))]` per method; `resolve_effects` beside `resolve_safety_class` | E1 declares here; a second table would be a second descriptor |
| H-P1-2 | P1 | `#[impress_private]` on an argument → `"x-private": true` in the input schema | the call log's privacy rule reads the schema, not a second list |
| H-P2-1 | P2 (queued) | `Call { args, caller, trace: TraceParent, parent: Option<CallId> }` — the trace id is generated by the pipeline when absent and propagated on `Call` effects and workflow steps | one id joins a surface click, its verb, the job it started and the ops it wrote |
| H-P2-2 | P2 | the audit layer sets `impress_core::call_context::CURRENT` (a task-local `{call_id, trace_id, caller}`) around invoke and subscribes to `subscribe_mutations` for the call's duration; the store stamps `batch_id = call_id` on every `OperationSpec` with `batch_id: None` while a context is set | CL-1; nothing else changes at the ~170 `None` sites |
| H-P2-3 | P2 | `Pipeline::invoke_on(store: Arc<SqliteItemStore>, …)` — a per-call store override used only by Tier A scenario runs | SC-2; the process-wide store stays the default |
| H-P2-4 | P2 | the audit layer writes the call record (§ Call log) **instead of** a bare `core/operation` row per mutating verb (D-P3 as approved says one op row; § Decisions D-R2 explains why the row cannot be an operation) | one audit record, not two |
| H-P4-1 | P4 (in flight) | `JobRow.verb/args` and `task-event@1.0.0` as they are; the call record carries `job_id` when the verb answered with a handle; a job's terminal transition writes one `task-event {name: "finished"}` | the `job` trigger and "what happened" for long verbs |
| H-P5-1 | P5 (queued) | `POST /api/verb/<name>` carries `traceparent`; the Tier B scenario runner uses it | S2 |
| H-G3-1 | G3 (queued) | examples on the descriptor (`#[impress_example]`, already in P1) | the spy runs them; a verb with no example is on the exception list by construction |
| H-P3-1 | P3 (queued) | the rename pass also visits `impress/workflow@1.0.0` and `impress/scenario@1.0.0` documents | they name verbs |

None of these change P1's or P2's shape; each is a field, a task-local or a parameter. If P2 lands
without H-P2-2, L1 adds it in P2's files with P2's owner's review (the session log will say).

### Effects

**Shape** (in `impress-service-core::descriptor`, pure):

```
Effects {
  reads:  &'static [Kind],      // record kinds read
  writes: &'static [Kind],      // record kinds written (insert, update, delete, apply_operation)
  reach:  &'static [Reach],     // outside the process
}
Kind  = Ref(SchemaRef)          // a canonical ref from schema-refs.json ("imbib/bibliography-entry")
      | Target(arg)             // the kind of the record the argument names (id, ids, publication_ids …)
      | Children(arg)           // the kinds parented under the record the argument names (collections)
      | Prefix("impress/ui/")   // every kind under a prefix (the layout/surface services)
      | Any                     // declared "any kind" — allowed only with a reason, listed in the exception table
Reach = App(id) | Network | Fs | Subprocess | Device | Provider
```

Declared once per service (`impress_service_impl! { effects = { reads: [...], writes: [...] } }`)
with per-method exceptions on the trait (`#[impress_method(effects(writes = [Target(id)]))]`), the
way P1 does safety. `Kind::Ref` takes a `SchemaRef` constant once P7 generates them; until then a
string the macro checks against `schema-refs.json` at compile time (a `build.rs` in `impress-service-macros`
reading the manifest — the same read P7 makes; a misspelt ref is a compile error, which is what the
manifest rule exists for).

**Derived where it can be.** The macro derives `reach: [App(service_app)]` for a service whose
`instance` is a `BackendSlot`-backed default (the `needs_app` derivation P1 already makes) and
`reads: [Target(id)]` for any verb whose only store markers are on its id arguments is *not*
derived — reads are declared, because deriving them from code is what table EF-1 showed cannot be
trusted. The declaration is short: for 313 of 433 verbs the set is one to three kinds (appendix A).

**Verified by a spy, not by reading.** `impress_core::store::SpyStore` wraps an `ItemStore` and
records, per call, `{reads: BTreeSet<SchemaRef>, writes: BTreeSet<SchemaRef>, inserted, deleted}`
— reads from `query`/`count`/`get`/`neighbors` by the query's schema or the row's, writes from the
mutation feed (`subscribe_mutations`, which every write already emits, `sqlite_store.rs:5381`). The
Tier A test `crates/impress-capabilities/tests/effects.rs` runs every example of every linked verb
against a scratch store under the spy through the pipeline and asserts `observed ⊆ declared` after
resolving `Target`/`Children`/`Prefix` against the scratch store; a verb whose examples observed
strictly less than it declared is printed as *under-exercised* (a warning table, not a failure —
the declaration may be right for arguments the example did not use). A verb with no example, a
`needs_app` verb, or an `external` verb whose default implementation refuses is on the **exception
table** in `docs/verb-effects.md` (marker-table style, D-G4's precedent), with the reason column
filled by the test, so the list cannot be edited by hand to hide a verb. The exception table is
expected to start at ~180 rows (83 `needs_app` + the external verbs with no Tier A path + verbs
without examples until G3 lands) and shrink as G3 writes examples; the test fails when it grows.

**Verified again at run time, everywhere.** The call log (below) records the observed effect set
of every mutating call on every path, including the app's. A mismatch is not a refusal (the verb
has already run) — it is a `core/verb-call` row with `effects_mismatch: true` and a counter the
`history-service_health` verb and the Console show. This is how the 83 `needs_app` verbs' declarations
are checked: by the calls people actually make, in the process where the verb actually runs.

**What effects feed:**

| Consumer | How | Closes |
|---|---|---|
| Surface invalidation | `SurfaceRuntime::query_refs()` unions each `Source::Verb`'s `descriptor.effects.reads` (resolving `Target(arg)` against the source's resolved args at plan time); `invalidate_sources` then treats a verb source like a query source | RS-S2 |
| Safety consistency | a test over the linked inventory: `read_only ⇒ writes = ∅ ∧ reach ⊆ {}`; `writes ≠ ∅ ⇒ class ≠ read_only`; `reach ≠ ∅ ⇒ class = external` (or an explicit `external = false` with reason) | S-1's second half |
| Conflict detection | the policy layer keeps the set of in-flight calls; a new call whose `writes ∩ (writes ∪ reads)` of an in-flight call from a *different* caller is non-empty on a resolved `Target` id is answered `{ok: false, code: "conflict", message: "<verb> by <caller> is writing <kind> <id>"}` for destructive verbs and logged (`conflict_with: call_id`) for mutating ones; wave 7's `expected_revision` remains the fine-grained mechanism | the concurrent-agents case |
| Impact analysis | `capabilities-service_impact {kind?} {verb?}`: for a kind, every verb reading or writing it (by declaration), every stored surface, workflow and scenario naming one of those verbs; for a verb, the same documents plus the kinds it touches — the input to P3's rename pass and to "what breaks if this is renamed" | |
| MCP | no new annotation (MCP has none for effects); the reference page (G3) prints the set | |

**Fails loudly:** an undeclared write in Tier A fails the build naming the verb, the kind and the
example; a service with no `effects` fails the descriptor test once E1 lands (as `since` does on P1);
an effects mismatch at run time is counted and shown; a `Kind::Any` needs a reason or the test fails.

**Coverage reachable:** 433 of 433 declared (the macro refuses a service without `effects` after
the seeding pass, the same construction as `safety`); verified in Tier A: every verb with an
example whose default implementation runs headless — 250 of 433 by table 4's `needs_app` (83) and
appendix A4's headless-external count, rising with G3; verified at run time: every verb ever called
after L1. The remainder is listed in `docs/verb-effects.md` with the reason the test wrote.

### Call log

**Record** — one new kind, `core/verb-call@1.0.0` (ask-first D-R1), an `items` row like an operation
but with no `op_target_id`:

```
{
  "verb": "imbib-tags-service_add-tag", "since": "0.9",   // the descriptor's name and version
  "caller": {"kind": "agent", "name": "mcp:agent-a"},     // CallerIdentity from the pipeline (never an argument)
  "trace_id": "…", "parent_call": "…"?, "surface": "…"?, "workflow_run": "…"?, "job": "…"?, "scenario": "…"?,
  "args": {…},                    // the privacy-filtered summary (below)
  "ok": true, "code": null, "message_len": 42,
  "started_at": "…", "duration_ms": 12,
  "effects": {"reads": ["imbib/bibliography-entry"], "writes": ["imbib/bibliography-entry"],
              "inserted": [], "deleted": [], "ops": 1, "effects_mismatch": false},
  "conflict_with": null,
  "wire_version": 1
}
```

`author`/`author_kind` on the row are the caller (`agent:mcp:agent-a` / `agent`; `human:<device>` /
`human`; `system:<daemon>` / `system`), so the existing `ops_minted_since_by_author` telemetry and
`author_kind` readers work unchanged. `retention: compactable`. `batch_id` on the call row is the
call's own id, and every op row written during the call carries the same id (H-P2-2), so:

- **the join down** is `SELECT … FROM items WHERE batch_id = :call AND op_target_id IS NOT NULL`
  (index `idx_items_batch`);
- **the join up** ("why did this item change") is `ops_for(item) → batch_id → call → parent_call …`
  (index `idx_items_op_target`, then the call row by id).

**Privacy rule** (the default is ids and sizes; values only where replay needs them and the verb
allows it):

| Argument shape (from the input schema) | Stored as |
|---|---|
| an id, or a field named `id`/`*_id`/`ids`/`*_ids`/`cite_key(s)` | the value(s), up to 64 ids then `{"len": n, "first": […8]}` |
| a scalar ≤ 64 chars whose field is not `x-private` | the value |
| a longer string, or any field marked `#[impress_private]` (H-P1-2) | `{"len": n, "sha256_8": "…"}` |
| an object or array of objects | `{"len": n, "keys": […]}` |
| whole values | only when the verb declares `#[impress_method(replay = full)]` **and** the args carry no `x-private` field and serialise under 16 KB — the 51 layout and surface verbs qualify today; `search-*`, `*-text-*`, `import-*` and everything carrying a body do not |

**Off the hot path.** The audit layer builds the record after the envelope and hands it to a bounded
channel (4,096) drained by one writer task per process that writes in batches inside one
transaction; on overflow the record is dropped and `history-service_health` reports `dropped: n` (a
dropped record is never silent — the counter is also in `/api/health`). Read-only calls are **not**
recorded by default (their timing is the span aggregator's, ADR-0035 D5); they are recorded when a
trace asks (`Call.trace.record_reads`) or when `IMPRESS_CALL_LOG=all` is set for a session. Cost:
one row per mutating verb — at the op-rate budget's 100 k/day the log adds at most that many rows,
and the 2026-08-06 backlog was 23 M rows of *ops*, not of calls; the per-day cap is the same budget
(`IMPRESS_OPS_RATE_BUDGET`), and the compaction daemon's window (`IMPRESS_COMPACT_WINDOW_DAYS`, 30)
applies to call rows in the same pass: a call older than the window whose ops were compacted is
reduced to `{verb, caller, started_at, effects.writes, ops}` — still an answer to "who wrote to this
kind that month", no longer to "with which arguments". Never durable, never synced (like the surface
ring and `task-event`).

**History verbs** (`history-service`, a new `*-service` in `impress-store-service`, store tier):

| Verb | Class | Answers |
|---|---|---|
| `history-service_calls {since?, until?, verb?, caller?, trace_id?, limit}` | read_only | what happened |
| `history-service_why {id}` | read_only | the ops on an item, each joined to its call and the call's parent chain (surface → verb → job), newest first; degrades per CL-6 |
| `history-service_trace {trace_id}` | read_only | every call, job and op under one trace, as a tree |
| `history-service_replay {call_ids | trace_id, dry_run: bool}` | mutating | re-invokes the recorded calls through the pipeline as `Agent("replay:<caller>")`; only calls with full args replay; `dry_run` lists what would run and refuses `not-replayable` calls by name |
| `history-service_save-macro {call_ids, name}` | mutating | writes an `impress/workflow@1.0.0` with `trigger: manual` whose steps are the calls (§ Workflows) |
| `history-service_health {}` | read_only | rows, dropped, mismatches, oldest, the writer's lag |

Over MCP and the CLI these are ordinary generated tools; a surface (G4's generator) gives the human
"Why did this change?" as a form on any record.

**Tested:** a Tier A test writes three ops through two verbs under one trace and asserts `why` returns
both calls in order with `batch_id` equal on every op; a test fills the channel and asserts the
`dropped` counter and that the calling verb's latency did not move; a test that a `#[impress_private]`
argument never appears in a row byte-for-byte; the compaction test runs the window pass and asserts
the reduced shape. **Fails loudly:** dropped counter; `effects_mismatch`; a `replay` of a
non-replayable call refuses by name.

### Workflows

**Spec** — one new kind, `impress/workflow@1.0.0` (ask-first D-R1), a document the pure crate
`impress-workflow` (kit, `pure`) validates, plans and reduces by **reusing** `impress_surface::reduce`:
a workflow is a `SurfaceSpec` with no `root`, whose events come from a trigger instead of a widget.

```
{
  "wire_version": 1, "name": "imbib.retention-cleanup", "description": "…",
  "state": "enabled" | "disabled" | "proposed",              // proposed: written by an agent, not yet reviewed
  "author": {"kind": "agent", "name": "…"},
  "trigger": {"schedule": {"every": "24h", "at": "03:00"?}}   // exactly one of:
           | {"store": {"kinds": ["imbib/bibliography-entry"], "ops": ["insert", "update"], "debounce_ms": 5000}}
           | {"job": {"verb": "imprint-project-service_project-build", "state": "done"}}
           | {"message": {"kind": "email-message", "folder": "…"?}}   // = a store trigger on that kind, named for readers
           | {"call": {"verb": "…"}}                                  // after a verb ran (from the call log's feed)
           | {"manual": {}}                                           // a macro
  "guards": {"not_before_startup_s": 90, "max_runs_per_hour": 4, "requires": ["app:imbib"]?},
  "params": [...], "sources": {...},   // the surface vocabulary, unchanged
  "steps": [ {"call": …, "each": "state.stale"}, {"set": …}, {"emit": …} ],   // Action, unchanged
  "review": {"required": true}         // an agent-proposed workflow cannot be enabled without a Person
}
```

No new action kinds: `call`, `each`, `set`, `emit`, `refresh` (and `publish`/`open`, which a
workflow without a pane refuses at validation). A step's `call` is a verb call through the pipeline
with `caller = System("workflow:<name>")`, `trace_id` = the run's, `parent_call` = the run; `emit`
writes a `task-event` on the run's job. The trigger payload is the event: `{"widget": "trigger",
"kind": "submit", "value": {…the store event, the job row, the schedule tick…}}`, so `on_submit`
is the step list and nothing in `reduce` changes.

**Who runs it.** A run is a P4 job: a `task@1.0.0` of kind `impress.workflow.run` with `verb =
"workflow-service_run"`, so it has the handle, the event ring, cancel, retry and the review
suspension the kernel already has. The **planner** (`impress-workflow::plan`, pure) turns
`(workflows, clock, store events since cursor, finished jobs since cursor, calls since cursor)` into
run specs; it is called from one place per host:

- **impel-taskd** — a fourth spawn rule beside the three (`main.rs:1091-1260`), reading workflow
  rows instead of code; `SchedulerConfig::start_delay` (90 s) is the startup rule and the planner
  never produces a run before it;
- **the app**, when no daemon holds the worker lease — `SharedStore` ticks the same planner from
  the FFI feed's existing 250 ms poll (`ui_feed.rs`) under the same `start_delay`, and runs the job
  inline (P4's inline runner). A workflow whose steps need the app (`reach: App(imbib)`) runs only
  here; the guard `requires: ["app:imbib"]` says so and the daemon skips it.

The 90-second rule therefore has one owner: `start_delay` on the runtime that plans runs. A Swift
service that becomes a workflow loses its own gate because the runtime has it; the test
`no_run_before_start_delay` in `impress-workflow` holds it.

**Dry run and validation.** `workflow-service_validate {spec}` returns the surface validator's
problems plus the workflow's: unknown verb (by name, from the inventory), a step calling a verb
whose `effects.writes` intersect a kind the trigger listens to without `debounce_ms` (a feedback
loop), a `schedule` under 60 s, `publish`/`open` present. `workflow-service_dry-run {id, event?}`
runs plan → resolve → reduce with the sources evaluated and every `call` effect **returned, not
executed**, as `{would_call: [{verb, args, effects, safety}]}` — the same thing a review surface
shows.

**Review.** An agent may `workflow-service_create` only with `state: proposed`; `workflow-service_enable`
is policy `Review` for an agent (ADR-0034 D3), so it becomes the workflow's review surface (the
generated form with the dry run's `would_call` table), and the person's confirm re-enters as
`Person`. `history-service_propose-workflows {since, min_repeats}` (W4, last) mines the call log for
repeated mutating sequences by one caller (an n-gram over `verb` with argument shapes abstracted to
`Target`) and writes them as `proposed` workflows with `trigger: manual`; nothing runs from it
without the review.

**The proof: `RetentionCleanupService` (#4)** becomes `imbib.retention-cleanup`: trigger `schedule
every 24h` plus a run at enable; source `stale = {query: inbox publications older than the retention
window, not starred}` (the retention window is a registry setting, § Registries); steps `each
state.stale → call imbib-library-service_delete-publications-undoable` (which D-G5 makes undoable);
guard `requires: app:imbib` is *not* needed (the verb runs on the store), so the daemon or the app
may run it. The Swift service and #7's duplicate are deleted; the call log shows each run as a job
with its calls, which is the first time this cleanup is on the record. Runners-up when W3 is
green: #5 enrichment (executors exist; an hourly sweep replaces the Swift loop) and #1 the feed
scheduler (harder: Swift source plugins with battery and network checks).

**Tested:** the planner is pure — property tests over clocks, cursors and guard combinations; the
validator's every refusal has a fixture; the reducer is `impress-surface`'s and needs no new test;
Tier A: a workflow with a `store` trigger on a scratch store runs when a row is inserted and not
before `start_delay`; Tier B: `imbib.retention-cleanup` on an isolated imbib with a throwaway
library. **Fails loudly:** validation names the verb or the loop; a run whose step refuses ends the
job `failed` with the refusal in `task-event`; a workflow naming a verb that has since been removed
is `state: broken` after P3's rename pass and shown so.

### Scenarios

**Spec** — one new kind, `impress/scenario@1.0.0` (ask-first D-R1), the pure crate `impress-scenario`
(kit, `pure`) validates and interprets over an abstract `Caller` trait:

```
{
  "wire_version": 1, "id": "layout.saved_round_trip", "description": "…", "tier": "a" | "b",
  "requires": {"app": "impress"?, "preset": "…"?, "kinds_present": ["manuscript"]?},   // skip, not fail, when unmet
  "seed": [ {"kind": "imbib/bibliography-entry", "payload": {…}, "as": "paper"} ],  // Tier A: rows in the scratch store
  "steps": [
    {"call": "layout-service_save-layout", "args": {"name": "{{uuid}}"}, "as": "person",
     "expect": {"ok": true, "fields": [{"path": "revision", "gte": 1}]}, "capture": {"name": "$.name"}},
    {"event": {"surface": "{{s}}", "widget": "bins", "kind": "change", "value": 17}},            // a human surface event
    {"gesture": {"verb": "split", "target": {"role": "detail"}, "direction": "right"}},           // a human layout verb
    {"wait": {"job": "{{job}}", "state": "done", "timeout_ms": 30000}},
    {"wait": {"log": {"category": "layout", "contains": "pane {{pane}} display", "timeout_ms": 3000}}},
    {"call": "…", "expect": {"ok": false, "code": "conflict", "status": 409}}
  ],
  "teardown": [ {"call": "layout-service_delete-layout", "args": {"name": "{{name}}"}} ],
  "expect_effects": {"writes": ["impress/ui/layout@1.0.0"]}?           // the spy checks the whole scenario
}
```

Templates are the surface's `{{…}}` resolver (`impress_surface::resolve`, reused), extended with
`{{uuid}}` and captures; expectations are a small closed set (`equals`, `contains`, `gte`, `lte`,
`within {value, tol}`, `len`, `present`, `absent`) evaluated on JSON paths — no expressions, as
ADR-0033 D3 requires of a spec. `as` names the caller identity the step runs under (`person`,
`agent:<name>`), which is what makes a scenario able to test policy (`review-pending`) and
attribution.

**Runners.** One interpreter, two `Caller`s: **Tier A** — the pipeline with a scratch store per
scenario (H-P2-3; without it, one subprocess per scenario with `IMPRESS_STORE_PATH` — D-R9) and
the effects spy on; **Tier B** — `POST /api/verb/<name>` over the transport (P5; until then, the
layout Tier B `Http` helper lifted into `impress-scenario-service` as the one client, with the
loopback token from `impress_core::loopback_token`), `event` → `/api/surface/{id}/dispatch`,
`gesture` → `/api/layout/verb`, `wait.log` → `/api/logs?category=&after=`, and the
`log_cursor` capture step → `/api/logs/stream` with no `after` (server cursor at capture time).
Reports are the shared
`impress_service_core::report` with `skipped` meaning `pass: false` (layout's rule; imprint's copy
retires). The three `run_selftest` verbs keep their names and ids and run the scenarios stored under
their catalogue, so nothing an agent calls today changes; `scenario-service_run {id | tier |
catalogue}` is the generic verb, `scenario-service_validate`, `_list`, `_create` (agents author
scenarios like surfaces), `_record {trace_id | since, until, as}` (S3).

**Generation from the call log.** `scenario-service_record` takes a trace or a time window of one
caller's calls, keeps the replayable ones (full args), turns each into a `call` step with `expect
{ok, code}` from the recorded outcome and `capture` for every id that a later call used as an
argument (matched by value), turns recorded surface dispatches into `event` steps, and writes the
document as `tier: b` with `requires.app` from the calls' `reach`. The person edits it once
(`expect.fields` are not guessed) and stores it.

**The proof:** three layout Tier B entries become scenarios — `layout.apply_preset`,
`layout.saved_round_trip` (needs `capture`) and `layout.wire_contract` (needs `status`/`code`
expectations) — plus `surface.http.routes` (already table-driven); and one scenario is recorded from
a live session (a person triaging three papers in impress on an isolated port), stored, and run in
Tier B. Class (ii) `layout.outline_collection_row` becomes a `gesture` step; class (iv) entries stay
code, marked `platform` in the catalogue with the reason.

**Tested:** the interpreter is pure — fixtures for every expectation kind and every refusal; a
scenario that expects an effect the spy did not see fails naming the kind; Tier A runs the four
converted scenarios and the recorded one; Tier B runs them on an isolated impress. **Fails loudly:**
a failed step names the step index, the verb, the path and both values; an unmet `requires` is
`skipped` with the requirement, never `pass`.

### Registries

**Settings.** A new pure kit crate `impress-settings` declares the registry as data in Rust:

```
setting! {
  key = "imbib.retention.inbox_days", ty = u32, default = 30, scope = Device,
  legacy = ["inboxRetentionDays"],          // the UserDefaults key(s) to migrate from
  doc = "Days an unread inbox paper is kept before the daily cleanup removes it."
}
Scope = Device | App(id) | Library | Synced
```

The store is `<workspace>/settings/<scope>.json` (one file per scope; `Device` and `App(id)` files
are per device; `Synced` rides the store as one `impress/settings@1.0.0` row (D-R1) so the sync
engine carries it) through a `SettingsStore` with the same `fs_lock`, `load`/`save` and version
field as `impress_ai::preferences` (the precedent, `preferences.rs:24-27,161-217`). `settings-service`
(store tier, in `impress-store-service`) exposes `settings-service_{schema, list, get, set, reset}`
with `set` mutating and effects `writes: [impress/settings@1.0.0]` for the synced scope. Swift reads
through one UniFFI object `SharedSettings` (`impress-store-ffi`) with a change feed the FFI's existing
poll drives (file mtime, 250 ms), and one property wrapper `@ImpressSetting("imbib.retention.inbox_days")
var days` in `ImpressKit` that replaces `@AppStorage` at the call sites — the value's type and default
come from the registry, so a misspelt key is a runtime error at the wrapper's first read, logged
under `settings` with the three-point trace, and a test (`SharedSettings.knownKeys` against the
Swift call sites, grep-based like `check-schema-refs.sh`) makes it a CI error. **Migration without
loss:** on first read of a key whose file has no value, the wrapper asks `UserDefaults` (and the app
group suite) for each `legacy` key in order, writes the first value found into the file, logs
`migrated <legacy> → <key> = <value>`, and **never removes the UserDefaults value** (D-R5: deleting
is a later, separate decision once no build reads the old key); a key with no `legacy` and no value
answers the default. The generated settings UI is ADR-0035's generator over `settings-service_schema`:
one `SurfaceSpec` per section, fields typed from the registry, `set` on change — a settings pane is
then a surface view kind on any app, and the Swift `Settings` scenes shrink to the platform-only
sections (keychain, permissions). Which keys move first: imbib's retention (needed by W3) and the
automation section (P0 already shares it across apps); the census table says which keys are
device-wide by their readers.

**Keybindings.** A new pure kit crate `impress-keymap`: `Chord {key, modifiers}` (the
`docs/keyboard-grammar.md` grammar as a parser, `"⌘⇧R"` ⇄ struct), `Binding {chord, action: Verb(name,
args) | Command(id), context: App(id) | Pane(view_kind) | Global, since}`, declared per app in Rust
(`keymap! { … }`), exported as `keymap_json` the way `layout_vocabulary_json` is. Swift's
`.keyboardShortcut(...)` sites read the chord from the registry (`Keymap.chord("imbib.paper.star")`)
instead of writing it; a command in `ImpressCommandPalette` registers with its registry id so the
palette and the menu are two projections of one binding. The **coverage test** (`impress-keymap`,
CI): every `Command(id)` registered by an app has a chord or a palette entry; no two enabled
bindings in one context share a chord; every `Verb` binding names a verb in the inventory with
literal args valid against its schema (the surface validator's check, reused); and a Swift test
pins the app's palette registry to `keymap_json`. `docs/keyboard.md` is generated from the registry
and CI diffs it; Settings ▸ Keyboard reads the same JSON. User overrides are a `Device`-scope
setting (`keymap.overrides`) the registry applies on load, so the coverage test runs on the shipped
map and the override path is one function.

**Tested:** registry round-trips (declare → JSON → Swift decode) pinned by a Swift test as
`ViewKindId::KNOWN` is; migration: a test seeds `UserDefaults` in a scratch suite, reads through the
wrapper, asserts the file value and that the old key is still there; the coverage test above.
**Fails loudly:** an unknown key or chord id is an error at first read and in CI; a chord collision
fails CI naming both bindings; a `Verb` binding to a removed verb fails after P3's rename pass.

### Crates and kit tiers

| Crate | Tier | Depends on | Holds |
|---|---|---|---|
| `impress-service-core` (existing, pure) | pure | — | `Effects`, `Kind`, `Reach`; the call record type and the audit layer (P2's) |
| `impress-core` (outside the kit) | — | — | `call_context` task-local, `SpyStore`, `batch_id` stamping, `core/verb-call` compaction |
| `impress-workflow` (new) | pure | `impress-surface`, `impress-service-core` | spec, validate, plan, dry-run |
| `impress-scenario` (new) | pure | `impress-surface` (resolve), `impress-service-core` (report) | spec, validate, interpret over `Caller` |
| `impress-settings` (new) | pure | — (`serde`, `fs_lock` lifted from `impress-ai` into `impress-core`? no: copied 60 lines, or `impress-ai::fs_lock` moves to a pure `impress-fs-lock` — D-R8) | registry, `SettingsStore`, `setting!` |
| `impress-keymap` (new) | pure | `impress-service-core` (verb names) | `Chord`, `Binding`, `keymap!`, the coverage test |
| `impress-store-service` (existing, store) | store | as today | `history-service`, `settings-service` |
| `impress-workflow-service`, `impress-scenario-service` (new) | store | `impress-core` (sqlite), the pure crates, `impel-core`? **no** — the job is created through `impress-core::job` (P4), so neither reaches impel | the verbs, the store rows, the runners |
| `impress-store-ffi` (existing, store) | store | as today | `SharedSettings`, `Keymap`, the in-app planner tick |

Every new crate goes into `docs/kit-manifest.md`'s table with its tier; `check-kit-deps --strict`
and `check-kit-standalone` must pass unchanged. A kit crate gaining a dependency is ask-first
(D-R8 lists the one candidate).

## Decisions needed from Tom (ask-first)

**All approved by Tom on 2026-09-26** (D-R1–D-R13 as recommended; D-R2 amends ADR-0034's D-P3: the audit row is a `core/verb-call`, and the call id is stamped as `batch_id` on every operation the verb wrote). Phase 2 approved in the plan's order.

- **D-R1. New record kinds:** `core/verb-call@1.0.0` (the call record), `impress/workflow@1.0.0`,
  `impress/scenario@1.0.0`, `impress/settings@1.0.0` (synced scope only). Each is registered in
  `schema-refs.json` and `impress-core/src/schemas` in its package's PR; none syncs except settings.
- **D-R2. The audit row is a call record, not an operation** (amends approved D-P3). A `core/operation`
  row needs an `op_target_id` (NOT NULL, FK, `sqlite_store.rs:820`) and one target; a verb call has
  zero or many. The approved "one `core/operation` row per mutating verb" cannot be written for a
  verb that inserts, deletes or touches several rows without inventing a target. Proposal: P2's
  audit layer writes one `core/verb-call` row (H-P2-4) and stamps `batch_id` on the ops the verb
  wrote, which gives every op its attribution (D-P3's intent) without a second row. If Tom prefers
  both, the op row's `target_id` would be the call row itself — recorded here as the rejected shape.
- **D-R3. Read-only calls are not logged by default** (counted by the span aggregator only); logged
  under `IMPRESS_CALL_LOG=all` or a trace's request. Alternative: log everything at 10× the volume.
- **D-R4. `tool-invocation@1.0.0` becomes a projection of the call record** for AI-run tool calls
  (impress-ai writes it today with full argument values; after L1 it would carry `call_id` and drop
  `arguments`). Its 13 live rows are not migrated.
- **D-R5. Migration never deletes a UserDefaults value.** The registry copies on first read and
  leaves the old key; a later plan removes them once no build reads them. Alternative: remove on
  migration and lose the value if the new build is rolled back.
- **D-R6. `state: proposed` workflows from agents; `enable` is a review for an agent** — a policy
  rule on top of ADR-0034 D3's matrix (a mutating verb an agent may otherwise run).
- **D-R7. Should `insert`/`insert_batch`/`delete` mint operation rows?** Not needed for this plan
  (the call row records inserted/deleted ids), but without it time travel cannot see creation or
  deletion. Recommendation: no, not now — the 23 M-row lesson says every new op source needs its
  retention decided first; recorded for the store owner.
- **D-R8. One kit dependency:** `impress-settings` needs a file lock; `impress_ai::fs_lock` is in a
  store-tier crate. Options: move `fs_lock` into `impress-core` (pure crates cannot reach it),
  duplicate ~60 lines, or a new 60-line pure crate `impress-fs-lock` both use. Recommendation: the
  new pure crate.
- **D-R9. Tier A store injection:** H-P2-3 (`Pipeline::invoke_on(store, …)`, a P2 parameter) or a
  subprocess per scenario. Recommendation: H-P2-3; it also gives the effects spy its store without
  a global.
- **D-R10. The first migrated service is `RetentionCleanupService`**, and #7 (the ungated macOS
  duplicate) is deleted with it. It deletes user data by design (already does); the workflow calls
  the undoable verb.
- **D-R11. Conflict detection refuses destructive verbs only** (`conflict` when a resolved target is
  being written by another caller) and logs for mutating ones. Alternative: refuse both.
- **D-R12. Where settings files live:** `<workspace>/settings/` beside `ai/preferences.json`
  (device, app scopes) and one store row for the synced scope. Alternative: everything in the store
  (then the daemon cannot read a setting without opening the store, which `impress-ai` avoided).
- **D-R13. Chord overrides are a device setting**, not per app; the coverage test runs on the shipped
  map only.

## Work packages

| WP | Owns | Closes | Proof | Gates | Parallel with |
|---|---|---|---|---|---|
| **E1 Effects declared** | `impress-service-core/src/descriptor.rs` (`Effects`, `Kind`, `Reach`, `resolve_effects`), `impress-service-macros` (the attribute, the manifest check in `build.rs`), every service crate's `impress_service_impl!`/trait (the seeding pass from appendix A), `docs/verb-effects.md`, `crates/impress-capabilities/tests/effects.rs` (declaration test) | EF-1, EF-2 | every linked verb has an effect set or the test names it; `read_only ⇒ writes = ∅` holds; a misspelt ref fails to compile | full gate; `descriptor.rs` test on P1 | R1, R2 (after P1 merges) |
| **E2 The spy** | `impress-core/src/store/spy.rs`, the Tier A runner in `effects.rs` over examples, the exception table's generated column | EF-3 | `observed ⊆ declared` for every example; the under-exercised table prints; removing a declared kind from `triage-service_set-starred` fails the build naming the example | `cargo test -p impress-capabilities`; kit checks | E3 |
| **E3 Invalidation, consistency, impact** | `impress-surface-service/src/runtime.rs` (`query_refs`, `invalidate_sources`), the safety-consistency test, `capabilities-service_impact`, the policy layer's in-flight set (P2's file, with P2's owner) | EF-4, RS-S2, D-R11 | Tier A: a `verb` source over `triage-service_set-starred` re-renders after a write to `imbib/bibliography-entry` (the T2 live proof repeated, now for a verb source); `impact {kind}` lists the verbs; two agents' destructive calls on one id → `conflict` | surface Tier A/B; Tier B on impress | E2 |
| **L1 The call record** | `impress-core/src/call_context.rs`, `sqlite_store.rs` (`batch_id` stamping, the writer task, compaction of call rows), `schemas/call.rs`, `schema-refs.json`, P2's audit layer body (H-P2-2/4), the privacy filter in `impress-service-core` | CL-1, CL-2, CL-3, CL-5, CL-6 | two verbs under one trace → ops with equal `batch_id`; the channel-full test; the private-argument test; `/api/health` shows `dropped` | full gate; `check-schema-refs`; the P2 bench (≤ 5 µs + the async hand-off) | S1 |
| **L2 History verbs** | `impress-store-service/src/history_service.rs`, the `why`/`trace`/`replay`/`save-macro`/`health` verbs, `impress-capabilities` link, `docs/verb-coverage.md` row, the generated "why did this change" surface | goals 3; the "what happened / why / replay / macro" list | `history-service_why` on a paper tagged from impress-cli names the call, its caller and the surface it came from, over MCP and the CLI; `replay --dry-run` lists it; `save-macro` writes a workflow that `workflow-service_dry-run` accepts | full gate; Tier B on impress | S1 |
| **S1 Scenario crate and runner** | new `crates/impress-scenario`, `crates/impress-scenario-service`, the shared Tier B client, H-P2-3, `docs/kit-manifest.md` rows, `docs/agent-surfaces.md` § Scenarios | SC-1, SC-2 | the four converted entries run as scenarios in Tier A (layout ones on a scratch store) and Tier B; the three `run_selftest` verbs report the same ids; the interpreter's fixtures | full gate; kit checks; Tier B on impress | L1, L2 |
| **S2 Convert the catalogues** | `impress-layout-service/src/tier_b.rs`, `impress-surface-service/src/tier_b.rs`, `imprint-selftest/src/tier_b.rs`, the stored scenario documents | SC-1's copies (one runner) | 20 class-(i) entries as documents; `layout.outline_collection_row` as a `gesture`; the 4 platform entries marked; `imprint`'s report copy deleted | Tier B ×3 catalogues | W1 |
| **S3 Record a session** | `scenario-service_record`, the capture matcher | SC-3 | a live session on an isolated impress (three papers triaged) is recorded, stored, edited once and runs in Tier B | Tier B on impress | W1 |
| **W1 Workflow crate and verbs** | new `crates/impress-workflow`, `crates/impress-workflow-service`, `impress/workflow@1.0.0`, the validator, dry run, `docs/kit-manifest.md`, `docs/agent-surfaces.md` § Workflows | WF-2's vocabulary; D-R6 | validator fixtures; `dry-run` returns `would_call`; an agent's `create` stores `proposed`; `enable` from an agent → `review-pending` | full gate; kit checks | S2, S3 |
| **W2 The planner in both hosts** | `impel-taskd/src/main.rs` (the fourth rule), `impress-store-ffi` (the in-app tick), `impress-workflow::plan`, the `job` and `call` triggers' cursors | WF-2, WF-3, goal 4's runtime rule | Tier A: no run before `start_delay`; a `store` trigger fires once per debounce; a `job` trigger fires on `done`; the daemon and the app never both run one workflow (the lease) | `cargo test -p impel-taskd -p impress-workflow`; Tier B | R3 |
| **W3 First migration** | `apps/imbib/PublicationManagerCore/…/Inbox/RetentionCleanupService.swift` (deleted), `imbibApp.swift:580-631` + `LibraryManager.swift:485-515` (#7 deleted), `InboxCoordinator.swift:97`, the stored `imbib.retention-cleanup` workflow, the retention settings in the registry (R1) | WF-1 (#4, #7), D-R10 | on an isolated imbib with a throwaway library: the workflow runs 90 s after launch and not before (`/api/logs` shows the job), removes the throwaway stale papers and not the starred one, and `history-service_why` on a removed paper names the run | PMC `swift test`; Tier B imbib; the `log show … SHKSharingServicePicker` check = 0 | R2 |
| **W4 Proposed workflows** | `history-service_propose-workflows`, the n-gram miner | the loop's last arc | a recorded session of three identical triage sequences yields one `proposed` workflow; nothing runs from it | `cargo test` | last |
| **R1 Settings registry** | new `crates/impress-settings` (+ `impress-fs-lock` per D-R8), `settings-service`, `SharedSettings` in `impress-store-ffi` (+ regenerated bindings), `@ImpressSetting` in `ImpressKit`, the migration, the first keys (imbib retention, automation), the generated settings surface | RG-1..3 | the migration test; imbib's retention pane is the generated surface reading the registry; `impress settings-service_get imbib.retention.inbox_days` over the CLI and MCP matches the pane | PMC + ImpressKit `swift test`; `check-uniffi-bindings`; kit checks; Tier B imbib | E1..E3 (Mac) |
| **R2 Keymap registry** | new `crates/impress-keymap`, `keymap_json` in `impress-store-ffi`, `ImpressCommandPalette` registry ids, the first app's `.keyboardShortcut` sites (imbib), `docs/keyboard.md` generated, the coverage test in CI | RG-4..6 | the coverage test passes for imbib and fails when a chord is duplicated in a fixture; Settings ▸ Keyboard shows the registry; the palette and the menu agree by test | PMC `swift test`; the new CI job | R1 |
| **R3 Second app** | imprint's settings and chords through the registries | the "one app" done-criterion becomes two | as R1/R2 for imprint | | after R1, R2 |

Order: E1 → E2 → E3 (E1 the day P1 merges); L1 → L2 after P2; S1 after L1 and H-P2-3, S2 ∥ S3 after S1;
W1 after P4 and L2, W2 after W1, W3 after W2 and R1, W4 last; R1 ∥ R2 beside everything (Mac), R3 after
both. Parallel sets with disjoint files: {E1, R1, R2}, {E2, E3}, {L1, S1 (crate half)}, {S2, S3, W1},
{W2, R3}.

## Ask-first list (stop that thread, write the question in the PR, continue elsewhere)

Everything under § Decisions needed, and in Phase 2 any of: a new record kind or schema ref beyond
D-R1; renaming or removing a verb or changing its arguments (`replay = full` is a descriptor field,
not an argument); a new action kind in the surface vocabulary (none is planned — `trigger` is an
event, not an action); a kit crate gaining a dependency beyond D-R8; deleting user data beyond what
`RetentionCleanupService` already deletes; a setting migration that could lose a value (D-R5 says
none can); changing what a preset contains; any change to impel's task model beyond P4's fields and
the `impress.workflow.run` kind.

## Recommendation

**Go, in the order E → L → S → W with R beside them, and with E1 written against P1's branch now.**
The measurements settle the two questions the brief left open. Effects must be *declared* (76 verbs'
effects are a function of an argument, and a static reading over-approximates the rest) and
*verified by a spy* — at build time over the examples, and at run time by the call log on every path,
which is the only way the 83 app-bound verbs are ever checked. The call log's join key is `batch_id`,
which exists, is indexed and is set by nothing meaningful today; one task-local in the store gives
every op its call without touching 170 call sites. The workflow runtime already exists in the daemon
(durable tasks, retry, review, `start_delay`) and lacks only a trigger as data, so W1/W2 are a planner
and a fourth rule, not a scheduler; the first migration deletes a duplicate that forgot the gate on
one platform, which is the argument for the rule having one owner. Scenarios reuse the surface's
resolver and the wave-7 report, and 20 of 25 Tier B entries are already sequences of calls. The
registries are the independent half and need the Mac; their first keys are the ones W3 needs.
**First work package: E1**, because every other package reads the effect set.

## Appendix A — every verb's static effects (the seed for E1, not a verification)

Columns: the A4 class P1's `docs/verb-safety.md` declares; the canonical kinds named anywhere on the
call path within three hops (over-approximate, see table EF-1); `r`/`w` when store read/write markers
were seen on that path; reach markers; and whether the walker found a kind at all (`static`), only
store markers (`dynamic` — declare `Target(arg)`), only reach (`reach-only`), or nothing (`none` —
pure computation or an HTTP backend). Generated by the walker on 60833ea1 + P1's table.

| Verb | A4 class (docs/verb-safety.md, P1) | Kinds named on the call path (≤ 3 hops) | Store markers | Reach markers | Static coverage |
|---|---|---|---|---|---|
| `collection-service_add-members` | mutating | collection, figure, figure-collection, imbib/collection, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface@1.0.0, manuscript, manuscript-collection | rw | fs | static |
| `collection-service_create` | mutating | collection, figure, figure-collection, imbib/collection, manuscript, manuscript-collection | w | — | static |
| `collection-service_delete` | destructive | collection, figure, figure-collection, imbib/collection, manuscript, manuscript-collection | rw | — | static |
| `collection-service_member-counts` | read_only | collection, figure, figure-collection, imbib/collection, manuscript, manuscript-collection | r | — | static |
| `collection-service_migrate` | mutating | collection, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, task@1.0.0 | rw | fs, network | static |
| `collection-service_migration-status` | read_only | collection, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0 | rw | fs, network | static |
| `collection-service_remove-members` | mutating | collection, figure, figure-collection, imbib/collection, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface@1.0.0, manuscript, manuscript-collection | rw | fs | static |
| `collection-service_rename` | mutating | collection, figure, figure-collection, imbib/collection, impress/ui/surface@1.0.0, manuscript, manuscript-collection | rw | fs | static |
| `collection-service_reorder` | mutating | collection, figure, figure-collection, imbib/collection, impress/ui/surface@1.0.0, manuscript, manuscript-collection | rw | fs | static |
| `collection-service_reparent` | mutating | collection, figure, figure-collection, imbib/collection, manuscript, manuscript-collection | rw | — | static |
| `collection-service_rollback` | destructive | collection, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0 | rw | fs, network | static |
| `collection-service_tree` | read_only | collection, figure, figure-collection, imbib/collection, manuscript, manuscript-collection | r | — | static |
| `docs-import-service_add-watched-folder` | mutating | impress/ui/surface@1.0.0, watched-folder@1.0.0 | rw | fs | static |
| `docs-import-service_finish-watched-scan` | mutating | impress/ui/surface@1.0.0, watched-file@1.0.0, watched-folder@1.0.0 | rw | fs | static |
| `docs-import-service_import-directory` | destructive | manuscript | rw | fs | static |
| `docs-import-service_import-discovered` | mutating | watched-file@1.0.0, watched-folder@1.0.0 | rw | fs | static |
| `docs-import-service_list-watched-files` | read_only | manuscript-file@1.0.0, watched-file@1.0.0 | r | — | static |
| `docs-import-service_list-watched-folders` | read_only | watched-folder@1.0.0 | r | — | static |
| `docs-import-service_prune-empty-manuscripts` | destructive | manuscript | rw | — | static |
| `docs-import-service_record-produced-rows` | mutating | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface@1.0.0, watched-file@1.0.0 | rw | fs, network | static |
| `docs-import-service_remove-watched-folder` | destructive | watched-file@1.0.0, watched-folder@1.0.0 | rw | — | static |
| `docs-import-service_update-watched-folder` | mutating | impress/ui/surface@1.0.0, watched-folder@1.0.0 | rw | fs | static |
| `imbib-annotations-service_count-annotations` | read_only | imbib/annotation | r | — | static |
| `imbib-annotations-service_create-annotation` | mutating | imbib/annotation | w | — | static |
| `imbib-annotations-service_create-comment` | mutating | imbib/comment | w | — | static |
| `imbib-annotations-service_create-comment-on-item` | mutating | imbib/comment | w | — | static |
| `imbib-annotations-service_list-annotations` | read_only | imbib/annotation | r | — | static |
| `imbib-annotations-service_list-comments` | read_only | imbib/comment | r | — | static |
| `imbib-annotations-service_list-comments-for-item` | read_only | imbib/comment | r | — | static |
| `imbib-annotations-service_list-comments-since` | read_only | imbib/comment | r | — | static |
| `imbib-annotations-service_update-comment` | destructive | impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-app-service_add-to-library` | external | — | — | — | none |
| `imbib-app-service_delete-annotation` | external | — | — | — | none |
| `imbib-app-service_delete-collection` | external | — | — | — | none |
| `imbib-app-service_delete-comment` | external | — | — | — | none |
| `imbib-app-service_delete-smart-searches` | external | — | — | — | none |
| `imbib-app-service_download-pdfs` | external | — | — | — | none |
| `imbib-app-service_get-logs` | external | — | — | — | none |
| `imbib-app-service_get-notes` | external | — | — | — | none |
| `imbib-app-service_open-manuscript-papers` | external | — | — | — | none |
| `imbib-app-service_recent-activity` | external | — | — | — | none |
| `imbib-app-service_resolve-identifier` | external | — | — | — | none |
| `imbib-app-service_search-sources` | external | — | — | — | none |
| `imbib-app-service_status` | external | — | — | — | none |
| `imbib-app-service_sync-nudge` | external | — | — | — | none |
| `imbib-app-service_sync-status` | external | — | — | — | none |
| `imbib-app-service_tag-artifact` | external | — | — | — | none |
| `imbib-app-service_update-notes` | external | — | — | — | none |
| `imbib-artifacts-service_count-artifacts` | read_only | impress/artifact/code, impress/artifact/dataset, impress/artifact/general, impress/artifact/media, impress/artifact/note, impress/artifact/poster, impress/artifact/presentation, impress/artifact/webpage | r | — | static |
| `imbib-artifacts-service_create-artifact` | mutating | imbib/tag-definition | rw | — | static |
| `imbib-artifacts-service_delete-artifact` | destructive | — | w | — | dynamic |
| `imbib-artifacts-service_get-artifact` | read_only | imbib/tag-definition | r | — | static |
| `imbib-artifacts-service_get-artifact-relations` | read_only | — | r | — | dynamic |
| `imbib-artifacts-service_link-artifact-to-publication` | mutating | — | w | — | dynamic |
| `imbib-artifacts-service_list-artifacts` | read_only | imbib/tag-definition, impress/artifact/code, impress/artifact/dataset, impress/artifact/general, impress/artifact/media, impress/artifact/note, impress/artifact/poster, impress/artifact/presentation, impress/artifact/webpage | r | — | static |
| `imbib-artifacts-service_search-artifacts` | read_only | imbib/tag-definition | r | — | static |
| `imbib-artifacts-service_update-artifact` | mutating | — | w | — | dynamic |
| `imbib-backup-service_create-backup` | mutating | — | w | fs | dynamic |
| `imbib-backup-service_delete-backup` | destructive | — | — | fs | reach-only |
| `imbib-backup-service_inspect-backup` | read_only | — | — | fs | reach-only |
| `imbib-backup-service_list-backups` | read_only | — | r | fs | dynamic |
| `imbib-backup-service_prune-backups` | destructive | — | r | fs | dynamic |
| `imbib-backup-service_restore-backup` | external | — | — | — | none |
| `imbib-eink-service_eink-append-notes` | mutating | imbib/annotation, imbib/linked-file, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0 | rw | device | static |
| `imbib-eink-service_eink-awaiting-source` | read_only | imbib/eink-mirror | r | — | static |
| `imbib-eink-service_eink-complete-ocr` | mutating | impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-eink-service_eink-configure-device` | mutating | imbib/eink-device | — | — | static |
| `imbib-eink-service_eink-devices` | read_only | imbib/eink-device | r | — | static |
| `imbib-eink-service_eink-folder-checklist` | external | — | — | subprocess | reach-only |
| `imbib-eink-service_eink-import` | external | ai-import-ledger@1.0.0, imbib/eink-device | rw | subprocess | static |
| `imbib-eink-service_eink-import-document` | external | imbib/bibliography-entry, imbib/eink-device, imbib/eink-mirror, imbib/library, imbib/linked-file, impress/artifact/note | rw | device, fs, subprocess | static |
| `imbib-eink-service_eink-list-annotations` | read_only | imbib/annotation, imbib/linked-file | r | — | static |
| `imbib-eink-service_eink-list-mirrored` | read_only | imbib/eink-mirror | r | — | static |
| `imbib-eink-service_eink-list-unmatched` | external | imbib/eink-device, imbib/eink-mirror | rw | fs, network, subprocess | static |
| `imbib-eink-service_eink-mark` | mutating | imbib/bibliography-entry, imbib/eink-device, imbib/eink-mirror, imbib/linked-file, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-eink-service_eink-note-source-error` | mutating | imbib/eink-device, imbib/eink-mirror, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-eink-service_eink-pending-ocr` | read_only | imbib/annotation, imbib/linked-file | r | fs | static |
| `imbib-eink-service_eink-plan` | external | imbib/eink-device | rw | subprocess | static |
| `imbib-eink-service_eink-reachable` | external | imbib/eink-device | — | fs, network, subprocess | static |
| `imbib-eink-service_eink-remove-device` | destructive | imbib/eink-device, imbib/eink-mirror | rw | — | static |
| `imbib-eink-service_eink-resend` | mutating | imbib/eink-mirror, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-eink-service_eink-search-annotations` | read_only | imbib/annotation | r | — | static |
| `imbib-eink-service_eink-status` | read_only | imbib/bibliography-entry, imbib/eink-device, imbib/eink-mirror | r | device | static |
| `imbib-eink-service_eink-sync` | external | imbib/eink-device | rw | subprocess | static |
| `imbib-eink-service_eink-unmark` | mutating | imbib/eink-device, imbib/eink-mirror, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-library-service_add-linked-file` | mutating | imbib/linked-file | w | — | static |
| `imbib-library-service_add-to-collection` | mutating | — | w | — | dynamic |
| `imbib-library-service_count-flagged` | read_only | imbib/bibliography-entry | r | — | static |
| `imbib-library-service_count-pdfs` | read_only | imbib/linked-file | r | — | static |
| `imbib-library-service_count-publications` | read_only | imbib/bibliography-entry | r | — | static |
| `imbib-library-service_count-starred` | read_only | imbib/bibliography-entry | r | — | static |
| `imbib-library-service_count-unread` | read_only | imbib/bibliography-entry | r | — | static |
| `imbib-library-service_create-collection` | mutating | — | w | — | dynamic |
| `imbib-library-service_create-library` | mutating | imbib/library | w | — | static |
| `imbib-library-service_create-muted-item` | mutating | imbib/muted-item | w | — | static |
| `imbib-library-service_deduplicate-library` | destructive | imbib/bibliography-entry | rw | — | static |
| `imbib-library-service_delete-library-undoable` | destructive | imbib/bibliography-entry | rw | — | static |
| `imbib-library-service_delete-publications-undoable` | destructive | — | rw | — | dynamic |
| `imbib-library-service_dismiss-paper` | mutating | imbib/dismissed-paper | w | — | static |
| `imbib-library-service_duplicate-publications` | mutating | — | w | fs | dynamic |
| `imbib-library-service_export-all-bibtex` | read_only | imbib/bibliography-entry, imbib/linked-file | rw | — | static |
| `imbib-library-service_export-bibtex` | read_only | imbib/linked-file | rw | — | static |
| `imbib-library-service_get-default-library` | read_only | imbib/bibliography-entry, imbib/library | r | — | static |
| `imbib-library-service_get-inbox-library` | read_only | imbib/bibliography-entry, imbib/library | r | — | static |
| `imbib-library-service_get-publication` | read_only | imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-library-service_get-publication-detail` | read_only | imbib/linked-file, imbib/tag-definition | rw | — | static |
| `imbib-library-service_import-bibtex` | mutating | imbib/bibliography-entry | rw | network | static |
| `imbib-library-service_import-papers` | mutating | imbib/bibliography-entry, imbib/dismissed-paper | rw | fs, network | static |
| `imbib-library-service_is-paper-dismissed` | read_only | imbib/dismissed-paper | r | — | static |
| `imbib-library-service_list-collection-members` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-library-service_list-collections` | read_only | — | r | — | dynamic |
| `imbib-library-service_list-dismissed-papers` | read_only | imbib/dismissed-paper | r | — | static |
| `imbib-library-service_list-libraries` | read_only | imbib/bibliography-entry, imbib/library | r | — | static |
| `imbib-library-service_list-linked-files` | read_only | imbib/linked-file | r | — | static |
| `imbib-library-service_list-muted-items` | read_only | imbib/muted-item | r | — | static |
| `imbib-library-service_list-publications` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-library-service_move-publications` | mutating | core/operation | w | — | static |
| `imbib-library-service_purge-dismissed-from-collection` | mutating | imbib/bibliography-entry, imbib/dismissed-paper | rw | — | static |
| `imbib-library-service_query-publications` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-library-service_query-recent` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-library-service_query-starred` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-library-service_query-unread` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-library-service_remove-from-collection` | mutating | — | w | — | dynamic |
| `imbib-library-service_search-publications` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/library, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-library-service_set-flag` | mutating | core/operation, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-library-service_set-library-default` | mutating | imbib/library, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-library-service_set-read` | mutating | core/operation, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-library-service_set-starred` | mutating | core/operation, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-library-service_sidebar-view` | read_only | imbib/bibliography-entry, imbib/library, imbib/smart-search, impress/artifact/code, impress/artifact/dataset, impress/artifact/general, impress/artifact/media, impress/artifact/note, impress/artifact/poster, impress/artifact/presentation, impress/artifact/webpage | r | — | static |
| `imbib-manuscripts-service_compile-manuscript` | external | — | — | — | none |
| `imbib-manuscripts-service_create-manuscript` | external | — | — | — | none |
| `imbib-manuscripts-service_create-manuscript-from-template` | external | — | — | — | none |
| `imbib-manuscripts-service_get-manuscript` | external | — | — | — | none |
| `imbib-manuscripts-service_list-manuscripts` | external | — | — | — | none |
| `imbib-manuscripts-service_list-templates` | external | — | — | — | none |
| `imbib-manuscripts-service_write-manuscript-body` | external | — | — | — | none |
| `imbib-scix-service_add-to-scix-library` | mutating | impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-scix-service_count-scix-library-publications` | read_only | imbib/bibliography-entry | r | — | static |
| `imbib-scix-service_create-scix-library` | mutating | imbib/scix-library | w | — | static |
| `imbib-scix-service_get-scix-library` | read_only | imbib/scix-library | r | — | static |
| `imbib-scix-service_list-scix-libraries` | read_only | imbib/scix-library | r | — | static |
| `imbib-scix-service_query-scix-library-publications` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-scix-service_remove-from-scix-library` | mutating | — | w | — | dynamic |
| `imbib-search-service_create-smart-search` | mutating | imbib/smart-search | w | — | static |
| `imbib-search-service_find-by-arxiv` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-search-service_find-by-bibcode` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-search-service_find-by-cite-key` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-search-service_find-by-doi` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-search-service_find-by-identifiers-batch` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-search-service_full-text-search` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-search-service_get-smart-search` | read_only | imbib/smart-search | r | — | static |
| `imbib-search-service_list-smart-searches` | read_only | imbib/smart-search | r | — | static |
| `imbib-search-service_resolve-cite-key` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/library, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-tags-service_add-tag` | mutating | core/operation, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-tags-service_count-by-tag` | read_only | imbib/bibliography-entry | r | — | static |
| `imbib-tags-service_create-tag` | mutating | imbib/tag-definition | w | — | static |
| `imbib-tags-service_delete-tag-undoable` | destructive | imbib/bibliography-entry, imbib/tag-definition | rw | — | static |
| `imbib-tags-service_list-tags` | read_only | imbib/tag-definition | rw | — | static |
| `imbib-tags-service_list-tags-with-counts` | read_only | imbib/bibliography-entry, imbib/tag-definition | r | — | static |
| `imbib-tags-service_query-by-tag` | read_only | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device | static |
| `imbib-tags-service_remove-tag` | mutating | core/operation, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-tags-service_rename-tag` | mutating | imbib/bibliography-entry, imbib/tag-definition, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-tags-service_update-tag` | mutating | imbib/tag-definition, impress/ui/surface@1.0.0 | rw | fs | static |
| `imbib-text-service_decode-latex` | read_only | — | — | — | none |
| `imbib-text-service_expand-journal-macro` | read_only | — | — | — | none |
| `imbib-text-service_generate-cite-key` | read_only | — | — | — | none |
| `imbib-text-service_normalize-tag-path` | read_only | — | — | — | none |
| `imbib-text-service_normalize-tag-segment` | read_only | — | — | — | none |
| `imbib-undo-service_recent-undo-groups` | read_only | core/operation | rw | — | static |
| `imbib-undo-service_undo-batch` | mutating | citation-usage, core/operation, manuscript-change@1.0.0, manuscript-revision | rw | device, fs | static |
| `imbib-undo-service_undo-operation` | mutating | core/operation, manuscript-change@1.0.0, manuscript-revision | w | fs | static |
| `impart-service_add-message` | external | — | — | — | none |
| `impart-service_branch-conversation` | external | — | — | — | none |
| `impart-service_create-conversation` | external | — | — | — | none |
| `impart-service_get-conversation` | external | — | — | — | none |
| `impart-service_get-logs` | external | — | — | — | none |
| `impart-service_list-conversations` | external | — | — | — | none |
| `impart-service_record-artifact` | external | — | — | — | none |
| `impart-service_record-decision` | external | — | — | — | none |
| `impart-service_status` | external | — | — | — | none |
| `impart-service_update-conversation` | external | — | — | — | none |
| `impel-service_cancel-task` | destructive | core/operation, manuscript-change@1.0.0, manuscript-revision, task@1.0.0 | rw | fs | static |
| `impel-service_list-failed-tasks` | read_only | task@1.0.0 | r | — | static |
| `impel-service_list-pending-reviews` | read_only | review-request@1.0.0 | r | — | static |
| `impel-service_resolve-review` | mutating | citation-usage, core/operation, impress/ui/preset@1.0.0, impress/ui/surface-event@1.0.0, impress/ui/surface@1.0.0, manuscript, manuscript-revision, review-request@1.0.0, task@1.0.0 | rw | fs | static |
| `impel-service_retention-status` | read_only | core/operation, review-request@1.0.0, task@1.0.0 | — | — | static |
| `impel-service_scheduler-status` | read_only | review-request@1.0.0, task@1.0.0 | r | fs | static |
| `implore-service_create-figure` | external | — | — | — | none |
| `implore-service_export-figure` | external | — | — | — | none |
| `implore-service_get-dataset` | external | — | — | — | none |
| `implore-service_get-figure` | external | — | — | — | none |
| `implore-service_get-logs` | external | — | — | — | none |
| `implore-service_list-datasets` | external | — | — | — | none |
| `implore-service_list-figures` | external | — | — | — | none |
| `implore-service_plot-histogram` | external | — | — | — | none |
| `implore-service_plot-series` | external | — | — | — | none |
| `implore-service_rg-batch` | external | — | — | — | none |
| `implore-service_rg-cascade-plot` | external | — | — | — | none |
| `implore-service_rg-colormaps` | external | — | — | — | none |
| `implore-service_rg-control` | external | — | — | — | none |
| `implore-service_rg-load` | external | — | — | — | none |
| `implore-service_rg-slice-png` | external | — | — | — | none |
| `implore-service_rg-slice-raw` | external | — | — | — | none |
| `implore-service_rg-slice-save` | external | — | — | — | none |
| `implore-service_rg-state` | external | — | — | — | none |
| `implore-service_rg-statistics` | external | — | — | — | none |
| `implore-service_status` | external | — | — | — | none |
| `impress-ai-service_ai-health` | external | — | — | — | none |
| `impress-ai-service_ai-preferences` | read_only | — | — | — | none |
| `impress-ai-service_create-conversation` | mutating | — | — | — | none |
| `impress-ai-service_get-conversation` | read_only | — | — | — | none |
| `impress-ai-service_list-conversations` | read_only | — | — | — | none |
| `impress-ai-service_list-models` | external | — | — | — | none |
| `impress-ai-service_list-providers` | external | — | — | — | none |
| `impress-ai-service_mint-pairing-link` | external | — | — | — | none |
| `impress-ai-service_provider-health` | external | — | — | — | none |
| `impress-ai-service_queue-message` | mutating | — | — | — | none |
| `impress-ai-service_run-provenance` | read_only | — | — | — | none |
| `impress-ai-service_select-model` | mutating | — | — | — | none |
| `impress-ai-service_set-enabled-tools` | mutating | — | — | — | none |
| `impress-ai-service_set-provider-endpoint` | mutating | — | — | — | none |
| `impress-ai-service_task-provenance` | read_only | — | — | — | none |
| `impress-ai-service_task-status` | read_only | — | — | — | none |
| `impress-bridges-service_add-papers-from-conversation` | external | conversation@1.0.0, imbib/bibliography-entry, imbib/dismissed-paper, imbib/library, task@1.0.0 | rw | fs, network | static |
| `impress-bridges-service_cite-in-section` | mutating | extraction-run@1.0.0, imbib/bibliography-entry, imbib/tag-definition, manuscript, manuscript-section | rw | fs | static |
| `impress-bridges-service_cite-multiple` | external | imbib/bibliography-entry, imbib/library, imbib/tag-definition | rw | — | static |
| `impress-bridges-service_cite-paper` | external | imbib/bibliography-entry, imbib/library | rw | — | static |
| `impress-bridges-service_conversation-decisions` | external | chat-message, conversation@1.0.0, task@1.0.0 | r | fs | static |
| `impress-bridges-service_conversation-to-outline` | external | chat-message, conversation@1.0.0, task@1.0.0 | rw | fs, network | static |
| `impress-bridges-service_embed-figure` | external | — | rw | fs | dynamic |
| `impress-bridges-service_embed-figure-reference` | external | — | rw | — | dynamic |
| `impress-bridges-service_export-conversation-citations` | external | conversation@1.0.0, imbib/bibliography-entry, imbib/eink-mirror, imbib/library, imbib/linked-file, imbib/tag-definition, task@1.0.0 | rw | device, fs, network | static |
| `impress-bridges-service_extract-papers-from-conversation` | external | chat-message, conversation@1.0.0, task@1.0.0 | rw | fs, network | static |
| `impress-bridges-service_extract-papers-from-text` | read_only | — | rw | fs, network | dynamic |
| `impress-bridges-service_get-citation-suggestions` | external | imbib/bibliography-entry, imbib/eink-mirror, imbib/linked-file, imbib/tag-definition | rw | device, fs | static |
| `impress-bridges-service_get-item` | read_only | — | w | fs | dynamic |
| `impress-bridges-service_get-related` | read_only | — | rw | fs | dynamic |
| `impress-bridges-service_list-available-figures` | external | — | r | fs | dynamic |
| `impress-bridges-service_resolve-artifact` | read_only | conversation@1.0.0, imbib/bibliography-entry, imbib/library, imbib/tag-definition, manuscript, manuscript-section, task@1.0.0 | rw | fs, network, subprocess | static |
| `impress-bridges-service_search-all` | read_only | — | rw | fs | dynamic |
| `impress-bridges-service_sync-figure` | external | — | r | fs | dynamic |
| `impress-surface-service_surface-create` | mutating | collection, figure, figure-collection, imbib/collection, impress/ui/surface@1.0.0, manuscript, manuscript-collection | rw | network | static |
| `impress-surface-service_surface-delete` | destructive | — | w | — | dynamic |
| `impress-surface-service_surface-dispatch` | mutating | agent-run@1.0.0, chat-message, collection, email-message, figure, figure-collection, imbib/bibliography-entry, imbib/collection, imbib/eink-device, imbib/library, impress/artifact/code, impress/artifact/dataset, impress/artifact/general, impress/artifact/media, impress/artifact/note, impress/artifact/poster, impress/artifact/presentation, impress/artifact/webpage, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface-state@1.0.0, impress/ui/surface@1.0.0, manuscript, manuscript-collection, memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0, task@1.0.0 | rw | fs, subprocess | static |
| `impress-surface-service_surface-events` | read_only | imbib/eink-device, impress/ui/surface-event@1.0.0, impress/ui/surface@1.0.0 | rw | subprocess | static |
| `impress-surface-service_surface-examples` | read_only | — | — | — | none |
| `impress-surface-service_surface-get` | read_only | — | w | — | dynamic |
| `impress-surface-service_surface-list` | read_only | impress/ui/surface@1.0.0 | rw | — | static |
| `impress-surface-service_surface-render` | read_only | agent-run@1.0.0, chat-message, collection, email-message, figure, figure-collection, imbib/bibliography-entry, imbib/collection, imbib/eink-device, imbib/library, impress/artifact/code, impress/artifact/dataset, impress/artifact/general, impress/artifact/media, impress/artifact/note, impress/artifact/poster, impress/artifact/presentation, impress/artifact/webpage, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface-state@1.0.0, impress/ui/surface@1.0.0, manuscript, manuscript-collection, memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0, task@1.0.0 | rw | fs, subprocess | static |
| `impress-surface-service_surface-schema` | read_only | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0 | — | — | static |
| `impress-surface-service_surface-show` | mutating | agent-run@1.0.0, chat-message, collection, email-message, figure, figure-collection, imbib/bibliography-entry, imbib/collection, imbib/eink-device, imbib/library, impress/artifact/code, impress/artifact/dataset, impress/artifact/general, impress/artifact/media, impress/artifact/note, impress/artifact/poster, impress/artifact/presentation, impress/artifact/webpage, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface-state@1.0.0, impress/ui/surface@1.0.0, manuscript, manuscript-collection, memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0, task@1.0.0 | rw | fs, subprocess | static |
| `impress-surface-service_surface-state-get` | read_only | imbib/eink-device | rw | subprocess | static |
| `impress-surface-service_surface-state-set` | mutating | agent-run@1.0.0, chat-message, collection, email-message, figure, figure-collection, imbib/bibliography-entry, imbib/collection, imbib/eink-device, imbib/library, impress/artifact/code, impress/artifact/dataset, impress/artifact/general, impress/artifact/media, impress/artifact/note, impress/artifact/poster, impress/artifact/presentation, impress/artifact/webpage, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface-state@1.0.0, impress/ui/surface@1.0.0, manuscript, manuscript-collection, memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0, task@1.0.0 | rw | fs, subprocess | static |
| `impress-surface-service_surface-update` | mutating | core/operation, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface@1.0.0, manuscript-change@1.0.0, manuscript-revision, vw/command-receipt@1.0.0 | rw | fs, network | static |
| `impress-surface-service_surface-validate` | read_only | — | rw | subprocess | dynamic |
| `impress-surface-service_surface-wait` | read_only | imbib/eink-device, impress/ui/surface-event@1.0.0, impress/ui/surface@1.0.0 | rw | subprocess | static |
| `imprint-app-service_create-comment` | external | — | — | — | none |
| `imprint-app-service_create-document` | external | — | — | — | none |
| `imprint-app-service_delete-comment` | external | — | — | — | none |
| `imprint-app-service_delete-text` | external | — | — | — | none |
| `imprint-app-service_get-bibliography` | external | — | — | — | none |
| `imprint-app-service_get-content` | external | — | — | — | none |
| `imprint-app-service_get-logs` | external | — | — | — | none |
| `imprint-app-service_get-pdf` | external | — | — | — | none |
| `imprint-app-service_insert-text` | external | — | — | — | none |
| `imprint-app-service_list-comments` | external | — | — | — | none |
| `imprint-app-service_replace` | external | — | — | — | none |
| `imprint-app-service_status` | external | — | — | — | none |
| `imprint-app-service_update-comment` | external | — | — | — | none |
| `imprint-app-service_update-document` | external | — | — | — | none |
| `imprint-app-service_update-metadata` | external | — | — | — | none |
| `imprint-manuscript-service_compile-latex` | read_only | — | — | subprocess | reach-only |
| `imprint-manuscript-service_compile-typst` | mutating | — | rw | fs | dynamic |
| `imprint-manuscript-service_delete-section` | destructive | — | w | — | dynamic |
| `imprint-manuscript-service_document-citations` | read_only | — | — | — | none |
| `imprint-manuscript-service_document-outline` | read_only | — | — | — | none |
| `imprint-manuscript-service_export-document` | read_only | — | — | — | none |
| `imprint-manuscript-service_get-document` | read_only | — | r | — | dynamic |
| `imprint-manuscript-service_get-section` | read_only | — | r | fs | dynamic |
| `imprint-manuscript-service_list-documents` | read_only | — | r | device, network | dynamic |
| `imprint-manuscript-service_list-sections` | read_only | bibliography-entry, chat-message, manuscript-section | rw | — | static |
| `imprint-manuscript-service_presentation-outline` | read_only | — | rw | — | dynamic |
| `imprint-manuscript-service_put-section` | mutating | extraction-run@1.0.0, impress/ui/surface@1.0.0, manuscript-section | rw | fs | static |
| `imprint-manuscript-service_reorder-presentation-slide` | read_only | — | rw | — | dynamic |
| `imprint-manuscript-service_replace-in-section` | destructive | extraction-run@1.0.0, manuscript-section | rw | fs | static |
| `imprint-manuscript-service_search` | read_only | — | r | — | dynamic |
| `imprint-manuscript-service_search-in-text` | read_only | — | r | — | dynamic |
| `imprint-manuscript-service_set-presentation-slide-beat` | read_only | — | rw | — | dynamic |
| `imprint-project-service_project-build` | external | extraction-run@1.0.0, figure, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, manuscript, manuscript-build@1.0.0, manuscript-file@1.0.0 | rw | fs, network, subprocess | static |
| `imprint-project-service_project-build-output` | read_only | manuscript-build@1.0.0 | r | fs | static |
| `imprint-project-service_project-builds` | read_only | manuscript-build@1.0.0 | r | — | static |
| `imprint-project-service_project-checkin` | mutating | extraction-run@1.0.0, figure, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, manuscript, manuscript-change@1.0.0, manuscript-file@1.0.0 | rw | fs, network | static |
| `imprint-project-service_project-checkout` | destructive | manuscript | rw | fs, network | static |
| `imprint-project-service_project-citations` | read_only | manuscript, manuscript-file@1.0.0, watched-file@1.0.0 | rw | — | static |
| `imprint-project-service_project-collect` | mutating | imbib/bibliography-entry | w | — | static |
| `imprint-project-service_project-compile` | read_only | imbib/bibliography-entry, imbib/library, manuscript, manuscript-file@1.0.0, watched-file@1.0.0 | rw | fs | static |
| `imprint-project-service_project-delete-file` | destructive | manuscript-file@1.0.0 | w | — | static |
| `imprint-project-service_project-export` | destructive | — | rw | fs | dynamic |
| `imprint-project-service_project-figure-preview` | external | extraction-run@1.0.0, figure, manuscript, manuscript-file@1.0.0 | rw | fs, network, subprocess | static |
| `imprint-project-service_project-file` | read_only | manuscript, manuscript-file@1.0.0, watched-file@1.0.0 | rw | fs | static |
| `imprint-project-service_project-graph` | read_only | manuscript, manuscript-file@1.0.0, plot-spec, watched-file@1.0.0 | rw | — | static |
| `imprint-project-service_project-import-directory` | mutating | extraction-run@1.0.0, figure, imbib/tag-definition, manuscript, manuscript-change@1.0.0, manuscript-file@1.0.0 | rw | fs, network | static |
| `imprint-project-service_project-materialize` | mutating | — | rw | fs | dynamic |
| `imprint-project-service_project-move-file` | mutating | impress/ui/surface@1.0.0, manuscript, manuscript-file@1.0.0, watched-file@1.0.0 | rw | fs, network | static |
| `imprint-project-service_project-new-figure` | mutating | extraction-run@1.0.0, figure, manuscript, manuscript-file@1.0.0 | rw | fs, network | static |
| `imprint-project-service_project-outline` | read_only | manuscript, manuscript-file@1.0.0, watched-file@1.0.0 | rw | — | static |
| `imprint-project-service_project-put-file` | destructive | extraction-run@1.0.0, figure, impress/ui/surface@1.0.0, manuscript, manuscript-file@1.0.0 | rw | fs, network | static |
| `imprint-project-service_project-reading-list` | read_only | imbib/bibliography-entry | rw | — | static |
| `imprint-project-service_project-render-figure` | external | extraction-run@1.0.0, figure, manuscript, manuscript-file@1.0.0 | rw | fs, network, subprocess | static |
| `imprint-project-service_project-set-bibliography` | mutating | impress/ui/surface@1.0.0, manuscript-file@1.0.0 | rw | fs | static |
| `imprint-project-service_project-set-entry` | mutating | manuscript, manuscript-file@1.0.0 | rw | network | static |
| `imprint-project-service_project-set-figure-build` | mutating | impress/ui/surface@1.0.0, manuscript-file@1.0.0 | rw | fs | static |
| `imprint-project-service_project-set-targets` | mutating | manuscript, manuscript-file@1.0.0, plot-spec, watched-file@1.0.0 | rw | network | static |
| `imprint-project-service_project-snapshot` | mutating | extraction-run@1.0.0, impress/ui/surface@1.0.0, manuscript, manuscript-revision | rw | fs, network | static |
| `imprint-project-service_project-status` | read_only | manuscript | r | fs | static |
| `imprint-project-service_project-sync-reading-collection` | mutating | imbib/bibliography-entry, imbib/library | rw | — | static |
| `imprint-project-service_project-tree` | read_only | manuscript, manuscript-file@1.0.0, plot-spec, watched-file@1.0.0 | rw | — | static |
| `imprint-project-service_project-uncollect` | mutating | imbib/bibliography-entry | rw | — | static |
| `imprint-selftest-service_run-selftest` | external | figure, imbib/bibliography-entry, imbib/library, manuscript | rw | fs | static |
| `imprint-text-service_compose-citation` | read_only | — | — | — | none |
| `imprint-text-service_compose-heading` | read_only | — | — | — | none |
| `imprint-text-service_extract-cite-key-usages` | read_only | — | — | — | none |
| `imprint-text-service_extract-cite-keys` | read_only | — | w | — | dynamic |
| `imprint-text-service_format-latex` | read_only | — | — | — | none |
| `imprint-throughline-service_create-throughline` | mutating | throughline | rw | — | static |
| `imprint-throughline-service_delete-throughline` | destructive | — | rw | fs | dynamic |
| `imprint-throughline-service_get-anchor-states` | read_only | bibliography-entry, chat-message, manuscript-section | rw | — | static |
| `imprint-throughline-service_get-coverage` | read_only | bibliography-entry, chat-message, manuscript-section | rw | — | static |
| `imprint-throughline-service_get-throughline` | read_only | — | r | fs | dynamic |
| `imprint-throughline-service_mark-supporting` | mutating | throughline | rw | — | static |
| `imprint-throughline-service_remove-anchor` | mutating | throughline | rw | — | static |
| `imprint-throughline-service_set-anchor` | mutating | bibliography-entry, chat-message, manuscript-section, throughline | rw | — | static |
| `imprint-throughline-service_update-throughline-source` | destructive | throughline | rw | — | static |
| `layout-selftest-service_run-selftest` | external | collection | rw | network | static |
| `layout-service_apply-layout` | destructive | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0 | rw | fs | static |
| `layout-service_apply-preset` | destructive | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0 | rw | fs | static |
| `layout-service_bind-param` | mutating | — | rw | fs | dynamic |
| `layout-service_close` | mutating | — | rw | fs | dynamic |
| `layout-service_commit` | destructive | collection, figure, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface@1.0.0, manuscript | rw | fs | static |
| `layout-service_delete-layout` | destructive | impress/ui/layout@1.0.0 | rw | — | static |
| `layout-service_detach` | mutating | — | rw | fs | dynamic |
| `layout-service_focus` | mutating | — | rw | fs | dynamic |
| `layout-service_focus-direction` | mutating | — | rw | fs | dynamic |
| `layout-service_get-channel` | read_only | imbib/eink-device | rw | fs, network, subprocess | static |
| `layout-service_get-layout` | read_only | — | rw | — | dynamic |
| `layout-service_get-pane` | read_only | agent-run@1.0.0, chat-message, collection, core/operation, email-message, figure, figure-collection, imbib/bibliography-entry, imbib/collection, imbib/library, impress/artifact/code, impress/artifact/dataset, impress/artifact/general, impress/artifact/media, impress/artifact/note, impress/artifact/poster, impress/artifact/presentation, impress/artifact/webpage, impress/ui/surface@1.0.0, manuscript, manuscript-collection, task@1.0.0 | rw | — | static |
| `layout-service_list-layouts` | read_only | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0 | rw | fs | static |
| `layout-service_list-presets` | read_only | collection, figure, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, manuscript | rw | fs | static |
| `layout-service_maximize` | mutating | — | rw | fs | dynamic |
| `layout-service_move-tile` | mutating | — | rw | fs | dynamic |
| `layout-service_redo` | mutating | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface@1.0.0 | rw | fs | static |
| `layout-service_reset-preset` | destructive | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0 | rw | fs | static |
| `layout-service_resize` | mutating | — | rw | fs | dynamic |
| `layout-service_resolve-reference` | read_only | imbib/eink-device | rw | fs | static |
| `layout-service_restore` | mutating | — | rw | fs | dynamic |
| `layout-service_save-layout` | destructive | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0 | rw | — | static |
| `layout-service_save-preset` | destructive | collection, core/operation, figure, imbib/eink-device, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, manuscript, manuscript-change@1.0.0, manuscript-revision | rw | fs | static |
| `layout-service_select` | mutating | — | rw | fs | dynamic |
| `layout-service_set-channel` | mutating | — | rw | fs | dynamic |
| `layout-service_set-collapsed` | mutating | — | rw | fs | dynamic |
| `layout-service_set-container-kind` | mutating | — | rw | fs | dynamic |
| `layout-service_set-default-channel` | mutating | — | rw | fs | dynamic |
| `layout-service_set-pane` | mutating | — | rw | fs | dynamic |
| `layout-service_set-query` | mutating | — | rw | fs | dynamic |
| `layout-service_set-role` | mutating | — | rw | fs | dynamic |
| `layout-service_set-view-kind` | mutating | — | rw | fs | dynamic |
| `layout-service_set-window-geometry` | mutating | — | rw | fs | dynamic |
| `layout-service_split` | mutating | — | rw | fs | dynamic |
| `layout-service_swap` | mutating | — | rw | fs | dynamic |
| `layout-service_undo` | mutating | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, impress/ui/surface@1.0.0 | rw | fs | static |
| `manuscript-collab-service_commit-manuscript-body` | mutating | manuscript, manuscript-change@1.0.0, manuscript-file@1.0.0 | rw | fs | static |
| `manuscript-collab-service_manuscript-change-history` | read_only | manuscript, manuscript-change@1.0.0, manuscript-file@1.0.0 | rw | fs | static |
| `manuscript-collab-service_manuscript-heads` | read_only | manuscript, manuscript-change@1.0.0, manuscript-file@1.0.0 | rw | fs | static |
| `manuscript-collab-service_manuscript-text-at` | read_only | manuscript, manuscript-change@1.0.0, manuscript-file@1.0.0 | rw | fs | static |
| `memory-service_confirm-claim` | mutating | core/operation, manuscript-change@1.0.0, manuscript-revision, memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0 | w | fs | static |
| `memory-service_forget` | destructive | citation-usage, core/operation, manuscript-change@1.0.0, manuscript-revision, memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0 | w | fs | static |
| `memory-service_memory-brief` | read_only | memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0 | rw | — | static |
| `memory-service_memory-status` | read_only | memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0 | r | — | static |
| `memory-service_recall` | read_only | memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0 | rw | — | static |
| `memory-service_remember` | mutating | memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0 | rw | — | static |
| `memory-service_supersede-claim` | mutating | core/operation, manuscript-change@1.0.0, manuscript-revision, memory/claim@1.0.0, memory/episode@1.0.0, memory/instruction@1.0.0 | w | fs | static |
| `parsers-service_decode-mime-header` | read_only | — | — | — | none |
| `parsers-service_decode-quoted-printable` | read_only | — | — | — | none |
| `parsers-service_extract-landing-page-pdf` | read_only | — | — | — | none |
| `parsers-service_list-publisher-rules` | read_only | — | — | — | none |
| `parsers-service_parse-mbox` | read_only | — | rw | — | dynamic |
| `parsers-service_resolve-publisher-pdf` | read_only | — | — | network | reach-only |
| `smart-search-service_build-ads-query` | read_only | — | rw | — | dynamic |
| `smart-search-service_classify-search-input` | read_only | — | r | network, subprocess | dynamic |
| `smart-search-service_clean-ads-query` | read_only | — | r | — | dynamic |
| `smart-search-service_extract-page-identifiers` | read_only | — | rw | fs, network | dynamic |
| `smart-search-service_free-text-extraction-prompt` | read_only | — | — | — | none |
| `smart-search-service_normalize-ads-query` | read_only | — | — | — | none |
| `smart-search-service_reference-parse-prompt` | read_only | — | — | — | none |
| `smart-search-service_rewrite-free-text-query` | read_only | — | — | — | none |
| `smart-search-service_split-reference-blocks` | read_only | — | — | — | none |
| `smart-search-service_validate-parsed-reference` | read_only | — | r | network | dynamic |
| `source-service_get-citation` | read_only | figure-region@1.0.0, source-citation@1.0.0 | rw | — | static |
| `source-service_get-content-chunk` | read_only | content-chunk@1.0.0, figure-region@1.0.0 | rw | — | static |
| `source-service_get-figure-image` | external | collection, content-chunk@1.0.0, extraction-run@1.0.0, figure, figure-collection, figure-region@1.0.0, imbib/collection, manuscript, manuscript-collection, source-citation@1.0.0 | rw | fs, subprocess | static |
| `source-service_get-page-image` | external | content-chunk@1.0.0, extraction-run@1.0.0, figure-region@1.0.0, source-citation@1.0.0 | rw | fs, subprocess | static |
| `source-service_put-citation` | mutating | collection, extraction-run@1.0.0, figure, figure-collection, imbib/collection, impress/ui/surface@1.0.0, manuscript, manuscript-collection, source-citation@1.0.0 | rw | fs | static |
| `source-service_put-content-chunk` | mutating | collection, content-chunk@1.0.0, extraction-run@1.0.0, figure, figure-collection, imbib/collection, impress/ui/surface@1.0.0, manuscript, manuscript-collection, source-citation@1.0.0 | rw | fs | static |
| `source-service_put-extraction-run` | mutating | collection, extraction-run@1.0.0, figure, figure-collection, imbib/collection, impress/ui/surface@1.0.0, manuscript, manuscript-collection | rw | fs | static |
| `source-service_put-figure-region` | mutating | collection, extraction-run@1.0.0, figure, figure-collection, figure-region@1.0.0, imbib/collection, impress/ui/surface@1.0.0, manuscript, manuscript-collection | rw | fs | static |
| `source-service_search-content-chunks` | read_only | content-chunk@1.0.0, figure-region@1.0.0 | rw | — | static |
| `store-query-service_get-item` | read_only | — | — | — | none |
| `store-query-service_list-items` | read_only | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0 | rw | — | static |
| `store-query-service_related-items` | read_only | email-message, figure, imbib/bibliography-entry, impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, manuscript | rw | — | static |
| `store-query-service_search-all` | read_only | — | r | network, subprocess | dynamic |
| `surface-demo-service_histogram` | read_only | — | rw | — | dynamic |
| `surface-demo-service_series` | read_only | — | rw | — | dynamic |
| `surface-selftest-service_run-selftest` | external | collection | rw | network | static |
| `triage-service_add-tag` | mutating | impress/ui/surface@1.0.0 | rw | fs | static |
| `triage-service_remove-tag` | mutating | impress/ui/surface@1.0.0 | rw | fs | static |
| `triage-service_set-flag` | mutating | impress/ui/surface@1.0.0 | rw | fs | static |
| `triage-service_set-starred` | mutating | impress/ui/surface@1.0.0 | rw | fs | static |
| `triage-service_set-status` | mutating | impress/ui/surface@1.0.0 | rw | fs | static |
| `vw-diagnostic-service_close-session` | mutating | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, vw/command-receipt@1.0.0, vw/measurement@1.0.0, vw/observation@1.0.0, vw/procedure-run@1.0.0 | rw | — | static |
| `vw-diagnostic-service_create-session` | mutating | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, vw/command-receipt@1.0.0, vw/configuration@1.0.0, vw/diagnostic-session@1.0.0, vw/measurement@1.0.0, vw/observation@1.0.0, vw/procedure-run@1.0.0, vw/vehicle@1.0.0 | rw | fs | static |
| `vw-diagnostic-service_evaluate-session` | read_only | — | rw | — | dynamic |
| `vw-diagnostic-service_get-capabilities` | read_only | — | rw | — | dynamic |
| `vw-diagnostic-service_get-photo` | read_only | — | — | — | none |
| `vw-diagnostic-service_get-session` | read_only | — | — | — | none |
| `vw-diagnostic-service_ingest-photo` | external | content-blob@1.0.0, extraction-run@1.0.0, imbib/linked-file, impress/artifact/media, vw/photo-evidence@1.0.0 | rw | fs | static |
| `vw-diagnostic-service_list-applicable-procedures` | read_only | — | rw | — | dynamic |
| `vw-diagnostic-service_list-sessions` | read_only | vw/diagnostic-session@1.0.0 | r | — | static |
| `vw-diagnostic-service_recommend-next-test` | read_only | — | rw | — | dynamic |
| `vw-diagnostic-service_record-measurement` | mutating | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, vw/command-receipt@1.0.0, vw/measurement@1.0.0, vw/observation@1.0.0, vw/procedure-run@1.0.0 | rw | — | static |
| `vw-diagnostic-service_record-observation` | mutating | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, vw/command-receipt@1.0.0, vw/measurement@1.0.0, vw/observation@1.0.0, vw/procedure-run@1.0.0 | rw | — | static |
| `vw-diagnostic-service_record-procedure-step` | mutating | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, vw/command-receipt@1.0.0, vw/measurement@1.0.0, vw/observation@1.0.0, vw/procedure-run@1.0.0 | rw | — | static |
| `vw-diagnostic-service_search-photos` | read_only | — | r | — | dynamic |
| `vw-diagnostic-service_start-procedure` | mutating | impress/ui/layout@1.0.0, impress/ui/preset@1.0.0, vw/command-receipt@1.0.0, vw/measurement@1.0.0, vw/observation@1.0.0, vw/procedure-run@1.0.0 | rw | — | static |

## Appendix B — every Tier B entry, and what a scenario needs to express it

Legend: **M** mutates, **C** cleans up, **L** asserts on rendering by polling `GET /api/logs?category=layout&after=`
(`layout tier_b.rs:1395-1426`). Class: (i) calls and assertions only; (ii) a human/GUI event; (iii) app
state a verb could set; (iv) platform. "Needs" names the scenario-format feature the entry requires
beyond a plain `call` step.

| # | Id (file:line) | Calls, in order | Asserts | M/C | Class | Needs |
|---|---|---|---|---|---|---|
| 1 | imprint `app.reachable` (`tier_b.rs:93`) | `GET /api/status` (the probe that gates the tier, `:35`) | responds | — | i | `requires.app` |
| 2 | imprint `app.list_documents` (`:109`) | `GET /api/documents` | 2xx, decodes | — | i | — |
| 3 | imprint `app.cross_doc_search` (`:124`) | `GET /api/search?q=the&limit=5` | responds | — | i | — |
| 4 | imprint `app.compile_pdf` (`:276`) | `POST /api/compile/typst` with an inline source | PDF bytes > 0 (a decode error is a skip) | — | i | `len` on a binary result |
| 5 | imprint `throughline.opt_in_live` (`:315`) | three `GET …/throughline`, `…/anchors`, `…/coverage` on a random doc id | all 404 | — | i | `{{uuid}}`, `status` |
| 6 | imprint `throughline.live_round_trip` (`:344`) | `POST …/throughline`, `GET …/anchors`, `PATCH …/anchors {mark-supporting}`, `DELETE …/throughline`, `GET …/throughline` | `has_throughline`, anchor states `["synced"]`, delete true, then 404 | M, C | i | `capture`, `teardown` |
| 7 | imprint `manuscripts.detail_and_history` (`:211`) | `GET /api/manuscripts`; per row `GET …/{id}`; first 3: `…/history`, `…/revisions` | every row's `store_detail_found` | — | iii | `each` over a captured list; `requires.kinds_present` (skip when none) |
| 8 | imprint `store.wal_health` (`:156`) | `GET http://127.0.0.1:8787/api/health` (impress-ai-http) | `wal_bytes ≤ 4 × wal_budget_bytes` | — | iv | another daemon; stays code |
| 9 | layout `app.reachable` (`tier_b.rs:427`) | `GET /api/status`; setup `POST /api/layout/op {save-layout RESTORE}` (`:441`) | responds | M | i | `seed`-like setup step |
| 10 | layout `layout.apply_preset` (`:480`) | `op apply-layout ordinal 1`; `GET /api/layout/tree` | `version` present, panes non-empty | M | i | — |
| 11 | layout `layout.version_moves` (`:512`) | tree; `verb split` on `{role: detail}`; tree; `verb resize` with shares read from the tree; `swap list/detail`; swap back; `close` | `version` strictly increases at each step | M, C | i | `capture` from the tree, `gte` on a captured value, a computed shares array (the one step that is not a literal) |
| 12 | layout `layout.saved_round_trip` (`:601`) | `op save-layout`; `GET /api/layout/layouts`; `op apply-layout name`; `op delete-layout`; `GET layouts` | listed, then `version`, then gone | M, C | i | `capture`, `contains`/`absent` |
| 13 | layout `layout.channel_selection` (`:660`) | tree; find the detail param sourced from a channel; `verb select` on the list with a fresh uuid; tree | that channel carries exactly `[uuid]` | M | i | a JSON-path lookup into the tree, `{{uuid}}` |
| 14 | layout `surface.show_and_dispatch` (`tier_b.rs`) | stored scenario: create; render; dispatch `bins` change 17; render and state reread; dispatch `choose` click; events; required delete teardown | initial/re-rendered slider values 4/17; persisted state 17; successful effect; event `bins-chosen` payload 17 | M, C | i | `{{!…}}` literal escape, `capture`, exact render JSON path |
| 15 | layout `layout.hidden_share` (`:1599`) | tree; `verb set-collapsed {role navigator}`; tree; same again; tree | share ≤ `HIDDEN_SHARE_CEILING`, then back within 1e-4 | M, C | i | `within` tolerance; a Rust constant → a literal in the document |
| 16 | layout `layout.outline_collection_row` (`:762`) | tree; **in-process `outline_target` + `outline_verbs`** (what a click runs); POST each; tree; `wait_for_log "pane N display: 0 rows"`; `verb select` random item; wait for the detail line | list query = collection query; channel 1 carries the collection; the logs appear | M | ii | `gesture` step; `wait.log`. L |
| 17 | layout `layout.reading_pdf_pane` (`:978`) | `apply-layout ordinal 1`; tree; `split` a pdf pane; `set-query` read filter; **`first_row_of` reads the shared store in-process** (`:1331-1362`); `select`; wait for `pane N pdf: publication`; `close` | the pdf pane logged the selected paper (note if none) | M, C | iv (+iii) | a read paper with a PDF on disk; depends on #16's leftovers (`:981`). L |
| 18 | layout `layout.source_pane_session` (`:1173`) | ordinal 1; split a source pane; tree; wait `source session <id> opened`; split a copy; split pdf; swap; close all newest-first; ordinal 1 | sessions stable and distinct; pdf has none; preset keeps the detail session | M, C | i | `wait.log`, `capture`. L |
| 19 | layout `layout.reading_preset` (`:913`) | `GET /api/status` (passes if not impress); `op apply-layout name Reading`; tree; `set-query`; `first_row_of` (direct store read, missing row **fails**); select; wait | detail pane is `pdf`; the log names the paper | M | iv (+iii) | `requires.app: impress`; a paper with a PDF. L |
| 20 | layout `layout.console_pane` (`tier_b.rs`) | apply ordinal 1; capture server log cursor; split console after detail with `view_state`; read tree; bounded fresh log wait; required close teardown | exact `view_state` round-trips; one new `layout` message contains pane id, search and level summaries (case-insensitive) | M, C | i | capture-aware `wait.log`, `log_cursor` and gesture-result capture. L |
| 21 | layout `layout.wire_contract` (`:1642`) | tree; raw `POST verb` with an unknown field; `focus` another pane; raw `close` with a stale `expected_revision`; tree; raw `set-view-kind editor` | `wire_version == 1`, no camelCase; 400 `invalid-argument` naming `targett`; 409 `conflict`, revision unchanged; 422 `unknown-view-kind` | M | i | `status`, `code`, `message contains` |
| 22 | layout `layout.restored` (`:1738`) | `op apply-layout name RESTORE`; `op delete-layout RESTORE` | no errors | C | i | catalogue-level restoration still closes over whether the live layout was parked |
| 23 | surface `surface.http.routes` (`tier_b.rs:152`) | `POST /api/surface`; 12 table steps (list, schema, examples, validate, get, render, state, put state, dispatch click, events, wait, put `?expected_revision=1`); events; DELETE | each 200 with `wire_version: 1` and its key; event `chosen`; delete ok | M, C | i | already a table (`:168-211`) |
| 24 | surface `surface.http.strict` (`:250`) | 3 raw calls against a nil uuid (`show` retired target, `events?after=`, `render?pane=`) | 400 `invalid-argument` naming the field | — | i | `status`, `message contains` |
| 25 | surface `surface.http.invalid_spec` (`:286`) | `POST /api/surface` with an invalid spec; `GET /api/surface` | 422 `invalid-spec` with problems; not stored | — | i | `status`, `absent` |

Counts: (i) 20, (ii) 1, (iii) 1, (iv) 3. Beyond a plain call the format needs: `capture` and JSON-path
expectations (11 entries), `{{uuid}}` (3), `status`/`code` (4), `within` (1), `each` over a captured
list (1), `wait.log` (5), `gesture` (1), `requires` with skip (3), `teardown` (4 + the catalogue's).
Every one of these is in § Scenarios' closed set; nothing needs an expression.

`wait.log` accepts `contains` plus optional `also_contains` needles (all required
on one message, case-insensitive), an optional capture-templated `after` cursor,
and a 1–60,000 ms timeout. A preceding
`{"wait":{"log_cursor":{"capture":"before"}}}` reads the server's
`nextCursor` from `/api/logs/stream` and captures it before the mutation; later
waits use `"after":"{{state.before}}"`. `gesture.capture` is a dotted JSON-path
map, matching call-step capture, so a split result can be named for required
per-scenario cleanup without evaluating expressions.

## Session log (append-only)

- 2026-09-26 — Planned on a worktree of main at 60833ea1, branch `claude/plan-self-reflective-layer`,
  after reading ADR-0034/0035 and both plans, and the in-flight P1 (bdddeb14: `VerbDescriptor`,
  `MethodMeta`, `#[impress_method(safety, idempotent)]`, `#[impress_example]`, `docs/verb-safety.md`
  with 433 rows) and P4 (87f4b9c4: `impress-core/src/job.rs`, `task-event@1.0.0`, five `job_*` verbs)
  branches. Measured: the static effects walker over all 433 verbs (three runs — the first two had
  a brace-matching and a same-crate-first resolution bug, caught by checking
  `triage-service_set-starred` and `imbib-library-service_list-publications` by hand against
  `triage_ops.rs:41` and `store_api.rs:1073-1088`); the operation log's schema, writers, `batch_id`
  sites, compaction and the 0238eb0a backlog (subagent; re-checked: `idx_items_op_target` at
  `sqlite_store.rs:866`, `apply_operation` at `:1994`, the commit and its `23.0M` comment); the 31
  background services and the task model (subagent; re-checked: `performAutomatic` in 9 files,
  `RetentionCleanupService.swift:54`, the ungated cleanup at `imbibApp.swift:580`); the three
  catalogues (subagent; re-checked: 8 + 14 + 3 Tier B ids by string literal, 25 + 39 + 15 `cap_*`
  Tier A functions); settings keys and chords (subagents; re-checked: 79 files / 303 raw
  `keyboardShortcut` hits → 77 / 299 after the four comment lines, 16 raw `keyboardGuarded` hits →
  14 sites after the definition and a comment, 122 `@AppStorage` declarations and 83 distinct
  literal keys against the census's 87 resolved, 51 `register(` lines in `CommandRegistry.swift`
  against 50 calls, `import ImpressCommandPalette` in 0 files outside the package, the collision
  test at `PaneLayoutCommandsTests.swift:260`). The brief's 39-file, 81-file, 86/85-key and
  467-verb figures did not reproduce and the tables say what does. No production code; the walker
  and its JSON stay in the session scratchpad (appendix A is its output). ADR-0036 written as the
  decision record; draft PR opened; **stopped before Phase 2** as the brief requires.

- 2026-09-26 — R1 (settings registry) finished on `claude/reflective-r1-settings`, worktree
  `.claude/worktrees/r1-settings`. Merged origin/main (only conflict: `Cargo.lock`, regenerated
  with `cargo generate-lockfile`); `cargo hakari manage-deps` added `impress-workspace-hack` to
  `impress-fs-lock` and `impress-settings`, `cargo hakari generate` picked up main's hakari-config
  change, `cargo hakari verify`'s remaining `cc` feature-set diagnostic was reproduced against a
  clean checkout of origin/main and left alone as pre-existing. RG-1..3 confirmed against the
  registry: retention's three keys and automation's five keys are each `setting!`'d once in
  `crates/impress-settings/src/registry.rs` with their legacy `UserDefaults` spellings; D-R5 is
  proved on both sides — `impress_settings::store::tests::legacy_import_runs_once_and_never_overrides`
  in Rust and `SettingsRegistryTests.testLegacyValueIsCopiedOnFirstReadAndNeverRemoved` in
  ImpressKit, neither of which deletes the old key. `impress/settings@1.0.0` is in
  `schema-refs.json`; `docs/verb-coverage.md`, `docs/verb-safety.md`, `docs/kit-manifest.md`
  (`impress-fs-lock` row) and `docs/chassis-capability-matrix.md` (the Retention pane) already
  carried their rows from the prior session. Chords are R2's, untouched here. Two clippy lints
  from the merged lint set fixed (`contains_key` over `get().is_none()` in a settings-store test;
  `std::slice::from_ref` over a needless clone in the surface writer's tag slice) — everything
  else was clean. Gates, serial, `CARGO_TARGET_DIR=target-r1`: fmt, clippy rest, clippy imprint,
  `check-uniffi-bindings.sh` (7/7 match, no export changed so no regeneration needed),
  `check-schema-refs.sh` (390 call sites, 0 divergences), `check-kit-deps.sh --strict`,
  `check-kit-standalone.sh`, `check-kit-packages.sh`, `check-chassis-deps.sh`,
  `check-verb-coverage.sh` all green; `cargo test -p impress-fs-lock -p impress-settings
  -p impress-store-service -p impress-ai -p impress-store-ffi -p impress-capabilities`: 323 passed,
  0 failed; `swift test` in ImpressLayout (79 passed), ImpressKit (13 XCTest + 30 swift-testing,
  0 failed — includes the D-R5 proof above), and PublicationManagerCore (2159 passed, 2 skipped,
  0 failed). Live proof and the push/PR are recorded separately in the same session's report to
  the R1 dispatcher.

- 2026-09-26 (addendum) — the pre-push hook's dual-platform gate (ADR-023 Rule 1) caught a real
  bug the tests above did not: `SettingsSurfacePane.swift` imported `ImpressLayout` unconditionally,
  but `PublicationManagerCore/Package.swift` links it macOS-only, so imbib-iOS could not resolve
  the module. Fixed by keeping the macOS body (unchanged, still `ImpressLayout.SurfacePaneModel`)
  and giving iOS a named `ContentUnavailableView` placeholder rather than a second, kit-only copy
  of the render/dispatch model — that copy would have needed its own `SharedSurface` /
  `SharedSurfaceChange` `Sendable` conformances, which `ImpressLayout` already declares
  retroactively, so a second declaration in `PublicationManagerCore` would collide at link time
  once both modules share the macOS binary (caught and backed out before committing). iOS support
  for the generated Retention pane is R1 follow-up, not silently dropped — see table RG-S.
  Re-verified: PMC `swift build` (macOS) clean, the pre-push hook's exact iOS command (`xcodebuild
  build -scheme imbib-iOS -destination 'generic/platform=iOS Simulator' ARCHS=arm64
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`) now succeeds, and PMC
  `swift test` is still 2159 passed / 2 skipped / 0 failed.
- 2026-09-26 — **P2 pipeline landed** (branch `claude/pipeline-p2-pipeline`, from main at c0277c7e;
  see plan-verb-pipeline-and-transport.md's session log for the full account). Hooks H-P2-1..4 all
  landed as this plan describes them: H-P2-1 (`Call { args, caller, trace, parent }` with the
  pipeline generating the trace id when absent), H-P2-2 (`impress_core::call_context::CURRENT` set
  around invoke, `batch_id = call_id` stamped on every operation the call writes), H-P2-3
  (`Pipeline::invoke_on(store, …)`, the per-call store override — used here by the bench and by the
  live audit proof, not yet by a Tier A scenario since S1 hasn't landed), H-P2-4 (the audit layer
  writes one `core/verb-call@1.0.0` record per mutating call instead of a bare `core/operation`
  row). Found and fixed live, not anticipated by this plan: the audit sink's own `flush()` (H-P2-2's
  writer) was never called by `impress-cli`/`imprint-cli` before `std::process::exit`, so a one-shot
  CLI process could race the writer thread and drop its own verb-call row; both binaries now flush
  before exit.
- 2026-09-26 — **E1 (declared effects)** on a worktree of main at d029648d, branch
  `claude/reflective-e1-effects`. `VerbDescriptor.effects: Effects { reads, writes, reach }` with
  `Kind = Ref | Target(arg) | Children(arg) | Prefix | Any(reason)` and `Reach = App(id) | Network |
  Fs | Subprocess | Device | Provider` (`impress-service-core/src/descriptor.rs`, `resolve_effects`
  beside `resolve_safety_class`); declared as `impress_service_impl! { effects = { reads: […],
  writes: […], reach: […] } }` with `#[impress_method(effects(…))]` replacing the whole set per
  method, and `#[impress_private]` on a `methods = […]` argument → `"x-private": true` in the input
  schema (H-P1-1, H-P1-2). The macro embeds `schema-refs.json` at build time (`build.rs`), so a
  misspelt ref is a compile error; the standalone kit scratch has no manifest and skips the check
  there, and the Tier A test re-checks every ref. Seeding pass from appendix A read against the
  services: **438 of 438** verbs declared (P4's five `job-*` verbs joined since the appendix), 38
  service defaults, 231 method exceptions. The walker's over-approximations were not carried over
  (`triage-service` writes `target(id)`, not the surface kind; the 25 layout verbs the walker
  called dynamic touch `impress/ui/layout@1.0.0`). `App(id)` reach is declared, not derived: P1
  made no `needs_app` derivation the macro could read. The store spy is
  `impress_core::effects_spy` (feature `effects-spy`, hooks on `get`/`query`/`count`/`neighbors`
  and `emit_mutation`), process-wide because the services reach the store through singletons.
  `crates/impress-capabilities/tests/effects.rs` runs every headless verb's examples and the three
  Tier A catalogues under it: **70 verbs verified by example** (a first batch of 70 examples on
  headless verbs — G3 adds more), **93 by catalogue** (service-level union for layout, surface and
  the four imprint services, since the catalogues call the traits directly), **275 on the exception
  table** (85 `needs a running app`, 20 `leaves the process`, 170 `no example`), ceiling pinned at
  275. `docs/verb-effects.md` is the marker table (rows and reasons written by the test);
  `check-verb-coverage.sh` checks the source-only half. The safety-consistency check lives in the
  same test (`read_only ⇒ writes = ∅`; reach beyond `fs` ⇔ `external`, allowlist of two read-only
  verbs with P1's evidence). **The spy's first run found three things the declarations and P1's
  table had wrong:** `list-libraries` also reads the entries; `layout-service_get-layout` writes the
  live row on a cold device and `list-layouts` seeds the shipped presets — both reclassed
  `mutating` (idempotent) in `docs/verb-safety.md` with the evidence; `project-build` runs as a
  job and touches `task@1.0.0`/`task-event@1.0.0`. Not done here, by the package split: the surface
  `verb`-source invalidation (RS-S2, `query_refs`) and `capabilities-service_impact` are E3's;
  per-verb attribution for the catalogues waits for the call log (L1). Gates (serial,
  `CARGO_TARGET_DIR=target-e1`): fmt clean; `clippy rest` and `clippy imprint` clean;
  `cargo test --workspace --features native` **4064 passed, 0 failed** (the effects-spy feature
  is an unconditional dev-dependency of `impress-capabilities`, so `tests/effects.rs` ran in that
  total — no separate spy invocation needed); `check-verb-coverage.sh` OK (38 services declare,
  438 verbs in `docs/verb-effects.md`, 275 exceptions; 75 crates with a verdict, 20
  `should-be-verb` at the ceiling); `check-kit-deps.sh --strict` OK; `check-kit-standalone.sh` OK
  (14 crates); `check-schema-refs.sh` OK (388 call sites, 81 canonical refs, 0 divergences);
  `check-uniffi-bindings.sh` OK, 7 bindings unchanged (no export moved); `cargo hakari generate`
  found nothing to regenerate, but `cargo hakari verify` still fails on a `cc` crate feature-set
  mismatch (`impress-workspace-hack` built with `parallel` vs. a fixup pass with no features) —
  pre-existing build-graph variance this branch's diff does not touch (no `Cargo.toml` dependency
  edits), not fixed here.
- 2026-09-26 — **R2 (keymap registry)**, Rust half, on a worktree of main, branch
  `claude/reflective-r2-keymap`. New pure crate `crates/impress-keymap`: `Chord` (a key plus
  ⌃/⌥/⇧/⌘, `Display` round-tripping the grammar's glyph spelling), `Scope` (`Global` /
  `Window(kind)` / `Pane(view_kind)`), `Target` (`Verb(name)` | `Command(id)`), `Binding` (chord +
  scope + target + label + section + `chordless`), declared as a plain Rust table
  (`imbib::bindings()`) rather than a macro or a data file — the plan named `keymap! { … }` but a
  bindings-returning function reads the same and needed no proc-macro crate for one app's seed.
  `keymap_json()` (`{"wire_version": 1, "bindings": [...]}`) is exported by `impress-store-ffi`
  next to `layout_vocabulary_json`; `docs/keyboard.md` is generated from the same registry
  (`render_markdown`) and a test fails on a diff (regenerate with
  `cargo test -p impress-keymap write_docs -- --ignored`). **66 chords seeded**, all of imbib's
  macOS main-window `Commands` (`imbibApp.swift`) plus the three universal pane toggles
  (`PaneLayoutCommands.swift`) and the two Notes/BibTeX-detached ⌘S saves
  (`DetachedViews.swift`); iOS and sheet-local `.cancelAction`/`.defaultAction` shortcuts were not
  seeded (out of scope for this pass — the plan's own DoD names imbib's sites, not iOS's). Collected
  with `grep -rn "keyboardShortcut(" apps/imbib packages/ --include="*.swift"` (152 raw hits, most
  sheet-local). RG-4's three disagreements, each decided per `docs/keyboard-grammar.md` and recorded
  in a comment beside the binding:
  - **⌃⌘S** is the sidebar toggle, only (`imbib.pane.toggle_sidebar`) — Paper ▸ Save to Library lost
    its ⌃⌘S in the 2026-09-24 fix already in `imbibApp.swift` and is seeded `chordless: true`, a
    palette-only `Command`, per the doc's account of that fix.
  - **⌘5 / ⌘6** are Notes / BibTeX — already correct in the current source (the swap the plan named
    was fixed before this pass; the seed just confirms it and would fail loudly if it regressed).
  - **⇧⌘F ×3**: Paper ▸ Share... (`imbibApp.swift`, the 2026-09-25 decision) is seeded; two other
    claimants in the same main-window scope — `ContentView.swift`'s hidden "Filter" button and
    `FindCoordinator.swift`'s "Find" — are recorded as superseded in a comment rather than seeded a
    second time, since seeding both would just be the fixture's collision with no decision made.
  - **⌘S ×2**: Edit ▸ Find ▸ "Smart Search (AI)..." owns plain ⌘S in the main window;
    `DetachedViews.swift`'s two ⌘S "Save" bindings (Notes-detached, BibTeX-detached) are a separate
    `Scope::Window("imbib.detached-content")` and do not collide — verified by the coverage test's
    same-scope-only collision rule.
  Coverage: the crate's own tests cover no-duplicate-chord-in-a-colliding-scope, chordless ⇒
  `Command` (never a bare `Verb`), `keymap_json` round-trips, and a fixture with a duplicated chord
  the same check rejects (`fixture_tests`, never added to `all()`). The verb-existence half (a
  `Target::Verb` must name a verb in the linked inventory) lives in
  `crates/impress-capabilities/tests/keymap_coverage.rs` instead, so `impress-keymap` keeps no
  dependency on `impress-service-core`'s descriptor machinery (RG-6) — none of imbib's seeded
  bindings are `Verb` targets, so this test is presently vacuous but wired for the first app that
  binds a chord straight to a verb. `docs/verb-coverage.md` gets a `kit-pure`/`internal` row for
  the new crate; `docs/kit-manifest.md` gets a `pure`-tier row (it must: `impress-store-ffi`, a kit
  crate, now links it to export `keymap_json`, so `check-kit-deps.sh --strict` would otherwise see
  a kit crate reaching outside the table). FFI: `impress-store-ffi::keymap_json` is a thin
  pass-through (the JSON string travels as-is, no `encode_static` re-encoding); the xcframework
  rebuilt with `IMPRESS_SKIP_X86=1` and `uniffi-bindgen` (swiftformat off `PATH`) produced a pure
  addition to `ImpressRustCore/Sources/ImpressRustCore/impress_store_ffi.swift` — one function, one
  checksum guard, zero declarations moved or lost. No Swift call site added in this pass (scope was
  deliberately Rust-only); Settings ▸ Keyboard reading the registry is Swift work for a later pass.
  **A concurrency lesson worth keeping:** the xcframework build was started twice by mistake (an
  untracked `nohup` background job, then a second one through the proper backgrounding tool) and
  the two collided on `crates/impress-store-ffi/frameworks/` — one's `rm -rf` deleted the other's
  in-progress output, and the second reported `cp: …/libimpress_store_ffi.a: No such file or
  directory` and exit 1 while the first finished cleanly seconds later with the binding it produced
  intact. Never start the same build twice against the same output directory, even by accident;
  when one does, read past the failing invocation's log to confirm whether a sibling run actually
  finished before treating the directory as broken.
  Gates (serial, `CARGO_TARGET_DIR=target-r2`): `rust-gate.sh fmt` clean; `clippy rest` clean;
  `clippy imprint` clean; `cargo test -p impress-keymap -p impress-store-ffi -p impress-capabilities`
  — 99 passed in `impress-store-ffi` (2 pre-existing, unrelated `surface.rs` timing failures under
  this machine's concurrent-agent load — confirmed by `git diff --stat` showing `surface.rs`
  untouched by this branch), 6 passed in `impress-keymap`, 1 passed in the new
  `keymap_coverage.rs`; `check-uniffi-bindings.sh` OK, 7 bindings (1 changed: `impress-store-ffi`,
  a pure addition); `check-kit-deps.sh --strict` OK (15 kit crates, `impress-keymap` now among
  them); `check-kit-standalone.sh --strict` OK (15 crates build with nothing else from this
  repository); `check-verb-coverage.sh` OK (76 crates with a verdict, 20 `should-be-verb` at the
  ceiling, unchanged); `check-schema-refs.sh` OK (388 call sites, 0 divergences, unaffected);
  `cargo hakari generate --diff` clean.
- 2026-09-26 — **E2 (the spy)** on a worktree of main at 95335f75, branch `claude/reflective-e2-spy`.
  Read E1 first: it had already built the row's whole shape — `impress_core::effects_spy` (feature
  `effects-spy`, hooks on `get`/`query`/`count`/`neighbors`/`emit_mutation`), the Tier A runner in
  `crates/impress-capabilities/tests/effects.rs` (`run_examples`/`run_catalogue`/`verification`)
  asserting `observed ⊆ declared` for every headless verb's examples and the three Tier A
  catalogues, the printed under-exercised table, and a *Verified* column in `docs/verb-effects.md`
  the test computes and refuses to let drift from a hand-typed value (`every_verb_declares_what_the_table_records`).
  **Kept the spy at `crates/impress-core/src/effects_spy.rs`**, not moved to `store/spy.rs` as the
  plan's path names it: it is already wired into five call sites in `sqlite_store.rs` and is a
  top-level module of `impress-core` (there is no `store/` submodule to move it into without
  churning those call sites for no behavioural change), so this is a location the plan's text
  didn't quite match, not a gap E2 needed to fill.
  **What E2 did add:** two examples (`imbib-library-service_query-unread`,
  `_query-starred`, `#[impress_example(args = "{parent_id: null, sort_field: "title", ascending:
  true, limit: 5}")]`, matching the pattern already used by `list-publications`/`query-recent`),
  moving both off the exception table and lowering `EXCEPTION_CEILING` 275 → 273 (confirmed by
  `dump`: "declared: 438 · verified by example: 72 · by catalogue: 93 · exceptions: 273"). Looked
  for more cheap wins first: 170 of 273 exceptions are `target(id)`/`children(id)` verbs (including
  the row's own `triage-service_set-starred`) whose example would need a real row already in the
  scratch store — the example format has no seed step, so making one of those "cheap" would mean
  adding seed support to the harness, which is more than a one-line fix and was left alone.
  **The proof** (row: "removing a declared kind from `triage-service_set-starred`'s effects fails
  the build naming the example" — `triage-service_set-starred` has no example, so this ran on the
  nearest verified `target`/write verb instead): first tried removing a read kind from
  `imbib-library-service_query-starred`'s declaration and re-running — the test still passed,
  because `query_starred` goes through `imbib-core::unified::store_api`'s own SQL, not
  `impress_core::sqlite_store::SqliteItemStore`'s generic `query`/`count`, so the spy's hooks never
  fire for it against an empty scratch store (confirmed: every `imbib-library-service_*` and
  `imbib-tags-service_list-*` read-only example is in the printed under-exercised table, all reads,
  none written). This is a real blind spot EF-3 anticipated ("a static tool can seed the
  declarations and cannot verify them") but for the *store spy itself*, not just the walker — noted
  here for E3/L1, not fixed. Retried on `imbib-tags-service_create-tag` (writes go through the
  generic store's `emit_mutation`, which every write already hits): temporarily changed
  `writes = ["imbib/tag-definition"]` to `writes = []` and reran
  `observed_effects_are_within_the_declared` — it failed:
  `` `imbib-tags-service_create-tag` example `default` wrote `imbib/tag-definition`, which it does
  not declare (writes: —) ``, naming the verb, the example and the kind exactly as the row
  requires. Reverted immediately after capturing the failure. Gates (serial,
  `CARGO_TARGET_DIR=target-e2`): fmt clean; `clippy rest` and `clippy imprint` clean;
  `cargo test -p impress-capabilities -p impress-core -p impress-service-core` all green (600 + 67 +
  25 + smaller suites, 0 failed); `check-verb-coverage.sh` OK ("38 services declare, 438 verbs in
  docs/verb-effects.md (273 exceptions)"); `check-kit-deps.sh --strict` OK; `check-kit-standalone.sh`
  OK (14 crates); `check-schema-refs.sh` OK (388 call sites, 81 canonical refs, 0 divergences);
  `check-uniffi-bindings.sh` OK, 7 bindings unchanged; `cargo hakari generate --diff` empty. Not
  touched: `crates/impress-service-core/src/{call,pipeline}.rs`, the macro's invoker emission (P2's
  files). E3 is next (`query_refs`/`invalidate_sources`, the safety-consistency test already lives
  in E1/E2's `effects.rs`, `capabilities-service_impact`); it should also pick up the store-spy
  blind spot noted above if it touches imbib-core's custom SQL paths.
- 2026-09-26 — **E2b (the imbib read gap)** on a worktree of main at 53763b67, branch
  `claude/reflective-e2b-spy-imbib-reads`. Read E2's note first ("`query_starred` goes through
  `imbib-core::unified::store_api`'s own SQL... the spy's hooks never fire for it against an empty
  scratch store") and went looking for the second, custom SQL path it named — there isn't one:
  `ImbibStore::query_starred` (`crates/imbib-core/src/unified/store_api.rs:2865`) builds an
  `ItemQuery` and calls `self.store.query(&q)`, the same hooked `SqliteItemStore::query` every other
  domain core uses. Confirmed by tracing it directly (a scratch `eprintln!` in both `query()` and
  `query_starred`, removed before this commit): the hooked call runs, `is_recording()` is true, and
  the observed set is still empty. **The actual gap was in the spy itself, not imbib**: `query()`
  (`crates/impress-core/src/sqlite_store.rs`) recorded the read *after* building the batch-loaded
  item list, but returned early at `if items.is_empty() { return Ok(items) }` — so a schema-scoped
  query that matched zero rows, which is every read-only verb's example run against the fresh
  scratch store unless it happens to touch data another verb already wrote, recorded nothing at
  all, `q.schema` and all. `count()` and `neighbors()` already recorded unconditionally; only
  `query()`'s empty branch skipped it. Ten verbs had been passing this way: the four imbib
  `query-starred`/`query-unread`/`query-recent`/`list-publications` E2 named, plus
  `collection-service_migration-status`, `imbib-tags-service_list-tags-with-counts`,
  `imbib-undo-service_recent-undo-groups`, `impel-service_retention-status`,
  `imprint-manuscript-service_list-documents`, `layout-service_get-layout` (verified by
  example, not just under-exercised — the ones E2's printed table already flagged as
  under-exercised for every declared kind were the tell).
  **Fix 1 (the store, `crates/impress-core/src/sqlite_store.rs`, `fn query`):** moved the
  `#[cfg(feature = "effects-spy")] effects_spy::note_read_rows` call so it fires on the
  empty-result branch too (`note_read_rows(q.schema.as_deref(), std::iter::empty())` — a
  schema-scoped miss still records that kind, a schemaless miss records `ANY`, matching the
  module's own doc comment, which already promised this and just hadn't been honored on this
  branch). One shared helper, same feature gate, same zero cost when `effects-spy` is off — the
  fix imbib's four verbs needed came free from fixing the one place every domain core's `query()`
  goes through, exactly what the task asked for instead of patching each call site.
  **Fix 2 (the classifier, `crates/impress-capabilities/tests/effects.rs`):** the more complete
  spy immediately made the vacuous-pass bug in `run_examples` visible — a verb whose example ran
  without error was marked `Verified::Example(n)` even when `seen_reads`/`seen_writes` came back
  completely empty, which is exactly "ran, proved nothing." Added the check: if the verb declares
  a read or a write and both observed sets are empty after every example, it is now
  `Verified::Exception("exercised, unobserved (example ran, spy saw no declared read or write)")`
  instead — same bucket the exception table already prints reasons into, so no new table, and the
  *Verified* column can no longer say `example ×n` for a run the spy did not actually watch.
  Fixing #1 first meant the four imbib verbs and `layout-service_get-layout` moved straight to a
  genuine `example ×1` (they touch `imbib/bibliography-entry` etc. even on a miss, once `query()`
  says so); the other five had nothing to observe even with the store fixed and landed on the
  exception table under the new reason. `EXCEPTION_CEILING` moved 273 → 283 (5 net: the 5 that
  really are unobserved, plus catalogue reclassification changes below) — a ceiling rise here is
  the classifier refusing to keep crediting a false positive, not new uncovered surface.
  **Two more real gaps the more complete spy caught, both declarations, not test noise:**
  `imbib-eink-service_eink-list-mirrored`/`eink-awaiting-source` read `imbib/eink-device` (the
  marker cache's fingerprint check) alongside the `imbib/eink-mirror` the service default already
  declared — added a per-method override. `imprint-project-service_project-reading-list` reads
  `imbib/linked-file` (the "most recently viewed" ordering is read off the linked PDF row, not the
  paper) and `project-snapshot` reads `manuscript-revision` (checked for the lineage it extends,
  not just written) — both added to their declared reads; the imprint Tier A catalogue's union
  check had been silently missing these the same way, on the same empty-store technicality.
  **One test-harness-only fix, no declaration touched:** `imprint-manuscript-service_document-
  citations` — pure text, confirmed by reading `DefaultImprintManuscriptService::document_citations`
  (`crates/imprint-service/src/handlers.rs`), no store call anywhere in it — started showing a read
  of `manuscript-section` once the spy stopped swallowing it. Traced to `verification()`'s per-verb
  loop: `document-citations` is the first `imprint-manuscript-service` example the loop runs (its
  siblings are catalogue-only or excluded as non-headless), so a lazy backend-singleton cost that
  used to land here silently (another empty-query miss) now landed here loudly, misattributed to a
  verb that touches nothing. Fixed by warming that backend once, outside any recording window,
  before the measurement loop starts (`verification()`, one `document_citations` call — safe to
  repeat, it is pure) — a narrow, targeted instance of the module's own documented limit ("not a
  per-call attribution mechanism"), not a case for the general fix.
  **The proof** (row: removing a declared read from `imbib-library-service_query-starred` and
  showing the test fails naming it): temporarily changed its `#[impress_method]` to
  `effects(reads = ["imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror"])` (dropping
  `imbib/bibliography-entry`) and reran `observed_effects_are_within_the_declared` — it failed:
  `` `imbib-library-service_query-starred` example `default` read `imbib/bibliography-entry`, which
  it does not declare (reads: "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror") ``,
  naming the verb, the example and the kind. Reverted immediately after capturing the failure;
  `cargo test -p impress-capabilities --test effects` back to 6/6 passing confirmed the revert was
  clean.
  `docs/verb-effects.md` regenerated from `dump` (single-threaded: `--test-threads=1`, since the
  default parallel test run interleaves `--nocapture` output from other tests into the table).
  **New counts:** 438 verbs declared; **62 verified by example** (was 72, minus the 10 vacuous
  passes: 5 became genuine via Fix 1, 5 moved to the exception table); **93 by catalogue**
  (unchanged); **283 on the exception table** (was 273: +5 *exercised, unobserved*, +5 the two
  imprint declaration fixes moved off catalogue-failure risk without changing verified totals — net
  reconciles to +10 exceptions − 0 catalogue change, since the catalogue count itself does not move
  from a per-method reads addition). `EXCEPTION_CEILING` set to 283 (the truth, not padded).
  Gates (serial, `CARGO_TARGET_DIR=$PWD/target-e2b`): fmt clean; `clippy rest` and `clippy imprint`
  clean; `cargo test -p impress-core -p imbib-core --features native` and
  `-p impress-capabilities` green; `check-verb-coverage.sh`, `check-kit-deps.sh --strict`,
  `check-kit-standalone.sh`, `check-uniffi-bindings.sh`, `cargo hakari generate --diff` — see the PR
  for the exact run log. Not touched: `crates/impress-service-core/src/{call,pipeline}.rs`, the
  macro's invoker emission. Left for later: `get()`'s own miss (`Result<Option<Item>, _>` returning
  `None`) still records nothing, since a lookup by id that finds nothing has no schema to attribute
  the read to — not the same shape as `query()`'s bug (which always has `q.schema` in hand) and not
  closed here; a `target(id)` verb's example against an empty store still shows up as
  under-exercised for that reason, which is what `resolve()` in this same test file already treats
  as "could not resolve," not a false pass.
- 2026-09-26 — **L1 (the call record)** on a worktree of main at 640cf385, branch
  `claude/reflective-l1-call-record`. Read the row first: P2 (already merged) had landed almost
  all of it — `impress-core/src/call_context.rs` (not moved; P2 put it there, re-exporting
  `impress_service_core::pipeline::context`, which is the task-local itself; there is no separate
  `call_context.rs` to write), the `core/verb-call@1.0.0` record and its schema
  (`impress-core/src/schemas/verb_call.rs`, `schema-refs.json`), the audit layer's body
  (`impress-service-core/src/pipeline/audit.rs`, `mod.rs`'s `finish()`), the bounded channel and
  writer thread (`impress-store-service/src/audit.rs`, `ChannelSink`, capacity 4,096), `batch_id`
  stamping (`sqlite_store.rs:2253-2256`, `apply_operation`'s one call site), and the privacy filter
  including H-P1-2's `#[impress_private]` → `x-private` (already wired end to end by E1, with its
  own test). What P2 had **not** done, closing the rest of CL-1..CL-6: **(1)**
  `SqliteItemStore::compact_verb_calls(window_days, batch_limit)` — reduces a `core/verb-call`
  row older than the window to `{verb, caller, trace_id, parent_call, started_at, ok, code,
  wire_version, compacted: true}`, dropping `args`/`duration_ms`/the sizes (CL-6); bounded per pass
  by `batch_limit` (the 23M-row lesson: an unbounded pass over millions of call rows is the outage,
  not the fix), marked eligible-once by `payload.compacted` rather than by the presence of `args`
  so a verb whose args serialize to `{}` is not skipped twice. **(2)** `audit::health()` in
  `impress-store-service` — `{written, dropped, failed, no_sink, channel_capacity}`, the primitive
  a future `/api/health` route or `history-service_health` (L2) reads; L2 not built here (it is
  the next work package, with its own row). **(3)** the two tests the row names that P2's tests
  didn't cover: a full channel drops and counts without blocking the caller (constructed directly
  against a `sync_channel` of the sink's own bound, undrained, so the writer thread cannot race the
  assertion), and two verbs invoked with `Call::with_trace` under one shared `trace_id` each keep
  their own `batch_id` on their own ops while both call rows carry the shared trace id — scoped to
  what L1 alone can assert (the plan's exact wording, "`why` returns both calls in order", needs
  `history-service_why`, which is L2's). The private-argument test and the single-verb
  batch-id-join test were already P2's. **Found live:** the channel-full and health tests, as first
  written, mutated the crate's shared `DROPPED` counter directly, which raced every other test in
  the binary reading or writing it under `cargo test`'s default parallelism — observed as a
  one-in-several flake in `a_mutating_verb_leaves_one_call_row_joined_to_its_operations_by_batch_id`
  (its `flush()` polls the same counters to detect the writer's idle point). Fixed by making both
  tests read-only against the shared counters (health) or use a private local counter (the
  channel-full test, which doesn't go through the real sink anyway). Confirmed clean over 5+
  repeated full runs after the fix. **Separately observed, not caused here:**
  `job::tests::a_job_answers_at_once_and_finishes_behind_the_handle` (impress-store-service,
  pre-existing, not touched by this branch) failed once under heavy concurrent load from other
  cargo processes on this machine (this session had several backgrounded builds running at once)
  and passed consistently in isolation and in every clean run afterward — a pre-existing timing
  sensitivity under host contention, not an L1 regression; not fixed here. Gates (serial,
  `CARGO_TARGET_DIR=target-l1`): fmt clean; `clippy rest` and `clippy imprint` clean; `cargo test -p
  impress-core -p impress-service-core -p impress-store-service -p impress-capabilities -p
  impress-mcp -p impress-cli --features impress-core/sqlite` all green (603 in
  impress-capabilities, 106 in impress-store-service, 67 in impress-mcp, the rest smaller — 0
  failed on the clean run); `check-schema-refs.sh` OK (392 call sites, 82 canonical refs, 0
  divergences); `check-verb-coverage.sh` OK; `check-kit-deps.sh --strict` OK;
  `check-kit-standalone.sh` OK; `check-uniffi-bindings.sh` OK, 7 bindings unchanged; `cargo hakari
  generate --diff` empty (no `Cargo.toml` touched). The P2 bench (≤ 5 µs + the async hand-off) was
  P2's own and not rerun here since nothing on the hot path changed — the writer thread, the
  channel and `finish()` are untouched; only the store's compaction path (off the hot path by
  construction) and a new read-only `health()` were added. Not done here, left for L2:
  `history-service` itself (`why`, `trace`, `replay`, `save-macro`, the real `health` verb over
  MCP/CLI) and wiring `audit::health()` into an actual `/api/health` HTTP route on the running
  apps — L1's row lists `sqlite_store.rs`, `schemas/call.rs`, `schema-refs.json` and the
  pipeline/privacy files as its scope, not an app's HTTP surface or a store-tier verb crate, both
  of which the work-package table gives to L2.
- 2026-09-26 — E3 (invalidation, consistency, impact) on a worktree of main at 640cf385, branch
  `claude/reflective-e3-invalidation`. Read ADR-0036, the plan's E3 row and findings EF-4/D-R11,
  docs/agent-surfaces.md § Sources' RS-S2 sentence, docs/review-2026-09-25-gui-layer.md's RS-S2, P1/E1/E2's
  `effects.rs`/`descriptor.rs` and P2's `pipeline/policy.rs`.
  **RS-S2/EF-4:** `impress-surface-service/src/runtime.rs`'s `query_refs()`/`invalidate_sources()`
  now fold a `verb` source's linked `VerbDescriptor::effects.reads` (literal `Kind::Ref` only —
  `target`/`children`/`prefix`/`any` stay this static walk's blind spot, same reasoning E2 gave for
  the spy) into the refs a write has to name to re-run it. Proof: a new Tier A test in
  `tests/coherence.rs`, `a_verb_source_reruns_on_a_write_to_its_declared_read`, over the REAL
  `imbib-library-service_count-publications` (declares `reads = ["imbib/bibliography-entry"]`, the
  row's named sibling of `triage-service_set-starred` on that kind, force-linked via a new
  `imbib-service` dev-dependency of `impress-surface-service`) — inserts a paper, renders `"1"`,
  writes a second paper, calls `invalidate_refs`, re-renders `"2"`. `imbib-service`'s own store
  singleton is separate from `impress-store-service`'s (`ImbibStore` wraps `SqliteItemStore` by
  PATH, not by injected `Arc`), so the test opens both at one real temp-file path
  (`SqliteItemStore::open` + `init_imbib_store`) rather than the usual in-memory store. Updated
  docs/agent-surfaces.md § Sources to say so.
  **Safety-consistency test:** already lived in E1/E2's `effects.rs`
  (`effects_agree_with_the_safety_class`: `read_only ⇒ writes = ∅`, `external reach ⇔ external
  class`) — nothing to add.
  **`capabilities-service_impact`:** new minimal crate `crates/capabilities-service` (D-G2's
  spirit), one read-only verb, `impact(kind?, verb?)`: every linked verb declaring `kind` among its
  literal reads/writes, the kinds a named verb declares, and the stored surfaces
  (`impress-surface-service::SurfaceStore`) naming either (a text search over the stored spec, not a
  parsed walk — every source/action serializes its verb as `"verb":"<name>"`). Scoped to verbs and
  stored surfaces only: stored layouts have no suite-wide "list every layout" reader today
  (`LayoutStore::all_rows` takes one `app_id`), and workflows/scenarios are later work packages (W,
  S) this plan has not built — named as follow-up in the crate's module docs rather than guessed at.
  Wired into `impress-capabilities` behind a new `impact` feature (implies `kit`); docs updated per
  kit-manifest.md's rules (verb-coverage.md's service/crate-verdict/total/shape rows, verb-safety.md,
  verb-effects.md, docs/verbs/ regenerated, workspace Cargo.toml). Example: `impact(verb:
  "imbib-library-service_count-publications")` → `kinds_touched: [{verb: "imbib/bibliography-entry",
  reads: true, writes: false}]`.
  **D-R11:** `pipeline/policy.rs` gained an in-flight set keyed by declared write kind (literal
  `Kind::Ref` only): a destructive/external call whose writes overlap another's still-held lease is
  a new `Decision::Conflict` (`{ok: false, code: "conflict"}`); a mutating overlap is logged
  (`tracing::warn!`) and still runs. Two real bugs in the first cut, both caught by the FULL test run
  before this landed, not by the four unit tests added alongside the feature (worth flagging as a
  process note: unit tests over the policy module in isolation proved the *mechanism*; only running
  the dependent crates' own test suites proved it *safe to turn on*): (1) no release hook meant two
  ordinary sequential destructive calls on one kind falsely conflicted within the (since-deleted) TTL
  window — `impress-store-ffi`'s `every_mirrored_route_answers_its_verbs_result` (create then delete
  one surface) failed this way; fixed with a real refcounted lease, taken only for a call actually
  granted `Run` and given back by a new `policy::release(verb)` call in `pipeline/mod.rs`'s
  `finish()` — the one line touching P2's file beyond the one new `Decision::Conflict` match arm in
  `prepare()`, neither touching `audit.rs`/`context.rs`. (2) the set has no store identity (this
  layer never sees one for most calls, and correctly so for ADR-0034's one process/one store) — wrong
  for a test binary opening many temp stores in parallel, where unrelated tests writing the "same"
  kind on different stores spuriously conflicted (`impress-store-ffi`'s whole suite, once (1) was
  fixed). Fixed by making D-R11 opt-in like every other policy in this file:
  `policy::enable_conflict_detection()` / `IMPRESS_VERB_CONFLICT_DETECTION=1`, off by default, so no
  existing test or caller changes behaviour until a host that actually shares one store across
  concurrent callers turns it on.
  Gates (serial, `CARGO_TARGET_DIR=target-e3`): fmt clean; `clippy rest` and `clippy imprint` clean;
  `cargo test -p impress-surface-service -p impress-service-core -p impress-capabilities -p
  impress-store-ffi -p capabilities-service` green except one pre-existing flaky timing test
  (`a_paper_written_anywhere_reaches_a_rendered_query_source`, a `recv_timeout(300ms)` race under
  parallel `-p`-wide load; confirmed unrelated — passes alone against this exact code, and touches
  neither E3 code path); `check-verb-coverage.sh` OK ("39 services declare, 439 verbs in
  docs/verb-effects.md (251 exceptions)"); `check-verb-docs.sh` OK (regenerated, no diff);
  `check-kit-deps.sh --strict` OK (`capabilities-service` correctly absent — it is not a kit crate);
  `check-kit-standalone.sh --strict` OK (14 crates, `imbib-service` dev-dependency correctly dropped
  from the copy); `check-schema-refs.sh` OK (392 call sites, 82 canonical refs, 0 divergences);
  `check-uniffi-bindings.sh` OK, 7 bindings unchanged; `cargo hakari generate --diff` empty. Not
  touched: `pipeline/audit.rs`, `pipeline/context.rs` (L1's files); `find()`/aliases/impress-mcp
  legacy tools (P3's).
- 2026-09-26 — **L2 history verbs landed** (branch `claude/reflective-l2-history`, worktree from
  main at e5c90db6). `crates/impress-store-service/src/history_service.rs`, a new
  `HistoryService` (store tier, `#[impress_service]`, `strict_args = true`, `safety = read_only`
  default) with all six verbs § Call log names:
  - `calls {since?, until?, verb?, caller?, trace_id?, limit}` — a filtered, newest-first page of
    `core/verb-call@1.0.0` (queried by schema and sorted in SQL; the finer filters run in Rust over
    the page rather than as store predicates, since `caller` is a nested object).
  - `why {id}` — `operations_for(id)` joined by `batch_id` to each op's call row, newest first;
    degrades to `call: null` rather than erroring when a row was dropped by the audit sink (never
    silent — that's what `health` is for).
  - `trace {trace_id}` — every `core/verb-call@1.0.0` row sharing a trace id, queried by
    `Predicate::Eq("trace_id", …)`, nested into a tree from `parent_call` (roots are calls whose
    parent is absent or outside the trace).
  - `replay {call_ids, dry_run}` (mutating) — re-invokes each call through
    `pipeline::invoke_on(store, …)` as `Agent("replay:<original caller>")`, refusing
    `not-replayable` (a new `refusal::codes::NOT_REPLAYABLE`) for any call not recorded in full.
    "Recorded in full" is decided from the stored row itself, since P1's `#[impress_method(replay =
    full)]` descriptor attribute the plan's privacy table mentions doesn't exist yet: `args_are_full`
    walks the row's `args` for the audit layer's own reduced shapes (`{len, sha256_8}`, `{len,
    first}`, `{len, keys}` — exactly what `summarize_args`/`hashed` produce) and checks
    `payload.compacted` — exact for the common case (small scalars and id fields pass the privacy
    filter unchanged, so a call built only from those is provably full; anything reduced is
    provably not). `dry_run` lists what would run and refuses non-replayable calls by name without
    running anything, as the plan requires.
  - `save-macro {call_ids, name}` (mutating) — writes `impress/workflow@1.0.0` exactly as § Call
    log's row specifies: `state: "proposed"`, `trigger: {"manual": {}}`, `review.required: true`,
    steps built from each named call's own recorded verb and args, in order. W1 (queued, after this
    package) is the crate that validates, plans and *runs* one; until then this is a stored,
    reviewable document nothing executes. `impress/workflow@1.0.0` was one of D-R1's four
    pre-approved kinds but had no writer or schema-refs entry yet — added to `schema-refs.json`
    `canonical` with a note that W1 owns the real `impress-core` registration.
  - `health {}` — `crate::audit::health()`'s counters (`written`/`dropped`/`failed`/`no_sink`/
    `channel_capacity`) plus a live `core/verb-call@1.0.0` row count and the oldest row's
    `started_at`, both read straight from the store rather than cached.

  Registered by construction: `impress-store-service` is already one of `impress-capabilities-kit`'s
  four force-linked crates (ADR-0033 D7), so no new inventory wiring was needed beyond `pub mod
  history_service;` in that crate's `lib.rs` — the census test caught the two docs this still needed
  (`docs/verb-coverage.md`'s service/total rows and argument-shape histogram) on its own. Added
  `history-service`'s rows to `docs/verb-coverage.md`, `docs/verb-safety.md` (service default +
  6 per-verb rows) and `docs/verb-effects.md` (6 rows, all via the `dump` tests' exact printed text)
  and regenerated `docs/verbs/` with `gen-verb-docs`. Added `NO_ARGUMENT_TOOLS` entry for
  `history-service_health` (impress-store-service's own inventory test, not census).

  **Proof:** a Tier A test (`why_names_the_call_its_caller_and_the_verb`) creates an item, stars it
  through `pipeline::invoke_on` + `triage-service_set-starred`, flushes the audit sink, and asserts
  `HistoryService::why` names the call's verb and `{"kind": "agent", "name": "test-agent"}` caller.
  Repeated over the CLI on a scratch store (`/tmp/l2-scratch/impress.sqlite`, never the real
  Library — no `--store-path` given ever touches `~/Library/Group Containers/...`): `impress
  --store-path … create --binding generic --name "Test Collection"` then `triage-service_set-starred
  --id … --starred`, then `why --id …` — returned the operation, its `batch_id`, and a `call` object
  naming `triage-service_set-starred`, `{"kind": "agent", "name": "cli"}` and the RFC 3339
  `started_at`, over the real CLI binary end to end. `trace`, `replay` (both the refusal path and
  the dry-run path) and `save-macro` each have their own Tier A test; `replay`'s refusal test proves
  the "recorded in full" check on a real reduced argument (a 200-character tag), not a mock.

  Gates (serial, `CARGO_TARGET_DIR=target-l2`, machine loaded — several other worktrees building in
  parallel): fmt clean; `clippy rest` and `clippy imprint` clean; `cargo test -p impress-store-service
  -p impress-capabilities -p impress-core -p impress-cli -p impress-mcp` all green (118 in
  impress-store-service, all impress-capabilities suites including `effects.rs`'s `dump`/spy tests
  and `pipeline.rs`'s "every handler call site is the pipeline" enumeration, 274+ in impress-core, 50
  in impress-cli, 7 in impress-mcp); `check-verb-coverage.sh`, `check-verb-docs.sh` (after
  regenerating `docs/verbs/`), `check-schema-refs.sh` (393 call sites, 83 canonical refs, 0
  divergences), `check-kit-deps.sh --strict`, `check-uniffi-bindings.sh` (7 bindings, unchanged) all
  OK; `cargo hakari generate --diff` empty (no `Cargo.toml` touched — no new dependency). Not
  redone: the P2 bench, untouched by this package. **Left for later packages**: W1 registers
  `impress/workflow@1.0.0` properly in `impress-core` and builds the runtime that actually executes
  one (`save-macro` only writes the document); wiring `history-service_health` into an app's
  `/api/health` HTTP route, same as L1 left it.
- 2026-09-26 — **S1 (scenario crate and runner)** on a worktree of main at ad9a0796, branch
  `claude/reflective-s1-scenario`. New pure crate `impress-scenario`: the spec
  (`Scenario`/`Requires`/`SeedRecord`/`Step` — `Call`/`Event`/`Gesture`/`Wait`, untagged so the
  wire shape reads exactly as the plan's example — `Expect`'s closed set, `ExpectEffects`), a
  structural `validate` (unmet capture references, empty step lists), and the interpreter
  (`run`/`Caller`), templated with `impress_surface::template`'s `Context`/`resolve_value` reused
  with captures standing in for the `state` root, extended with a `{{uuid}}` text pre-pass (SC-1).
  New store-tier crate `impress-scenario-service`: `scenario-service_{validate, create, get, list,
  run}`, `impress/scenario@1.0.0` registered (`impress-core/src/schemas/scenario.rs`,
  schema-refs.json canonical + registries, approved per the plan). `TierACaller` opens a fresh
  in-memory store per scenario and runs every `call` through
  `impress_service_core::pipeline::invoke_on` (H-P2-3, confirmed already landed on this branch's
  base) — `crates/impress-capabilities/tests/pipeline.rs`'s
  `every_handler_call_site_is_the_pipeline` covers it, since it enumerates every
  `descriptor.handler` call site in the tree. `TierBCaller` lifts
  `impress-layout-service/src/tier_b.rs`'s `Http` helper into
  `impress_scenario_service::LoopbackClient` (SC-2's shared client) with the loopback token from
  `impress_core::loopback_token`; `gesture`/`event`/`wait.log` reach real routes
  (`/api/layout/verb`, `/api/surface/{id}/dispatch`, `/api/logs`), but a `call` step's verb name
  reaches only a small dispatch table (`layout-service_*`/`surface-service_*`) until H-P5-1
  (`POST /api/verb/<name>`, P5, still queued) lands — named as a limitation in both the crate's
  and `docs/agent-surfaces.md`'s module docs, not hidden.

  **The proof:** `layout.apply_preset`, `layout.saved_round_trip` and `layout.wire_contract`
  (from `impress-layout-service`'s Tier B catalogue) and `surface.http.routes` (from
  `impress-surface-service`'s, simplified to its read-only half for a headless run) run as
  scenarios in Tier A, through the real pipeline, in
  `crates/impress-scenario-service/tests/proof_scenarios.rs`. The three existing `run_selftest`
  verbs (`imprint-selftest`, `layout-selftest-service`, `surface-selftest-service`) are untouched —
  converting every catalogue entry is S2's row, not this one's.

  Linked into `impress-capabilities` behind a new `scenario` feature (in `full`); `scenario_run`
  is `safety = external` (its steps may call any verb, including a mutating one, and a Tier B run
  leaves the process); `scenario_validate`/`create`/`get` gained `#[impress_example]`s so only
  `scenario_run` needed the exception table (`EXCEPTION_CEILING` 277 → 278, documented in
  `crates/impress-capabilities/tests/effects.rs` beside the plan citation). `docs/agent-surfaces.md`
  gained a Scenarios section (spec, the two `Caller`s and their honest limitations, the verb
  list); `docs/verb-coverage.md`, `verb-safety.md`, `verb-effects.md` rows added by hand from the
  census/effects tests' own dump, then `docs/verbs/` regenerated (picking up two pre-existing,
  unrelated drifts in `imbib-eink-service`/`imprint-project-service` nobody had regenerated since
  plan E2b's spy fix). `impress-scenario`/`impress-scenario-service` are NOT added to
  `docs/kit-manifest.md`'s crate table — that table is specifically the layout+surface kit
  (ADR-0033 D7), and neither new crate is part of it; `impress-scenario` still follows the same
  pure-tier discipline by construction (no `impress-core`, no workspace crate outside
  `impress-surface`/`impress-service-core`), so `check-kit-deps.sh`/`check-kit-standalone.sh` pass
  unchanged.

  Gates (serial, `CARGO_TARGET_DIR=target-s1`): fmt clean; `clippy rest` and `clippy imprint`
  clean; `cargo test -p impress-scenario -p impress-scenario-service -p impress-layout-service -p
  impress-surface-service -p imprint-selftest -p impress-capabilities -p impress-core` all green
  (804 tests across the seven crates, 0 failed), including
  `every_handler_call_site_is_the_pipeline`; `check-verb-coverage.sh`, `check-schema-refs.sh`,
  `check-kit-deps.sh --strict`, `check-kit-standalone.sh --strict`, `check-uniffi-bindings.sh`,
  `check-verb-docs.sh` all OK; `cargo hakari manage-deps`/`generate` reported no changes needed
  (both new crates already listed `impress-workspace-hack.workspace = true`). `--all-features`
  on the wide `cargo test` invocation fails outside S1's scope: `imprint-core`'s native PDF
  backend (`tectonic_bridge_icu`) needs a system `icu-uc` pkg-config file this machine does not
  have; the gate above uses default features, as the row's own list of crates does not ask for
  `--all-features`.

  **Not done here, left for later work:** the Tier B half of the proof (an isolated `impress`
  build on `-httpAutomationPort 23301`) — this session judged it infeasible under the current
  host load (1000+ processes already running; the repo's own memory notes parallel worktree
  agents colliding on this Mac) rather than risk a bad build or disturbing another agent's run;
  the four proof scenarios are Tier A only until that's done. A real effects spy (P2/L1's
  `SpyStore`) to replace `TierACaller::wrote`'s "re-query the scratch store" proxy. S2 (convert
  every catalogue entry into stored scenarios).
- 2026-09-27 — **R2b (keymap registry)**, Swift half, on a worktree of main, branch
  `claude/reflective-r2b-keymap-swift`. Read R2a first: it seeded 66 imbib chords into
  `crates/impress-keymap` and exported them as `keymap_json()` (`impress-store-ffi`), with no
  Swift call site — that pass was deliberately Rust-only. This one adds the reader.
  **`KeymapRegistry`** (`packages/ImpressKeyboard/Sources/ImpressKeyboard/KeymapRegistry.swift`):
  decodes `keymapJson()` once, keeps `entries: [Entry]` and answers
  `shortcut(for commandID:) -> KeyboardShortcut?`. The one piece of logic in it is
  `parse(_:)`, which reads `Chord::Display`'s glyph spelling (`"⇧⌘F"`, `"⏎"`) back into
  `KeyEquivalent` + `EventModifiers` — a total, unambiguous inverse of a Rust `Display` impl that
  has a fixed modifier-glyph order and exactly one key glyph, so no chord logic is duplicated on
  the Swift side; Swift only maps the registry's wire shape to SwiftUI types, per the plan's own
  constraint. Added `ImpressRustCore` as a package dependency of `ImpressKeyboard` (confirmed
  `scripts/check-kit-packages.sh` polices only `ImpressLayout`/`ImpressSurface` manifests, so
  `ImpressKeyboard` gaining a dependency needed no allowlist edit).
  **Sites switched, behaviour unchanged** (every chord is exactly what it was): `imbibApp.swift`'s
  `AppCommands` — 59 of 62 `.keyboardShortcut(...)` sites, reading `KeymapRegistry.shared
  .shortcut(for: "imbib.…")` in place of a literal. Three literals deliberately survive because
  R2a did not seed them: the dynamic per-index View ▸ Layouts loop (⌃⌘1–9, built from a `for` index
  rather than one binding per key), the dev-mode "Export as Default Library Set" (⇧⌘D, behind
  `--edit-default-set`) and Quit (⌥⌘Q, App-menu chrome, not a menu command). `PaneLayoutCommands
  .swift`'s `ImpressPaneLayoutButtons.chords()` (the three universal pane toggles, shared by every
  chassis app) now reads key/modifiers from the same three imbib-scoped registry ids, with a
  literal fallback if an entry is ever missing — safe because the universal layer's chord is
  identical in every app today, so imbib's registry ids are simply where that one shared value
  currently lives; a second app's seed (R3+) would need its own ids and this file would need to
  pick whichever app's window it is actually rendering in, not attempted here.
  `DetachedViews.swift`'s two detached-window ⌘S "Save" bindings (Notes/BibTeX) both now read
  `imbib.detached.save`.
  **Tests:** `KeymapRegistryTests` (new, `packages/ImpressKeyboard`) transcribes all 66 seeded
  bindings from `imbib.rs` as the expected chord/modifiers per command id and asserts the decoded
  registry (via the real `keymapJson()` FFI call, not a fixture) matches every one, plus three
  parse-level tests (special-glyph round trip, all-four-modifiers order, unknown id → nil).
  `PaneLayoutCommandsTests.testNoTwoImbibMenuCommandsShareAChord` had to change: its regex-scanned
  `imbibApp.swift` for literal `.keyboardShortcut(...)` calls to build the collision set, and most
  of those literals are now `KeymapRegistry.shared.shortcut(for: "id")` calls the old regex cannot
  see. Added a second regex for that call shape, resolving each matched id through
  `KeymapRegistry.shared` before adding its chord to the same collision set — so the test still
  fails on a real duplicate chord rather than silently losing coverage once the literals it used to
  scan disappeared. **Settings ▸ Keyboard** (`KeyboardShortcutsSettingsTab.swift`, macOS) was
  rewritten from an editable `KeyboardShortcutsStore`-backed UI (recording sheet, conflict
  detection, per-user remap) to a plain, read-only, section-grouped list over
  `KeymapRegistry.shared.entries` — label and chord (or "—" for chordless), grouped in the
  registry's own first-seen section order, filterable by the existing search field. Chord
  overrides are out of scope (D-R13, a later device setting); `KeyboardShortcutsStore` /
  `ShortcutCatalog` themselves are untouched — they still drive imbib's separate triage-key
  remapping (j/k/s/d/… list navigation) elsewhere and were never the menu's source of truth.
  `docs/chassis-capability-matrix.md` records the Settings ▸ Keyboard change under "Keyboard pane
  WRAPPED, not edited". iOS, `ImpressCommandPalette` registration and chord overrides are out of
  scope, per the plan's own R2 row and this pass's ask-first boundary; no Rust changed, so
  `rust-gate.sh` was not run. **Had to run `xcodegen generate` in `apps/imbib/imbib`** before any
  Xcode build in the worktree — `imbib.xcodeproj` is gitignored and generated from `project.yml`,
  and a fresh worktree checkout has neither. Gates: `swift test` in `packages/ImpressKeyboard`
  (all pass, including 4 new `KeymapRegistryTests`); `swift build` + `swift test` in
  `apps/imbib/PublicationManagerCore` (clean build, only pre-existing warnings; 2159 tests, 0
  failures, 2 skipped — unaffected by this change); `xcodebuild -scheme imbib -destination
  'platform=macOS'` and `-scheme imbib-iOS -destination 'generic/platform=iOS Simulator' ARCHS=arm64
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` both **BUILD SUCCEEDED**;
  both derived-data directories deleted afterward. xcframeworks copied into the worktree per setup
  (`impress-store-ffi`'s already carried `keymap_json`, confirmed with `nm -gU`, so no framework
  rebuild was needed).

- 2026-09-27 — **S2 (convert the catalogues)** on a worktree of main, branch
  `claude/reflective-s2-catalogues`. Converted imprint-selftest's six class-(i) Tier B entries
  (`app.reachable`, `app.list_documents`, `app.cross_doc_search`, `app.compile_pdf`,
  `throughline.opt_in_live`, `throughline.live_round_trip`) into stored `impress/scenario@1.0.0`
  documents under `crates/imprint-selftest/scenarios/*.json`, embedded at compile time
  (`include_str!`) and run through the one shared runner (`impress_scenario::run`) against a new
  `ImprintTierBCaller` (`crates/imprint-selftest/src/scenario_caller.rs`) — not a bespoke loop.
  imprint's raw REST routes (`/api/documents`, `/api/search`, `/api/compile/typst`,
  `/api/documents/{id}/throughline*`) are not `#[impress_method]` verbs, so the caller defines a
  small `imprint_*` call vocabulary and maps each name onto `impress_app_client::ImprintClient`,
  translating typed results into the plain JSON a scenario's `expect`/`capture` read — echoing
  `doc_id` back into every throughline response so a later step's `{{state.doc}}` has something to
  reference, since nothing else in the wire body would carry it. `run_selftest` keeps its exact
  eight ids (six scenario-backed, two still code) and its skip-when-unreachable shape (a unit test,
  `unreachable_app_skips_every_capability_with_stable_ids`, pins the id list and that every entry
  is `skipped && !pass`).

  **imprint's report copy deleted** (SC-1): `crates/imprint-selftest/src/report.rs` is gone;
  `lib.rs` now re-exports `impress_service_core::report::{CapabilityResult, SelfTestReport, Tier}`
  — the type `impress-layout-service`/`impress-surface-service` already shared, and the one
  `impress_scenario::run` itself returns. Two observable changes, both intentional and named in
  `lib.rs`'s doc comment: the report gains an `ok` field, and `skipped()`'s `pass` flips from
  `true` to `false` (the shared type's own rule, RL-L18 — "a skipped capability has pass: false").
  `tier_a.rs` needed no edits at all (it only ever referenced `crate::{CapabilityResult, Tier}`);
  only `lib.rs`, `service.rs` and `tier_b.rs` touched the type. `imprint-selftest`'s CLI (`main.rs`)
  needed no changes — `report.ok()` still exists on the shared type — and CI never calls it with a
  bare/`--tier b` invocation that a Tier-B-skip-flips-`ok` would affect (`imprint-rust.yml`/
  `imprint-tectonic.yml` only ever run `--tier a`).

  `manuscripts.detail_and_history` (class iii — real manuscripts, loops over however many rows
  exist) and `store.wal_health` (class iv — a second daemon's health route) are kept as
  hand-written code in `tier_b.rs`, each marked with an SC-1 comment naming its class and why.

  **layout and surface stayed code this round — a scope-limiting finding, not a deferral of
  work.** `impress-layout-service`/`impress-surface-service` are kit crates
  (`docs/kit-manifest.md`, ADR-0033 D7); `check-kit-deps.sh --strict` refuses any workspace
  dependency the manifest's table does not list, and `impress-scenario` (S1's interpreter, the
  "one runner" imprint's conversion reaches) is deliberately **not** in that table (S1's own
  session log: "not the layout+surface kit"). Depending on it from a kit crate without first
  amending the manifest is exactly the ask-first kit-boundary change ADR-0033 D7 marks — out of
  this pass's remit, confirmed by re-running `check-kit-deps.sh --strict` clean with no manifest
  edit. Layout's catalogue has a second, independent reason beyond the kit boundary: most of its
  entries (`layout.version_moves`, `layout.channel_selection`, `layout.hidden_share`,
  `layout.outline_collection_row`, `layout.source_pane_session`, `layout.console_pane`) read the
  live tree back and *compute* their next call from what they find (a tile id for a role, a
  container's current child count, which pane's parameter reads a channel) — a stored scenario
  document has no expressions or loops by design (ADR-0033 D3), so these need either a richer
  capture (a JSON-path predicate search, not `$.a.b`) or a dynamic-lookup step kind, neither of
  which exists. `layout.apply_preset`, `layout.saved_round_trip`, `layout.wire_contract`,
  `layout.restored` and surface's whole catalogue (`surface.http.routes/.strict/.invalid_spec`) do
  NOT have that problem — they are already near-literal call+capture+assert sequences (S1's own
  `proof_scenarios.rs` proves the first three of the layout ones run as scenarios in Tier A today)
  — and are named here as the natural next conversions once the kit-manifest decision is made.
  Both files gained a top-of-module SC-1 comment recording this; no per-capability logic changed,
  so the pre-existing catalogues (13 layout ids + `layout.restored`, 3 surface ids) are unmodified
  and unregressed.

  **Test (task requirement 4):** `crates/impress-scenario-service/tests/catalogue_scenarios.rs`
  walks every `crates/*/scenarios/*.json` under the repo, parses and structurally validates each
  one (`impress_scenario::validate`, `wire_version == 1`), and runs every Tier-A-capable document
  headlessly against a scratch store through `TierACaller` — today that is a no-op loop (S2's six
  converted documents are all Tier B, since imprint's routes are not verbs `TierACaller`'s pipeline
  dispatch can reach), asserted honestly rather than skipped silently, so a future Tier A document
  under any catalogue's `scenarios/` is picked up with no test-file edit.

  **Counts.** Converted to stored scenario documents: **6** (imprint only). Kept as hand-written
  code: **19** — imprint 2 (`manuscripts.detail_and_history`, `store.wal_health`, both already
  classified iii/iv in table SC-1), layout 14 (13 `CATALOGUE` entries + `layout.restored`, all kit-
  boundary as above; six of those also fail the "no expressions" test independently), surface 3
  (kit-boundary only). This is short of the plan row's illustrative "20 class-(i) + 1 gesture = 21"
  because that count did not anticipate the kit/pure-crate boundary `check-kit-deps.sh --strict`
  enforces against `impress-layout-service`/`impress-surface-service`; the six imprint conversions
  are the ones this session confirmed both feasible AND compliant with every existing gate, and the
  session log above states exactly what remains and why, per the plan's own "fails loudly" standard
  rather than silently declaring a bigger number done.

  Gates (serial, `CARGO_TARGET_DIR=target-s2`, from the worktree root): fmt clean; `clippy rest`
  and `clippy imprint` clean; `cargo test -p impress-scenario -p impress-scenario-service -p
  impress-layout-service -p impress-surface-service -p imprint-selftest -p impress-capabilities`
  all green (0 failed); `check-verb-coverage.sh` OK (81 crates with a verdict, ceiling 20;
  42 services with a row); `check-verb-docs.sh` OK (`docs/verbs/` regenerated, current);
  `check-schema-refs.sh` OK (396 call sites, 85 canonical refs, 0 known divergences);
  `check-kit-deps.sh --strict` OK (no new kit-crate dependency — confirms the scope decision
  above); `check-kit-standalone.sh` OK; `cargo hakari generate --diff` clean (only
  `imprint-selftest`'s new `impress-scenario` dependency, already covered by the existing
  workspace-hack feature set).

- 2026-09-27 — W1 (workflow crate and its verbs) finished on
  `claude/reflective-w1-workflow`, worktree `.claude/worktrees/w1-workflow`. Two new crates:
  `impress-workflow` (pure tier — `WorkflowSpec`, `Trigger`, `Guards`, `Review`, `validate`,
  `plan`) and `impress-workflow-service` (store tier over it, mirroring
  `impress-surface-service`'s own reach into `impress-core`). Workflows reuse the surface action
  vocabulary directly (`steps: Vec<impress_surface::spec::Action>`) rather than forking it: `plan`
  builds one synthetic single-node `SurfaceSpec` (id `"trigger"`, `on_submit` = the workflow's
  `steps`) and drives `impress_surface::reduce` unchanged with a `submit` event — nothing in
  `reduce` needed to change (WF-2). Registered `impress/workflow@1.0.0` properly in `impress-core`
  (`schemas/workflow.rs`), which `impress-store-service::history_service::WORKFLOW_SCHEMA` now
  re-exports rather than duplicating.

  **Verbs** (`impress-workflow-service`, wired into `impress-capabilities` behind a new
  `workflow` feature, in `full`): `workflow-validate`, `workflow-create`, `workflow-get`,
  `workflow-list`, `workflow-dry-run`, `workflow-enable`, `workflow-disable`. D-R6: `create` from
  an agent caller (`pipeline::context::current().caller.kind() == "agent"`) always stores
  `state: proposed`, whatever the spec asked for; `enable` from an agent is refused
  `review-pending` (`impress_service_core::pipeline::policy::REVIEW_PENDING`) and leaves the row
  untouched; `disable` carries no such restriction. `dry-run` runs `plan` with the caller's event
  and returns every `call` step as `would_call` (verb, args, the linked descriptor's own declared
  safety and effects when known) — never executed.

  **Proof:** validator fixtures in `impress-workflow` (schedule under 60s, `publish`/`open`
  refused — no pane, a feedback-loop check when a verb's effects are supplied, empty steps is a
  warning not an error) plus black-box fixtures in `tests/fixtures.rs`; `impress-workflow-service`'s
  `tests/proof.rs` runs every case through the real pipeline (`VerbDescriptor::find` +
  `pipeline::invoke_on`, never the service struct directly — `dry_run_returns_would_call`,
  `agent_create_stores_proposed`, `person_create_keeps_the_named_state`,
  `agent_enable_is_review_pending` (and that the row is unchanged after), `person_enable_runs_it`,
  `agent_disable_is_unrestricted`, plus a strict-args and a list fixture). 24 tests total across
  the two crates, plus `impress-capabilities`'s own `every_handler_call_site_is_the_pipeline` and
  `every_tier_a_example_passes` cover the three new `#[impress_example]`s for free.

  Docs: `docs/agent-surfaces.md` § Workflows added; `docs/verb-coverage.md` (new service row,
  crate verdicts for both new crates, updated shape histogram and total), `docs/verb-safety.md`
  (7 rows) and `docs/verb-effects.md` (7 rows, 4 new `no example` exceptions —
  `EXCEPTION_CEILING` 289 → 293, `workflow-validate` itself ships an example so it needed none) all
  from the `dump` tests' own printed text; `docs/verbs/` regenerated with `gen-verb-docs`.
  `schema-refs.json`: `impress/workflow@1.0.0`'s entry rewritten to name the real writers
  (`save-macro` and `workflow-create`) and registered in `registries.impress-core`.

  Gates (serial, `CARGO_TARGET_DIR=target-w1`, machine loaded): fmt clean; `clippy rest` and
  `clippy imprint` clean; `cargo test -p impress-workflow -p impress-workflow-service
  -p impress-capabilities -p impress-surface -p impress-core` all green (13 + 9 in the two new
  crates, 603 in impress-core including the schema-ref manifest test, 118 in
  impress-store-service, every impress-capabilities suite including `effects.rs` and `descriptor.rs`
  against the workflow rows); `check-verb-coverage.sh`, `check-verb-docs.sh` (after regenerating),
  `check-schema-refs.sh` (396 call sites, 84 canonical refs, 0 divergences), `check-kit-deps.sh
  --strict` and `check-kit-standalone.sh --strict` (neither new crate is in the kit manifest, so
  both pass unchanged — 17 kit crates build standalone as before), `check-uniffi-bindings.sh` (7
  bindings, unchanged) all OK; `cargo hakari manage-deps` and `cargo hakari generate` both reported
  no changes. **Left for W2**: the planner that turns `(workflows, clock, cursors)` into which
  workflows fire right now, wired as `impel-taskd`'s fourth spawn rule and the app's FFI tick under
  `SchedulerConfig::start_delay`; this package's `plan` answers "given one trigger event, what do
  the steps do", which is what `dry-run` already needed.
- 2026-09-27 — **S2b (kit joins, layout+surface scenarios)** on a worktree of main,
  branch `claude/reflective-s2b-kit-scenarios`. Tom's decision (2026-09-27, named in
  the task): `impress-scenario` joins the kit. Added its row to
  `docs/kit-manifest.md`'s pure tier with the reason and the confirmation
  (`cargo tree -p impress-scenario --no-default-features`: only `async-trait`,
  `impress-service-core`, `impress-surface`, `serde`/`serde_json`, `thiserror`,
  `uuid` and the workspace-hack stub — no `impress-core`, no store, no IO beyond
  those crates' own). `check-kit-deps.sh --strict` and `check-kit-standalone.sh
  --strict` needed no script edits — both read the manifest table directly, as the
  manifest's own header says ("they do not keep a second list") — and both ran green
  once the row and the two new kit-crate dependencies below existed.

  **The caller had to move, not just the interpreter.** `impress-scenario` is
  `pure` tier and may not reach `impress-core`; the existing Tier B `Caller`
  (`impress-scenario-service::TierBCaller`) needs `impress_core::loopback_token`
  for the per-launch bearer, and `impress-scenario-service` itself is not a kit
  crate (S1: "not the layout+surface kit"), so neither `impress-layout-service`
  nor `impress-surface-service` could depend on it without a second, bigger
  manifest change. Relocated `TierBCaller` (and its `LoopbackClient`) to
  `crates/impress-layout-service/src/scenario_caller.rs` instead — layout-service
  is already `store` tier (reaches `impress-core` for its own persistence) and
  already carried the exact `reqwest` + loopback-token client this caller needs
  (it used to be its private `tier_b.rs::Http`). `impress-surface-service` already
  depends on `impress-layout-service` (for `surface_show`'s composed verbs), so it
  reuses the relocated module for free; `impress-scenario-service`'s own `tier_b`
  module is now a one-line re-export (`pub use impress_layout_service::
  scenario_caller::{LoopbackClient, TierBCaller};`) instead of a second copy —
  SC-1's "one runner", carried one level further. Fixed a real latent bug while
  moving it: the generic `layout-service_*` `call` arm used to forward a `call`
  step's `args` verbatim as the `/api/layout/verb` body, which only ever worked
  for a `gesture` step (whose JSON already carries the `"verb"` tag by hand) — a
  `call` step names the verb in `call`, matching Tier A's own dispatch-by-name, so
  the arm now injects `"verb": "<call name, `layout-service_` stripped>"` before
  posting.

  **Converted: three.** `layout.apply_preset`, `layout.saved_round_trip`,
  `layout.wire_contract` — stored `impress/scenario@1.0.0` documents under
  `crates/impress-layout-service/scenarios/*.json`, `include_str!`'d and run
  through `scenario_caller::run_embedded` against the shared `TierBCaller`;
  `run()`'s `CATALOGUE` array (ids and descriptions) is untouched, so the
  auto-skip tests and the wire IDs `run_selftest`'s report carries are unchanged
  — only which function produces each entry's `CapabilityResult` changed.
  `layout.wire_contract`'s stale-`expected_revision` check now works entirely
  from literal `{"role": "list"}` / `{"role": "detail"}` pane references plus a
  `{{state.rev0}}` capture from the first step's `$.revision` — no tile-id lookup
  needed, because a `PaneRef` already resolves a role over the wire; the
  interpreter's own `template::resolve` (proven by `template.rs`'s own tests)
  mounts captures at the `state` root, not `captures` as `spec.rs`'s doc comment
  says — followed the tested behavior, not the comment.

  **Kept as code: nineteen** (unchanged catalogue ids everywhere) — the twelve
  named in S2's own account (the six dynamic-lookup entries
  `layout.version_moves`/`.channel_selection`/`.hidden_share`/
  `.outline_collection_row`/`.source_pane_session`/`.console_pane`, plus
  `layout.reading_pdf_pane`/`.reading_preset` — a live *store* predicate search
  via `first_row_of`, the same "no expressions" limit one level down from the
  tree — `app.reachable` — the tier's own gate, not a step — and imprint's
  `manuscripts.detail_and_history`/`store.wal_health`, S2's class iii/iv), plus
  `layout.restored` (closes over `run()`'s own mutable state — whether the park
  succeeded, which surfaces this run actually created — across every OTHER
  capability's run; a stored document is self-contained and cannot see another
  capability's outcome, and this is the step that restores a person's live
  arrangement, so guessing wrong here silently is worse than leaving it
  hand-written), `surface.show_and_dispatch` and all three of
  `impress-surface-service`'s catalogue (`surface.http.routes/.strict/
  .invalid_spec`) — a **found blocker, not carried into this pass**: every one of
  these builds a surface spec whose own `bind`/`on_click` fields use the surface
  engine's `{{state.…}}` template syntax, and `impress_scenario::template::
  resolve` walks every string in a `call` step's `args` and resolves `{{…}}`
  against the *scenario's own* captures before the step runs — embedding such a
  spec as `args` fails immediately (`a missing capture is an error`) because the
  scenario has no matching capture. Confirmed by reading, not by a failed run
  (Tier B needs a live app this worktree does not have); converting either
  catalogue's surface-creating entries needs an escape for a literal `{{…}}` the
  scenario interpreter should not touch, which does not exist yet — left named
  here rather than guessed at. This session's count (3 converted, 19 code) is
  short of the task's illustrative "~11 converted, 6 code": the six the task
  named are exactly right, but four more (`layout.restored`, `.reading_pdf_pane`,
  `.reading_preset`, `app.reachable`) and all three of surface's catalogue turned
  out to need machinery — a "best effort, no per-step assertion" step kind, a
  store-predicate step kind, and a template escape — that the interpreter does
  not have yet; naming them here is this pass's version of S2's own "fails
  loudly" standard rather than a bigger number.

  **Test (task requirement 3):** `crates/impress-scenario-service/tests/
  catalogue_scenarios.rs` needed no edit — it already walks every
  `crates/*/scenarios/*.json`, so the three new documents were picked up as
  soon as they existed; `every_stored_scenario_document_is_structurally_valid`
  and `every_tier_a_document_runs_headlessly` both green (the three new
  documents are Tier B, so the Tier A loop parses and skips them, same as S2's
  six).

  Gates (serial, `CARGO_TARGET_DIR=target-s2b`, from the worktree root): fmt
  clean; `clippy rest` and `clippy imprint` clean; `cargo test -p impress-scenario
  -p impress-scenario-service -p impress-layout-service -p impress-surface-service
  -p impress-capabilities` all green (0 failed, every count run to completion —
  4+0+4+7+6+1+6+1+1+1+73+2+18+8+0+8+16+38 passed across the five crates' unit and
  integration binaries); `check-kit-deps.sh --strict` OK (`impress-scenario` now
  pure-tier in the table; `impress-layout-service`/`impress-surface-service` each
  reach it, both still within their `store`-tier allowance); `check-kit-standalone.sh
  --strict` OK (19 crates, up from 18, build with nothing else from this
  repository); `check-kit-packages.sh` OK; `check-verb-coverage.sh` OK (43
  services declare, 462 verbs in `docs/verb-effects.md`, 85 crates with a
  verdict, ceiling 20 unchanged); `check-schema-refs.sh` OK (396 call sites, 85
  canonical refs, 0 divergences, unaffected — no schema ref touched);
  `cargo hakari generate --diff` clean (the two new `impress-scenario`
  dependency edges already covered by the existing workspace-hack feature set,
  same as S2's note for imprint-selftest's).

- 2026-09-27 — **W2 (the planner in both hosts)** finished on
  `claude/reflective-w2-planner`, worktree `.claude/worktrees/w2-planner`. The trigger engine is
  split the way `impress-workflow`/`impress-workflow-service` already are: `impress_workflow::trigger`
  (new module, pure) is `tick(enabled_workflows, now_ms, start_delay_ms, cursors, signals) ->
  Vec<DueRun>` — no I/O, no clock of its own (`Clock`/`SystemClock` exist for a host that wants one,
  but `tick` itself just takes `now_ms`), so it is driven by injected values in every test. The
  `start_delay` rule lives here exactly once: `EngineCursors::started_at_ms` is stamped when a host
  creates its engine, and no `tick` call before `started_at_ms + start_delay_ms` produces a run,
  whatever signals are handed in. `schedule` triggers are computed from the clock and a persisted
  per-workflow `last_schedule_run_ms`; `store`/`message`/`job`/`call` triggers fire off
  host-resolved `Signal`s (the host already had to query the store to find them, so this crate
  never guesses at a schema). `store`/`message` debounce per workflow (a window collapses to one
  run); `job`/`call` fire once per matched signal (a finished job or a completed call is a discrete
  event, not a stream).

  `impress_workflow_service::runner` (new module, store-tier) wires the pure engine to a real
  store: `WorkflowEngine::run_once(store, now_ms, workspace)` reads every `state: enabled` row,
  resolves signals with `SqliteItemStore::items_arrived_after`'s rowid keyset (impel-taskd's own
  cross-process trigger-scan primitive, one cursor per schema — the store's declared `kinds`,
  `task@1.0.0` filtered by `verb`/`state` for `job`, `core/verb-call@1.0.0` filtered by `verb`/`ok`
  for `call`), calls `impress_workflow::trigger::tick`, and for each due run acquires a
  [`WorkflowLease`] (new: `impress_fs_lock::FileLock::try_exclusive` on
  `<workspace>/runtime/workflow-<id>.lock`, impel's `WorkerLease` pattern lifted per-workflow rather
  than per-process, so two *different* workflows may run concurrently on the daemon and the app) —
  skipping a run whose lease is already held elsewhere, never retrying it until the next signal.
  `run_workflow` plans with `impress_workflow::plan` and runs every `Effect::Call` through
  `impress_service_core::pipeline::invoke_on` as `CallerIdentity::system("workflow:<id>")`
  (`VerbDescriptor::find` on the name), landing every run in the call log
  (`core/verb-call@1.0.0`) — exactly the plan's "Who runs it" wording.

  **Two hosts.** `impel-taskd` (`main.rs`): a fourth block in the main loop, after the throughline
  scans — `WorkflowEngine::new(now_ms, delay * 1000)` created once at startup (the SAME `now_ms`
  and `delay` the daemon's own settling sleep already computed, so the daemon's 90s guard and the
  engine's `start_delay` are one number), `run_once` called every pass (not gated on
  `store_changed`, since a `schedule` trigger is due on the clock alone). Added
  `impress-workflow`/`impress-workflow-service`/`impress-capabilities` (`full`, so
  `VerbDescriptor::find` resolves a workflow step's verb — the daemon links the whole inventory the
  same way `impress-mcp`/`impress-cli` do) as dependencies; no cycle (`cargo check -p impel-taskd`
  is the proof — `impress-capabilities` does not reach back to `impel-taskd`, a binary). `impress-store-ffi`
  (`workflow.rs`, new): `SharedStore.workflow_tick() -> [String]` — one UniFFI export, one
  process-wide `WorkflowEngine` behind a `OnceLock<Mutex<_>>` anchored at the module's first call
  (close enough to "the app started"; a late anchor only makes the guard stricter). Returns nothing
  for an in-memory store (no workspace to lease against). `impress-workflow`/`impress-workflow-service`
  added to the kit (`docs/kit-manifest.md`, both kit-safe: `impress-workflow` reaches only
  `impress-surface`, `impress-workflow-service` only the kit's own store-tier crates) so
  `impress-store-ffi` can link them without the `impress-capabilities` cycle its own doc comments
  already explain. Regenerated Swift bindings (`build-xcframework.sh`, swiftformat off `PATH`):
  one new method, `workflowTick()`, nothing lost. The app's own timer that calls this on a cadence
  is not part of this package (the row: "Don't wire the app-side timer into Swift beyond the
  export").

  **Proof (Tier A, injectable clock, no real sleeps):** `impress_workflow::trigger`'s own tests —
  `no_run_before_start_delay` (a signal inside the window is dropped, the SAME signal fires once
  `start_delay` has passed), `store_trigger_fires_once_per_debounce_window` (two signals in one
  window collapse to one run; a signal outside it fires again), `job_trigger_fires_on_done`,
  `a_workflow_not_enabled_never_fires`, `schedule_trigger_runs_every_interval_after_start_delay` (5
  tests). `impress_workflow_service::runner`'s own tests, through a real in-memory store:
  `no_run_before_start_delay_through_the_engine` (a matching store row inserted before `start_delay`
  produces nothing until a tick past it; caught a real bug in the first draft — signals resolved
  before the gate check silently consumed the pre-delay row's arrival cursor, so it was never seen
  again once the gate opened; fixed by gating signal resolution on `start_delay` too, not just the
  runs `tick` returns) and `the_lease_prevents_a_double_run` (2 tests). `impress-store-ffi`'s
  `workflow::tests` cover the FFI edge (in-memory store is a no-op; a fresh file-backed workspace
  with no rows ticks cleanly) (2 tests).

  Gates (serial, `CARGO_TARGET_DIR=target-w2`, machine loaded): fmt clean (after `cargo fmt`);
  `clippy rest` and `clippy imprint` clean; `cargo test -p impress-workflow -p
  impress-workflow-service -p impel-taskd -p impel-core -p impress-store-ffi --features
  impress-store-ffi/native -p impress-capabilities` all green (18 + 2 in impress-workflow, 9 + 2 in
  impress-workflow-service, 4 in impel-taskd, 110 + 1 in impress-store-ffi including the two new
  `workflow::tests`, 9 in impress-capabilities's pipeline/policy/tier_a suites — one
  `impress-store-ffi` test, `a_hard_delete_in_another_process_reaches_the_feed_and_the_sources`,
  failed under the default parallel run and passed alone and under `--test-threads=1`: pre-existing
  test-order flakiness from process-wide singleton state, not a regression, confirmed by running it
  in isolation before touching anything); `check-verb-coverage.sh`, `check-schema-refs.sh` (399
  call sites, 85 canonical refs, 0 divergences), `check-kit-deps.sh --strict` (19 kit crates, the
  two new ones reach only what the manifest says), `check-kit-standalone.sh` (unchanged),
  `check-uniffi-bindings.sh` (7 bindings; `workflowTick` gained, nothing lost) all OK; `cargo hakari
  generate --diff` reported no changes both before and after the new dependency edges (no new
  third-party crate entered the graph). **Left for W3**: migrating any Swift background service
  onto a workflow row (this package built the planner and its two hosts, not a Swift migration);
  **left generally**: a job-wrapped run (`task@1.0.0` per workflow run, P4's inline-runner
  precedent) — this package runs a fired workflow's `call` effects through the pipeline directly, as
  the row's execution bullet asked, but does not yet wrap the whole run in its own job handle, so a
  running workflow has no `task-event` progress ring of its own yet (its calls are each on the
  record in the call log, which is the row's actual acceptance bar).

- 2026-09-27 — **W3 (first migration), WIP — stopped for budget, not blocked.** Worktree
  `.claude/worktrees/w3-retention`, branch `claude/reflective-w3-retention`, from origin/main at
  f5a29bb8. The retention verb: `imbib-library-service_retention-cleanup`
  (`crates/imbib-service/src/library_service.rs`), `safety = destructive`, reading
  `imbib.retention.{inbox_days,auto_remove_read,exploration_days}` from the settings registry (R1,
  via a new `imbib_service::store_singleton::default_workspace_dir()` helper and a
  `SettingsStore::open` beside it) rather than taking thresholds as arguments. Ports all three of
  `RetentionCleanupService`'s sweeps (inbox, per-collection feeds, exploration searches), keeping
  its two invariants structurally rather than by convention: every removed inbox/feed paper is
  `dismiss_paper`'d before `delete_item` (never re-enters the inbox), and `delete_item` is a plain
  store delete with no path to Swift's `UndoCoordinator` at all — the PH-H2 bug this file existed to
  prevent cannot recur once the logic is in Rust. Narrowed one piece on purpose: exploration-library
  identity (`explorationLibraryID`) is a `UserDefaults` pointer with no store row, so the verb only
  sweeps exploration when a caller passes `exploration_library_id`; the stored workflow (below) has
  no dynamic args and so covers inbox + feed only — left as follow-up (promote that id into the
  store, table RG-S) rather than scope-creeping this package into owning it.

  The stored workflow: `imbib.retention-cleanup` (`impress/workflow@1.0.0`), a `schedule` trigger
  (`every: "24h"`) calling the verb, `guards.not_before_startup_s: 90`, `author.kind: "system"`,
  seeded `state: Enabled` (not agent-proposed, so D-R6's review gate never applies) by
  `impress-store-ffi::workflow::ensure_system_workflows_seeded`, run once — matched by `name`, so a
  disabled or edited row is never overwritten — the first time `workflow_tick()` runs against a
  workspace that lacks it. This is the one imbib-specific decision living in the shared kit crate
  (`impress-store-ffi`); a second migrated service will want a less ad hoc seeding seam than "hardcode
  it at the tick call site," left as an open question for W4.

  Swift: `RetentionCleanupService.swift` deleted; `imbibApp.swift`'s ungated `cleanupExplorationCollectionsOnStartup`
  (macOS `:580-631`) and its iOS twin deleted along with `LibraryManager.cleanupExplorationCollections`
  (`:485-515`, WF-1 finding #7) — not ported, since unlike the real retention logic it ignored its
  own `days` parameter beyond a zero check and deleted every exploration collection outright.
  `InboxCoordinator.start` (`:97`) now calls `WorkflowTickTimer.shared.start()` (new file), which
  waits its own 90s before the first `SharedStore.workflowTick()` call — belt-and-suspenders with the
  engine's own `start_delay`, because the tick's first call also seeds the workflow row, a write this
  app's startup-gate rule (CLAUDE.md) says must not happen at t=0 either. macOS-only, matching the
  deleted service's own gate (iOS never ran it). `AutomaticWorkUndoTests.swift`'s retention tests
  replaced: the undo-stack proof moved to Rust (it is now structural, not merely tested), and what's
  left in Swift is the mapping shape — one caller (`InboxCoordinator.swift`, source-scanned), the
  90s gate (source-scanned), never touching `UndoCoordinator`.

  **Tests, all green:** Rust Tier A `library_service::tests::retention_cleanup_removes_read_inbox_papers_but_never_starred_ones`
  (scratch store + scratch settings workspace, proves starred-never-removed and the dismiss-before-delete
  order); a full end-to-end workflow test,
  `crates/imbib-service/tests/w3_retention_workflow.rs::retention_workflow_runs_once_after_start_delay_and_the_call_lands_in_the_log`
  (two connections to one on-disk store — `imbib_service::store_singleton` for the verb's own dispatch,
  a raw `SqliteItemStore` for the engine and the call-log sink's `store_override` — proves no run
  before 90s, exactly one run at 90s, the paper actually removed, and a `core/verb-call@1.0.0` row
  naming the verb; and that a second tick inside the 24h window does not run again). `docs/verb-safety.md`
  and `docs/verb-effects.md` updated by hand to the exact rows `crates/impress-capabilities/tests/{descriptor,effects}.rs`
  printed on failure; `docs/verbs/` regenerated via `gen-verb-docs`. PMC `swift build` clean (the
  Swift side compiles; `swift test` not yet run — see below).

  **Gates run:** `cargo fmt -p imbib-service -p impress-store-ffi`; `cargo test -p imbib-service`
  (19 lib tests + the workflow integration test, all green); `cargo test -p impress-capabilities
  --test descriptor` and `--test effects` (green after the doc edits above). **Gates NOT yet run**
  (stopped for budget, not because anything failed): `rust-gate.sh fmt`/`clippy rest`/`clippy imprint`
  across the whole workspace; `cargo test` for the full touched-crate set (`impress-store-ffi`,
  `impress-workflow`, `impress-workflow-service`); `check-verb-coverage.sh`, `check-schema-refs.sh`,
  `check-kit-deps.sh --strict`, `check-kit-standalone.sh`, `check-uniffi-bindings.sh` (no UniFFI
  signature changed, so likely a no-op, but unconfirmed), `cargo hakari generate --diff` (three new
  dev-dependencies were added to `imbib-service`: `impress-core`, `impress-workflow`,
  `impress-workflow-service`, `impress-store-service`, `uuid`, `tempfile` — hakari needs a pass);
  `swift test` in PublicationManagerCore; the imbib macOS/iOS app builds and the pre-push hook; the
  live proof (xcodebuild + `/api/logs`); `docs/chassis-capability-matrix.md` was checked for a
  RetentionCleanupService row and has none to update. Pushed as a WIP branch with a **draft** PR —
  do not merge before a follow-up session finishes the gate list above.

- 2026-09-27 — **W3 verified and submitted as [PR #121](https://github.com/yipihey/impress-apps/pull/121)**
  after merging main at 633aeeef. Review found that the app had never linked the domain verb:
  added the approved P5b imbib-owned `imbib-verbs-ffi` target and its Swift package/build-lane
  provisioning. The kit still has no domain dependency. The GUI initializes the service at its
  exact database path, and both store/settings singletons retain that path. Anchor the engine's
  startup clock at store open, rather than imposing a second 90-second delay after Swift's gate;
  run ticks off the main actor and stop the timer with the coordinator. Seed only when the host
  links the retention verb, and never overwrite an existing workflow.

  Retention review fixed feed scope (Contains members, not the entire owning library), preserved
  the inbox's zero-days keep-forever setting, required dismissal to succeed before deletion,
  counted only successful deletes, and kept exploration cleanup before feed cleanup. The automatic
  workflow still covers inbox/feed; the existing explicit exploration-library argument remains
  the follow-up described in the original entry.

  The acceptance proof exposed a missing L1/L2 seam: call rows had no inserted/deleted IDs, despite
  D-R7 relying on them. Added per-call task-local deduplicated capture at the store mutation seam,
  wrote the two fields into the existing call schema, and taught `why` to include call-only
  evidence (`operation_id: null`) without duplicating operation-backed calls. No new schema ref
  or operation source. Nested/concurrent isolation and the actual retention-to-why path are tested.

  Scratch launches now share one file-backed store for the workflow, domain verbs and settings;
  shared preferences/notification payloads are isolated too. A live attempt found imbib ignoring
  `-httpAutomationPort`; its legacy settings adapter now applies process-only overrides through
  ImpressAutomation. The first attempt was stopped without fixture calls; the subsequent scratch
  store mismatch was fixed and pinned by a Swift two-connection regression test.

  **Gates green:** fmt; clippy rest + imprint; verb coverage and generated reference docs; strict
  kit dependencies; standalone kit (21 crates); UniFFI (8 bindings); schema refs (401 sites,
  85 refs); chassis dependencies; hakari generate --diff. Rust touched/workflow/capabilities tests:
  1,063 passed, 0 failed. PMC: 2,159 XCTest (2 skipped), 112 Swift Testing, then the final 9-test
  regression suite. ImpressKit: 13 + 30 tests; ImpressAutomation: 20 + 78. Store, imbib core and
  imbib verbs xcframeworks rebuilt for arm64 macOS/iOS/simulator with swiftformat absent and no
  `--fast`. Verb marker tables regenerated from the census/descriptor/effects dump with optional
  semantic-search verbs linked. Both pushes passed the unmodified pre-push hook's macOS and iOS
  builds; a scoped xcodebuild wrapper supplied only a worktree-owned derived-data path and disabled
  installation, without skipping any check.

  **Live proof:** own derived build, bundle `com.impress.imbib.w3proof`, port 23331, device
  `w3-retention-proof`, PID 66655 and its PID-owned scratch workspace. All three papers remained
  at 89.749 seconds; by 97.810 seconds the stale paper was gone while starred/fresh papers remained.
  `history-service_why` named `System(workflow:d3d02d6b-df59-4f3e-a432-2f1b43925a9b)`;
  `/api/logs?category=workflow` recorded the tick. `SHKSharingServicePicker` count: 0. Only that
  launched PID was stopped. Evidence: `/tmp/impress-w3-live-proof.json` and
  `/tmp/impress-w3-live-proof-run.log`. No launcher or real store was changed.

- 2026-09-27 — **W4 (proposed workflows)** on a worktree of origin/main, branch
  `claude/reflective-w4-propose`. `history-service_propose-workflows {since?, min_repeats?,
  max_len?}` (mutating, `strict_args`, `effects(reads = ["core/verb-call@1.0.0"], writes =
  ["impress/workflow@1.0.0"])`) added to `crates/impress-store-service/src/history_service.rs`
  beside `save_macro`: an n-gram miner over the call log, grouped by caller (preserving each
  caller's own order — other callers' interleaved calls do not break a sequence), filtered to
  successful calls whose verb's declared `safety.class == Mutating`. `mine_ngrams` tries block
  lengths from `max_len` (default 6) down to 2, chunking each caller's sequence into non-overlapping
  windows and grouping by verb signature; a signature occurring at least `min_repeats` times
  (default 3) becomes one proposal, consumed so a shorter length cannot re-report it as a
  sub-pattern. An argument identical across every repeat stays literal in the proposed step; one
  that differs becomes `"{{event.value.step<i>_<key>}}"` — `WorkflowSpec.params` (a `ParamDecl`
  bound to a record kind, the pane-query type) is the wrong mechanism for a scalar that varies
  between repeats, so the miner leaves it empty and uses the `manual` trigger's own event payload
  as the parameter channel instead, documented at the method and at `steps_from_group`. Every
  proposal is built as an `impress_workflow::spec::WorkflowSpec` (`state: Proposed`, `author: {kind:
  "agent", name: "history-service"}`, `trigger: Manual {}`, `review.required: true` — D-R6) and
  validated with `impress_workflow::validate::validate` before being written; a proposal that would
  not validate is skipped, not written. `impress-store-service` gained a dependency on the pure kit
  crate `impress-workflow` (`Cargo.toml`; no kit-manifest change needed — `impress-workflow` is
  already `pure` tier and a store-tier crate may reach it).

  The proof, in two halves. Mining (`impress-store-service::history_service::tests`): three
  identical two-step triage sessions (`triage-service_set-starred` then `triage-service_add-tag`,
  same caller) yield exactly one `proposed` workflow with `repeats: 3`, two steps, `trigger:
  {"manual": {}}`, `review.required: true`
  (`three_identical_triage_sequences_propose_one_workflow`); three different two-step sequences by
  the same caller yield none (`three_different_sequences_propose_nothing`). Nothing runs from it
  (`impress-workflow-service::runner::tests::a_proposed_workflow_never_runs_through_the_engine`):
  the same mined session, `WorkflowEngine::run_once` called a million ms past `start_delay`,
  produces zero outcomes — the engine's own row filter (`state == WorkflowState::Enabled`,
  `runner.rs:97`) excludes a `proposed` row before any trigger is even evaluated, which
  `trigger.rs`'s doc comment already states as the contract this test exercises end to end rather
  than assumes.

  Docs and tables regenerated: `docs/verbs/history-service.md` and `docs/verbs/README.md`
  (`gen-verb-docs`); `docs/verb-coverage.md`'s `history-service` row (6→7 verbs); `docs/verb-safety.md`
  (`history-service_propose-workflows | mutating`, service row 6→7/2→3); `docs/verb-effects.md` (the
  declared-effects row and the "exercised, unobserved" exception row — the example runs against an
  empty call log, so the spy observes nothing, the same shape as `save_macro`'s neighbor row);
  `crates/impress-capabilities/tests/effects.rs`'s `EXCEPTION_CEILING` 300 → 301 for that one row,
  with the reason recorded beside the constant.

  Gates (serial, `CARGO_TARGET_DIR=target-w4`): fmt clean (after `cargo fmt`); `clippy rest` and
  `clippy imprint` clean (one fix along the way: `consumed[start..start+len].fill(true)` over a
  `needless_range_loop`); `cargo test -p impress-store-service -p impress-workflow -p
  impress-workflow-service -p impress-capabilities` all green; `check-schema-refs.sh` OK (400 call
  sites, 85 canonical refs, 0 divergences); `cargo hakari generate --diff` reported no changes.
  **Not run this session, budget-limited — left for a follow-up pass before merge:**
  `check-verb-coverage.sh`, `check-verb-docs.sh` (docs were regenerated and diffed by hand against
  the census test's own output, but the script itself was not re-run), `check-kit-deps.sh --strict`,
  `check-kit-standalone.sh`. None of these were expected to disagree with what the census and
  effects tests already confirmed by construction (the doc tables were edited to exactly the rows
  those tests printed), but they are unverified and should be the first thing checked before this
  PR leaves draft.

- 2026-09-27 — **W4 draft closeout after merging fresh `origin/main`.** The miner now excludes
  compacted and privacy-reduced call arguments, so a stored `{len, sha256_8}` summary cannot become
  a literal workflow argument (`privacy_reduced_arguments_are_not_embedded_in_a_proposal`). It also
  skips repeated calls with different argument key sets rather than dropping an unmatched key, and
  checks the minimum repeat count without overflowing on a large requested value. The
  `semantic-search` inventory dump showed the coverage table's Total and scalar rows were stale;
  `docs/verb-coverage.md` now matches that dump (472 verbs, 1056 arguments, 946 scalar arguments).

  Final gates with the private `target-w4-gates` cache: `scripts/rust-gate.sh fmt`, both clippy
  shards, `scripts/check-verb-coverage.sh`, `scripts/check-verb-docs.sh`,
  `scripts/check-kit-deps.sh --strict`, `scripts/check-kit-standalone.sh`,
  `scripts/check-uniffi-bindings.sh`, `scripts/check-schema-refs.sh`, and
  `cargo hakari generate --diff` passed. Tests passed for `impress-store-service`,
  `impress-workflow`, `impress-workflow-service`, and `impress-capabilities` with
  `impress-capabilities/semantic-search` enabled. W4 remains draft until W3 lands; main must be
  merged and these checks repeated after that integration.

- 2026-09-27 — **W4 integrated W3 after PR #121 landed on main.** Fresh `origin/main`
  (`35ea75fa`) merged into `claude/reflective-w4-propose` without rebasing. The
  history service retained both W3's call-only `why` entries (`operation_id: null`,
  affected-ID evidence and deduplication) and W4's proposal miner. Both W3 and W4
  plan logs were preserved. The merged semantic-search census printed 473 verbs,
  1,057 arguments and 947 scalar arguments; those exact totals replaced the
  conflicting coverage table values. Reference pages were regenerated with the
  existing default-feature `gen-verb-docs` lane.

  The miner now logs its request (since, repeats and length), each saved proposal
  (ID and counts), and the returned proposal count. A skipped group logs its verb
  sequence and a named error category, without call argument values. This uses
  the store service's existing `log` dependency and the Rust Console bridge's
  existing `verb` category, so the logs reach the app console and `/api/logs`. The proposal is still
  `state: proposed` and cannot run until a person enables it.

  Integration checks in private `target-w4-gates`: formatting, both clippy
  shards, source verb coverage, strict kit dependencies, standalone kit (21
  crates), UniFFI binding names (8), schema refs (403 sites, 85 refs), and
  `cargo hakari generate --diff` passed. The merged touched crates
  (`impress-store-service`, `impress-workflow`, `impress-workflow-service`,
  `impress-capabilities`, `imbib-service`) passed with semantic-search enabled,
  including W3 retention and `why` proofs plus W4 miner proofs. Focused history
  tests passed after the final logging change. The generated-reference-docs
  checker is run after committing, because it treats staged generated pages as
  dirty even when they match the generator output.

- 2026-09-27 — **W4 integrated G7c after PR #118 landed on main.** Fresh
  `origin/main` (`8d102646`) merged without rebasing. G7c's four-verb
  `perf-service`, `perf` Console bridge, and scoped surface Tier A fixture
  remain intact; W4's proposal logs use the already bridged `verb` category.
  The full `semantic-search` census gave 475 verbs, 1,059 arguments (704
  required), 122 described arguments, 80 strict verbs, and 949 scalar
  arguments; the coverage totals were set from that dump. Reference pages
  were regenerated with the existing default-feature generator (44 pages).

  Review found the miner rescanned the remaining call history for each
  candidate, which is quadratic on varied large histories. It now indexes
  fixed-length verb windows once and processes each signature in earliest
  start order, filtering consumed spans after a longer/earlier match. A
  test-only reference of the old scan agrees on deterministic overlapping and
  minimum-repeat fixtures, and a 10,000-call varied history produces no
  spurious proposal. The store-service test for the `IMPRESS_STORE_PATH`
  override now restores its caller's value with a drop guard and uses its own
  temporary path. This prevents later tests in one process from falling back
  to the user's default store.

  **Verification:** fmt; clippy rest and imprint; source verb coverage;
  strict kit dependencies; standalone kit (21 crates); UniFFI (8 bindings);
  schema refs (403 sites, 85 refs); and `cargo hakari generate --diff` passed.
  The combined touched-crate/capabilities suite, including the surface and
  store FFI crates, passed 487 tests (0 failed, 3 ignored) with
  `IMPRESS_STORE_PATH`, `IMBIB_STORE_PATH`, and `IMPRESS_WORKSPACE` set to
  `/tmp/impress-w4-g7c-tests.sQ5WYZ`; it includes the repaired override test.
  Earlier W4 test runs did not carry those process-wide overrides, so their
  isolation is unverified; the final run is the acceptance evidence. Full
  store and imbib-verbs xcframework rebuilds passed all three arm64 slices
  each, with `--fast` unused, swiftformat unavailable, and generated Swift
  bindings unchanged. Gate output is under `/tmp/impress-w4-g7c-*.log`;
  framework output is `/tmp/impress-w4-store-build.log` and
  `/tmp/impress-w4-imbib-verbs-build.log`. The generated-reference-docs
  checker runs after the commit because it considers staged generated files
  dirty even when they match the generator output.

- 2026-09-27 — **W3 and W4 completion.** [W3 PR #121](https://github.com/yipihey/impress-apps/pull/121)
  merged on main as `35ea75fa`; [W4 PR #119](https://github.com/yipihey/impress-apps/pull/119)
  merged as `f7af1c37`, after G7c. W3's isolated live proof already established the 90-second
  startup guard, stale-paper deletion, preservation of starred/fresh papers, and a
  `history-service_why` result naming the workflow run. W4's final explicitly isolated
  touched-crate/capabilities run passed 487 tests, 0 failed, 3 ignored. All requested local quick
  gates, full store and imbib-verbs xcframework rebuilds for macOS arm64, iOS device arm64 and iOS
  simulator arm64, and the unmodified pre-push macOS/iOS builds passed for both packages. W4's
  store-service test helper restores its environment override. Earlier Rust test runs without
  explicit process-wide store/workspace overrides have unverified isolation; the observed failure
  showed an initialized singleton, not a path or data change. No real store was inspected for
  this completion handoff. The automatic W3 workflow still cannot discover the exploration-library
  ID held only in legacy UserDefaults; explicit `exploration_library_id` remains available.
  The combined main at `f7af1c37` passed an explicitly isolated full native workspace run,
  serially: 4,291 passed, 0 failed, 23 ignored, including doctests. The initial parallel run hit
  the known impel-tools backend-state race. Evidence: `/tmp/impress-open-packages-workspace-serial.log`;
  owned scratch `/tmp/impress-cargo-tests.8X6GhB/workspace`. S3 has since started in
  `s3-record` / `claude/reflective-s3-record`; its implementation and live proof are not yet
  verified. The later packages remain unstarted.

- 2026-09-28 — **W3 exploration identity follow-up**, commit `a3752f6b` plus the resolver-name
  correction. `LibraryManager` now migrates its legacy `explorationLibraryID` pointer into the
  existing Device settings file and mirrors subsequent setter changes. The setting is marked
  internal and omitted from generated user panes; the existing settings registry remains the
  persistence mechanism, with no new record kind, schema ref, or public verb argument. Retention
  uses the stored UUID only when the explicit argument is absent, and ignores malformed IDs. The
  stored workflow's 90-second delay and seed-if-missing behavior are unchanged. Startup now reads
  the pointer from `LibraryManager.init`, ensuring migration completes before the retention
  workflow's delayed first run even when no view opens the exploration library. Scratch-only Rust
  and PMC tests cover migration, precedence and UUID handling. Shared gates and native builds are
  pending the root review.

- 2026-09-27 — **S3 implementation and first isolated native proof.** Added
  `impress-scenario-service_scenario-record` (trace, or inclusive time window with one exact
  caller), a pure capture matcher, and losslessness/output-ID metadata on the existing call row.
  `replay = full` is opt-in on the 51 layout/surface methods; private fields still prevent full
  recording, and full arguments must fit below 16 KiB. Bounded output-ID extraction follows local
  schema references and fails closed on private/unknown branches. The recorder reports omitted
  calls, suppresses children of retained parents, refuses dependencies on omitted producers and
  truncated ID metadata, and preserves outcomes. App identities are not promoted to `person`.
  Scenarios use the existing spec and schema ref; no new widget, action or record kind was added.
  Native surface dispatch now enters the pipeline around its existing runtime, preserving the
  pane and store override. Tier B sends canonical verbs through `/api/verb`; failed native surface
  event replays fail the scenario instead of passing silently. The output-schema lookup is cached.

  The first hosted proof passed in an isolated impress at port 23333, device
  `codex-s3-proof-*`, distinct bundle `com.impress.s3proof.impress`, and the PID-owned
  `impress-unit-tests-229/workspace/impress.sqlite`. It used trusted native-person dispatch to
  star/tag/flag three scratch papers, recorded four calls, checked an ID capture, stored and fetched
  the scenario, edited its field expectations once, reset the state, replayed via HTTP, and checked
  the resulting stars/tag/flag and live verb logs. The test host exited. Evidence:
  `/tmp/impress-s3-proof-75721661-fcf9-40fe-882f-440e6d836ffa/output/host-229/` and
  `/tmp/impress-s3-proof-run-cohort.log`. This is a native-dispatch proof, not a claim that the
  ordinary publication-list actions are audited: those still use the legacy RustStoreAdapter
  path. A second hosted proof through the native surface-event path is being completed.

  Rust verification so far: 579 touched-crate tests passed (4 ignored), 7 caller-selection tests
  passed after the identity fix, the event-failure regressions passed, and the final capabilities
  run passed 30 tests (2 ignored). Format, both workspace clippy shards, source coverage, generated
  reference pages, strict kit dependencies, standalone kit, binding/schema checks and hakari diff
  all passed. Semantic-search census/descriptor/effects comparisons passed 4/7/6 tests; the effects
  table stays at 301 exceptions, with 82 example-verified and 93 catalogue verbs. The new recording
  example seeds its audit row before the effects-spy window and verifies a real scenario write.

  Native build finding: copying an archive is unsafe when a shared Rust descriptor layout changes.
  The copied ImbibCore contained the old `VerbDescriptor` layout under the same crate hash as the
  new store/verb archives; the first proof returned `no such verb` for all triage verbs. Full
  ImbibCore, ImbibVerbsFfi and ImpressStoreFfi rebuilds passed macOS/iOS-device/iOS-simulator arm64;
  ImpelTools was rebuilt for its supported macOS arm64 target. Swift bindings were unchanged.
  impress now enables dead-code stripping, matching imbib's link of the overlapping static
  archives. All rebuilds kept swiftformat off PATH, used `IMPRESS_SKIP_X86=1`, and never used
  `--fast`. Logs: `/tmp/impress-s3-*-build*.log`, `/tmp/impress-s3-final-*.log`,
  `/tmp/impress-s3-quick-gates.log`, `/tmp/impress-s3-touched-tests.log`.

  Remaining boundary: linked native surface effects inherit the parent trace. Effects delegated
  through the Swift `SharedVerbHost`/ImpelTools callback still cross a context-losing boundary;
  expanding that callback's identity/trace contract is not part of this capture-matcher package.

- 2026-09-27 — **S3 final native proof and schema review.** Both hosted tests passed on the
  final rebuilt archive cohort: direct native triage (4 calls, no omissions, one ID capture)
  and native surface triage (6 calls selected, 3 parent dispatch steps retained, 3 duplicate
  children reported as omitted). Each stored and fetched the scenario, edited expectations
  once, reset the scratch papers, replayed over HTTP, and verified their stars/tag/flag and live
  verb logs. Both Tier B reports passed with no skips. The proof used port 23333, distinct
  bundle `com.impress.s3proof.impress`, its own device ID and PID-owned workspace
  `impress-unit-tests-12083/workspace`; PID 12083 exited after testing. Evidence is
  `/tmp/impress-s3-proof-6f13b826-efab-4b6e-8e7b-78aa17735877/output/host-12083/`,
  `/tmp/impress-s3-proof-run-final.log`, and its adjacent result bundle. These are native
  dispatch tests, not GUI clicks or a claim about the unaudited ordinary publication list.

  The first surface run correctly exposed a conservative false refusal: the result schema is
  recursive even when the actual rendered tree is finite. Audit extraction now follows the
  bounded actual value through local references and discriminated/nullable branches, retaining
  the private/unknown-branch refusal. Regressions use the real `SurfaceDispatchResult` schema;
  arbitrary table-row JSON IDs remain excluded. Eleven audit regressions and two real-schema
  regressions passed. The post-review isolated native run passed 434 tests, 0 failed, 3 ignored
  across seven affected packages; fmt and both workspace clippy shards passed. The earlier
  broader 579-test run covers the other touched crates. Final native rebuilds covered all three
  arm64 slices for ImbibCore, ImbibVerbsFfi and ImpressStoreFfi, plus macOS ImpelTools; generated
  Swift bindings stayed unchanged. Logs: `/tmp/impress-s3-post-review-*.log`,
  `/tmp/impress-s3-final-cohort-*.log`, `/tmp/impress-s3-proof-build-final.log`.

- 2026-09-27 — **Audit flush barrier prerequisite after G5.** The post-G5 full native workspace
  run on main at `85cf0520` stopped in
  `impress-workflow-service::runner::tests::a_proposed_workflow_never_runs_through_the_engine`:
  the proposal query saw no repeated sequence. Focused native reruns, including all three
  workflow-service tests together, passed. This did not establish the cause of that failure. It
  did expose a correctness hole in the audit sink: `flush()` treated 20 ms of unchanged global
  counters as an empty queue, even though accepted records could still be queued or in flight.
  On `claude/audit-flush-barrier`, a marker now travels through the same bounded FIFO as records;
  the writer acknowledges it only after processing all earlier messages. Regular submissions
  still use nonblocking `try_send` and count overflow. Flush has a five-second deadline and
  returns a typed timeout or disconnect error rather than claiming success. Tests require a
  successful drain; scenario recording returns a store refusal on failure; impress and imprint
  CLIs report an audit error and exit nonzero before printing a result. A held-writer/queued-record
  regression and timeout/disconnect checks cover the barrier.

  The first broad run separately exposed a pre-existing job test race: `finish_job` makes the
  row terminal before `append_event("finished")`, so the test could snapshot `max_seq` between
  those writes. The test now waits for the actual final event with a bounded deadline before
  asserting an already-consumed cursor; production job ordering is unchanged. The final isolated
  native affected-crate run passed 331 tests, 0 failed, 2 ignored across 27 groups including
  doctests. Fresh scratch workspace: `/tmp/impress-cargo-tests.BYvwYN/workspace`; log:
  `/tmp/impress-audit-flush-final-tests-v2.log`. Workspace formatting and focused native
  all-targets clippy for the changed crates and both CLIs passed. No app or real store was run.
  A full native workspace rerun after integration remains for the main branch.

- 2026-09-28 — **R3 (imprint registries), implementation and local gate checkpoint**,
  branch `claude/reflective-r3-imprint`, worktree `r3-imprint`, created from main
  `9d7ee7a4`. The submitted P8 head `d1ee36de` is merged locally for native
  compatibility; P8 must land on main before this package is merged.
  Thirteen General/Editor/Documents controls now read `@ImpressSetting`, with
  exact original defaults and legacy keys. First reads copy old values; they
  never delete or overwrite the old UserDefaults values. Five already-declared
  automation settings drive the generated imprint pane and the server's
  serialized startup/change-feed snapshots. The existing network bearer stays
  outside agent-readable settings. Launch overrides remain process-only.
  Cross-process settings writes now take a shared cursor lock and advance the
  global cursor even when writes share a clock tick or affect different scope
  files; Unix cache fingerprints also include the atomic replacement's inode.
  The pane reseeds only on changes to its own section's values.

  Sixty imprint menu/layout bindings are seeded in `impress-keymap`: 42 static
  commands and 18 context-dependent layout ordinals. The chassis/editor focus
  choice stays intact, shared menus take an explicit app ID, and other hosts
  keep their previous defaults. Menus, the new Keyboard settings section and
  the existing shortcut-help window read one registry. The old help's bare Tab
  was wrong: SwiftUI's `.keyboardShortcut(.tab)` uses Command-Tab. Its Veusz and
  version-history chords had no live handlers. Editor-local AI-task chords are
  still owned by the shared `InlineAITaskCatalog`, outside this app-menu seed;
  dialog default/cancel keys and local Template Editor shortcuts are likewise
  outside this package. Command-palette overrides remain D-R13's later work.
  App-specific LaTeX/export/AI/integration preferences and shared appearance/modal
  editing settings remain owned by those subsystems; this does not claim every
  imprint preference has migrated.

  Local validation: 315 Rust tests passed, 0 failed, 3 ignored, across 22 test
  groups (`/tmp/impress-r3-touched-tests.log`, scratch
  `/tmp/impress-cargo-tests.ZhNEPe/workspace`). Both clippy
  shards, fmt, verb coverage/docs, strict kit dependencies, Swift kit boundary,
  standalone builds of 21 kit crates, bindings, schema references and hakari
  `generate --diff` pass. Six Swift keymap tests and eight settings tests pass
  against the rebuilt native store; the latter exercise all thirteen actual
  legacy migrations, reopening, external writes and launch-override exclusion.
  Twelve supported arm64 framework builds pass, including iOS slices where
  supported, with `IMPRESS_SKIP_X86=1`, swiftformat off PATH and no `--fast`.
  Logs are `/tmp/impress-r3-{native-*,swift-keyboard,swift-settings}.log`.
  The newly exercised pre-push interlock stage now builds and verifies unique
  test bundles, then injects owned ports, device IDs and scratch paths into a
  copied xctestrun before launching its unchanged three suites. Three no-launch
  Python fixture tests pass. Hosted imprint proof, PMC checks, normal pre-push,
  PR and merge are still pending at this checkpoint.

- 2026-09-28 — **R3 native verification**: the mounted imprint Automation pane
  installed surface `cbe41e0b-6740-4703-a246-6d8e97dd1039`, then the independent
  CLI changed `imprint.automation.log_requests` to false. The same surface row
  and a native pane model showed false; the settings feed restarted the listener
  on the same isolated port (56754) and rotated its loopback token. Native menu
  equivalents and all 60 registry bindings were checked; a legacy saved value
  was copied without deletion and read back by the CLI. `/api/logs` returned 200.
  Proof evidence is
  `/private/tmp/impress-r3-proof-kkc8spwk/output/host-56007/proof.json`; the app
  process exited. This is a mounted SwiftUI pane and its shared rendered model,
  not a claim of physical clicks or private SwiftUI-state introspection.
  `scripts/test-imprint-registry-native.py --derived-data <owned-build> --cli
  <built-impress>` reproduces it; the runner requires the exact isolated bundle
  ID `com.impress.imprint.codex.r3`. The build needs the existing ImpressLayout
  and ImpressSurface products linked explicitly into the test target.
  The initial proof invocation used qualified CLI names for unique methods;
  the final proof uses the generated `get`/`set` names and passes (1 test,
  1.136 s). All 33 focused PMC settings/keymap contract tests pass, as does the
  arm64 imprint iOS simulator build. Normal pre-push and hosted CI remain.

- 2026-09-28 — **S2b interpreter gaps, implementation checkpoint** on
  `claude/reflective-s2b-gaps`. Added bounded `store` predicate selection using
  the existing `store-query-service_list-items` and `get-item` verbs through
  the same Caller in either tier. Predicates reuse the closed field checks;
  captures expose the selected envelope and parsed payload. Truncated payloads,
  missing captures, exhausted bounds and no matches fail explicitly. No kit
  dependency, verb argument, schema reference or record kind was added.
  `best_effort` accepts only a call and its arguments/identity, without an
  assertion or capture; operational refusals appear in report detail while
  later steps continue. Authoring errors still fail before execution. The
  `{{!state.field}}` escape preserves `{{state.field}}` for a nested surface,
  including a surface serialized inside a string; `{{!uuid}}` stays literal.
  A checked-in Tier A scenario selects a seeded manuscript, tolerates an
  optional lookup refusal and validates an escaped surface. Initial tests:
  39 passed, zero failures, covering paging, bounds, truncation, templates,
  operational failures and existing scenarios. Full gates and native proof
  remain pending. Existing native catalogue entries retain their current route
  assertions; this change supplies the missing interpreter mechanisms.

- 2026-09-28 — **S2b final verification**: 84 integrated Rust tests passed,
  zero failed, three ignored (`/tmp/impress-s2b-final-tests.log`). Both clippy
  shards and all quick gates pass. All twelve supported arm64 framework builds
  pass with swiftformat off PATH, `IMPRESS_SKIP_X86=1` and no `--fast`.
  The isolated imprint proof passed two XCTest cases, two stored scenarios,
  three surface cases and fourteen layout cases. The new scenario selects its
  own stored row, reports optional 422/404 refusals, preserves a nested surface
  template until its click emits the expected value, and deletes that surface.
  Evidence: `/tmp/impress-g5-proof-4pgger3v/output/gaps-run.json` and `proof.json`.
  The first proof fixture searched for a read-only demo audit row; read-only
  calls intentionally are not recorded, so the corrected fixture selects its
  own scenario ID. The app exited. Native reproduction uses
  `scripts/prove-strict-args.py imprint --scenario-gaps --cli <this-revision-cli>
  --derived-data <owned-target-g5-directory>`. No user's apps or data were used.

- 2026-09-28 — **R3 hosted smoke check**: the normal push passed, but hosted
  run 36488811160 built and launched impart-iOS (PID 84886) then reported it
  missing. The `launchctl list | grep -q` check under `pipefail` can report a
  false failure when the producer gets a closed pipe; a large process-list
  fixture reproduced that behavior. Read the complete list into a file before
  matching, and print it on a real absence. This fixes the check without
  relaxing it; the original run did not preserve enough diagnostics to prove
  whether that defect or an actual process exit caused its failure.

- 2026-09-28 — **R3 normal push and review checkpoint**: ready PR
  [#130](https://github.com/yipihey/impress-apps/pull/130) follows P8 #129. The
  installed pre-push symlink originally selected main's older script even from
  the R3 worktree; the first attempt was stopped during impart's build, before
  that host launched. A worktree-aware dispatcher now runs the invoking
  worktree's complete hook. The committed installer replaces only that exact
  legacy link atomically and refuses custom hooks. All ten Python installer
  and isolation-runner fixtures passed. The complete normal retry passed the
  impel, impart and impress interlock suites with unique bundles, ports, device
  IDs and owned stores, then macOS imbib and arm64 iOS simulator imbib. Evidence:
  `/tmp/impress-r3-push2.log` and
  `/var/folders/nt/x289rxb53njg4qpvf0b6l8080000gn/T/impress-pre-push.aP2NSB/`.
  Hosted checks and fresh-main verification before merge remain. No user's app,
  launcher or store was used.

- 2026-09-28 — **Post-batch retention fixture repair**: the full native
  workspace run at `158502c2` failed in the impel-service retention preview
  test (zero sweepable rows instead of two). The fixture queried a strict
  millisecond cutoff in the same tick as its writes. It now waits, with a
  five-second bound, until the cutoff is strictly after the newest fixture
  timestamp. Production retention semantics and all row-count assertions
  remain unchanged. The touched-crate/capabilities run passed 52 tests, zero
  failures, three ignored; the regression passed 20 consecutive runs. Both
  clippy shards passed. Logs: `/tmp/impress-retention-cutoff-tests2.log` and
  `/tmp/impress-retention-cutoff-repeat.log`. The first test build exhausted
  disk space before running; obsolete session caches were cleared before retry.

- 2026-09-28 — **S3 nested host-context follow-up (implementation pending
  verification)**: the surface FFI now carries the current pipeline caller,
  trace and parent call in a separate, strictly parsed context value across
  `SharedVerbHost` into `impel-tools`; domain arguments cannot set those fields.
  `DefaultExecutor` re-enters that context around its `spawn_blocking` host
  callback, and the existing app transport continues trace and parent
  forwarding from the nested pipeline call. Added focused context round-trip,
  malformed-context, argument-separation and Rust callback tests, plus an
  owned native audit-lineage proof through the Swift ImpelTools callback. The
  additive UniFFI export and callback signature require binding regeneration;
  native builds/proof and workspace verification remain for integration.

- 2026-09-28 — **S2c: surface HTTP catalogue converted to stored scenarios.**
  On `claude/reflective-s2c-surface`, all three `surface.http.*` entries now
  use the shared interpreter and checked-in JSON with canonical inventory names.
  The catalogue selects the REST projection of the shared caller, preserving
  method/path/query/status/wire-version checks; other canonical calls keep
  `/api/verb`. Unknown query arguments reach the server instead of disappearing,
  `surface-show` posts to `/show`, and update/wait use their existing routes.
  The routes case checks the emitted payload and required deletion; invalid
  create compares the entire surface list before/after. Escaped nested surface
  templates remain intact. Captured JSON now works in expectations, including
  typed arrays; invalid capture references fail validation. Required teardown
  failures now fail the report, while all cleanup is attempted and explicit
  `best_effort` remains optional. No record kind, schema ref, public verb
  argument, widget/action kind or dependency changed.

  Final isolated touched-crate and capabilities tests: **249 passed, zero failed,
  three ignored** (`/tmp/impress-s2c-tests-final.log`). Both clippy shards, fmt,
  verb coverage/docs, strict kit dependencies, kit standalone, Swift kit boundary,
  bindings, schema refs and hakari diff passed (`/tmp/impress-s2c-final-*.log`).
  All twelve native frameworks were verified on the final sources for their
  supported arm64 slices, without swiftformat or `--fast`
  (`/tmp/impress-s2c-frameworks-final.log`). Owned imprint proof
  `/tmp/impress-g5-proof-7_ulo7mz/output`: two XCTest cases, two stored scenarios,
  all three surface entries and all fourteen layout entries passed, zero skips.
  The proof used its own bundle, derived data, port 63381, device and store;
  owned host PID 80634 exited. Native symbol/SQLite checks passed.
  Twelve of twenty-five catalogue entries are documents; thirteen remain code
  (eleven layout/gate/restoration entries and two platform imprint entries).

- 2026-09-28 — **S2e: `layout.console_pane` converted to a stored scenario.**
  The scenario preserves the default layout ordinal, detail-side vertical
  split, `search: layout` and the info/warning/error level state. It captures
  the server's `/api/logs/stream` cursor before splitting, captures the new
  tile id from the gesture result, verifies the exact pane `view_state`, then
  requires one fresh layout log message to contain the pane prefix, search
  summary and level summary case-insensitively within 3 seconds. Required
  scenario teardown closes the tile; global layout restoration remains in
  the catalogue. The closed log-wait vocabulary now supports capture-templated
  needles/cursors, server cursor capture and bounded 1–60-second waits, with no
  expression language or verb signature changes. Added interpreter validation
  and caller coverage. No build or test run was performed in this package;
  verification remains with the parent task.

- 2026-09-28 — **S2d: layout surface-dispatch capability stored as a scenario.**
  `surface.show_and_dispatch` now embeds its surface spec in
  `crates/impress-layout-service/scenarios/surface.show_and_dispatch.json`
  and runs canonical `impress-surface-service_*` calls through the REST-route
  projection. Its assertions cover the initial slider render, `change` to 17,
  the fresh render and persisted-state reads, a successful click effect, the emitted
  `bins-chosen` event with its payload, and required deletion in teardown.
  `{{!state.bins}}` preserves the surface engine's payload template from
  scenario interpolation. The Rust render contract supplies the exact
  `tree.root.node.items.1.node.value` path. Inventory and structural checks
  cover this embedded document. The combined Tier B catalogues now have thirteen
  documents and twelve remaining code entries (ten layout/gate/restoration
  entries and two platform imprint entries). This is an implementation
  checkpoint; final tests and native gates are being run by the parent task.
- 2026-09-28 — **S3 host-context verification completed.** The nested
  callback now preserves the pipeline context across `spawn_blocking`, the
  SharedVerbHost callback, Swift and ImpelTools. Separate trusted metadata
  carries caller, trace and parent; domain arguments cannot choose them. The
  generated bindings were rebuilt with all twelve supported full arm64
  framework scripts (no swiftformat/fast mode). Both clippy shards and every
  quick gate passed. The final combined native-feature Rust run passed
  **367 tests, zero failed, four ignored** (`/tmp/impress-s3-combined-tests3.log`).
  An earlier import-papers example readback failed once; the same graph passed
  on retry and default capabilities passed separately. Its failure now includes
  the complete ImportSummary for diagnosis; no assertion or fixture was weakened.

  The owned native proof passed one XCTest with no skips, checking actual audit
  rows for a human surface dispatch and its memory-service child: same trace,
  exact parent call. Evidence: `/tmp/impress-s3-proof-gpaxukku/output/host-48118/`.
  The first proof attempt stopped at the bootstrap ownership check because
  Python resolved `/tmp` to `/private/tmp` while Foundation canonicalized only
  the existing parent. The runner now keeps the consistent `/tmp` spelling;
  the ownership checks remain unchanged. Native symbol checks passed and the
  owned host exited. Reproduce with `scripts/test-s3-host-context-native.py`,
  an owned `target-s3-*` build using bundle `com.impress.s3proof.impress`, and
  the built CLI. Normal pre-push passed macOS and arm64 iOS simulator builds
  (`/tmp/impress-s3-host-context-push.log`), with installation disabled and
  worktree-owned derived data. No user's app or store was used.

- 2026-09-28 — **W3 exploration identity verification completed.** Automatic
  retention can now discover the migrated internal settings pointer when the
  existing explicit argument is omitted; invalid explicit IDs do not silently
  select another library. The setting stays out of generated preference panes.
  The final touched-crate/capabilities run passed **340 tests, zero failed,
  three ignored** (`/tmp/impress-w3-discovery-final-tests.log`). Both clippy
  shards and all quick gates passed (`/tmp/impress-w3d-final-*.log`). All twelve
  native frameworks were rebuilt for their full supported arm64 slices, without
  swiftformat or fast mode (`/tmp/impress-w3-discovery-frameworks.log`). The
  isolated LibraryManager suite passed **20 tests**, including migration before
  any getter and authoritative settings/mirrored updates, using a scratch store
  and unique defaults suites (`/tmp/impress-w3-discovery-swift-tests.log`). The
  normal pre-push hook passed macOS and arm64 iOS simulator builds with owned
  derived data and installation disabled (`/tmp/impress-w3-discovery-push.log`).
  No running app, launcher or user store was touched.

- 2026-09-28 — **S2d verification completed.** The final touched-crate and
  capabilities run passed **146 tests, zero failed, three ignored**
  (`/tmp/impress-s2d-final-tests.log`). Both clippy shards and all quick gates
  passed (`/tmp/impress-s2d-final-*.log`). The two affected native archives,
  impress-store-ffi and impel-tools, were rebuilt for all supported arm64
  slices; unchanged coherent frameworks were copied with COW. Owned imprint
  proof `/tmp/impress-g5-proof-6vwvm7kk/output/` passed both XCTest cases,
  the stored scenarios, all three surface and all fourteen layout entries
  with zero skips. `surface.show_and_dispatch` ran the document and verified
  its render/state/event/cleanup assertions. Native symbol checks passed and
  owned host PID 56685 exited. No user's app or store was used.
