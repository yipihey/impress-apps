# ADR-0020: Sync Engine Implementation

**Status:** Accepted
**Date:** 2026-07-25
**Authors:** Tom (with Claude)
**Implements:** ADR-0007 D27 (Phase 3), which explicitly deferred the engine
design to "an implementation ADR". This is that ADR.
**Scope:** impress-core graph store, imbib (macOS + iOS)

---

## Context

ADR-0007 defined a four-phase sync roadmap and specified Phase 3 as
record-level CloudKit sync of the SQLite graph store. It fixed the CKRecord
mapping, the last-writer-wins conflict rule, and the bootstrap sequence — but
deliberately left the *mechanism* open: how local changes are detected, where
merge logic lives, which process runs the engine, and how the Swift/Rust split
falls.

Implementation (Phases A–D, 2026-07-24/25) answered those questions, and in
several places the answers required amending ADR-0007 rather than following it
literally. Those amendments are recorded here, with the reasoning, so a future
reader does not "fix" a deliberate deviation.

Motivating requirement, in the user's words: curate publication libraries and
work on the same manuscripts on the go, on the laptop, and at the office. One
logical library across iPhone, laptop, and office Mac.

---

## Decisions

### D1. Change detection is a trigger-fed outbox, not a clock scan

`sync_outbox` (durable, in the main database) is written by SQLite triggers on
`items`, `item_tags`, and `item_references`.

**Why not a "changed since clock" scan:** it cannot distinguish *changed
locally* from *changed by a remote apply*. Remote records arrive carrying
clocks newer than any local watermark, so every pull would re-push what it just
received — a guaranteed echo loop.

**Why triggers rather than call-site instrumentation:** the store has two Swift
façades (`ImbibStore`, `SharedStore`) plus direct `SqliteItemStore` use, and
new write paths get added routinely. Triggers make capture structural: any SQL
write through the store is caught, and a new call site cannot forget to
participate. A façade-level integration test (`sync_outbox_facade.rs`) pins
this by driving writes through the high-level API and inspecting the outbox
from a second connection.

**Echo suppression** uses a per-connection `TEMP TABLE _sync_apply`; triggers
carry `WHEN NOT EXISTS (SELECT 1 FROM _sync_apply)`. Per-connection is exactly
right: a remote apply on the engine's connection must not enqueue, while a
sibling process writing concurrently still must.

Consequence: triggers are TEMP (SQLite forbids main-database triggers from
referencing TEMP tables), so they are created per connection at open. Ad-hoc
`sqlite3` CLI writes therefore bypass capture — acceptable, since all writes
are supposed to go through the store.

### D2. Enqueues use UPSERT, not `INSERT OR REPLACE`

SQLite silently downgrades `INSERT OR REPLACE` to ABORT semantics inside
foreign-key-action trigger contexts. This surfaced as a `UNIQUE constraint
failed` when deleting a library (whose `ON DELETE SET NULL` cascade fires the
items trigger). `ON CONFLICT(kind, record_name) DO UPDATE` survives that
context. Verified directly against `sqlite3` before adopting.

### D3. Every envelope row carries a real HLC clock

Before Phase A, non-operation items had `logical_clock = 0` forever — only
operation items were stamped, so there was nothing for LWW to compare.
`insert_item` now stamps `next_hlc_clock()` when the incoming clock is zero
(a nonzero clock is preserved verbatim — that is the remote-apply and
undo-restore path), and `materialize_operation` stamps the operation's clock
onto the target row, since operation and materialised change are one causal
event. Pre-existing rows were backfilled with `modified << 16`, which is
comparable across devices because it uses the same packing as the HLC.

`hlc_observe_remote` replaces the orphaned `merge_clock`, which performed a
Lamport `max+1` on the packed integer without touching HLC state — local and
merged clocks could diverge. The receive rule now raises
`hlc_last_wall_ms`/`hlc_counter` component-wise.

### D4. Only non-operation envelope items sync (amends ADR-0007's tier table)

Materialised state syncs; operation history stays device-local.

