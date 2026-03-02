# ADR-0003: Operations, Provenance, and Materialized State

**Status:** Accepted
**Date:** 2026-03-02
**Authors:** Tom (with architectural exploration via Claude)
**Supersedes:** ADR-0002 (Operations as Overlay Items and Data Model Foundations) — both the version in `docs/ADR-0002-operations-as-overlay-items.md` and `~/Downloads/newADRs/ADR-0002-operations-as-overlay-items.md`
**Depends on:** ADR-0001 (Unified Item Architecture)
**Scope:** `crates/impress-core` — specifically `src/operation.rs` and `src/sqlite_store.rs`; imbib migration (Phase 1 and beyond)

---

## Context

ADR-0002 established the concept of operation items as the provenance mechanism for state changes in the item graph. That document served its purpose: it justified the departure from mutable fields and sketched the required concepts. It did not, however, specify those concepts precisely enough to govern implementation.

The core library now has working code. `crates/impress-core/src/operation.rs` defines `OperationType`, `OperationIntent`, `OperationSpec`, `UndoInfo`, `EffectiveState`, and `StateAsOf`. `crates/impress-core/src/sqlite_store.rs` implements `SqliteItemStore`, which uses a single `items` table as the unified store for both subject items and operation items, materializes effective state into SQL columns on every write, and uses a monotonic logical clock stored in `store_metadata`. This ADR supersedes ADR-0002 with the authoritative, implementation-grounded specification.

### The Provenance Requirement

Researchers need complete attribution for every state change on a research artifact:

- **Who** changed it (human, which agent, which system service)
- **When** (wall time and causal order)
- **What** the change was (operation type and parameters)
- **Why** the change was made (intent classification and optional free-text reason)
- **What it was before** (captured previous value enabling O(1) undo)

A mutable-field model answers none of these questions. An operation stream answers all of them. Every tag addition, flag change, priority update, and reference modification must therefore create a durable operation item in the graph, not merely update a column.

### The Ephemeral vs. Durable Distinction

Not everything that updates state deserves a provenance record. The distinction is:

**Durable changes** are semantically meaningful to the researcher: adding a tag, setting a flag, marking an item starred, recording a read/unread transition, changing priority, adding a reference, modifying payload fields. Each of these changes what the researcher meant about an item. They produce operation items.

**Ephemeral changes** are process artifacts with no long-term meaning: scroll position, cursor location, UI panel state, transient notification delivery status. These do NOT produce operation items. They may update SQL columns directly (or not be persisted at all).

The boundary can be non-obvious. Read status (`is_read`) is **durable** because it represents a meaningful research activity event — "I read this paper on this date." Cursor position within a PDF is **ephemeral** because it has no meaning beyond the current session.

This ADR specifies the full operation model in terms of the existing implementation.

---

## Decisions

### D11. Durable State Changes Produce Operation Items

Every semantically meaningful state change on an item creates an operation item in the `items` table with `schema_ref = 'core/operation'` and `op_target_id` pointing to the subject item. The subject item's effective state is then materialized immediately to its SQL columns.

The operation item's `payload` contains:

| Key | Type | Purpose |
|-----|------|---------|
| `target_id` | UUID string | The item being changed |
| `op_type` | string | The operation variant name (e.g., `"add_tag"`) |
| `op_data` | JSON value | The operation parameters |
| `intent` | string | One of the `OperationIntent` variants |
| `prev` | JSON value (optional) | Previous field value for O(1) undo |
| `reason` | string (optional) | Free-text explanation |

This structure is produced by `build_operation_payload()` in `operation.rs` and consumed by `parse_op_type_from_payload()` in `sqlite_store.rs`.

### D12. Ephemeral State Changes Do NOT Produce Operation Items

Scroll position, cursor location, panel visibility, and other transient UI state must not create operation items. This is both a correctness concern (the operation stream would be meaningless noise) and a performance concern (the startup render-loop bug described in CLAUDE.md was caused in part by background services firing `storeDidMutate` notifications excessively).

Rule of thumb: if replaying the operation at a later date would teach you something useful about the researcher's intellectual work, it is durable. If not, it is ephemeral.

### D13. Materialized Columns Are the Authoritative Read Model

