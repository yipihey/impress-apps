# ADR-0001: Unified Item Protocol for the Impress Suite

**Status:** Accepted
**Date:** 2026-03-02
**Authors:** Tom
**Supersedes:** ADR-0001-unified-item-architecture.md (Proposed, 2026-02-08)
**Scope:** `impress-core` crate, imbib (Phase 1 proving ground), impart (Phase 2 construction from scratch)

---

## Context

The impress suite has six applications — imbib, imprint, implore, impel, implement, impart — each with its own data model and persistence layer. This separation produces friction: a researcher cannot reference a paper in their email reply without leaving imbib and switching mental context into impart. Two apps cannot trivially display each other's data. Cross-app automation requires bespoke inter-process protocols.

The core observation driving this ADR: bibliography entries, reading annotations, agent progress logs, chat messages, manuscript comments, and dataset references differ primarily in *presentation*, not in *structure*. At the data level, they all have an identifier, a creation timestamp, an author, a payload of domain-specific fields, and typed relationships to other entities. The differences that matter are in schema (what fields the payload contains) and view (how the UI renders them) — not in transport or storage.

This ADR records the decisions made to implement a single shared data protocol — `impress-core` — and the concrete architectural constraints that govern it. The implementation of `impress-core` is not aspirational: the crate exists at `crates/impress-core/` and its modules are described below as they actually are.

### Why the Previous ADR is Superseded

The 2026-02-08 ADR (Proposed) described a target architecture with several elements that have been decided against or significantly refined:

- It described tiered hot/warm/cold storage. This architecture is rejected. SQLite with WAL mode is sufficient; complexity of LMDB or custom storage is not warranted at current scale.
- It proposed a `ViewTemplate` declarative DSL (TOML/YAML) for defining views. This is rejected. Views are concrete SwiftUI code — five named cognitive views per the design philosophy.
- It described an in-core "Attention Router" service. Attention routing is app-level middleware, not a core store service. The store emits events; routing logic lives in each app.
- It described a lock-free ring buffer for agent communication. Deferred. The current model uses Darwin notifications and SQLite events. The ring buffer is an optimization for a future phase with proven throughput requirements.
- It left the storage engine as an open question. It is now decided: SQLite, via rusqlite, as a feature-gated backend behind the `ItemStore` trait.
- It described `ItemId` as UUID without committing to a version. Decided: UUIDv4 (random). See D1.

### Guardrails Against Over-Abstraction

This architecture is aware of the Chandler/OSAF failure mode: eight million dollars and seven years building a "unified representation for tasks and information" that never answered "who is this for?" OpenDoc, CORBA, and the Semantic Web all collapsed under their own generality.

**Our concrete guardrails:**

1. **Phase 1 is the proving ground.** Imbib must work identically from the user's perspective after migration to `impress-core`. If the migration takes more than a few weeks, the abstraction is wrong.

2. **Each abstraction justifies itself with two concrete, already-needed use cases.** The shared `Item` struct is justified by bibliography entries and research artifacts (both exist today in imbib). The `EdgeType` taxonomy is justified by citation graphs and file attachments (both exist today). Not hypothetical future uses.

3. **Write concrete types first.** `BibliographyEntry` and `ResearchArtifact` existed before `impress-core`. The protocol was extracted from what they actually shared, not designed in the abstract.

4. **The view framework is concrete SwiftUI, not a declarative DSL.** The five cognitive views (Library, Stream, Chronicle, Landscape, Desk) are concrete SwiftUI views compiled into each app. There is no `ViewTemplate` struct with TOML fields.

5. **Phases 3+ (impel integration, collaboration, impress mode) are explicitly deferred.** They do not drive any design decisions in this ADR.

6. **The question to keep asking:** What *specific operations* work across item types that wouldn't work without the unified protocol? If the answer is only "they're in the same database," the unification isn't earning its complexity.

---

## Decision

### D1. ItemId is UUID v4 (128-bit, random)

`ItemId` is a type alias for `uuid::Uuid`, generated with `Uuid::new_v4()`.

```rust
// crates/impress-core/src/item.rs
pub type ItemId = Uuid;
```

