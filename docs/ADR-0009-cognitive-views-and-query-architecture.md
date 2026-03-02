# ADR-0009: Cognitive Views and Query Architecture

**Status:** Proposed
**Date:** 2026-03-02
**Authors:** Tom Abel (with architectural exploration via Claude)
**Supersedes:** Position paper sections 2 (view framework portions) and 5 (collaboration and context-sharing view concepts)
**Scope:** impress-core query library, all impress app UI layers

---

## Context

ADR-0001 introduced a declarative `ViewTemplate` type — a TOML/YAML/DSL structure specifying `source_query`, `grouping`, `sort`, `layout`, `renderer_overrides`, and `attention_rules`. It also listed an attention router as a core service inside `impress-core`, alongside the item store and event bus.

Practical implementation has surfaced two problems with that design:

**Problem 1: Declarative view templates cannot express the cognitive variation they need to express.** The five mental modes researchers operate in — scanning inventory, tracking activity, reconstructing provenance, discovering gaps, and building toward a goal — differ not only in which items they surface but in how those items are grouped, the semantic glue between rows, and how selection triggers cross-item actions. A TOML template can describe a filter and a sort order. It cannot express "when the user selects a bibliography entry, show the Chronicle of operations touching it alongside the Desk items referencing it." That logic is navigation code.

**Problem 2: A centralized attention router in impress-core is the wrong abstraction boundary.** The router needs to know what the user is currently looking at — what view is active, what item is selected, what has been visible long enough to count as read. That is UI state. A Rust core library has no access to UI state and should not. Routing attention is middleware, not a data primitive. Embedding it in the core would either require the core to model UI state (wrong) or reduce the router to a pure priority-filter (insufficient).

This ADR retires the declarative `ViewTemplate` type and the attention router as a core service, and replaces them with two concrete decisions:

1. The five cognitive views are implemented as concrete SwiftUI code, not as instances of a template engine.
2. The attention router lives as middleware inside each app, not as a service inside `impress-core`.

The `ItemQuery` Rust type and its SQL compilation layer (`compile_query`) remain unchanged — they are the right abstraction for expressing *what* to fetch. What changes is *how* views and routing are expressed.

---

## Decision

### D32. The Five Cognitive Views Are Concrete SwiftUI Code

Each cognitive view is a named SwiftUI screen (or screen configuration) specific to each impress app. There is no view template engine and no view registry. Apps do not instantiate views from declarative descriptions.

The five views, their cognitive function, and their implementation phase:

| View | Cognitive question | Phase |
|---|---|---|
| Library | "What do I have?" | 1 (SQL) |
| Stream | "What's happening?" | 2 (SQL) |
| Chronicle | "What happened and why?" | 2 (SQL on operation items) |
| Desk | "What am I building?" | 3 (user-curated SQL) |
| Landscape | "What am I missing?" | 4 (vector embeddings) |

**Why not declarative templates.** The position paper described views as "declarative specifications" with a `ViewTemplate` struct. This was aspirational. After designing the actual interactions, the views' logic involves:

- Selection state propagating across panes (selecting a Library entry loads its Chronicle)
- Keyboard navigation that differs per view (j/k in Library navigates items; in Landscape it navigates similarity clusters)
- Toolbar actions whose availability depends on multi-view context (pin-to-Desk requires a Desk to exist)
- Per-view loading strategies (Library is paginated; Stream is live-updating; Landscape is async)

A template engine powerful enough to express all of this would be a programming language. SwiftUI is the programming language we already have. The views share behavior through protocols, shared components, and the `ItemQuery` layer — not through a common runtime interpretation of a template format.

**What this does not change.** The item store's query API (`ItemQuery`, `Predicate`, `SortDescriptor`) is still the interface between the UI layer and `impress-core`. Each view constructs one or more `ItemQuery` values, executes them against the store, and renders the results. The query layer is where the UI/core boundary sits.

---

### D33. Implementation Phases for Each View

#### Library — Phase 1

The Library is the entry point for a session with an impress app. It answers "what do I have?" by presenting all items of the app's primary schema, browsable and filterable.