Effective state is a pure function of the operation stream. Computing it by replaying all operations on every read would be O(n) in the number of operations, which is unacceptable for list views over large bibliographies.

The solution is not a cache — it is a materialized read model. The `items` table contains dedicated columns for every classification field that changes via operations:

```
is_read       INTEGER NOT NULL DEFAULT 0
is_starred    INTEGER NOT NULL DEFAULT 0
flag_color    TEXT
flag_style    TEXT
flag_length   TEXT
priority      TEXT NOT NULL DEFAULT 'normal'
visibility    TEXT NOT NULL DEFAULT 'private'
parent_id     TEXT
modified      INTEGER NOT NULL
```

Tags are materialized in the dedicated `item_tags` table (`item_id`, `tag_path`) with a covering index on `tag_path`. References are in `item_references`.

Every call to `apply_operation()` in `sqlite_store.rs` does two writes atomically:

1. `insert_operation_item()` — writes the provenance record
2. `materialize_operation()` — updates the SQL columns on the target

The materialized columns are **not a cache**. They are the read model. There is no separate cache to invalidate. If the operation write fails, the materialization does not happen (they are in the same database connection, and batch operations use an explicit `unchecked_transaction()`).

The `modified` column is a stored scalar, not derived on read. It is updated to `Utc::now().timestamp_millis()` by `materialize_operation()` on every operation application. This is the `now` parameter threaded through from `apply_operation()`.

Time-travel queries ("state as of last Tuesday") bypass the materialized columns and use `replay_state()`, which replays the operation stream up to a clock or timestamp cutoff via `operations_for()`.

### D14. Hybrid Logical Clock (HLC) Specification

The `logical_clock` column on every item carries a u64 value using Hybrid Logical Clock semantics. The intent is to provide causal ordering that survives wall-clock skew between devices.

**Encoding:** `(wall_clock_ms << 16) | counter`

- Upper 48 bits: milliseconds since Unix epoch (wall clock component)
- Lower 16 bits: monotonic counter that breaks ties within the same millisecond

This encoding gives every HLC value a total order that is strongly correlated with wall time but never goes backwards due to clock skew: when merging a remote clock value, the local clock advances to `max(local, remote) + 1`.

**Current implementation note:** The current `next_clock()` in `sqlite_store.rs` uses a simple monotonic counter stored in `store_metadata`:

```rust
fn next_clock(conn: &Connection) -> Result<u64, StoreError> {
    conn.execute(
        "UPDATE store_metadata SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'logical_clock'",
        [],
    )?;
    // ... read back the incremented value
}
```

The merge path (`merge_clock()`) already applies Lamport semantics (`max(local, remote) + 1`). The full `(wall_ms << 16) | counter` encoding is the target HLC form once multi-device sync is implemented. The counter currently acts as a Lamport clock; the wall-clock component will be blended in when the sync layer reads remote items with their clock values.

**Operations query ordering:** `operations_for()` orders by `(logical_clock ASC, created ASC, id ASC)` — logical clock first for causal order, wall time and UUID as tiebreakers for deterministic replay when logical clocks are equal.

**The critical property:** Two concurrent operations on the same item from different devices will have logically ordered clock values after merge, enabling deterministic effective state computation regardless of network timing.

### D15. Actor Identity Model

Actor identity in the item graph uses three fields:

```rust
pub type ActorId = String;

pub enum ActorKind {
    Human,
    Agent,
    System,
}
```

`ActorId` is a bare `String` (currently `"system:local"` by default, as set in `StoreConfig`). `ActorKind` is the structured variant distinguishing humans from agents from system processes.

**Conventions for `ActorId`:**

| Actor type | Format | Example |
|-----------|--------|---------|
| Human | `human:{username}` or `human:{username}@{device}` | `human:tom@macbook-pro` |
| Agent | `agent:{name}:{version}` | `agent:enrichment-v2` |
| System | `system:{service}` | `system:local`, `system:inbox-scheduler` |

The device suffix on Human actors enables disambiguation when the same researcher acts from multiple devices — a prerequisite for correct per-device attribution in the measurement agenda. Agents carry their version in `ActorId` so that operation provenance records which model/prompt/parameters produced a given change. The `produced_by` field on `Item` links agent-generated items back to the agent's task item.