UUID v4 was chosen over ULID and UUID v7 because:
- imbib already uses UUID v4 for all existing records. Migration to a different format would require a full re-keying.
- Time-sortability is not required at the store layer; sorting is by the `created` timestamp column, not by key structure.
- UUID v4 has no privacy implications (no embedded timestamp, no embedded node ID).

**Note:** UUIDv7 is a candidate for future items if time-sortability of keys becomes valuable (e.g., for distributed ingestion ordering). The `ItemId` type alias makes this substitution local.

`canonical_id` (for future collaboration, where two stores refer to the same logical entity) is also an `Option<String>` holding a UUID from a shared namespace agreed among collaborators. It is not used in Phase 1.

### D2. The Item Struct is the Canonical Definition

All data across the impress suite is represented as `Item` values. There are no app-specific data model types at the persistence layer; apps define typed Swift wrappers over items (see D30).

The `Item` struct as implemented in `crates/impress-core/src/item.rs`:

```rust
pub struct Item {
    // Immutable envelope — set at creation, never changed
    pub id: ItemId,               // UUID v4; stable across sync
    pub schema: SchemaRef,        // String key into the schema registry ("bibliography-entry")
    pub created: DateTime<Utc>,   // Wall-clock time of first write
    pub author: ActorId,          // String: email, agent ID, or "system:local"
    pub author_kind: ActorKind,   // Human | Agent | System

    // Domain-specific content
    pub payload: BTreeMap<String, Value>,  // Schema-typed fields; see D8

    // Causal ordering and collaboration
    pub logical_clock: u64,        // Monotonically increasing per store; used for operation ordering
    pub origin: Option<String>,    // Store instance ID that created this item (UUID)
    pub canonical_id: Option<String>, // Shared identity across collaborating stores (see D2)

    // Classification — materialized projections of the operation history (see D9)
    pub tags: Vec<String>,         // Hierarchical tag paths, e.g. "methods/sims/hydro"
    pub flag: Option<FlagState>,   // Color + optional style/length
    pub is_read: bool,
    pub is_starred: bool,
    pub priority: Priority,        // None | Low | Normal | High | Urgent
    pub visibility: Visibility,    // Private | Shared | Public

    // Communication and provenance
    pub message_type: Option<String>,  // For communication items: progress, result, anomaly, etc.
    pub produced_by: Option<ItemId>,   // Agent run or process that created this item
    pub version: Option<String>,       // For versioned items (manuscripts, code)
    pub batch_id: Option<String>,      // Groups related mutations for undo/redo

    // Graph structure
    pub references: Vec<TypedReference>, // Outbound edges; denormalized, also in item_references table
    pub parent: Option<ItemId>,          // Hierarchical containment (collection, thread, section)
}
```

**Field group semantics:**

The *immutable envelope* (`id`, `schema`, `created`, `author`, `author_kind`) is set once at creation and is never modified. Enforcing this at the API layer is the responsibility of the store; `SqliteItemStore.insert()` validates that no item with the same ID exists.

The *classification fields* (`tags`, `flag`, `is_read`, `is_starred`, `priority`, `visibility`) are materialized projections. They are stored as columns for O(1) read performance, but every change to them is also written as an operation item (schema `impress/operation`) targeting the parent item. This preserves the full history of who changed what and why, enabling audit trails and undo without full replay. See the operation model in `crates/impress-core/src/operation.rs`.

The *graph structure* (`references`, `parent`) is stored both in the `Item` struct and in the `item_references` SQL table. The SQL table is the authoritative source for graph queries (the `neighbors()` method); the `references` field on the struct is a convenience snapshot loaded with the item.

### D3. modified is a Stored, Materialized Column

The `modified` timestamp is a stored column in the `items` SQL table, set to `NOW()` on each `update()` call. It is not on the `Item` struct (it would be stale immediately after any operation); it is included in SQL sort descriptors as the field path `"modified"`.

The previous ADR proposed that `modified` be derived from the most recent operation item. This was rejected: deriving it requires a join or subquery on every sort, which is expensive for large lists. A materialized column is updated as a side effect of each write and costs nothing on read.

### D4. payload is BTreeMap<String, Value>; Raw Access is an Anti-Pattern

```rust
pub payload: BTreeMap<String, Value>,
```

The `Value` enum is a JSON-compatible dynamic type:

```rust
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(String),
    Array(Vec<Value>),
    Object(BTreeMap<String, Value>),
}
```