This view is Phase 1 because it is the minimum viable surface: without it, no impress app is usable.

**Base query (all bibliography entries, creation-recency order):**

```sql
SELECT * FROM items
WHERE schema_ref LIKE 'bibliography-entry%'
  AND NOT is_deleted
ORDER BY created DESC
```

Expressed as an `ItemQuery`:

```rust
ItemQuery {
    schema: Some("bibliography-entry".into()),
    predicates: vec![],
    sort: vec![SortDescriptor { field: "created".into(), ascending: false }],
    limit: Some(200),
    offset: None,
}
```

**FTS5 search (when the user has typed a query):**

```sql
SELECT items.* FROM items
JOIN items_fts ON items.id = items_fts.rowid
WHERE items_fts MATCH ?
  AND schema_ref LIKE 'bibliography-entry%'
  AND NOT is_deleted
ORDER BY rank
```

The `compile_query` function in `impress-core/src/sql_query.rs` handles the FTS path automatically when a `Predicate::Contains` is applied to a known FTS field (`title`, `author_text`, `abstract_text`, `note`). The field-to-FTS routing is encoded in `is_fts_field()`:

```rust
fn is_fts_field(field: &str) -> bool {
    matches!(
        field,
        "title" | "author_text" | "abstract_text" | "note" | "payload.title"
            | "payload.author_text"
            | "payload.abstract_text"
            | "payload.note"
    )
}
```

When a match is on an FTS field, the compiled predicate is:

```
id IN (SELECT item_id FROM items_fts WHERE items_fts MATCH ?)
```

**Library filtering (sidebar selection, smart searches):**

Tag-scoped: `Predicate::HasTag("project-aurora")` compiles to:

```sql
id IN (SELECT item_id FROM item_tags WHERE tag_path = ? OR tag_path LIKE ? || '%')
```

Flagged: `Predicate::HasFlag(Some("red"))` compiles to `flag_color = ?`.

Starred: `Predicate::IsStarred(true)` compiles to `is_starred = 1`.

Unread: `Predicate::IsRead(false)` compiles to `is_read = 0`.

Library is the only view that requires pagination. Initial load targets 200 rows; subsequent pages are fetched via `offset`.

---

#### Stream — Phase 2

The Stream answers "what's happening?" by presenting items across all schemas within a project context, ordered by recency. It is the unified activity feed — everything that has been created or modified recently, regardless of type.

**Base query (all items in a project, recency order, bounded):**

```sql
SELECT * FROM items
WHERE id IN (
  SELECT item_id FROM item_tags
  WHERE tag_path LIKE 'project/aurora/%'
)
AND NOT is_deleted
ORDER BY modified DESC
LIMIT 200
```

Expressed as an `ItemQuery`:

```rust
ItemQuery {
    schema: None,  // all schemas
    predicates: vec![
        Predicate::HasTag("project/aurora".into()),
    ],
    sort: vec![SortDescriptor { field: "modified".into(), ascending: false }],
    limit: Some(200),
    offset: None,
}
```

The `HasTag` predicate uses prefix matching: items tagged `project/aurora/amr-convergence` also match the `project/aurora` predicate. This is the intended behavior — the project namespace acts as a scope.

Stream is a live-updating view. When the item store fires a change notification (`storeDidMutate`), the Stream reloads with the same query. The `modified DESC LIMIT 200` bound keeps latency constant regardless of total item count.

Stream differs from Library in schema scope (all vs. primary schema) and sort key (modified vs. created). Everything else — FTS search, tag/flag/star filtering — uses the same predicate system.

---

#### Chronicle — Phase 2

The Chronicle answers "what happened and why?" by presenting the provenance audit trail for a target item. It is the time-ordered sequence of operation items that have modified a given item's state — tag assignments, flag toggles, visibility changes, patch edits, and status transitions, each with its author, timestamp, intent, and reason.

Chronicle requires operation items as specified in ADR-0002. It is a Phase 2 view because it depends on the operation item infrastructure that imbib migration (Phase 1) establishes.