Operations store both `author` (the `ActorId` string) and `author_kind` (the `ActorKind` enum). Every operation item written by `apply_operation()` inherits these from `OperationSpec`:

```rust
pub struct OperationSpec {
    pub target_id: ItemId,
    pub op_type: OperationType,
    pub intent: OperationIntent,
    pub reason: Option<String>,
    pub batch_id: Option<String>,
    pub author: ActorId,
    pub author_kind: ActorKind,
}
```

### D16. Operation Type Taxonomy

The `OperationType` enum in `operation.rs` defines every mutation that produces a provenance record:

```rust
pub enum OperationType {
    // Classification state
    SetRead(bool),
    SetStarred(bool),
    SetFlag(Option<FlagState>),
    SetPriority(Priority),
    SetVisibility(Visibility),

    // Tag set membership
    AddTag(String),
    RemoveTag(String),

    // Payload (structured metadata fields)
    SetPayload(String, Value),      // set a named field to a value
    RemovePayload(String),          // delete a named field
    PatchPayload(BTreeMap<String, Value>), // bulk update multiple fields atomically

    // Graph structure
    AddReference(TypedReference),
    RemoveReference(ItemId, EdgeType),
    SetParent(Option<ItemId>),

    // Extension point
    Custom(String, Value),
}
```

**Semantics by category:**

`SetRead`, `SetStarred`, `SetFlag`, `SetPriority`, `SetVisibility` are idempotent scalar assignments. Their materialization writes directly to the corresponding SQL column. Undo captures the previous column value before writing, enabling O(1) inverse computation without operation replay.

`AddTag` / `RemoveTag` are symmetric: the inverse of `AddTag("foo")` is `RemoveTag("foo")` and vice versa. No previous-value capture is needed. Materialization writes to / deletes from the `item_tags` join table and bumps `modified` on the parent item.

`SetPayload` / `RemovePayload` / `PatchPayload` modify the JSON `payload` blob using SQLite's `json_set` and `json_remove` functions. These are the mechanism for updating domain-specific metadata fields (e.g., `title`, `abstract`, `doi`) without creating a new item. Undo captures the previous field value via `json_extract`.

`AddReference` / `RemoveReference` modify the `item_references` table. These are symmetric; no previous-value capture. They represent changes to the item's position in the reference graph (e.g., adding a citation, linking to a collection).

`SetParent` reparents an item in the hierarchy (changes `parent_id`). Undo captures the previous `parent_id`.

`Custom(name, data)` is the extension point for domain-specific operations whose semantics are defined at the application layer. The store records the operation faithfully but cannot compute an inverse — `inverse_of()` returns `None` for `Custom`. Materialization only bumps `modified`.

**Note on ADR-0002 naming:** ADR-0002 referred to `CreateItem`, `DeleteItem`, `TaskStateChange` as operation types. In the actual implementation, item creation is handled by `ItemStore::create()` (not an operation), deletion by tombstone (the `op_target_id` foreign key with `ON DELETE CASCADE` causes operation items to be cleaned up when the target is deleted), and task state changes use `SetPayload` or `SetVisibility` on the task item. This ADR reflects the implemented taxonomy.

### D17. OperationIntent Taxonomy

`OperationIntent` is the "why" annotation on every operation. It applies **only to operation items** (items with `schema_ref = 'core/operation'`). It is stored in the operation's `payload` as the `intent` key.

```rust
pub enum OperationIntent {
    Routine,      // (default) Normal workflow action, no special attention required
    Hypothesis,   // Exploratory, flagging something for investigation
    Anomaly,      // Something unexpected observed by an automated system
    Editorial,    // Stylistic or organizational change, not substantive
    Correction,   // Fixing a previous error (also used by undo operations)
    Escalation,   // Requires human review before the workflow can proceed
}
```

**Precise definitions:**