`BTreeMap` was chosen over `HashMap` for deterministic serialization order, which makes diffing and testing easier.

**The anti-pattern:** accessing `payload["title"]` directly outside the adapter layer. Code that does this is brittle against schema evolution and obscures intent. The correct pattern is schema-specific typed accessors.

**The accessor pattern (Rust side):** each schema module exposes functions that take `&Item` and return typed values. In the Swift layer, each app defines typed Swift structs wrapping `Item` (see D30).

### D5. TypedReference Model

```rust
// crates/impress-core/src/reference.rs
pub struct TypedReference {
    pub target: ItemId,
    pub edge_type: EdgeType,
    pub metadata: Option<BTreeMap<String, Value>>,
}
```

`metadata` carries edge-specific data. For `Cites`, it may hold `{"page": 42}` or `{"locator_type": "section"}`. For `Attaches`, it may hold `{"filename": "figure.pdf", "mime_type": "application/pdf"}`. The metadata map is intentionally untyped; constraints are enforced by the schema's `expected_edges` declarations, not at the store layer.

### D6. EdgeType Taxonomy

The `EdgeType` enum defines the standard typed edges. A `Custom(String)` variant allows domain-specific edges without forking the crate.

The current implemented variants (as of this ADR):

| Variant | Meaning | Typical use |
|---|---|---|
| `Cites` | Academic citation | Paper A cites paper B |
| `References` | General reference | Item links to another item without implying citation |
| `InResponseTo` | Reply/response | Message B is a reply to message A |
| `Discusses` | Topic reference | Agent log discusses manuscript section |
| `Contains` | Logical containment | Collection contains paper |
| `Attaches` | File attachment | Item has an attached file artifact |
| `ProducedBy` | Authorship/generation | Paper produced by author; artifact produced by agent run |
| `DerivedFrom` | Data/computation lineage | Figure derived from dataset |
| `Supersedes` | Version replacement | Preprint v2 supersedes preprint v1 |
| `Annotates` | Annotation | Reading note annotates paper |
| `Visualizes` | Visualization | Figure visualizes dataset |
| `RelatesTo` | General association | Catch-all for weak, unclassified relationships |
| `DependsOn` | Task/computation dependency | Analysis step depends on data pipeline step |
| `OperatesOn` | Agent action target | Agent run operates on a set of papers |
| `Custom(String)` | Domain-specific | Anything not covered above |

**Variants specified in the master decisions not yet in the implemented enum:**

The following variants were specified for the target taxonomy but are not yet in `reference.rs`: `IsPartOf`, `HasVersion`, `Mentions`, `TriggeredBy`, `Exports`. These are additive — adding them is backward compatible, as `Custom("is-part-of")` can be used until they are promoted to first-class variants.

**Tradeoff:** A closed enum forces code to be exhaustive in match arms, which is valuable for correctness. The `Custom` escape hatch provides extensibility without losing that guarantee for known types. Domain-specific edges that appear in more than one place in the codebase should be promoted to named variants.

### D7. Schema Definition and Registry

`SchemaRef` is a `String` — a dotted path like `"bibliography-entry"` or `"impress/artifact/presentation"`. It is stored as a column in the `items` table and is the key into the `SchemaRegistry`.

```rust
// crates/impress-core/src/schema.rs
pub struct Schema {
    pub id: SchemaRef,
    pub name: String,
    pub version: String,             // SemVer string, e.g. "1.0.0"
    pub fields: Vec<FieldDef>,       // Required and optional field definitions
    pub expected_edges: Vec<EdgeType>, // Edge types this schema typically uses
    pub inherits: Option<SchemaRef>, // Single-parent schema inheritance
}

pub struct FieldDef {
    pub name: String,
    pub field_type: FieldType,   // String | Int | Float | Bool | DateTime | StringArray | Object
    pub required: bool,
    pub description: Option<String>,
}
```

The `SchemaRegistry` validates items at insert time. Validation checks:
- Required fields are present and non-null.
- Present fields match their declared `FieldType`.
- Inherited fields (via `inherits`) are included in the validation pass.

Schemas are currently registered in code, not loaded from files. The `impress/artifact/*` family (8 artifact types) is registered via `register_artifact_schemas()` in `crates/impress-core/src/schemas/artifact.rs`. The `bibliography-entry` schema is defined in imbib's Rust core.

