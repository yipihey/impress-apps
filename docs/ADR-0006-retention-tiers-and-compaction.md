# ADR-0006: Retention Tiers and Operation Compaction

**Status:** Accepted
**Date:** 2026-03-02
**Authors:** Tom (with architectural exploration via Claude)
**Supersedes:** ADR-0003 (retention portion only — §Decisions/3 "Retention Tiers" and the binary-asset lifecycle described there)
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0002 (Operations as Overlay Items)
**Scope:** impress-core library; all apps that write to an ItemStore

---

## Context

ADR-0002 establishes that every modification to an item is itself an item — an *operation item* stored in the same graph. This is correct for provenance, but it means the operation table grows without bound as researchers work. The growth is not linear: agents and background enrichment pipelines produce far more operations than humans do.

**The volume math is unavoidable.** A modest imbib library of 10,000 papers, each passing through the standard enrichment DAG (metadata-resolve, abstract-extract, keyword-tag, recommendation-score, digest-generate), arrives at the store pre-populated with roughly 50,000–100,000 operation items before the researcher has done a single thing manually. Every subsequent flag change, tag edit, or priority update adds more. At agent-assisted research pace, the operation table will exceed one million rows within months of sustained use.

Not all of these operations carry equal long-term value. The information "this paper was flagged red on February 14, then orange on March 3, then unflagged on March 12" has some value for a brief window while the researcher is deciding what to do with the paper. It has essentially no value six months later. Keeping all three operations forever wastes space and — more importantly — degrades every time-travel query and audit log that must scan them.

**The challenge is to reduce volume without compromising what actually matters:** the permanent research record. The record of "this paper was annotated with this insight" must survive indefinitely. The record of "this paper was flagged and then unflagged while sorting the inbox" does not need to.

ADR-0003 (§3, "Retention Tiers") introduced a high-level three-tier model and gestured at compaction without specifying the mechanism. That vagueness has been adequate while the storage layer was still being designed. Now that `sqlite_store.rs` exists and `store_metadata` is in production, the compaction mechanism needs a precise decision before any app writes enough operation history to make the problem irreversible.

This ADR supersedes ADR-0003's retention section only. The task model, spawn rules, and enrichment pipeline described in ADR-0003 are unaffected.

---

## Decisions

### D1. Three Retention Tiers on Operation Items

Every operation item carries a `retention` field (part of its envelope metadata). The field takes one of three values.

**Durable.** The operation is permanent provenance. It is never compacted, never summarized, never removed except by an explicit researcher action that creates a compensating operation (which is itself durable). A durable operation is part of the research record.

Examples of operations that must be durable:
- Item creation (`CreateItem`)
- Human annotation creation or deletion
- Tag addition by a human or a peer-reviewed agent action
- Task completion (terminal state transitions on task items)
- Editorial decisions, corrections, and escalations
- Tombstone operations (soft deletion — see D4)
- Snapshot operations written by the compactor (see D3)

**Compactable.** The operation contributes to the item's effective state but its individual history is only interesting for a bounded window. After a configurable retention window (default: 30 days), a sequence of compactable operations targeting the same item may be collapsed into a single snapshot operation encoding the net effective state.

Examples of operations that may be compactable:
- Flag changes (`SetFlag`) during inbox triage
- Priority changes (`SetPriority`) during routine sorting
- Visibility changes (`SetVisibility`) by background coordination
- Agent-driven metadata field updates where the final value is what matters
- Intermediate task state transitions on task items (e.g., `proposed → active → blocked`) where only the terminal state is durable

**Ephemeral.** The operation is useful only within the current session or for a 24-hour debugging window. It is never synced to other devices. It is deleted on session end or after 24 hours, whichever comes first.

Examples of ephemeral operations:
- Search query records
- Scroll position snapshots
- UI state saves (which column is sorted, which sidebar node is expanded)
- Presence heartbeats from agents
- Progress-update operations from enrichment tasks mid-execution