- **Routine** is the default (`#[default]`). A researcher marks a paper as read, an agent adds a bibliographic tag, a sync service updates a DOI. No special routing.
- **Hypothesis** signals that the actor was operating in an investigative mode — testing a tagging scheme, trying an exploratory categorization. Useful for distinguishing committed organizational decisions from tentative ones.
- **Anomaly** is used exclusively by automated systems (agents, background services) to signal that something unexpected was observed that may require human attention. An enrichment agent that detects a DOI mismatch would flag with `Anomaly`.
- **Editorial** marks organizational or stylistic changes that do not affect the substantive content of the research record — reorganizing a tag hierarchy, renaming a collection, correcting a typo in a note.
- **Correction** marks the reversal of a prior error. The `undo_operation()` implementation applies the inverse as a `Correction` with `reason = "undo:{original_operation_id}"`.
- **Escalation** signals that the operation requires human attention before the surrounding workflow can continue. Used by agents to request human review of a decision they are not confident making autonomously.

**Critical distinction:** `OperationIntent` is only for operation items. The `message_type` field on `Item` is a separate, unrelated concept for communication items (see D20 below). Do not conflate them.

### D18. Batch Grouping via `batch_id`

Operations that are logically a single user action must share a `batch_id`. The field is an optional `String` on both `Item` and `OperationSpec`.

Examples of multi-operation logical actions:

- Moving a paper from one collection to another: `RemoveReference` from source + `AddReference` to target
- Bulk-tagging a selection of 50 papers: 50 `AddTag` operations
- Clearing all tags before applying a new taxonomy: N `RemoveTag` + M `AddTag` operations

`apply_operation_batch()` in `sqlite_store.rs` wraps all operations in a single SQLite transaction (via `unchecked_transaction()`) and assigns a freshly generated UUID as the shared `batch_id`. The transaction commits atomically; if any operation fails, none are written.

Undo respects batch boundaries. `undo_batch()` finds all operations with a given `batch_id`, orders them by `logical_clock DESC`, computes inverses in reverse order, and applies them as a new batch with `intent = Correction` and `reason = "undo_batch:{original_batch_id}"`. The result is an `UndoInfo` containing all inverse operation IDs and the new batch ID.

The `batch_id` column has a partial index: `idx_items_batch ON items(batch_id) WHERE batch_id IS NOT NULL`. This makes batch lookups O(log n) without indexing the majority of rows that have null `batch_id`.

### D19. UndoInfo and the Undo/Redo Model

Every mutation through `apply_operation()` or `apply_operation_batch()` returns an `ItemId` (or `Vec<ItemId>`) for the created operation item(s). The caller wraps this in an `UndoInfo` for registration with the platform undo manager:

```rust
pub struct UndoInfo {
    pub operation_ids: Vec<ItemId>,
    pub batch_id: Option<String>,
    pub description: String,  // e.g., "Star 3 Papers", "Add Tag 'methods/sims'"
}
```

`UndoInfo.description` is generated by `undo_description()` in `operation.rs`, which produces human-readable Edit-menu strings like `"Mark as Read"`, `"Flag Paper"`, `"Add Tag 'methods/sims'"`.

Undo is implemented as a new forward operation (not as a state rollback). `undo_operation()` reads the original operation's payload, extracts `op_type` and `prev`, calls `inverse_of()` to compute the reversing operation, and applies it with `intent = Correction`. This means:

- The undo itself is fully in the provenance record
- Redo is undo of the undo (the undo manager holds the `UndoInfo` of the correction operation)
- No special undo log is maintained; the operation stream is the undo log

`inverse_of()` returns `None` for `Custom` operations (no defined semantics) and for `RemovePayload` when the field did not previously exist (nothing to restore). The caller handles `None` by disabling undo registration for that operation.

### D20. `message_type` on Communication Items

The `message_type` field on `Item` is unrelated to `OperationIntent`. It applies to communication items — items representing emails, chat messages, agent progress updates, and similar message-shaped artifacts. It is `Option<String>` stored as a nullable SQL column.

Defined values:

| `message_type` | Meaning |
|----------------|---------|
| `"progress"` | An in-progress status update from a running agent task |
| `"result"` | The final output of a completed task |
| `"anomaly"` | An unexpected observation surfaced for human review |
| `"question"` | A clarifying question from an agent requiring human response |
| `"handoff"` | A transition of responsibility from one actor to another |

These values have no effect on operation semantics. They are read by the communication/message UI layer to decide how to render and route communication items. A message with `message_type = "anomaly"` is not an operation item and does not carry `OperationIntent`.