**Schema versioning and evolution:** the `version` string is stored but not yet used for migration logic. This is a known gap. Items written under an old schema version remain readable; new required fields cannot be added without either a migration or making them optional. This must be solved before Phase 1 ships to production.

### D8. Schema-Specific Typed Accessors are the Pattern

Each schema's Rust module exposes typed accessor functions rather than requiring callers to use raw `payload` map access.

Example pattern (bibliography entry):

```rust
// In the bibliography-entry schema module:
pub fn title(item: &Item) -> Option<&str> {
    match item.payload.get("title") {
        Some(Value::String(s)) => Some(s.as_str()),
        _ => None,
    }
}

pub fn year(item: &Item) -> Option<i64> {
    match item.payload.get("year") {
        Some(Value::Int(n)) => Some(*n),
        _ => None,
    }
}
```

Callers write `bibliography::title(&item)` not `item.payload["title"]`. The accessor is the schema contract.

**FTS extractors:** each schema accessor module also provides an `fts_text(item: &Item) -> FtsEntry` function that extracts the text content suitable for full-text indexing. The `SqliteItemStore` calls this on insert to populate the `items_fts` virtual table. This is schema-specific knowledge that belongs in the schema module, not in the store.

### D9. The Relational Store with Graph-Structured Relationships

The implementation is SQLite (via rusqlite, feature-gated under `features = ["sqlite"]`) with the following table layout:

```
items              — one row per item; all envelope and classification columns materialized
item_tags          — normalized tag membership (item_id, tag_path)
item_references    — adjacency list (source_id, target_id, edge_type, metadata)
store_metadata     — key/value pairs for store-level configuration (origin_id, logical_clock, tag_namespace)
items_fts          — FTS5 virtual table (title, author_text, abstract_text, note)
```

**This is not a graph database.** Calling it a graph database would be false advertising. Graph databases (Neo4j, TigerGraph) provide native graph storage engines, traversal query languages (Cypher, Gremlin), and index-free adjacency. This implementation is a relational store with a typed adjacency list table (`item_references`) and a `neighbors()` method that performs recursive SQL joins up to a given depth.

The `neighbors()` method is correct for research workflows where graph depth is shallow (citations are typically depth 1-2, thread replies are depth 5-10). It is not suitable for arbitrary-depth traversal over millions of nodes without depth limits.

SQLite WAL mode (`PRAGMA journal_mode = WAL`) provides concurrent readers with a single writer, which matches the single-process app model.

**Why not LMDB, sled, or a custom engine?**

- SQLite WAL is sufficient for the current scale: thousands of items in imbib, tens of thousands in impart over months. Millions of items per day from concurrent agents is a future problem.
- SQLite provides FTS5 for full-text search, which would require a separate process or library otherwise.
- SQLite has 20+ years of reliability and is the only embedded database with broad platform support including iOS sandbox.
- LMDB and sled would require implementing sorting, filtering, and full-text search from scratch.

The `ItemStore` trait abstracts the backend:

```rust
// crates/impress-core/src/store.rs
pub trait ItemStore: Send + Sync {
    fn insert(&self, item: Item) -> Result<ItemId, StoreError>;
    fn insert_batch(&self, items: Vec<Item>) -> Result<Vec<ItemId>, StoreError>;
    fn get(&self, id: ItemId) -> Result<Option<Item>, StoreError>;
    fn update(&self, id: ItemId, mutations: Vec<FieldMutation>) -> Result<(), StoreError>;
    fn delete(&self, id: ItemId) -> Result<(), StoreError>;
    fn query(&self, q: &ItemQuery) -> Result<Vec<Item>, StoreError>;
    fn count(&self, q: &ItemQuery) -> Result<usize, StoreError>;
    fn neighbors(&self, id: ItemId, edge_types: &[EdgeType], depth: u32) -> Result<Vec<Item>, StoreError>;
    fn subscribe(&self, q: ItemQuery) -> Result<Receiver<ItemEvent>, StoreError>;
}
```

If throughput requirements grow to the agent-scale case (thousands of writes per second), the storage engine can be replaced behind this trait without changing callers.

### D10. App Architecture: Single Process, Shared SQLite