**Critical clarification: retention tiers apply to operation items, not to items themselves.** An item (a paper, an annotation, a task) is never compacted. Its operation history may be compacted. This distinction is essential. A researcher querying "show me all papers tagged `methods/sims`" always gets the correct answer — the compactor only collapses the path to that answer, not the answer itself.

**Foundational invariant (inherited from ADR-0003).** Compaction never alters effective state. The effective state computed from the post-compaction operation stream must be bitwise-identical to the effective state computed from the original stream. This invariant is testable: replay both streams through the projection function and diff. CI must run this test against any compacted fixture.

### D2. Retention Field Placement and Assignment

The `retention` field is stored on the operation item's envelope as a text column in the `items` table (alongside `schema_ref`, `op_target_id`, etc.). The domain values are `"durable"`, `"compactable"`, and `"ephemeral"`.

**Who assigns retention?**

The creating actor assigns retention at write time. The store does not override it. The default is `"durable"` — anything not explicitly classified as compactable or ephemeral is permanent.

**Why default to durable?** A mistake in classification costs disk space. A mistake in the other direction destroys research provenance. Disk space is recoverable; provenance is not.

Callers that create compactable or ephemeral operations must be explicit. Background enrichment services and agent loops are the expected sources of non-durable operations. Human-initiated writes should almost always be durable.

**Agent promotion limits (carried forward from ADR-0003 §9).** Agent personas carry a configurable ceiling on how many items per unit time they can elevate to durable retention. Below a configurable confidence threshold, an agent-generated operation defaults to compactable rather than durable. The researcher can promote it during triage. This prevents a misconfigured agent from flooding the permanent record.

### D3. The Compaction Algorithm

Compaction replaces a sequence of compactable operations on a single item with one snapshot operation encoding the net effective state of the compacted fields. It does not touch durable or ephemeral operations.

**Step-by-step specification:**

1. **Identify candidates.** Query `items` for all rows where:
   - `op_target_id` = the target item's ID
   - `retention` = `'compactable'`
   - `created` < `NOW() - compaction_window` (default: 30 days)

2. **Check for a durable anchor.** If no durable operation exists for this item older than the oldest candidate, the item itself may not yet be compaction-eligible (its full history is needed for time-travel queries within the window). Skip.

3. **Compute net effective state.** Replay the candidate operations in `logical_clock` order. Compute the net change to each field (e.g., three `SetFlag` ops produce a final `Option<FlagState>`; three `SetPriority` ops produce a final `Priority`). This is a pure function with no side effects.

4. **Write one snapshot operation.** Insert a new durable operation item with:
   - `schema_ref` = `"core/operation/snapshot"`
   - `op_target_id` = the target item's ID
   - `op_type` = `"Snapshot"`
   - `payload.snapshot` = JSON object encoding the net effective state of all compacted fields
   - `payload.compacted_clock_range` = `[min_logical_clock, max_logical_clock]` of the operations being replaced
   - `payload.compacted_op_count` = number of operations collapsed
   - `retention` = `"durable"` — the snapshot is part of the permanent record

5. **Delete the intermediate operations.** Remove the candidate operation rows from `items` (and their `item_tags`, `item_references`, `items_fts` entries via CASCADE).

6. **Update the compaction watermark.** Write to `store_metadata`:
   - `key` = `"compaction_watermark:{item_id}"`, `value` = ISO8601 timestamp of the compaction run

   The watermark serves two purposes: it tells the compactor not to revisit recently-compacted items, and it serves as an audit record that compaction occurred.

**Why per-item compaction, not per-table?** A table-level compaction pass that targets all items of a given schema could be simpler to implement, but it obscures auditability. If a question arises about why a specific item's flag changed, the compaction record for that item answers it directly. Per-item watermarks in `store_metadata` allow inspectors to say "item X was compacted on date Y, collapsing N operations with logical clock range [A, B]." Per-table compaction would require correlating a table-wide event with individual item histories.