**Why:** `update()` always records an operation, so syncing operations to a
peer that re-materialises them would double-apply and re-bump clocks — an echo
machine. Whole-record LWW over materialised columns is exactly what the ADR's
conflict rule needs and nothing more. It also renders ADR-0007's "conditional
compactable" clause moot: nothing with `op_target_id` syncs, at any retention
tier.

**Accepted cost:** concurrent tag edits to the *same item within one sync
window* are whole-record LWW — one set loses. Rare for a single user, and one
gesture to redo. Undo/time-travel remains per-device, which it already was in
practice.

### D5. Deletes propagate as `ImpressTombstone` records; no `is_deleted` flag

ADR-0007 listed both an `is_deleted` field on `ImpressItem` *and* a separate
tombstone record type, and its own Open Question #4 flagged the contradiction.
Tombstones win: the machinery already existed (`record_tombstone`,
`list_tombstones_since`, `cleanup_tombstones`), tombstones age out at 90 days
whereas soft-delete flags accumulate forever, and there is no live `is_deleted`
column to map.

Wired at the single chokepoint `SqliteItemStore::delete()`, which both façades
funnel through. In the same transaction it records the tombstone, enqueues the
delete, prunes any pending push for that id, and pre-enqueues edge deletions
before the cascade removes them.

**Delete-vs-edit race** (deterministic on both peers): an incoming tombstone
deletes the local item **unless** `local.modified > tombstone.deleted_at`, in
which case the edit resurrects the item and re-enqueues it for push. Ties
favour the delete.

### D6. Unmapped envelope columns fold into `envelope_json`

`canonical_id`, `visibility`, `message_type`, `produced_by`, `version`,
`batch_id`, `retention` are absent from ADR-0007's field list and would have
been silently dropped on bootstrap. They are carried as one JSON string field
rather than seven CKRecord fields, so the CloudKit schema — a contract, once
deployed — stays frozen as the local envelope evolves.

### D7. Reference records have deterministic names and no tombstones

`recordName = "ref_" + sha256(source|target|edge_type)[..32]`. Deterministic
naming means two devices independently creating the same edge collide onto one
record with identical content, which is idempotent rather than conflicting.
Edge deletion propagates as CKRecord deletion; tombstones are reserved for
items, which need the delete-vs-edit arbitration. Remote references whose
endpoints have not yet arrived are deferred in `sync_pending_refs` and retried
after every item batch.

### D8. One custom zone, `ImpressGraph`, in a new container `iCloud.com.impress.suite`

Resolves ADR-0007 Open Question #5. Per-library zones are chicken-and-egg
(libraries are themselves items), force zone lifecycle management onto library
CRUD, and break cross-library edges. Phase 4 sharing can migrate a chosen
library's subtree into a shared zone at that time; record types and names are
zone-independent, so nothing is foreclosed.

The container is new and shared suite-wide rather than reusing
`iCloud.com.impress.imbib`, because the store is shared across apps. The legacy
container stays in the entitlements — the KVS settings sync uses it.

### D9. Rust owns merge; Swift owns CloudKit

All conflict resolution, tombstone arbitration, HLC observation, FTS refresh
and tag/reference reconciliation live in `impress-core/src/sync.rs`. Swift owns
only transport, codec, scheduling and UI.

The engine holds **no** merge logic — even `serverRecordChanged` hands the
server record to `syncApplyRemoteItems` and reads the report — so LWW has
exactly one implementation, the one the convergence suite exercises.

**LWW order:** HLC clock → author kind (Human > Agent > System) → author id
lexicographic → content key. The final content-key tiebreak amends ADR-0007:
two stores can mint identical clocks in the same millisecond, and a row's
author fields describe its *creator*, unchanged by later edits, so full ties
with differing content would otherwise diverge permanently.

**Manuscript safety net:** when a losing local manuscript has unpushed body
edits, a `sync-conflict-backup` revision is created before the overwrite. The
user's writing is never silently lost to a merge.

### D10. Exactly one engine host per device, by lease