The distinction is important: `OperationIntent::Anomaly` on an operation item means "this state change was flagged as anomalous," and exists in the provenance trail. A communication item with `message_type = "anomaly"` is a message artifact sent to surface an observation to a human. Both may coexist as a result of the same agent action, but they are separate items with separate purposes.

---

## Effective State as a Pure Function Requiring Materialized Columns

The formal statement of effective state is:

```
effective_state(item_id, as_of) =
    fold(
        operations
            .filter(|op| op.op_target_id == item_id && op.logical_clock <= as_of)
            .sort_by(|a, b| a.logical_clock.cmp(&b.logical_clock)
                           .then(a.created.cmp(&b.created))
                           .then(a.id.cmp(&b.id))),
        initial_state_from_envelope,
        apply_operation
    )
```

This is a pure function. Given the same operation stream and the same initial envelope, it always produces the same result. There is no mutable state.

However, evaluating this function on every read — even for a single item — is O(k) in the number of operations targeting that item. For a list view of 2,000 publications each with an average of 20 operations, that is 40,000 operation reads per render cycle. This is unacceptable.

The materialized columns are the engineering resolution: the database maintains the result of `effective_state(id, current)` as a set of SQL columns, updated eagerly on every write. The `StateAsOf::Current` branch of `effective_state()` in `sqlite_store.rs` takes the fast path, reading directly from the materialized columns:

```rust
StateAsOf::Current => {
    // Fast path: read materialized columns
    let item = self.get(id)?;
    // ... return EffectiveState from item fields
}
```

Time-travel queries (`StateAsOf::LogicalClock(clock)` and `StateAsOf::Timestamp(ts)`) call `replay_state()`, which executes the full fold over the filtered operation stream. These are O(k) and reserved for explicit time-travel use cases (audit, reproducibility), not routine reads.

**The materialized columns are not a cache.** A cache can be invalid. If the columns are out of sync with the operation stream, the store is corrupt, not stale. The write path in `apply_operation()` ensures they are always in sync by performing both writes in the same database connection under the same lock (`Mutex<Connection>`).

---

## Compaction

Operation items accumulate over time. A researcher who interacts with a large bibliography daily generates thousands of operations per year. Most of these are routine: tag adds/removes, read-status toggles, flag changes. Their individual provenance value diminishes after the decisions they represent are well-established.

Compaction is the mechanism for bounding this growth without destroying the invariant that effective state is computable from the stream.

**The compaction invariant:** Compaction must never alter the durable effective state. If the full operation stream produces state S at clock T, the compacted stream must also produce state S at clock T. This is testable: compute effective state from both streams and assert equality.

**What can be compacted:** Operations in the Compactable retention tier (per ADR-0003/the retention tier design). These include: routine agent tag operations after a configurable window, completed enrichment task state-transition operations, redundant read-status toggles (a sequence of set_read=true, set_read=false, set_read=true reduces to a single set_read=true).

**What cannot be compacted:** Operations in the Durable tier: human annotations, editorial decisions, hypothesis-tagged operations, Correction operations (they are audit trail), Escalation operations.

**Compaction mechanism:** Replace a sequence of operations with a single snapshot operation whose payload contains the net effective contribution of the sequence. The operation stream remains append-only; compaction is implemented by marking original operations as superseded and inserting a snapshot, or by physical deletion with a logged summary, depending on the retention tier.

The current `sqlite_store.rs` does not implement compaction. The `op_target_id ON DELETE CASCADE` foreign key handles the case where a subject item is deleted (all its operation items are removed automatically). Compaction of live items is a future implementation task.

---

## Consequences

### Positive

1. **Complete provenance.** Every state change on any item is attributable to an actor with a timestamp, causal order, intent classification, and optional reason. "Who starred this paper, when, and why?" is always answerable.
2. **Time-travel.** `effective_state(id, StateAsOf::Timestamp(ts))` replays the operation stream to any point in history. Reproducibility and audit are intrinsic.
3. **O(1) reads.** Materialized columns make list-view rendering fast regardless of operation history depth.
4. **Undo is free.** The operation stream is the undo log. `undo_operation()` and `undo_batch()` require no separate undo stack; they read from the existing provenance trail.
5. **Consistent event sourcing.** No mutable hidden state. Sync, backup, and replication work on an append-only stream.
6. **Measurement agenda enabled.** Operation items are the data source for human-AI collaboration metrics: who applies which tags, which intent distributions emerge, which agent operations are subsequently corrected by humans.
7. **Batch operations are atomic.** `apply_operation_batch()` wraps in a SQLite transaction. Either all operations commit or none do.
8. **Intent × priority for attention routing.** Two orthogonal dimensions for filtering the operation stream without a separate notification system.

