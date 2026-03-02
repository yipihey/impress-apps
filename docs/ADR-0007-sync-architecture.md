# ADR-0007: Sync Architecture

**Status:** Accepted
**Date:** 2026-03-02
**Authors:** Tom (with Claude)
**Supersedes:** Sync sections of ADR-0004 (Hybrid Storage Architecture, Decision 6: "Sync Architecture")
**Scope:** impress-core graph store sync, all apps

---

## Context

ADR-0004 established the two-layer storage system: a SQLite graph store for structured item data and Automerge documents for collaborative content. It sketched a sync architecture but left the phasing and implementation mechanics unspecified, describing personal multi-device sync and multi-user collaboration as adjacent concerns with a shared CloudKit strategy.

Two problems with the ADR-0004 framing have become clear:

**First, sync is a product phase, not a feature.** Shipping sync too early (before the data model and item graph are stable) creates migration debt. Shipping it too late (after users have multiple devices they want connected) creates pressure to cut corners. The right answer is an explicit roadmap with clear entry criteria for each phase.

**Second, ADR-0004 treated personal multi-device sync and multi-user collaboration as requiring the same infrastructure.** They do not. Personal sync (one user, N devices) needs a reliable delta-sync mechanism with conflict resolution for independent edits. Multi-user collaboration (M users, shared documents) needs operational transformation or CRDT-based merge for concurrent character-level edits. These are different problems at different product maturity levels, and conflating them leads to choosing infrastructure (Automerge) that is appropriate for Phase 4 but adds complexity to Phase 3.

This ADR defines the four-phase sync roadmap for the impress graph store, specifies the Phase 2 and Phase 3 mechanisms in detail, and clarifies when and why Automerge becomes relevant.

The graph store being described is the SQLite database (`sqlite_store.rs`) which holds the `items` table, `item_tags`, `item_references`, `store_metadata`, `tombstones`, and the `items_fts` full-text search index. The Automerge content store (for manuscript text and collaborative documents) has its own sync path (iCloud Drive file sync, then CloudKit Shared Zones) that is not changed by this ADR.

---

## Decision

### D25. Phase 1 (current): Local-only. No sync.

Data lives in the shared SQLite file. For imbib, this is the shared app group container (`group.com.impress.suite`). For other apps that share the store, the same path. Nothing leaves the device.

No sync code exists. The `store_metadata` table stores a `origin_id` (a UUID generated on first open) which will be used in Phase 3. The `origin` column on each item records which device created it. These are the only forward-looking concessions to Phase 3 that exist in Phase 1.

**Entry criteria:** This is the current state.

### D26. Phase 2: iCloud Drive backup (not sync).

The SQLite database file is placed inside the user's iCloud Drive container. iCloud Drive uploads it automatically. On a second device, the file is available as a downloaded file — not live-synced, but restorable.

This is a backup, not sync. If two devices have the app open simultaneously and both write to the file, iCloud Drive will produce a conflict file (`.icloud` conflict). Phase 2 does not resolve this — it simply accepts the limitation. For most single-user workflows, one device is active at a time.

**What this provides:** Disaster recovery. New device setup (download the backup, open the app). No code required beyond placing the database in the correct container path.

**What this does not provide:** Real-time or even eventual consistency across two simultaneously-active devices.

**Entry criteria:** Data model and item schema are stable enough that a backup from one week ago is useful.

### D27. Phase 3: CloudKit sync for the graph store.

Phase 3 replaces iCloud Drive backup with record-level CloudKit sync for the graph store. Each row in the `items`, `item_references`, and `item_tags` tables becomes a `CKRecord` in a CloudKit private database. A background sync engine pushes local changes and pulls remote changes via `CKFetchRecordZoneChangesOperation` with server change tokens.

**What syncs:**

| Table | Syncs | Notes |
|-------|-------|-------|
| `items` (durable tier) | Yes | Core publications, artifacts, annotations, permanent operations |
| `items` (ephemeral tier) | No | Session-only state, never leaves the device |
| `items` (compactable tier) | Conditional | Sync if `is_read`/`is_starred`/`flag_*` mutations; skip raw agent drafts |
| `item_references` | Yes | Graph edges needed for cross-item queries |
| `item_tags` | Embedded in item record | See CloudKit record mapping below |
| `store_metadata` | No | Device-local configuration; each device has its own |
| `items_fts` | No | Regenerated locally from synced item text |
| `tombstones` | Yes | Required for delete propagation |