**Query for all operations on a target item, causal order:**

```sql
SELECT op.*, target.*
FROM items op
JOIN items target ON op.payload->>'$.target_id' = target.id
WHERE op.schema_ref LIKE 'operation%'
  AND NOT op.is_deleted
ORDER BY op.logical_clock DESC
```

Expressed as an `ItemQuery` for the operations themselves:

```rust
ItemQuery {
    schema: Some("operation".into()),  // matches 'operation%' via LIKE
    predicates: vec![
        Predicate::HasReference(EdgeType::Annotates, target_item_id),
    ],
    sort: vec![SortDescriptor { field: "logical_clock".into(), ascending: false }],
    limit: None,
    offset: None,
}
```

The `HasReference` predicate compiles to:

```sql
id IN (
  SELECT source_id FROM item_references
  WHERE target_id = ? AND edge_type = ?
)
```

Chronicle can also be rendered without a target item — showing all operations on all items in a time window. This is the project-level audit view:

```rust
ItemQuery {
    schema: Some("operation".into()),
    predicates: vec![
        Predicate::HasTag("project/aurora".into()),
        Predicate::Gte("logical_clock".into(), Value::Int(checkpoint_clock)),
    ],
    sort: vec![SortDescriptor { field: "logical_clock".into(), ascending: false }],
    limit: Some(500),
    offset: None,
}
```

The dual use — item-scoped and project-scoped — is expressed through the same `ItemQuery` mechanism. No special API is required.

---

#### Desk — Phase 3

The Desk answers "what am I building?" by presenting a user-curated collection of items assembled around a current research focus. Unlike Library (entire corpus) and Stream (recent activity), Desk is small and intentional — the researcher puts things on the Desk explicitly.

A Desk is itself an item in the graph. Items on the Desk are linked to it via typed edges (`Contains`, `Discusses`, `Annotates`). The Desk query fetches the targets of those edges.

**Query for items on a specific Desk:**

```sql
SELECT items.* FROM items
JOIN item_references ON items.id = item_references.target_id
WHERE item_references.source_id = ?   -- the Desk item's ID
  AND item_references.edge_type IN ('Contains', 'Discusses', 'Annotates')
  AND NOT items.is_deleted
```

Expressed as an `ItemQuery`:

```rust
ItemQuery {
    schema: None,
    predicates: vec![
        Predicate::ReferencedBy(EdgeType::Contains, desk_item_id),
        // OR Discusses, OR Annotates — the view layer assembles a union
    ],
    sort: vec![SortDescriptor { field: "modified".into(), ascending: false }],
    limit: None,
    offset: None,
}
```

Because `ItemQuery` does not currently express OR at the predicate-result-set level across different `ReferencedBy` edges, the Phase 3 implementation may either:

1. Run three queries (one per edge type) and union the results in Swift, or
2. Extend `Predicate` with a `ReferencedByAny(Vec<EdgeType>, ItemId)` variant.

The preferred approach is (2) if the union pattern recurs in multiple views; (1) if it is unique to Desk. This is an open question for Phase 3.

Desk is Phase 3 because it depends on the user having enough content in the store to warrant a curated collection, and because the Desk management UI (drag-to-add, edge-type labeling) is non-trivial.

---

#### Landscape — Phase 4

The Landscape answers "what am I missing?" by surfacing items that are semantically related to the user's current focus but not explicitly linked. It is the discovery view — finding papers never encountered, connections never made, parallel work never seen.

**Landscape is not implementable with SQL alone.** It requires:

1. An embedding pipeline: item text (title + abstract + notes) extracted and passed to an embedding model (local, e.g., a CoreML model, or remote)
2. An approximate nearest-neighbor (ANN) index: usearch or faiss, stored as a separate file alongside the SQLite database
3. A query path: the current focus item's embedding is fetched, ANN search returns candidate item IDs, those IDs are retrieved from the item store via standard `ItemQuery`

The SQL query is the final retrieval step only:

```sql
SELECT * FROM items
WHERE id IN (?, ?, ?, ...) -- ANN-returned candidate IDs
  AND NOT is_deleted
```