Each impress app is a single macOS process. Apps do not share a process; they share a file. The shared store lives in the app group container at `group.com.impress.suite/`. SQLite WAL mode allows multiple processes to read concurrently with one writer at a time.

The Swift entry point is `RustStoreAdapter` — a `@MainActor @Observable` singleton that wraps the UniFFI-generated bindings over the Rust store. All store access in the Swift layer goes through this adapter.

```
App process (e.g., imbib)
├── Swift UI (SwiftUI views)
├── RustStoreAdapter (@MainActor @Observable)  ← single point of store access
└── impress-core (Rust, via UniFFI)
    └── SqliteItemStore
        └── ~/Library/Group Containers/group.com.impress.suite/store.sqlite
```

A second app (e.g., impart) opens the same SQLite file via its own `SqliteItemStore` instance. SQLite's WAL locking ensures consistency. Apps do not need to coordinate writes explicitly; the database's write lock serializes them.

**The consequence of this model:** there is no dedicated server process, no IPC protocol to define, and no network partition to handle. The shared state is a file. The tradeoff is that write throughput is limited to what SQLite can sustain (typically 10,000–100,000 simple writes/second on modern hardware), which is adequate for human-paced research workflows and moderate agent output. High-frequency agent logging at scale would require a dedicated write process and is deferred.

### D11. Event Notification Model: Darwin Notifications, Not a Ring Buffer

When a mutation is committed to the store, the `SqliteItemStore` emits an `ItemEvent` via an in-process `std::sync::mpsc` channel. The Swift `RustStoreAdapter` wraps this and posts a Darwin notification (via `CFNotificationCenter`) so that other apps observing the same store can refresh their view.

```
SqliteItemStore.update() → mpsc::Sender<ItemEvent>
                         → RustStoreAdapter bridges to Swift
                         → CFNotificationCenter.post("com.impress.store.didMutate")
                         → Other apps receive notification, poll the store
```

**This is a notification, not a data channel.** Darwin notifications carry no payload. The receiving app does not get the mutated item; it gets a signal that something changed, then queries the store itself for the current state. This is polling on notification, which is appropriate for low-frequency mutations (human actions, background sync) but would be inefficient for high-frequency agent output.

The previous ADR proposed a lock-free ring buffer in shared memory as the agent output channel. This is deferred. The ring buffer becomes necessary only when agent output exceeds what Darwin notification + poll can handle without visible latency. That threshold has not been reached, and building the ring buffer now would be premature.

**`storeDidMutate` and the startup render loop:** background services that call `storeDidMutate` during the first ~90 seconds of app launch cause perpetual SwiftUI body re-evaluation (spinning beach ball). All background services that mutate the store must apply a startup grace period delay before their first work cycle. This is not optional. See CLAUDE.md for the exact mechanisms.

### D12. UniFFI is the Rust-Swift Bridge

`RustStoreAdapter` in imbib is the reference implementation of the UniFFI bridge pattern. It exposes the full Rust store API to Swift through generated bindings. Swift apps do not access rusqlite or any Rust internals directly; all access is through the UniFFI interface.

The adapter is the only place where:
- `ItemId` (Rust `Uuid`) is converted to Swift `UUID`
- `Item` (Rust struct) is converted to domain-specific Swift types
- Errors (`StoreError`) are converted to Swift `LocalizedError` types

### D13. Typed Swift Structs Wrap Item at the App Layer

Each Swift app defines typed structs that wrap `Item`. These structs are not stored; they are view models over the underlying `Item`.

Example pattern:

```swift
// In imbib
struct Publication {
    let item: Item        // The underlying item

    var title: String? { item.payload["title"]?.stringValue }
    var year: Int? { item.payload["year"]?.intValue }
    var citeKey: String? { item.payload["cite_key"]?.stringValue }
    var isRead: Bool { item.isRead }
    var tags: [String] { item.tags }
}
```

The typed wrapper:
- Provides Swift-idiomatic access (computed properties, not subscript)
- Documents the schema contract in Swift
- Is the boundary where `Optional` handling is made explicit
- Never reaches into `payload` with string literals scattered across the codebase

Raw `payload["title"]` access is permitted only inside the typed wrapper struct and inside UniFFI adapter methods. Everywhere else, it is an anti-pattern.

### D14. Attention Routing is App-Level Middleware, Not a Core Service