The compactable tier sync policy is: sync operation items whose `op_target_id` points to a durable item. Skip raw agent draft items that have never been reviewed by a human.

**CloudKit Record Mapping:**

Each item in the `items` table maps to a `CKRecord` with record type `"ImpressItem"`:

```
CKRecord type: "ImpressItem"
  id            String   = items.id (UUID)
  schema_ref    String   = items.schema_ref
  payload_json  String   = items.payload (JSON blob)
  logical_clock Int64    = items.logical_clock
  author_kind   String   = items.author_kind ("Human" | "Agent" | "System")
  author_id     String   = items.author
  origin        String   = items.origin (device UUID)
  created       Date     = items.created (epoch ms → Date)
  modified      Date     = items.modified (epoch ms → Date)
  is_deleted    Int64    = 0 (live) or 1 (soft-deleted)
  tag_paths     [String] = all tag_path values from item_tags for this item
  is_read       Int64    = items.is_read
  is_starred    Int64    = items.is_starred
  flag_color    String?  = items.flag_color
  flag_style    String?  = items.flag_style
  flag_length   String?  = items.flag_length
  priority      String   = items.priority
  parent_id     String?  = items.parent_id
  op_target_id  String?  = items.op_target_id
```

Item tags are embedded in the item's `CKRecord` as a `[String]` field `tag_paths` rather than as separate records. Tags are always fetched and updated as part of the item, which avoids multi-record transactions for a very common mutation pattern (tagging a paper). The local `item_tags` table remains the source of truth; `tag_paths` is a denormalized projection.

Each row in `item_references` maps to a `CKRecord` with record type `"ImpressReference"`:

```
CKRecord type: "ImpressReference"
  source_id     String   = item_references.source_id
  target_id     String   = item_references.target_id
  edge_type     String   = item_references.edge_type
  metadata      String?  = item_references.metadata (JSON)
  logical_clock Int64    = logical_clock of the item that created this edge
```

Each row in `tombstones` maps to a `CKRecord` with record type `"ImpressTombstone"`:

```
CKRecord type: "ImpressTombstone"
  id            String   = tombstones.id
  schema_ref    String   = tombstones.schema_ref
  deleted_at    Int64    = tombstones.deleted_at (epoch ms)
  origin        String   = tombstones.origin
```

Operation items (items with a non-null `op_target_id` and durable retention) use the same `"ImpressItem"` record type. The `op_target_id` field on the `CKRecord` distinguishes them from envelope items.

**Conflict Resolution via Hybrid Logical Clock:**

The `logical_clock` column (an integer, already present in the schema) implements a Hybrid Logical Clock (HLC). Every write increments the local clock and takes the max of the local clock and any incoming clock value from a remote record.

When the sync engine receives a remote `ImpressItem` record for an item that also has a local version with uncommitted changes, conflict resolution proceeds as follows:

1. **Higher `logical_clock` wins.** The record with the greater clock value represents the most recent causal event and is applied. The other version is discarded.

2. **Tie-break by `author_kind` precedence: Human > Agent > System.** If two devices produced records with identical `logical_clock` values (which should be extremely rare in practice), the record authored by a Human takes precedence over an Agent-authored one, which takes precedence over a System-authored one. This reflects the principle that human intent should not be overridden by automated operations in ambiguous cases.

3. **Tie-break by `author_id` lexicographic ordering.** If both `logical_clock` and `author_kind` are identical, the record with the lexicographically greater `author_id` string wins. This is arbitrary but deterministic: both devices will compute the same winner independently without coordination.

This is last-write-wins with causal ordering. It is not operational transformation and it is not a CRDT. It is appropriate for the graph store because most mutations are discrete state transitions (read/unread, tag applied, flag set) rather than character-level edits to shared text. Two devices independently marking the same paper as read produce the same result regardless of which wins. Two devices independently tagging a paper with different tags produce two durable operation items, both of which survive (append-only).

**The append-only operation model reduces conflict surface significantly.** Because tags, flags, read state, and most other mutations are recorded as overlay operation items (ADR-0002) rather than as in-place updates to the target item, the only true conflicts are on the materialized state columns of the `items` table (`is_read`, `is_starred`, `flag_*`). The resolution rule above applies to those columns.

**Bootstrap Procedure (New Device):**

When a new device opens impress for the first time with an iCloud account that has existing CloudKit data:

1. Generate a fresh `origin_id` for this device.
2. Fetch all `ImpressItem` records from the CloudKit private database zone using `CKFetchRecordZoneChangesOperation` with no change token (full fetch).
3. Insert all received items into the local `items` table, setting `origin` to the record's `origin` field to preserve device attribution.
4. Fetch all `ImpressReference` records and insert into `item_references`.
5. For each item with a non-null `tag_paths` field, insert the corresponding rows into `item_tags`.
6. Fetch all `ImpressTombstone` records; delete any corresponding items from the local database.
7. Rebuild `items_fts` by re-indexing all items (FTS indices are always local; there is nothing to download).
8. Save the CloudKit server change token to `store_metadata` for future incremental fetches.

Steps 2–6 are idempotent; a partial bootstrap can be resumed after a crash by restarting from step 2 with the last saved change token (or from the beginning with no token if none was saved).

**Sync Engine Architecture (sketch, deferred to implementation ADR):**

The sync engine is a background actor that:
- On local mutation: enqueues a `CKModifyRecordsOperation` for the changed item(s).
- On CloudKit push notification: fetches changes using the saved server change token.
- On conflict: applies the resolution rule above and records the outcome in `store_metadata` for diagnostic purposes.
- On error: retries with exponential backoff; surfaces persistent failures to the user via the app's standard notification system.

The sync engine is not designed in this ADR. This ADR establishes the record schema and conflict semantics that constrain its design.

**Entry criteria for Phase 3:** At least one successful cross-device workflow (e.g., read a paper on one device, have it appear as read on the other) has been demonstrated manually. The item schema is frozen for at least one major version.

### D28. Phase 4: CloudKit Shared Zones and Automerge for multi-user collaboration.

Phase 4 introduces shared research environments: a PI and their students, a writing group, a research team reviewing papers together.

**Why Automerge is deferred to Phase 4 and not used in Phase 3:**

Automerge is designed for collaborative, concurrent editing of shared documents — the kind of editing where two people type in the same paragraph simultaneously and both edits must be preserved. The Phase 3 conflict surface does not require this. A single user on two devices will almost never independently modify the same field at the same time in ways that both matter. The HLC last-write-wins rule handles the rare case adequately.

Introducing Automerge into Phase 3 would require:
- Wrapping the `items` table rows as Automerge documents (complex, requires schema evolution)
- Running Automerge sync alongside CloudKit (two sync protocols)
- Handling the Beelay dependency for multi-document sync (pre-production as of this writing)

These costs are not justified until the collaboration use case (Phase 4) actually demands them.

**Phase 4 design (subject to a dedicated ADR):**

- The graph store sync graduates from CloudKit private database to CloudKit Shared Zones, enabling shared libraries.
- The Automerge content store (manuscript text, collaborative annotations) uses Automerge sync messages delivered via CloudKit Shared Zone records or a relay server.
- Access control uses CloudKit's native sharing model initially; Keyhive/Beelay when they mature.
- Presence (who else is viewing the same paper) is ephemeral and out of scope for this ADR.

---

## Consequences

### Positive

- **No sync debt.** Phase 1 is the current state; no premature sync infrastructure is built.
- **Incremental complexity.** Each phase adds only what the current product stage requires.
- **Phase 2 is free.** Moving the database file to the iCloud Drive container requires no sync code. Users get backup and new-device restore without additional engineering.
- **Phase 3 conflict model is tractable.** Last-write-wins with causal ordering is straightforward to implement and reason about. The append-only operation model reduces the conflict surface to a small set of materialized state columns.
- **Automerge is deployed at the right time.** Phase 4 uses Automerge for the workload it was designed for (concurrent multi-user text editing), not as a general-purpose sync mechanism for structured data.
- **New-device bootstrap is well-defined.** The seven-step procedure is complete and idempotent.
- **FTS regeneration is explicit.** There is no ambiguity about which data is synced and which is derived locally.

### Negative

- **Phase 2 does not handle two simultaneously-active devices.** iCloud Drive conflict files are not resolved. Users who regularly work on two active devices simultaneously will have a poor experience until Phase 3.
- **Phase 3 CloudKit record schema must be stable before shipping.** Schema migrations across CloudKit records are painful. The record schema defined in this ADR should be treated as a contract; changes require explicit migration planning.
- **Last-write-wins loses information in the degenerate case.** If a user genuinely makes different meaningful changes to the same field on two devices while offline for an extended period, one change is discarded. This is an acceptable trade-off for the graph store (where such conflicts are rare and the lost state is typically recoverable from the operation log), but it must be communicated clearly.
- **Ephemeral items are never synced.** If ephemeral items carry session state that the user has come to rely on, losing that state across devices may feel like a bug. Schemas must be designed carefully to ensure that user-facing state lives in durable or compactable items.
- **Tombstone table grows unboundedly in Phase 3.** Tombstones are required for delete propagation but can be cleaned up after a device-dependent safe age (e.g., 90 days). The cleanup policy is deferred to the sync engine implementation.

### Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| CloudKit record size limit (1 MB) | Item payloads must stay small. Large content (manuscript text) lives in Automerge documents, not in `payload_json`. Monitor payload sizes in telemetry before Phase 3 launch. |
| iCloud account not signed in | Phase 2 and 3 silently degrade to Phase 1. The app remains fully functional. Alert the user that sync is inactive. |
| CloudKit throttling during bootstrap | Implement exponential backoff and progress reporting. Bootstrap is a one-time event per device. |
| HLC clock skew across devices | HLC is designed for this. Wall clock skew only matters for the rare case where two clocks read the same value; the tie-break rules handle it deterministically. |
| Schema frozen requirement for Phase 3 | Defer Phase 3 until at least one stable release has shipped and schema evolution has stopped. |
| Automerge Beelay dependency | Automerge is not introduced until Phase 4. Beelay maturity is an entry criterion for Phase 4, not Phase 3. |

---

## Open Questions

1. **Should compactable-tier operation items sync selectively or unconditionally?** The current proposal syncs operation items whose target is a durable item. This means agent drafts that were never reviewed (compactable) do not propagate. Is there a case where unreviewed agent work should be available on another device? Probably not for imbib, but worth revisiting when impel (agent orchestration) enters Phase 3.

2. **What is the Phase 3 entry criterion for schema stability?** "Stable enough" is vague. A concrete criterion would be: no breaking schema changes for two consecutive minor releases, and the migration path for all existing databases has been validated. Define this before beginning Phase 3 engineering.

3. **How are CloudKit Shared Zone membership changes handled in Phase 4?** When a collaborator is removed from a shared library, their device must stop receiving updates and their local copy must be invalidated (or retained read-only). This is a significant UX and security question that needs its own ADR before Phase 4.

4. **Should the `tombstones` table itself have a CloudKit record type, or should deletes be modeled as a soft-delete flag on `ImpressItem`?** This ADR uses a separate `ImpressTombstone` record type for clarity, but a soft-delete `is_deleted` field on `ImpressItem` would simplify the record schema. The trade-off is that soft-deleted item records accumulate and must be garbage-collected. Tombstone records can be cleaned up by age. Decision deferred to the sync engine implementation ADR.

5. **What is the right CloudKit zone structure?** A single private zone for all `ImpressItem` records (simpler) versus per-library zones (enables granular sharing in Phase 4). The Phase 3 choice constrains Phase 4. A per-library zone structure is likely the right default, but this requires the library concept to be stable before Phase 3 launches.

6. **Should `logical_clock` be a Hybrid Logical Clock (combining wall clock + monotonic counter) or a pure vector clock?** This ADR describes it as an HLC but the current implementation is an integer counter. The implementation must be upgraded before Phase 3 to guarantee that clock values are comparable across devices. A pure Lamport timestamp (integer incremented on each local event and on each remote event received) is simpler than a full HLC and may be sufficient.

---

## References

- ADR-0001: Unified Item Architecture for the Impress Suite
- ADR-0002: Operations as Overlay Items
- ADR-0003: Tasks, Retention, and Enrichment
- ADR-0004: Hybrid Storage Architecture (Decision 6 superseded by this ADR)
- `crates/impress-core/src/sqlite_store.rs` — current schema and sync support stubs
- `crates/impress-core/src/item.rs` — `ActorKind` enum, `Item` struct, `logical_clock` field
- Kleppmann, M. (2017). *Designing Data-Intensive Applications*, Ch. 8–9 (distributed clocks, replication)
- Apple CloudKit documentation: `CKFetchRecordZoneChangesOperation`, server change tokens, record size limits
- Kulkarni et al. (2014). "Logical Physical Clocks and Consistent Snapshots in Globally Distributed Databases." (HLC paper)
- Ink & Switch, "Local-first software" (2019)
- Ink & Switch, Keyhive/Beelay lab notebooks (2024–2025)