**The snapshot operation is itself durable.** This is important: after compaction, the audit trail is not empty — it contains the snapshot record, which encodes the range of what was collapsed and the net result. An auditor can see that compaction happened, when, and what the effective state was. They cannot see the individual intermediate operations. This is the intended trade.

### D4. Soft Deletion of Items (Tombstone Operations)

Items are never physically deleted from the store by normal application code. "Deleting" an item creates a durable **tombstone operation** — an operation item with `op_type = "DeleteItem"` — targeting the deleted item. The tombstone is durable and permanent.

The tombstone's creation triggers the store to set a materialized `is_deleted = 1` column on the target item row. Normal queries filter `is_deleted = 0`. Sync protocols propagate the tombstone to remote peers so they can apply the same soft deletion.

**The `is_deleted` column does not currently exist in the schema.** It must be added via `migrate_schema` before tombstone-based deletion is wired to any user-facing action. The existing `tombstones` table in `sqlite_store.rs` is a parallel sync-tracking mechanism (listing deleted IDs for sync propagation). It coexists with the operation-based tombstone described here: the operation tombstone is the authoritative deletion record; the `tombstones` table is a sync-protocol optimization for peers that need to query "what was deleted since timestamp T?" without scanning the full operation stream.

**When to physically reclaim.** An item that has been soft-deleted for longer than a researcher-configurable archive window (default: 90 days) may be moved to cold storage or physically deleted — but only after:
1. All binary assets it references have been checked for other referencing items (see D5).
2. The tombstone operation remains in place (it is durable).
3. The researcher has been notified and has not objected within the archive window.

This ADR does not specify the archive-to-cold-storage mechanism. It requires only that any implementation honor the above sequence.

### D5. Binary Asset Garbage Collection

Binary assets (PDFs, images, datasets, attachments) are stored content-addressed: the storage key is a hash of the content. Multiple items may reference the same hash (two papers citing the same preprint PDF, for example). The asset is retained as long as any non-deleted item references its hash.

**Collection trigger.** When an item is soft-deleted (tombstone created), the store schedules a background GC pass for each content hash the item referenced. The GC pass checks: "does any item with `is_deleted = 0` reference this hash?" If no live item references the hash, the binary data is eligible for collection.

**GC is deferred, not immediate.** A GC pass runs asynchronously, not inline with the tombstone write. Reason: the check involves a query across item references, which may be expensive for large collections. A deferred GC pass can batch multiple deletions.

**GC of agent-generated binaries.** Enrichment tasks may produce intermediate binary outputs (extracted text, embedding vectors, thumbnail images). These are associated with compactable or ephemeral operation items. When those operations are compacted or deleted, the GC pass for any referenced binary content hashes runs by the same mechanism.

**GC is not compaction.** Compaction operates on operation items in SQLite. Binary GC operates on content-addressed files on disk (or in object storage). They are independent processes that happen to be triggered by related events.

### D6. Compaction Triggers

Compaction runs are triggered by three mechanisms, in priority order:

1. **Periodic background sweep.** A compaction service runs on a configurable schedule (default: nightly, at 02:00 local time) and sweeps all items whose oldest compactable operation predates the compaction window. This is the primary mechanism.

2. **Write-triggered, probabilistic.** When any compactable operation is written, the store increments an in-memory counter. When the counter reaches a threshold (default: 1,000 compactable writes since last compaction), a background compaction pass is scheduled. This prevents the compaction window from growing unbounded during heavy agent activity without requiring a strict transactional sweep.

3. **Explicit API call.** `SqliteItemStore::compact(item_id: Option<ItemId>)` runs compaction for a specific item (if provided) or for all eligible items (if None). This is exposed for testing, for the CLI maintenance tool, and for agent-driven compaction requests.