The `impress-core` store does not route attention. It emits `ItemEvent` values when items are created or modified. Each app decides what those events mean for notification, badging, or interruption.

Attention routing logic (deciding whether a new item should trigger a notification, increment a badge, or be suppressed) lives in app-specific middleware that subscribes to store events. This logic is different per app and per user, and placing it in the core would make it impossible to customize without forking the library.

The `Priority` field on `Item` and the `OperationIntent` on operations provide structured inputs for attention routing decisions, but the routing itself is not in scope for `impress-core`.

### D15. The Query Model

```rust
// crates/impress-core/src/query.rs
pub struct ItemQuery {
    pub schema: Option<SchemaRef>,
    pub predicates: Vec<Predicate>,
    pub sort: Vec<SortDescriptor>,
    pub limit: Option<usize>,
    pub offset: Option<usize>,
}
```

`Predicate` supports field comparisons (`Eq`, `Gt`, `Contains`, `In`), classification predicates (`HasTag`, `HasFlag`, `IsRead`, `IsStarred`), graph predicates (`HasParent`, `HasReference`, `ReferencedBy`), and logical combinators (`And`, `Or`, `Not`).

`SortDescriptor.field` is a field path string: `"created"`, `"modified"`, `"priority"`, or `"payload.title"` (for JSON-extracted payload fields). The SQLite query compiler (`sql_query.rs`) translates these to SQL with `json_extract()` for payload fields.

This query model directly replaces imbib's `PublicationSource` enum and `LibrarySortOrder` type. A library filter maps to `ItemQuery { predicates: [HasParent(libraryId)] }`. A smart search maps to `ItemQuery { predicates: [Or([Contains("title", q), Contains("abstract", q)])] }`.

---

## Consequences

### What Becomes Easier

- **Cross-app data access.** Any app can query items created by another app without IPC, protocol negotiation, or format conversion. An impart message can reference a bibliography entry by ID and the reference is valid in both apps.

- **Shared infrastructure.** Tagging, flagging, read state, full-text search, and graph traversal are implemented once in `impress-core`. Apps do not reimplement them.

- **Provenance by design.** The operation log (`impress/operation` items) records every classification change with author, timestamp, and intent. Audit trails and undo are available without additional plumbing.

- **Agent output as items.** Agent-produced content (analysis results, draft text, recommendations) are `Item` values with `author_kind: Agent` and `produced_by: agentRunId`. They appear in the same store, are queryable with the same predicates, and are rendered by the same views as human-created content.

- **Schema evolution path.** The `SchemaRegistry` with inheritance allows adding specialized schemas (`preprint` extending `research-item`) without duplicating fields. New schemas appear to existing queries that filter by parent schema.

### What Becomes Harder

- **Migration cost.** Imbib's existing Core Data model must be migrated to `impress-core`. This is a one-time cost, but it is real. The migration must produce identical user-facing behavior, including all tag hierarchy logic, smart search behavior, and annotation display.

- **Schema design is now consequential.** Field naming choices in a schema affect all apps and all queries. A field named `"author_text"` in imbib's FTS extractor must match what impart's FTS extractor expects if cross-app search is to work. Schema versioning and evolution are not yet fully solved.

- **Debugging the operation layer.** Classification changes are now writes to the `items` table (materialized state) plus writes to the operations table (history). Debugging why an item's `is_read` is incorrect requires looking at both the materialized value and the operation history. The three-point trace pattern in CLAUDE.md addresses this.

- **Write amplification.** Every user action on a classification field (marking read, adding a tag) produces two writes: the materialized update and the operation item. This is acceptable at human interaction pace but would need review at high agent output rates.

- **SQLite contention under concurrent agents.** SQLite serializes writers. If multiple agent processes write to the shared store simultaneously, they queue. This is not a problem for current usage (one app at a time writes); it becomes a problem at agent scale. Deferred.

### What is Explicitly Deferred

- **Hot/warm/cold storage tiers.** Not needed at current scale. Revisit if imbib approaches 500,000+ items or if agent logging produces more than ~10,000 items per day.

- **High-throughput agent output channel (ring buffer).** The Darwin notification + poll model is adequate for Phase 1-2. Revisit when profiling shows notification latency is a bottleneck.