This is expressed as `Predicate::In("id", candidate_ids)` after the ANN search has already run.

**Landscape is deferred to Phase 4.** There is no SQL-only approximation worth building. Keyword search (FTS5) is already in Library. An ANN index without good embeddings produces poor results. The right time to implement Landscape is after:

- The embedding pipeline is established (likely shared infrastructure with impel's agent context)
- Enough items exist in the store to make similarity search meaningful (hundreds to thousands of items)
- The ANN index storage strategy is decided (file location, format, rebuild frequency)

**Do not propose SQL approximations for Landscape.** The cognitive value of Landscape is semantic relatedness, not keyword overlap. A LIKE-based approximation would be misleading — it would surface items containing shared words, not items exploring shared ideas. Better to have no Landscape view than a mislabeled Library search.

---

### D34. The `ItemQuery` Type Is the View-Core Boundary

The `ItemQuery` struct in `impress-core/src/query.rs` is the complete interface between the UI layer and the item store for all five views:

```rust
pub struct ItemQuery {
    pub schema: Option<SchemaRef>,
    pub predicates: Vec<Predicate>,
    pub sort: Vec<SortDescriptor>,
    pub limit: Option<usize>,
    pub offset: Option<usize>,
}
```

Every view constructs one or more `ItemQuery` values. The `compile_query` function in `impress-core/src/sql_query.rs` translates them into `CompiledQuery` structs containing parameterized SQL fragments:

```rust
pub(crate) struct CompiledQuery {
    pub where_clause: String,
    pub params: Vec<SqlValue>,
    pub order_clause: String,
    pub limit_offset: String,
}
```

The full predicate set covers everything the five views need for Phases 1–3:

| Predicate | Compiled SQL | Used by |
|---|---|---|
| `Contains(fts_field, text)` | `id IN (SELECT item_id FROM items_fts WHERE items_fts MATCH ?)` | Library search, Stream search |
| `Contains(other_field, text)` | `{col} LIKE ? ESCAPE '\'` | Payload field substring match |
| `HasTag(path)` | `id IN (SELECT item_id FROM item_tags WHERE tag_path = ? OR tag_path LIKE ? || '%')` | Library sidebar, Stream scoping |
| `HasFlag(Some(color))` | `flag_color = ?` | Library flagged view |
| `HasFlag(None)` | `flag_color IS NOT NULL` | Library any-flag view |
| `IsRead(bool)` | `is_read = {0\|1}` | Library unread filter |
| `IsStarred(bool)` | `is_starred = {0\|1}` | Library starred view |
| `HasParent(id)` | `parent_id = ?` | Thread/section hierarchy |
| `HasReference(edge, target)` | `id IN (SELECT source_id FROM item_references WHERE target_id = ? AND edge_type = ?)` | Chronicle (operations on item) |
| `ReferencedBy(edge, source)` | `id IN (SELECT target_id FROM item_references WHERE source_id = ? AND edge_type = ?)` | Desk (items pinned to desk) |
| `And`, `Or`, `Not` | Nested SQL with `AND`, `OR`, `NOT (...)` | Smart searches, compound filters |
| `Eq`, `Neq`, `Gt`, `Lt`, `Gte`, `Lte` | Direct column comparisons | Payload field filters, clock range for Chronicle |
| `In(field, values)` | `{col} IN (?, ?, ...)` | Landscape final retrieval (ANN candidate IDs) |

Payload field access (`payload.doi`, `payload.year`, etc.) is compiled to `json_extract(payload, '$.doi')` with path sanitization to prevent injection. The sanitizer in `sanitized_json_extract` allows only alphanumeric, `.`, `_`, `-`, `$`, `[`, `]` in JSON paths — anything else is compiled to `NULL`.

---

### D35. Attention Routing Is App-Level Middleware, Not a Core Service

ADR-0001 described an attention router as a core service inside `impress-core`, sitting between the event bus and the notification system. This is retired.

**Why the core is the wrong location.**

The attention router as described in ADR-0001 requires:

- Knowledge of which view the user is currently in (UI state)
- Knowledge of which item is selected (UI state)
- Knowledge of what the user has looked at long enough to count as "read" (UI state + time)
- Delivery of notifications via the operating system notification center (platform API)

`impress-core` is a Rust library. It has no access to SwiftUI state, no access to AppKit, and no path to the system notification center. Placing the router there would require either:

- Exporting all UI state to the Rust layer via FFI (enormous complexity, wrong direction), or
- Reducing the router to a stateless priority filter that ignores what the user is currently doing (insufficient — a user reading the Chronicle of an item should not receive a Badge notification for a new operation on that same item)

**Where attention routing lives.**

Each app implements attention routing as a Swift actor or ObservableObject that sits between the item store's change notifications (`storeDidMutate`) and the app's notification delivery. It has access to:

- The item store (via `RustStoreAdapter` or equivalent) for querying item metadata
- The current view state (which sidebar node is selected, which item is open in the detail pane)
- The app's user preferences for notification thresholds
- The system notification APIs

The router subscribes to item store change notifications, consults the current view state, applies the user's priority rules, and decides what to deliver, suppress, or batch. This is middleware — it wires together the store and the UI — and belongs with the other wiring code in the Swift app layer.

**What `impress-core` provides.**

The core provides the data that attention routing needs to make decisions:

- `item.priority` — the initial priority level assigned at creation
- `item.author_kind` — Human, Agent, or System
- Operation items carry `intent` (Routine, Hypothesis, Anomaly, Editorial, Correction, Escalation) in their payload
- `message_type` on communication items
- Tag paths that encode project membership and topic scope

The router reads these fields via `ItemQuery` (the same query mechanism views use) and applies the app's routing rules. The routing logic is in Swift. The data it reasons about is in the Rust store.

**Per-app responsibility.**

Each impress app owns its attention routing implementation. This means:

- imbib routes bibliography-domain signals (new recommendation matching a flagged topic, SciX sync completion with new papers)
- impart routes communication signals (new message in a subscribed thread, agent handoff requiring human response)
- impel routes agent orchestration signals (task completion, anomaly escalation, AwaitHumanResponse pause)

These have different defaults, different urgency thresholds, and different delivery mechanisms. A single core router would require parameterizing all of this — at which point it is not a service but a library of helpers, which is a fine thing to put in `ImpressKit` (the shared Swift package) if duplication becomes a problem across apps.

**ImpressKit role.**

If attention routing logic is substantially shared across apps, the common parts (priority escalation rules, batching of agent notifications, standard read-status update triggers) can be extracted into `packages/ImpressKit/` as a Swift package. The `ImpressKit` package already contains cross-app infrastructure (`SiblingBridge`, `ImpressNotification`, `SharedDefaults`). An `AttentionRouter` protocol with default implementations would fit there if warranted. This is not required for Phase 1 or Phase 2.

---

## Consequences

### Positive

1. **Views are debuggable.** A SwiftUI view is a Swift function. It can be stepped through in Xcode, logged, and instrumented. A declarative template interpreted at runtime would require a custom debugger.

2. **Views can express complex interactions.** Selection propagation across panes, keyboard shortcut handling, toolbar state, cross-view drag-and-drop — all of this is natural in SwiftUI and unnatural in a template format.

3. **Query layer is decoupled and testable.** `ItemQuery` and `compile_query` have 20+ unit tests in `sql_query.rs`. They are pure functions with no UI dependencies. Views can be tested independently by asserting on the queries they construct.

4. **Phase gating is explicit.** The phase assignments (Library: 1, Stream/Chronicle: 2, Desk: 3, Landscape: 4) replace the aspirational "to be decided" status of the position paper's view framework with binding implementation commitments.

5. **Attention routing has access to the full UI context.** The middleware pattern allows the router to know what the user is currently looking at — preventing spurious notifications when the user is already viewing the relevant item.

6. **No runtime template engine to maintain.** Every custom DSL is a maintenance liability. SwiftUI is maintained by Apple.

### Negative

1. **Views are not user-configurable.** ADR-0001's `ViewTemplate` included a `shareable` flag and the implication that users could define custom views. Concrete SwiftUI code cannot be authored by users. If user-configurable views are a requirement (not currently established), this decision must be revisited.

2. **Views are harder to port.** If impress ever ships an iPadOS or iOS version, the SwiftUI code ports more easily than a template format would — but it still requires per-platform UI adjustments. The query layer (`ItemQuery`) is fully portable.

3. **Attention routing duplication across apps.** Five apps each implementing their own router is more code than one shared router. Mitigated by the `ImpressKit` escape hatch if duplication becomes a problem.

4. **Landscape deferred to Phase 4 creates a gap.** Researchers may ask for semantic discovery sooner. There is no acceptable SQL-only substitute. The gap must be managed by setting expectations, not by shipping a weaker approximation under the Landscape name.

### What This Retires

- The `ViewTemplate` struct from ADR-0001 (Section 3, "The View Framework") is retired. The struct definition and the concept of a runtime view template engine are removed from the design.
- The attention router as a named service inside `impress-core` is retired. The routing pipeline diagram in ADR-0001 (Section 4) describes the right routing logic but the wrong location for it.
- The position paper's description of "a declarative attention router in impress-core" (Section 9 of the position paper) is superseded by this ADR.

---

## Open Questions

1. **`ReferencedByAny` predicate.** Desk Phase 3 may need to union items linked by multiple edge types (`Contains`, `Discusses`, `Annotates`). Should `Predicate` gain a `ReferencedByAny(Vec<EdgeType>, ItemId)` variant, or should Phase 3 union three queries in Swift? Decide during Phase 3 design.

2. **Stream live-update strategy.** `modified DESC LIMIT 200` keeps the query constant, but the update trigger needs a debounce — if an agent is writing 100 items per second, the Stream should not attempt 100 reloads per second. The debounce threshold (suggested: 500ms) and the mechanism (Combine, AsyncStream, or `Task.sleep` with cancellation) are implementation decisions for Phase 2. Do not use `try? Task.sleep` in a loop — see CLAUDE.md on startup render loop bugs.

3. **Landscape embedding model selection.** Phase 4 requires an embedding model that runs on-device (for offline capability and privacy) or via an opt-in remote service. CoreML with a sentence-transformer model is the likely on-device approach. This decision will affect the embedding pipeline, index format, and rebuild frequency. Not in scope before Phase 3 is complete.

4. **Chronicle view for non-operation items.** The Chronicle query targets operation items referencing a specific target. But some provenance is expressed via typed edges on non-operation items (e.g., a `Supersedes` edge from a new item to an old one, a `DerivedFrom` edge from a figure to its source data). Should Chronicle also show non-operation items in the target's edge neighborhood? Decide during Phase 2 design.

5. **Desk vs. Library disambiguation for the user.** A researcher with a Desk configured around a topic may have difficulty distinguishing it from a Library filtered to the same tag. The UX distinction — Desk is curated by explicit action, Library is filtered by automatic classification — must be communicated clearly. View naming and onboarding copy are out of scope for this ADR but must be resolved before Desk ships (Phase 3).

6. **Multi-Desk support.** Can a researcher have multiple Desks (one per active project)? The data model supports it (each Desk is an item; items link to their Desk). The UI implication — sidebar entries per Desk, switching between them — needs design. Not needed for Phase 3 MVP but should not be precluded by the initial implementation.

---

## References

- ADR-0001: Unified Item Architecture for the Impress Suite (view framework concept, now amended)
- ADR-0002: Operations as Overlay Items (operation items used by Chronicle view)
- Position paper: Cognitive Architecture for Research Software, Sections 2 and 5 (superseded by this ADR)
- `impress-core/src/query.rs` — `ItemQuery`, `Predicate`, `SortDescriptor` definitions
- `impress-core/src/sql_query.rs` — `compile_query`, `compile_predicate`, `is_fts_field`, `sanitized_json_extract`
- CLAUDE.md — startup render loop bugs (relevant to Stream live-update strategy)