**Compaction must not block reads or writes.** The compaction algorithm in D3 does not hold the store mutex across its full execution. Candidate identification, effective-state computation, and snapshot construction are performed with a short-lived lock acquisition. The DELETE of intermediate operations and INSERT of the snapshot operation are performed atomically in a single SQLite transaction, which is the only period when the mutex is held for compaction-specific work.

**Startup grace period.** Background compaction must not run during the first 90 seconds after app launch. This follows the same rule as all other background services (documented in CLAUDE.md): background mutations during startup cause SwiftUI re-evaluation storms. The compaction scheduler initializes with a 90-second delay before its first work cycle.

### D7. Compaction Window Configuration

The compaction window (default: 30 days) is stored in `store_metadata` as `key = "compaction_window_days"`, `value = "30"`. It is user-configurable via the Preferences UI. Valid range: 7 days to 365 days.

Reducing the window takes effect at the next compaction pass. Increasing it has no retroactive effect (already-compacted operations remain compacted; the snapshot operation is permanent).

---

## Schema Additions Required

This ADR requires the following changes to the storage layer before any compaction-related code goes to production:

**New column on `items` table:**
```sql
ALTER TABLE items ADD COLUMN retention TEXT NOT NULL DEFAULT 'durable';
ALTER TABLE items ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_items_retention ON items(retention);
CREATE INDEX IF NOT EXISTS idx_items_deleted ON items(is_deleted);
-- Compound index for compaction candidate queries:
CREATE INDEX IF NOT EXISTS idx_items_compaction
    ON items(op_target_id, retention, created)
    WHERE op_target_id IS NOT NULL AND retention = 'compactable' AND is_deleted = 0;
```

**New entries in `store_metadata`:**
| Key | Default Value | Description |
|-----|---------------|-------------|
| `compaction_window_days` | `"30"` | Minimum age of compactable operations before they are eligible |
| `compaction_watermark:{item_id}` | (set by compactor) | ISO8601 timestamp of last compaction for item |
| `last_compaction_sweep` | (set by compactor) | ISO8601 timestamp of last full sweep |
| `compactable_writes_since_sweep` | `"0"` | Counter for probabilistic trigger (reset on sweep) |

These migrations go into `migrate_schema` as `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` statements. The `DEFAULT 'durable'` on `retention` ensures all pre-migration operation items are classified correctly: they were written without retention awareness and should be treated as permanent.

---

## Consequences

### Positive

- **Bounded operation table.** A library of 10,000 papers with active agent enrichment will stabilize at a fraction of the raw operation count once compaction is running. Flag-change storms during inbox triage collapse to one snapshot per paper per 30-day window.
- **Auditability preserved.** Durable operations — human annotations, task completions, editorial decisions, tombstones — are never touched. The permanent record is intact.
- **Time-travel within the window.** Compactable operations are preserved for at least 30 days, meaning any time-travel query for "state as of 3 weeks ago" returns a correct answer.
- **Snapshot operations are themselves auditable.** The snapshot encodes the `compacted_clock_range` and `compacted_op_count`, so an auditor can verify that compaction ran and what it collapsed, even without the original operations.
- **Binary GC is reference-counted.** No binary asset is deleted while any live item references it. Shared assets (e.g., a PDF referenced by both an original paper item and a "read later" artifact) are retained correctly.
- **Per-item watermarks enable targeted inspection.** `store_metadata` keys of the form `compaction_watermark:{item_id}` allow a diagnostic tool to answer "has this item ever been compacted, and when?" without a full operation scan.

### Negative

- **Schema migration required before shipping.** The `retention` and `is_deleted` columns must be added via `migrate_schema` before any application code tries to set them. Pre-migration operation items all default to `retention = 'durable'`, which is safe but means the first compaction pass will find no candidates.
- **Compaction correctness is subtle.** The foundational invariant (compaction does not change effective state) must be enforced by tests, not by intuition. The compaction algorithm must be exercised against property-based test cases before production use.
- **30-day window is a guess.** The right compaction window for a researcher who triages inbox daily is different from one who triages weekly. The default will need empirical tuning during early use.
- **Soft deletion adds query complexity.** Every query must filter `is_deleted = 0`. Forgetting this filter is a latent bug class. The existing `ItemQuery` struct should enforce this by default, with an explicit opt-in for "include deleted items" (useful for sync and audit views).

