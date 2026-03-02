# ADR-0002: SQLite Storage Architecture

**Status:** Accepted
**Date:** 2026-03-02
**Authors:** Tom (with architectural exploration via Claude)
**Supersedes:** ADR-0004 (Hybrid Storage Architecture — SQLite + Automerge two-layer model)
**Resolves:** ADR-0001 Open Questions #1 (storage engine choice)
**Scope:** `impress-core` storage layer (`crates/impress-core/src/`), all apps that open the shared workspace database

---

## Context

ADR-0001 established the `ItemStore` trait and deferred the storage engine decision. The previous draft for this slot (ADR-0004) proposed a two-layer architecture: SQLite for the item graph plus Automerge for collaborative content. While architecturally coherent, that model had two problems that forced a revision:

1. **The Automerge layer has no implementation path in Phase 1-2.** Efficient multi-document Automerge sync depends on Beelay (Ink & Switch's next-generation sync protocol), which is pre-alpha as of early 2026. Building on it now would mean building on a moving target with no stable API.

2. **Phase 1-2 have no multi-user collaborative editing requirements.** The collaboration use case — two researchers editing the same paragraph simultaneously — exists only in imprint (manuscript authoring) and is explicitly scoped to Phase 3. Nothing in Phase 1-2 (imbib migration, impart message store) needs character-level CRDT merge.

This ADR therefore collapses the two-layer model to a single layer for Phase 1-2 and records the specific implementation decisions that are now live in `SqliteItemStore`.

### Alternatives Evaluated and Rejected

**LMDB.** High write throughput, memory-mapped reads. Rejected because: no full-text search built in (FTS5 would need a separate process or library), no SQL query interface (every query is a key scan or manually built secondary index), and no JSON introspection functions. Concurrency model (writers block readers on the same key) is worse than WAL for our read-heavy, append-heavy workload. No compelling advantage over SQLite for our access patterns.

**sled.** Pure-Rust embedded KV store. Rejected for the same reasons as LMDB, plus it is not production-stable as of 2026 (version 0.x, breaking API changes between releases). The Rust ecosystem has converged on SQLite via rusqlite for embedded storage with query needs.

**Automerge (Phase 1).** Rejected for Phase 1-2 as described above. Reserved for Phase 3 manuscript editing (see Open Questions).

**PostgreSQL / server database.** Rejected. Impress is local-first; requiring a server process contradicts data ownership and offline requirements.

**Pure file system (one JSON file per item).** Rejected. No indexed queries, no transactions, no FTS. Does not scale to bibliographies of 10,000+ items or inboxes of 100,000+ messages.

---

## Decision

### D1. Single Storage Engine: SQLite with WAL Mode

All item graph data in Phase 1-2 is stored in a single SQLite database per research workspace. WAL (Write-Ahead Log) mode is enabled unconditionally at connection open time:

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
```

WAL mode gives concurrent read access while a single writer is active. This matches the operational profile: the human UI reads continuously, agents write frequently, and our operation model is append-heavy (each mutation creates a new operation item). WAL also enables Litestream-style streaming backup without application changes.

The connection is wrapped in a `Mutex<Connection>` in `SqliteItemStore`. Concurrency is at the process level: multiple Swift actors on the main process share one `SqliteItemStore` instance, which serializes writes through the mutex. No multi-process write sharing is needed in Phase 1-2.

### D2. Shared Database File Location

All apps in the suite open the same database file:

```
~/Library/Group Containers/group.com.impress.suite/workspace/impress.sqlite
```

The path is accessed via the macOS app group container (`group.com.impress.suite`), which all impress apps declare in their entitlements. This gives every app read-write access to the same SQLite file without a server process. The UniFFI bridge exposes `SqliteItemStore::open(path:)` to Swift callers.

### D3. Authoritative Schema

The complete schema as of the initial implementation in `crates/impress-core/src/sqlite_store.rs`:

```sql
-- Core item envelope.
-- Columns are immutable after INSERT per ADR-0002 (Operations as Overlay Items),
-- except for the materialized state columns (is_read, is_starred, flag_*, priority,
-- visibility, parent_id, modified), which are updated in-place by apply_operation().
CREATE TABLE items (
    id              TEXT PRIMARY KEY,        -- UUID v4, stable across sync
    schema_ref      TEXT NOT NULL,           -- Schema identifier, e.g. "bibliography/entry"
    payload         TEXT NOT NULL,           -- JSON object; schema-specific fields
    created         INTEGER NOT NULL,        -- Unix epoch milliseconds
    modified        INTEGER NOT NULL,        -- Unix epoch milliseconds; bumped by every operation
    author          TEXT NOT NULL,           -- Actor identity string, e.g. "user:local" or "agent:impel"
    author_kind     TEXT NOT NULL,           -- "human" | "agent" | "system"
    is_read         INTEGER NOT NULL DEFAULT 0,
    is_starred      INTEGER NOT NULL DEFAULT 0,
    flag_color      TEXT,                    -- NULL = no flag; "red" | "orange" | "yellow" | "green" | "blue" | "purple" | "grey"
    flag_style      TEXT,                    -- Optional flag style variant
    flag_length     TEXT,                    -- Optional flag length variant
    parent_id       TEXT REFERENCES items(id) ON DELETE SET NULL,  -- Hierarchy (library, collection, thread)
    logical_clock   INTEGER NOT NULL DEFAULT 0,  -- Lamport clock; incremented per mutation
    origin          TEXT,                    -- Origin store UUID; identifies the device/instance that created this item
    canonical_id    TEXT,                    -- Shared identity across collaborative contexts (Phase 3+)
    priority        TEXT NOT NULL DEFAULT 'normal',   -- "low" | "normal" | "high" | "urgent"
    visibility      TEXT NOT NULL DEFAULT 'private',  -- "private" | "shared" | "public"
    message_type    TEXT,                    -- For impart: "email" | "chat" | "notification" etc.
    produced_by     TEXT,                    -- UUID of the agent/process that produced this item (if any)
    version         TEXT,                    -- Schema version stamp for payload migrations
    batch_id        TEXT,                    -- Groups related operation items that should undo together
    op_target_id    TEXT REFERENCES items(id) ON DELETE CASCADE
                                             -- Non-NULL only on operation items; foreign key to the item being mutated
);

-- Tags: normalized many-to-many. Tag paths use "/" separators for hierarchy.
-- Example: "methods/simulation", "status/to-review".
CREATE TABLE item_tags (
    item_id         TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    tag_path        TEXT NOT NULL,
    PRIMARY KEY (item_id, tag_path)
);

-- Typed directed edges between items. Denormalized from item payloads per D7.
-- edge_type is a JSON string serialization of the EdgeType enum.
CREATE TABLE item_references (
    source_id       TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    target_id       TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    edge_type       TEXT NOT NULL,           -- JSON-serialized EdgeType enum variant
    metadata        TEXT,                    -- Optional JSON for edge-specific properties
    PRIMARY KEY (source_id, target_id, edge_type)
);

-- Store-level metadata: origin UUID, logical clock value, tag namespace.
CREATE TABLE store_metadata (
    key             TEXT PRIMARY KEY,
    value           TEXT NOT NULL
);

-- Tombstones: records of deleted items for sync propagation.
-- Items are deleted from the items table; tombstones ensure remote peers learn of the deletion.
CREATE TABLE tombstones (
    id              TEXT PRIMARY KEY,        -- Former item UUID
    schema_ref      TEXT NOT NULL,
    deleted_at      INTEGER NOT NULL,        -- Unix epoch milliseconds
    origin          TEXT                     -- Origin store UUID of the deleting actor
);

-- Full-text search. See D5 for the FTS design.
CREATE VIRTUAL TABLE items_fts USING fts5(
    item_id UNINDEXED,   -- Not indexed; used as the join key back to items
    title,
    author_text,
    abstract_text,
    note
);
```

### D4. Index Rationale

```sql
-- Schema filter is the outermost predicate on almost every list query.
CREATE INDEX idx_items_schema       ON items(schema_ref);

-- Hierarchy traversal: "all items in library X" is the most common query shape.
CREATE INDEX idx_items_parent       ON items(parent_id);

-- Sort support for date-ordered lists (the default sort for all views).
CREATE INDEX idx_items_created      ON items(created);
CREATE INDEX idx_items_modified     ON items(modified);

-- Status filter support — individually indexed to allow partial scans.
CREATE INDEX idx_items_flag         ON items(flag_color);
CREATE INDEX idx_items_read         ON items(is_read);
CREATE INDEX idx_items_starred      ON items(is_starred);

-- Priority and visibility filters.
CREATE INDEX idx_items_priority     ON items(priority);
CREATE INDEX idx_items_visibility   ON items(visibility);

-- Lamport clock ordering: used for operation log queries and sync delta scans.
CREATE INDEX idx_items_logical_clock ON items(logical_clock);

-- Tag lookup: "all items with tag X or any descendant of X".
CREATE INDEX idx_item_tags_path     ON item_tags(tag_path);

-- Reverse edge traversal: "all items that reference target T via edge type E".
CREATE INDEX idx_item_refs_target   ON item_references(target_id, edge_type);

-- Operation log lookup: all operations targeting item X, ordered by clock.
-- Partial index (WHERE op_target_id IS NOT NULL) keeps it small — only operation
-- items have this column set.
CREATE INDEX idx_items_op_target    ON items(op_target_id, logical_clock)
    WHERE op_target_id IS NOT NULL;

-- Batch undo support: look up all operation items in a batch.
-- Partial index for the same reason.
CREATE INDEX idx_items_batch        ON items(batch_id)
    WHERE batch_id IS NOT NULL;

-- Tombstone cleanup: scan by deletion time.
CREATE INDEX idx_tombstones_deleted ON tombstones(deleted_at);
```

No covering indices exist yet. They are added if query profiling in Phase 2 reveals hot paths (e.g., `(schema_ref, is_read)` for the unread count query).

### D5. FTS5 Design

Full-text search uses SQLite's built-in FTS5 extension. The `items_fts` virtual table is a non-content FTS table: it stores copies of indexed text independently from the main `items` table. This avoids the trigger machinery required by content FTS tables and gives simpler insert/delete semantics at the cost of modest storage duplication.

**Indexed columns:**

| Column | Content |
|--------|---------|
| `title` | `payload["title"]` — the item's human-readable title |
| `author_text` | `payload["author_text"]` — flattened author string for bibliography entries |
| `abstract_text` | `payload["abstract_text"]` — abstract or body text |
| `note` | `payload["note"]` — user-written note or annotation |

**FTS extractor interface (D31):** Each schema's Rust implementation provides a `fts_text(item: &Item) -> FtsEntry` function that extracts the four fields from its payload. The generic `update_fts()` in `SqliteItemStore` calls `extract_string_field()` for each canonical name. Schema-specific extractors are responsible for populating these canonical field names in their payloads; FTS indexing is schema-agnostic at the storage layer.

**Query compilation:** `Predicate::Contains(field, text)` for FTS fields generates:

```sql
id IN (SELECT item_id FROM items_fts WHERE items_fts MATCH ?)
```

The `?` parameter is the search text wrapped in double-quotes to force FTS5 phrase matching (`"dark matter"`). Non-FTS fields fall back to `LIKE '%text%' ESCAPE '\'`.

**FTS update lifecycle:**
- Insert: `update_fts()` called from `insert_item()` if any FTS field is present.
- Delete: `delete_fts()` called from the `ItemStore::delete()` implementation.
- Payload mutations (via `OperationType::SetPayload` / `PatchPayload`): FTS is **not** re-indexed automatically after mutations in Phase 1. Re-index is triggered by the next full insert of a replacement item, or explicitly via a background `REBUILD` command. This is a known limitation tracked in Open Questions.

### D6. Binary Asset Storage: Content-Addressed Files

Binary assets (PDFs, figures, datasets, attachments) are stored as files in a content-addressed directory, not as BLOBs in SQLite. SQLite BLOBs:
- Bloat WAL pages, slowing down concurrent reads for non-asset queries.
- Cannot be streamed; the full blob must be loaded into memory.
- Are not deduplicated across items that share the same underlying file.

**Layout:**

```
~/.local/share/impress/content/
└── {sha256-hex}/
    └── {original-filename}
```

Example: a PDF with SHA-256 `ab3c...f7` stored as `ab3c...f7/smith2024.pdf`.

**Reference in item payload:** The item's payload stores two fields:

```json
{
  "content_hash": "ab3c...f7",           // SHA-256 hex digest
  "content_path": "ab3c...f7/smith2024.pdf"  // Relative path within the content root
}
```

The content root itself is resolved from the app group container or a user-configured path. No absolute paths are stored in the database; this makes the store portable.

**Deduplication:** Two items referencing the same binary (e.g., a paper that appears in two libraries) share one file on disk. Reference counting is implicit: a file is retained as long as any item references its hash. A background garbage-collect pass (Phase 2) walks `content_path` values in the database and removes unreferenced files.

**No binary blobs in SQLite.** This is a hard constraint. If a future schema needs inline binary data, it goes in the content store with a hash reference in the payload.

### D7. References Field: Denormalized in `item_references`

The `ItemQuery` and `Item` structs carry a `references: Vec<TypedReference>` field. These are stored denormalized in the `item_references` table (not embedded in the payload JSON) to make edge traversal queries O(log n) with an index rather than O(n) JSON scans. An `AddReference` / `RemoveReference` operation mutates this table directly and is reflected in all subsequent reads.

### D8. Lamport Clock and Origin ID

Each `SqliteItemStore` instance generates a UUID v4 `origin_id` on first open and persists it in `store_metadata`. This is the stable identity of this device's database.

A monotonic Lamport clock is also stored in `store_metadata` and incremented atomically with each operation:

```sql
UPDATE store_metadata
SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)
WHERE key = 'logical_clock';
```

Every operation item written to the store carries the clock value at the time of write. This provides total ordering of operations within one origin and enables Lamport merge for two-device sync:

```rust
new_clock = max(local_clock, remote_clock) + 1;
```

The clock is used for operation log ordering (`ORDER BY logical_clock ASC`) and for time-travel queries (`StateAsOf::LogicalClock(n)` replays only operations up to clock n).

### D9. `modified` Is a Materialized Column

The `items.modified` column is a stored, materialized timestamp. It is set to `created` at insert time and bumped to `NOW()` by every `materialize_operation()` call. This makes `ORDER BY modified DESC` an O(log n) index scan rather than requiring a join over the operation log.

This creates a modest consistency obligation: any code path that changes item state must call `materialize_operation()` (or update `modified` explicitly). The only way to mutate an item's state is through `apply_operation()`, which enforces this.

### D10. Schema Migration Strategy

Migrations use idempotent `ALTER TABLE ... ADD COLUMN` statements. Each migration SQL statement is wrapped in a `.ok()` (or `let _ =`) so that:

- On a fresh database, `init_schema()` creates the full table definition and the migration in `migrate_schema()` is a no-op (the column already exists, `ALTER TABLE` fails silently).
- On an existing database, `migrate_schema()` adds the new column; `init_schema()` is a no-op for the table itself.

No version number table is used. This is intentional: the set of executed migrations is implied by the schema structure itself, and `IF NOT EXISTS` / ignored errors guarantee idempotency without a migration version tracker.

**Current migration list** (each is a single `ALTER TABLE` or `CREATE INDEX`):

```sql
ALTER TABLE items ADD COLUMN logical_clock   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN origin          TEXT;
ALTER TABLE items ADD COLUMN canonical_id    TEXT;
ALTER TABLE items ADD COLUMN priority        TEXT NOT NULL DEFAULT 'normal';
ALTER TABLE items ADD COLUMN visibility      TEXT NOT NULL DEFAULT 'private';
ALTER TABLE items ADD COLUMN message_type    TEXT;
ALTER TABLE items ADD COLUMN produced_by     TEXT;
ALTER TABLE items ADD COLUMN version         TEXT;
ALTER TABLE items ADD COLUMN batch_id        TEXT;
ALTER TABLE items ADD COLUMN op_target_id    TEXT REFERENCES items(id) ON DELETE CASCADE;
-- Followed by index creation for each of the above (idempotent via IF NOT EXISTS).
```

**Rule for future migrations:** Add a new `ALTER TABLE` line to the `migrations` array in `migrate_schema()`. If the migration requires data backfill, add a separate `UPDATE` statement immediately after. No migration may drop or rename a column — these require a full table rebuild (copy → drop → rename), which is a distinct, named operation.

### D11. `SqliteItemStore` Concurrency Model

`SqliteItemStore` holds a single `Mutex<Connection>`. All reads and writes go through this mutex. The choice is deliberate for Phase 1-2:

- The write workload is modest: one user plus agents writing a few items per second.
- WAL mode allows SQLite to serve concurrent read requests from the OS page cache even when a writer holds the mutex, because readers do not block on WAL.
- A single connection avoids the `SQLITE_BUSY` / `BEGIN IMMEDIATE` complexity of multi-connection pools.

If profiling in Phase 2 reveals read latency problems (e.g., large FTS queries blocking agent writes), the migration path is to open a second read-only `Connection` for queries and keep the write `Connection` under the mutex. The `ItemStore` trait abstracts this away from callers.

### D12. Query Compilation: `ItemQuery` to SQL

`ItemQuery` (defined in `crates/impress-core/src/query.rs`) is a structured query IR that is compiled to SQL by `compile_query()` in `sql_query.rs`. The compilation is a one-pass translation with no query optimizer:

```
ItemQuery { schema, predicates, sort, limit, offset }
    → CompiledQuery { where_clause, params, order_clause, limit_offset }
```

**Predicate to SQL mapping:**

| Predicate | Generated SQL |
|-----------|---------------|
| `Eq(field, value)` | `{col} = ?` |
| `Neq`, `Gt`, `Lt`, `Gte`, `Lte` | `{col} != ?`, `> ?`, `< ?`, `>= ?`, `<= ?` |
| `Contains(fts_field, text)` | `id IN (SELECT item_id FROM items_fts WHERE items_fts MATCH ?)` |
| `Contains(other_field, text)` | `{col} LIKE '%text%' ESCAPE '\'` |
| `HasTag(path)` | `id IN (SELECT item_id FROM item_tags WHERE tag_path = ? OR tag_path LIKE ? || '%')` |
| `HasFlag(Some(color))` | `flag_color = ?` |
| `HasFlag(None)` | `flag_color IS NOT NULL` |
| `IsRead(v)` | `is_read = 1` / `is_read = 0` |
| `IsStarred(v)` | `is_starred = 1` / `is_starred = 0` |
| `HasParent(id)` | `parent_id = ?` |
| `HasReference(edge, target)` | `id IN (SELECT source_id FROM item_references WHERE target_id = ? AND edge_type = ?)` |
| `ReferencedBy(edge, source)` | `id IN (SELECT target_id FROM item_references WHERE source_id = ? AND edge_type = ?)` |
| `And(preds)` | `(... AND ... AND ...)` |
| `Or(preds)` | `(... OR ... OR ...)` |
| `Not(pred)` | `NOT (...)` |

**Payload field access:** Unknown field names are treated as payload paths: `"payload.doi"` → `json_extract(payload, '$.doi')`. Bare field names not matching any envelope column also become payload paths. JSON paths are sanitized — only alphanumeric, `.`, `_`, `-`, `$`, `[`, `]` are allowed; invalid paths produce `NULL` rather than injectable SQL.

**Sort fields:** `created`, `modified`, `is_read`, `is_starred`, `flag_color` map to their envelope columns. Payload fields map to `json_extract(payload, '$.field')`. No FTS-ranked sort is supported in Phase 1 (results are sorted by the specified sort key, not by relevance score).

---

## Consequences

### What Becomes Easier

- **O(1) reads for common queries.** `is_read`, `flag_color`, `priority`, `modified` are materialized envelope columns with indices. Filtering and sorting large item sets (10,000+ bibliography entries) does not require deserializing payloads.
- **Full-text search with no additional infrastructure.** FTS5 is bundled with SQLite. No Elasticsearch, no Meilisearch, no separate process.
- **Tooling.** DB Browser for SQLite, the `sqlite3` CLI, and Litestream work against the store with no additional setup. Debugging data issues does not require custom tools.
- **Schema evolution is additive.** New fields go in the payload JSON (no migration required) or as new nullable columns (migration required but trivial). The migration strategy handles both.
- **Time travel is free.** Because every mutation is an operation item in the same table, `StateAsOf::LogicalClock(n)` replays history without any separate event log table.

### What Becomes Harder

- **Concurrent multi-process writes.** Only one `SqliteItemStore` instance should hold the write connection at a time. In practice this is one process (the host app), but if a future agent runtime runs in a separate process, it must route writes through the host app's HTTP API rather than opening the SQLite file directly.
- **Payload queries are slower than envelope queries.** Queries on `json_extract(payload, '$.field')` cannot use the envelope column indices. High-frequency payload fields that become common filter targets (e.g., `doi`, `pub_year`) should be promoted to envelope columns in a future migration.
- **FTS is not re-indexed on payload mutation.** See Open Questions #2.
- **No built-in conflict resolution.** When two devices both create operations on the same item, Lamport clocks give ordering but not semantic merge. For flag and read-status mutations this is fine (last-write-wins by clock). For payload patches, the same field patched on two devices independently will take the later value. This is acceptable for Phase 1-2 (personal use, single primary device) but must be revisited for Phase 3 multi-device workflows.

### Explicitly Deferred

- **Automerge / CRDT layer (Phase 3+).** Collaborative manuscript editing in imprint requires character-level concurrent merge. This will be layered on top of the current store, not replacing it. The `ItemStore` trait abstraction provides the seam. Items with `StorageHint::ContentStore` schemas will carry an `automerge_doc_id` payload field pointing to an `.automerge` file alongside the item's hash metadata.
- **Sync transport (Phase 2-3).** CloudKit record sync for the graph store and iCloud Drive / WebSocket relay for future Automerge documents are not designed here. The Lamport clock and origin ID are the sync primitives; transport design is a separate ADR.
- **Full-text search ranking.** FTS5 supports BM25 ranking via `rank` column. Relevance-ranked search is deferred to Phase 2 once the query interface is proven.
- **sqlite-vec for embedding search.** Vector similarity search (for AI-powered paper recommendations) requires the `sqlite-vec` extension. The schema makes no provision for embedding columns yet; this is a Phase 3 addition.
- **Litestream backup.** WAL mode makes Litestream integration trivial. Configuration is deferred to user-facing setup.

---

## Open Questions

**Q1. FTS re-indexing on payload mutation.**
When an operation patches `payload.title` (e.g., correcting a bibliography entry title), the `items_fts` row is not updated. The stale FTS entry will return stale text in search results. Options: (a) re-run `update_fts()` after every `SetPayload` / `PatchPayload` materialization; (b) rebuild FTS on read (too expensive); (c) accept staleness and document it. Option (a) is preferred but requires loading the full item after every payload mutation to extract FTS fields. This should be addressed before Phase 2 search features ship.

**Q2. Payload field promotion policy.**
As schema usage stabilizes, some payload fields will appear in nearly every query predicate (e.g., `payload.pub_year` for bibliography date filters). There is no current policy for deciding when a payload field earns an envelope column. This should be decided before Phase 2 with actual query performance data from imbib in production.

**Q3. Multi-process write access.**
The current `Mutex<Connection>` model assumes one process. If impel (agent orchestration) runs as a separate process with high write throughput (thousands of agent messages per second), it cannot safely share the SQLite file without a write proxy. The options are: (a) impel routes writes through the host app's HTTP API; (b) impel uses a separate SQLite database that syncs into the shared one; (c) switch to a connection pool with `BEGIN IMMEDIATE` write transactions. This needs resolution before any agent runs in its own process.

**Q4. Automerge boundary definition (Phase 3).**
ADR-0004 proposed a `StorageHint` field on schema definitions to route items to the content store. The specific schemas that need character-level CRDT merge, and the exact boundary mechanism, are unresolved. This will be addressed in the imprint Phase 3 ADR once Beelay's API is stable enough to build against.

**Q5. Tombstone retention and sync protocol.**
Tombstones are written on delete and can be queried by `deleted_at` range for sync. The retention period (currently `cleanup_tombstones(max_age_days)`) is not specified. A peer that has been offline longer than the retention window will not receive deletions. The tombstone retention period, and the sync protocol that uses tombstones, are unresolved.

---

## References

- `crates/impress-core/src/sqlite_store.rs` — `SqliteItemStore` implementation
- `crates/impress-core/src/sql_query.rs` — `compile_query()` and predicate compilation
- `crates/impress-core/src/query.rs` — `ItemQuery`, `Predicate`, `SortDescriptor` definitions
- ADR-0001: Unified Item Architecture for the Impress Suite
- ADR-0002: Operations as Overlay Items and Data Model Foundations
- SQLite documentation: WAL mode, FTS5, JSON functions, `json_extract()`
- Kleppmann, M. (2017). *Designing Data-Intensive Applications*, Ch. 3 (storage engines)
- Ink & Switch, "Local-first software" (2019)
- Ink & Switch, Beelay lab notebooks (2024–2025) — motivation for deferring Automerge multi-document sync