`SyncLease` (ImpressKit) is a JSON lease file beside the SiblingDiscovery
heartbeats: 60s TTL, renewed every 20s, stealable when stale. Only the holder
constructs `CKSyncEngine`. In 3.0 imbib is the only host; imprint and impel
still *capture* changes (triggers are process-independent) and those push on
imbib's next run. A `syncApplied` Darwin notification wakes siblings to
re-query.

### D11. The engine starts after the startup grace period

Constructed no earlier than 120s after launch, via the `BackgroundScheduler`
pattern. This respects the standing render-loop invariant (no store mutations
or events in the first 90s — see CLAUDE.md); because the engine does not exist
before then, no inbound apply can violate it. `ImpressRuntime.isUnitTestProcess`
short-circuits the launcher entirely.

**Availability is an ordered gate**, each step with a user-facing explanation
and a machine-readable code: test process → feature flag → entitlement probe
(`SecTaskCopyValueForEntitlement`; a `CKContainer` is *never* constructed
unguarded, the crash class fixed in 5edde41) → account status → lease. Any
failure degrades silently to Phase-1 local behaviour and is explained in
Settings.

### D12. First sync merges independently-imported libraries

Two devices that each imported the same papers before sync existed would
otherwise converge into a library of duplicates. `FirstSyncMerge` pairs
publications on DOI → bibcode → arXiv id, keeps the lexicographically smaller
UUID as survivor (deterministic on both peers, so they agree without
coordinating), unions tags, ORs read/starred, re-points collection edges, and
deletes the loser through the normal delete path so its tombstone makes the
peer's pass a no-op.

It only merges groups spanning **two or more origins**. Same-origin duplicates
are the user's own double-import and are left to the existing manual dedup UI —
silently deleting there would be a surprise.

### D13. `busy_timeout` on every connection

5000ms on the writer and each reader-pool connection. Three apps plus a
background sync writer share one WAL file; block-and-retry beats immediate
`SQLITE_BUSY`.

---

## Verification

The load-bearing gate is `crates/impress-core/tests/sync_convergence.rs`: two
in-memory stores, seeded-RNG interleaved mutations (400 seeds × 5 rounds ×
7 operations per store per round ≈ 28,000 operations), exchanged in randomised
sub-batch order with duplicate delivery, asserting byte-identical projections
and drained outboxes at quiescence. Targeted tests cover idempotent re-apply,
delete-vs-edit in both orders, every tiebreak branch, deferred-reference
resolution, and the manuscript conflict backup.

Above that: a Swift round-trip test drives two `ImbibStore` handles through the
FFI, and 45 Phase-D tests cover codec round-trips (including CKAsset spill and
`UInt64`↔`Int64` clock bridging), the availability matrix, lease lifecycle, and
merge determinism/symmetry — all runnable with no CloudKit account.

Live two-device verification (Phase F) is a manual matrix: mark-read, tag,
flag, collection membership, manuscript ping-pong with a forced concurrent
edit, delete propagation, offline queue, and kill-mid-push recovery.

---

## Known limitations in 3.0

- **Large manuscript bodies and PDF attachments do not sync.** Bodies over 1MB
  are stored as `blob:sha256:` references into a BlobStore outside the app
  group; metadata syncs, those bodies show as unavailable on other devices.
  CKAsset spill covers the 700KB–1MB band. A future `ImpressBlob` record type
  closes this.
- **Operation history and undo are per-device** (D4).
- **imprint and impel changes push only while imbib runs the engine** (D10);
  they queue in the meantime.
- **Push notifications are not yet enabled** on the App ID, so cross-device
  latency is governed by CKSyncEngine's own scheduling plus a 60s nudge timer
  rather than being near-instant.

## Rollout

Feature flag defaults OFF. Dogfood on the author's own devices; deploy the
CloudKit schema Development → Production **before** any TestFlight build syncs;
flip the default on only after the ADR-0007 entry criterion (a cross-device
workflow demonstrated) plus a week of clean `/api/sync/status`. Disabling the
toggle is always safe: data is local and the outbox is preserved.