### Non-consequences (what this ADR does not change)

- **Items are not compacted.** The item table is not touched by the compactor. Only operation items (rows with `op_target_id IS NOT NULL`) are compaction candidates.
- **The `tombstones` table is not replaced.** The existing `tombstones` table in `sqlite_store.rs` continues to serve its sync-protocol purpose. The tombstone *operation item* described in D4 is an additional record, not a replacement.
- **ADR-0003's task model is unchanged.** Task items, spawn rules, enrichment pipelines, and the durable tier governance (confidence thresholds, attention-gated demotion) are all unaffected. This ADR narrows D3 of ADR-0003; everything else in that ADR stands.

---

## Open Questions

1. **`is_deleted` and the existing `tombstones` table: how to reconcile for sync?** The `tombstones` table is queried by sync peers via `list_tombstones_since(since_ms)`. The tombstone operation item is the authoritative record. Do sync peers need both? Or should `list_tombstones_since` be rewritten to query the operation stream for `DeleteItem` ops instead of the `tombstones` table? The answer depends on how many rows each sync peer needs to process; the `tombstones` table is an optimization for the case where peers only need IDs. Decide before sync is implemented.

2. **Compaction and sync: who compacts on a multi-device setup?** If a researcher uses imbib on two Macs and one has been offline for six weeks, the offline device has operations that the online device has already compacted. When the devices sync, the online device has the snapshot; the offline device has the originals. The merge protocol must accept both as correct representations of the same effective state. The sync ADR (not yet written) must address this. This ADR requires only that the snapshot operation's `payload.compacted_clock_range` contains enough information to detect and resolve such overlaps.

3. **Ephemeral operations and on-disk persistence.** This ADR states ephemeral operations are "deleted after session end or 24 hours." Should they ever touch SQLite at all, or should they live only in memory? Keeping them in SQLite allows crash recovery of in-session undo history; keeping them in memory avoids any write amplification. The undo system's needs should drive this decision.

4. **Compaction of tag-change sequences.** `AddTag` and `RemoveTag` are symmetric operations — their net effect for a given tag path is binary (present or absent). If a paper is tagged `methods/sims`, then untagged, then tagged again within 30 days, the compactor would see three operations and a net state of "tagged." But the AddTag and RemoveTag ops are currently in `OperationType` without a retention annotation — should repeated agent tagging cycles on the same tag path be classified as compactable? The answer is probably yes for agent-driven tagging and no for human-driven tagging, which implies the `retention` field must be set correctly at write time by the caller, not inferred from op_type.

5. **Compaction window per schema.** Should enrichment task items compact on a shorter window (7 days is probably sufficient) while flag/priority changes compact on the default 30-day window? Per-schema windows would be more precise but add configuration complexity. A single global window simplifies the implementation. Start with one global window; revisit after measurement shows whether task items dominate the operation table as expected.

---

## References

- ADR-0001: Unified Item Architecture for the Impress Suite
- ADR-0002: Operations as Overlay Items and Data Model Foundations
- ADR-0003: Tasks, Retention, and Enrichment (§3 Retention Tiers superseded by this ADR)
- `crates/impress-core/src/sqlite_store.rs` — `init_schema`, `init_store_metadata`, `init_tombstones`, `migrate_schema`
- `crates/impress-core/src/operation.rs` — `OperationType`, `EffectiveState`, `build_operation_payload`
- Kleppmann, M. (2017). *Designing Data-Intensive Applications*, Ch. 11 (Event Sourcing and CQRS)
- Hellerstein, J. et al. (2019). "Keeping CALM: When Distributed Consistency Is Easy." *CACM* 63(9)