### Negative

1. **Storage growth.** Operations accumulate. An active bibliography with 2,000 papers and 10 operations per paper per year reaches 20,000 operation items annually. The `op_target_id` index (partial, not-null-only) keeps lookups fast, but raw table size grows. Compaction is necessary for multi-year use.
2. **Two writes per mutation.** Every `apply_operation()` does both `insert_operation_item()` and `materialize_operation()`. For bulk imports or batch enrichment, this roughly doubles write latency compared to direct column updates. The batch path (`apply_operation_batch()` + single transaction) mitigates this significantly.
3. **Developer conceptual overhead.** The distinction between the operation item (provenance) and the materialized column (read model) must be understood. New contributors must not update materialized columns directly — all mutations go through `apply_operation()`.
4. **Custom operations cannot be undone.** `inverse_of()` returns `None` for `OperationType::Custom`. Callers that use `Custom` must handle this gracefully or provide their own undo logic.

---

## Open Questions

1. **HLC full encoding.** The current clock is a Lamport counter. Blending in the wall-clock component (`wall_ms << 16 | counter`) requires deciding how the counter resets at each millisecond boundary and how to handle overflow when counter exceeds 65535 within a single millisecond. Design when the sync layer is implemented.

2. **Conflict resolution for non-commutative concurrent operations.** Two devices concurrently setting `priority` to different values on the same item will produce a deterministic winner (the one with the higher logical clock after merge), but the loser is silently dropped. This may not match user expectations. Consider: last-write-wins (current behavior), explicit conflict items, or per-field CRDTs.

3. **Compaction implementation.** The compaction invariant and tier classification are specified; the implementation is not. Key questions: is compaction a background task or eager-on-write? Does it produce a snapshot operation item or physically delete rows? How is the compaction audit trail (what was compacted, when) recorded?

4. **`OperationIntent` evolution.** The enum is currently closed (`#[serde(rename_all = "lowercase")]`). Adding a new variant is a serde breaking change for stored operation items. Consider: open-string enum with validated set (extensible without migration) vs. closed enum (compile-time exhaustiveness, migration required to add values).

5. **`ActorId` format governance.** The `human:{username}@{device}` convention is informal. Two implementations could produce different strings for the same actor. A validation layer (or at minimum a constructor function) should enforce the format before multi-device sync is built.

6. **Custom operation undo.** Applications that use `OperationType::Custom` cannot get undo support from the store. Possible remedies: require callers to supply a `CustomInverse` alongside `Custom`; extend the operation payload to carry an inverse spec; or accept that `Custom` operations are explicitly non-undoable.

7. **Operation history UI.** How to present operation history in imbib — a provenance panel showing who changed which tags and when, with intent badges and reason tooltips. The data is available; the view design is open.

---

## References

- `crates/impress-core/src/operation.rs` — `OperationType`, `OperationIntent`, `OperationSpec`, `UndoInfo`, `EffectiveState`, `StateAsOf`, `inverse_of()`, `undo_description()`, `build_operation_payload()`
- `crates/impress-core/src/sqlite_store.rs` — `SqliteItemStore`, `apply_operation()`, `apply_operation_batch()`, `undo_operation()`, `undo_batch()`, `materialize_operation()`, `capture_previous_value()`, `effective_state()`, `operations_for()`, `merge_clock()`
- `crates/impress-core/src/item.rs` — `Item`, `ActorKind`, `ActorId`, `FlagState`, `Priority`, `Visibility`, `Value`
- ADR-0001: Unified Item Architecture for the Impress Suite
- Young, G. (2010). "CQRS Documents"
- Kulkarni, S. et al. (2014). "Logical Physical Clocks and Consistent Snapshots in Globally Distributed Databases" (HLC paper)
- Kleppmann, M. (2017). *Designing Data-Intensive Applications*, Ch. 11 (Event Sourcing and CQRS)