- **Collaboration and `canonical_id` semantics.** The field exists on `Item` but its semantics (shared namespace, conflict resolution) are not defined in this ADR.

- **Schema versioning and migration.** Items written under schema v1 must remain readable when the schema is at v3. The `version` string is stored but migration logic is not implemented. Must be solved before Phase 1 ships.

- **Plugin security for third-party schemas.** Not in scope.

- **The five cognitive views.** Library, Stream, Chronicle, Landscape, and Desk are defined in the design philosophy but their SwiftUI implementations are per-app work, not core library work.

---

## Open Questions

1. **Schema versioning.** How do items written under schema v1 behave when the registered schema is v2 and has added a required field? Options: (a) required fields are never added, only optional ones; (b) a migration closure is registered alongside the schema; (c) the store marks migrated items with a `schema_version` column and applies lazy migration on read. This must be decided before Phase 1 ships.

2. **FTS extractor registration.** Currently, `SqliteItemStore` calls a hardcoded FTS extraction path. There is no formal mechanism to register a schema-specific FTS extractor. When Phase 2 (impart) introduces `chat-message` items, how does the store know what text to index? Possible answer: each `Schema` carries an optional `FtsExtractorId` that the store looks up in a registered extractor map.

3. **Cross-app write coordination.** If imbib and impart both have the store open, SQLite serializes their writes. Is this acceptable? At what point does write queue depth become visible latency to the user? No profiling has been done.

4. **Tombstones and deletion semantics.** `SqliteItemStore` has an `init_tombstones` function visible in the source but not described here. What is the tombstone model? Are deleted items recoverable? Is deletion cascaded to operation items (losing provenance of the deleted item)?

5. **The `neighbors()` depth limit.** The current signature allows `depth: u32` but there is no enforced maximum. Deep traversal on a large graph will produce slow SQL. Should the store enforce a maximum depth (e.g., 5)? Should it return a partial result with a `truncated` flag?

6. **`ItemQuery` pagination and cursor stability.** `limit` and `offset` are supported but offset-based pagination is unstable if items are inserted between pages. For impart's message stream (append-only, high volume), cursor-based pagination (by `created` timestamp) would be more correct.

7. **The `subscribe()` method.** Currently returns `Receiver<ItemEvent>` but the `SqliteItemStore` implementation emits events only to the in-process channel, not across processes. The Darwin notification + poll model means that cross-process subscribers do not receive typed `ItemEvent` values; they receive an untyped "something changed" signal and must re-query. Should the `subscribe()` contract be clarified to reflect this?

8. **Operation items and the schema registry.** Operations are stored as items with schema `impress/operation`, but this schema is not registered in `SchemaRegistry` in the current codebase. Is it intended to be? If not, `registry.validate()` will reject operation items. If yes, the schema definition needs to be added to `schemas/`.

---

## References

- `crates/impress-core/src/item.rs` — `Item`, `Value`, `ActorKind`, `Priority`, `Visibility`, `FlagState`
- `crates/impress-core/src/reference.rs` — `TypedReference`, `EdgeType`
- `crates/impress-core/src/schema.rs` — `Schema`, `FieldDef`, `FieldType`, `SchemaRef`
- `crates/impress-core/src/registry.rs` — `SchemaRegistry`, validation logic
- `crates/impress-core/src/store.rs` — `ItemStore` trait, `FieldMutation`, `StoreError`
- `crates/impress-core/src/operation.rs` — `OperationType`, `OperationIntent`, `EffectiveState`, `undo_description`
- `crates/impress-core/src/query.rs` — `ItemQuery`, `Predicate`, `SortDescriptor`
- `crates/impress-core/src/sqlite_store.rs` — `SqliteItemStore`, SQL schema, WAL configuration
- `crates/impress-core/src/schemas/artifact.rs` — 8 registered artifact schemas
- `crates/impress-core/src/event.rs` — `ItemEvent` variants
- `CLAUDE.md` — startup render loop guardrails, UniFFI bridge pattern, three-point trace pattern
- `apps/imbib/CLAUDE.md` — imbib-specific migration and adapter details
- `docs/ADR-0002-operations-as-overlay-items.md` — operation item model (companion ADR)
- Rosenberg, S. (2007). *Dreaming in Code* — case study of the Chandler/OSAF failure mode
