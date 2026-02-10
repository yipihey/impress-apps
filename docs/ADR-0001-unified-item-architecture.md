# ADR-0001: Unified Item Architecture for the Impress Suite

**Status:** Proposed  
**Date:** 2026-02-08  
**Authors:** Tom (with architectural exploration via Claude)  
**Supersedes:** Individual app-level data model decisions  
**Scope:** impress-core library, imbib migration (Phase 1), impart from scratch (Phase 2)

---

## Context

The impress suite consists of six applications (imbib, imprint, implore, impel, implement, impart), each with its own data model and Rust core. This separation forces context switches that interrupt research flow — a researcher pursuing a single line of inquiry must move between apps that don't share data.

We identified during the design of impart (the communication layer) that chat messages, email, agent logs, bibliography entries, and manuscript annotations differ primarily in presentation, not substance. At the data level, they are all items with metadata, references, and typed payloads.

This ADR establishes the shared data model and core services that unify the suite. It covers only what is needed for Phases 0–2: the core library, imbib migration, and impart construction.

### Guiding Principles

1. **Reproducibility.** Complete provenance of every research product must be preserved, portable, and archivable.
2. **Open exchange.** All data exportable in standard formats (mbox for messages, open formats for all types). Users can always walk away with everything.
3. **View sovereignty.** The user chooses how to see information. The system provides views; users select and configure them.
4. **Agent scale.** The architecture must support hundreds of concurrent agents producing thousands of messages per second without degrading human experience.
5. **Extensibility without permission.** Other research groups can create domain-specific schemas and views without modifying the core.
6. **Collaboration as context sharing.** (Aspirational — not in scope for Phases 0–2, but the data model must not preclude it. See companion position paper for the full vision.)

### Guardrails Against Over-Abstraction

This architecture is at risk of the failure mode that killed Chandler (OSAF, 2002–2008) and OpenDoc (Apple, 1992–1997): generalizing a system out of existence. Chandler spent $8M and seven years building a "unified representation for tasks and information" and was still asking "who is this for?" at year seven. OpenDoc's document-centric component framework collapsed under its own weight — performance problems, developer confusion, no clear UX owner.

The common pattern: systems that try to be maximally general lose to systems that are opinionated about a specific use case. CORBA lost to REST. The Semantic Web lost to domain-specific formats. Xanadu lost to the Web (which implemented ~5% of its vision but shipped). Enterprise JavaBeans lost to Spring.

**Our concrete guardrails:**

1. **Write concrete types first, extract protocol second.** Do not define `Item` in the abstract and then derive `BibliographyEntry`. Write `BibliographyEntry` and `ChatMessage` in imbib and impart, see what they actually share, and extract only the genuinely shared structure into the protocol. The ADR below describes the target; the implementation path is bottom-up.

2. **Phase 1 is the proving ground.** If replicating imbib's current functionality on `impress-core` takes more than a few weeks, the architecture is too abstract. Imbib must work identically from the user's perspective after migration.

3. **Each abstraction justifies itself with two concrete, already-needed use cases.** Not hypothetical future uses. The schema registry is justified by bibliography entries and agent messages (both exist or are immediately needed). The view framework is justified by imbib's list view and impart's chat view.

4. **Phases 3–5 (impel, collaboration, impress mode) are aspirational.** They should not drive any current design decisions. If the architecture is right, they will emerge. If they have to be forced, the architecture was wrong.

5. **The question to keep asking:** What *specific operations* work across item types that wouldn't work without the unified protocol? If the answer is only "they're in the same database," the unification isn't earning its complexity.

---

## Decision

### 1. The Unified Item Protocol

All entities across the impress suite are represented as **items** conforming to a single protocol defined in a shared Rust core library (`impress-core`). There are no app-specific data models.

An item consists of:

```
Item {
    id: ItemId,                          // Globally unique (UUID), stable across sync
    canonical_id: Option<CanonicalId>,   // Shared identity in collaborative projects
    item_type: SchemaRef,                // Reference to a registered schema
    payload: TypedPayload,               // The domain-specific content
    
    // Universal metadata
    created: Timestamp,
    // Note: no `modified` field. Last modification time is derived from
    // the most recent operation item targeting this item (see ADR-0002).
    author: ActorId,                     // Human or agent
    author_kind: ActorKind,              // {Human, Agent, System}
    
    // Collaboration (initial values — changes tracked via operation items, see ADR-0002)
    visibility: Visibility,              // {Private, Shared(project), Public}
    origin: Origin,                      // Which instance created this item
    
    // Classification (initial values — effective state computed from operation items, see ADR-0002)
    tags: Vec<TagPath>,                  // Tags assigned at creation
    flags: FlagSet,                      // Flags set at creation
    priority: Priority,                  // Attention level at creation
    message_type: Option<MessageType>,   // For communication items: {Progress, Result,
                                         //   Anomaly, Question, Handoff, Discussion, 
                                         //   Lifecycle, ...}
    
    // Graph structure
    references: Vec<TypedReference>,     // Edges to other items
    parent: Option<ItemId>,              // Hierarchical containment (thread, section, etc.)
    
    // Provenance
    produced_by: Option<ItemId>,         // The agent run or process that created this
    version: VersionId,                  // For items that evolve (manuscripts, code)
}
```

#### Typed References

References are first-class, typed edges in an item graph:

```
TypedReference {
    target: ItemId,
    edge_type: EdgeType,     // {Cites, Discusses, ProducedBy, InResponseTo,
                              //  Visualizes, Implements, Refines, Escalates,
                              //  Attaches, Supersedes, Annotates, RelatesTo,
                              //  CanonicalOf, DerivedFrom, DependsOn, ...}
    metadata: Option<Map>,   // Edge-specific metadata (e.g., page number for a citation)
}
```

The item store is a **graph database** where edges are typed references. Navigation is by reference traversal, not by app boundary. "Show me everything related to this manuscript" is a graph neighborhood query, not an inter-app communication.

#### Schema System

Item types are defined by **schemas** — declarative descriptions of what fields a payload contains, what edge types are expected, and what view components can render it. Schemas are registered at runtime, not compiled into the core.

```
Schema {
    id: SchemaRef,
    name: String,                        // e.g., "bibliography-entry", "agent-log-step"
    version: SemVer,
    payload_fields: Vec<FieldDef>,       // Typed fields with names and constraints
    expected_edges: Vec<EdgeSpec>,        // What reference types are typical
    default_view_hints: ViewHints,       // Suggested rendering approach
    inherits: Option<SchemaRef>,         // Schema inheritance for specialization
}
```

#### What This Means for Existing Apps

| Current app | Items it primarily creates | Items it primarily renders |
|---|---|---|
| imbib | bibliography entries, reading notes, collection metadata | bibliography entries, recommendations |
| imprint | manuscript sections, annotations, drafts | manuscripts, review comments, agent suggestions |
| implore | figures, plots, data views | data artifacts, visualization configs |
| impel | agent run records, orchestration events | agent states, run histories |
| implement | code files, build artifacts, diffs | code, test results, agent code suggestions |
| impart | messages (human and agent), threads | messages, digests, escalations, all item types in context |

Every app reads and writes to the same item store. The "app" is determined by which schemas and view configurations are active, not by which data is accessible.

---

### 2. The Inter-App Communication Channel

Apps do not communicate with each other directly. They communicate by publishing items to and subscribing to items from the shared store.

#### Architecture

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  Swift UI    │  │  Swift UI    │  │  Swift UI    │
│  (imbib)     │  │  (impart)    │  │  (imprint)   │  ... etc.
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                  │
       └────────────┬────┴──────────────────┘
                    │
          ┌─────────▼──────────┐
          │   impress-core     │
          │   (Rust library)   │
          │                    │
          │  ┌──────────────┐  │
          │  │  Item Store   │  │  ← Unified graph database
          │  │  + Index      │  │
          │  └──────────────┘  │
          │  ┌──────────────┐  │
          │  │  Event Bus    │  │  ← Pub/sub for live updates
          │  └──────────────┘  │
          │  ┌──────────────┐  │
          │  │  Attention    │  │  ← Priority routing + notification
          │  │  Router       │  │
          │  └──────────────┘  │
          │  ┌──────────────┐  │
          │  │  Schema       │  │  ← Type registry
          │  │  Registry     │  │
          │  └──────────────┘  │
          └────────────────────┘
                    │
          ┌─────────▼──────────┐
          │   impel runtime    │  ← Agent processes write items
          │   (agent processes)│    via async append channel
          └────────────────────┘
```

#### Event Bus

When an item is created or modified, the event bus notifies all subscribers. Subscriptions are query-based:

- "Notify me of any item referencing manuscript X" (imprint watching for discussion)
- "Notify me of any item with tag `project-aurora/*` and priority ≥ Anomaly" (PI attention rule)
- "Notify me of any item of type `agent-handoff` targeting me" (human-in-the-loop)

This replaces all inter-app communication protocols (App Groups, XPC Services) with a single mechanism. Apps that appear to "talk to each other" are simply reacting to items that another app created.

#### Agent Channel

The impel runtime communicates with the item store through a **high-throughput async append channel**:

```
AgentMessage {
    item: Item,              // The full item to be stored
    delivery: DeliveryHint,  // {FireAndForget, ConfirmStored, AwaitHumanResponse}
}
```

- **FireAndForget**: Agent writes and continues. Used for progress logs, intermediate results. The vast majority of agent output.
- **ConfirmStored**: Agent waits only for durable write confirmation, not for any downstream processing. Used for important results.
- **AwaitHumanResponse**: Agent saves state and suspends. Impart routes the handoff to the appropriate human. When the human responds, impel resumes the agent. Used for decision points.

The channel itself is a lock-free ring buffer in shared memory (or memory-mapped file for cross-process). Impart and the indexer consume from this buffer asynchronously. Agents are **never** blocked on view rendering, notification routing, or human attention.

---

### 3. The View Framework

Views are the primary abstraction for user interaction. Everything the user sees — imbib's library browser, impart's chat stream, imprint's editor — is a view.

#### View Definition

A view is a declarative specification:

```
ViewTemplate {
    id: ViewId,
    name: String,                         // "Chat View", "Email View", "Lab Notebook"
    
    // What to show
    source_query: ItemQuery,              // Filter: which items appear
    grouping: GroupingRule,               // How items cluster (by thread, by time, 
                                          //  by tag, by schema type)
    sort: SortRule,                       // Ordering within groups
    
    // How to show it
    layout: LayoutSpec,                   // Arrangement of panels and renderers
    renderer_overrides: Map<SchemaRef, RendererRef>,  // Custom rendering per item type
    
    // Attention behavior
    attention_rules: Vec<AttentionRule>,  // What triggers notifications in this view
    collapse_rules: Vec<CollapseRule>,    // What gets auto-folded (e.g., agent progress)
    
    // Metadata
    domain: Option<String>,              // "astrophysics", "genomics", etc.
    shareable: bool,                     // Can this template be exported/shared
}
```

#### Built-in Renderers

- **MessageStreamRenderer** — chronological message display (chat-style)
- **ThreadedListRenderer** — grouped-by-thread display (email-style)
- **DigestRenderer** — collapsible summary with drill-down (agent log view)
- **RichTextRenderer** — manuscript/document display
- **DataVizRenderer** — figure and plot display
- **CodeRenderer** — syntax-highlighted code display
- **GraphNeighborhoodRenderer** — shows items related to a focus item
- **RecommendationRenderer** — surfaces connections via graph analysis, with transparency explanations
- **TreeBrowserRenderer** — hierarchical list (bibliography, file tree, tag tree)

#### Chat vs. Email Toggle (Impart Example)

| Property | Chat View | Email View |
|---|---|---|
| source_query | Items in channel X | Items in channel X |
| grouping | None (flat stream) | By thread (reference chain) |
| sort | Chronological | Thread-first, then chronological within |
| layout | Single stream + composer | Inbox list → thread detail |
| collapse_rules | None | Collapse quoted text in replies |
| attention_rules | All human messages notify | Only new threads and direct replies notify |

Same data. Different view templates.

#### Declarative vs. Compiled Views

View templates are expressed in a declarative format (TOML, YAML, or a custom DSL — to be decided). For rendering logic that cannot be expressed declaratively, the framework supports **view plugins** — Swift packages conforming to a `ViewRendererProtocol`.

The boundary: if it's about *which* items and *how to arrange* them, it's declarative. If it's about *how to draw* a specific item type, it may require a plugin.

---

### 4. The Attention Routing System

Attention routing is a **suite-wide service**, not an impart feature.

#### Attention Levels

```
enum AttentionLevel {
    Suppress,           // Not shown, not counted, available in archive
    Silent,             // Accumulates in view, no badge, no notification
    Badge,              // View/channel shows unread count
    Notify,             // System notification delivered
    Interrupt,          // Notification that overrides focus/DND settings
}
```

#### Routing Pipeline

```
Item created
    → Author kind filter (agent vs. human defaults)
    → Message type mapping (progress → Silent, anomaly → Notify, ...)
    → Tag hierarchy rules (inherit from project, override per-subtag)
    → User-specific overrides
    → Context-aware adjustment (if user is focused on related item, elevate)
    → Final AttentionLevel
    → Delivery to notification system
```

#### Defaults for Agent Messages

- Agents inherit attention rules from their **project tag path**
- Base defaults: `Progress → Suppress`, `Result → Silent`, `Anomaly → Badge`, `Question/Handoff → Notify`
- PI sets rules at project level: "For `project-aurora/mesh-refinement/*`, elevate Anomaly to Notify"
- Individual agents never need explicit configuration unless exceptional

#### Cross-App Attention

"Don't interrupt me unless an agent finds an anomaly OR a co-author comments on section 3 OR a tracked paper gets cited" — one query with OR clauses across all item types, not four app-specific configurations.

---

### 5. Storage Architecture

#### Design Constraints

- **Write throughput**: Thousands of items per second from concurrent agents
- **Read latency**: Sub-millisecond for live view updates
- **Corpus size**: Millions of items per project over months/years
- **Export**: mbox and other formats on demand, never synchronous with writes
- **Portability**: All data extractable in open formats at any time

#### Tiered Storage

```
┌──────────────────────────────────────────────────┐
│ HOT TIER: In-memory indexed store                │
│ Recent items (configurable window, e.g., 24h)    │
│ Backed by memory-mapped append log               │
│ Engine: TBD (LMDB, sled, or custom)              │
├──────────────────────────────────────────────────┤
│ WARM TIER: On-disk indexed store                 │
│ Full project history, queryable by metadata      │
│ Loaded on demand for historical views            │
├──────────────────────────────────────────────────┤
│ COLD TIER: Archived exports                      │
│ mbox segments, compressed, immutable             │
│ Suitable for iCloud backup, institutional archive│
└──────────────────────────────────────────────────┘
```

#### Mbox and Export

- The live store is an indexed graph database, not mbox.
- Mbox export is a **projection** from the live store, on demand or scheduled.
- Cold tier segments are immutable. Mbox carries full metadata in extended headers.

#### Storage Engine (Deferred)

Depends on benchmarking. Critical constraint: **abstracted behind a trait interface**.

```rust
trait ItemStore {
    fn append(&self, item: Item) -> Result<ItemId>;
    fn append_batch(&self, items: Vec<Item>) -> Result<Vec<ItemId>>;
    fn get(&self, id: ItemId) -> Result<Option<Item>>;
    fn query(&self, q: ItemQuery) -> Result<ItemIterator>;
    fn subscribe(&self, q: ItemQuery) -> Result<Subscription>;
    fn neighbors(&self, id: ItemId, edge_types: &[EdgeType], depth: u32) 
        -> Result<ItemGraph>;
}
```

---

## Roadmap

### Phase 0: Foundation

- [ ] Create `impress-core` Rust crate with `Item`, `TypedReference`, `Schema`, `ItemStore` trait
- [ ] Implement `TagPath` and `FlagSet`, generalizing from imbib's existing implementation
- [ ] Define `AgentMessage` channel interface and `DeliveryHint` types
- [ ] Define `ViewTemplate` structure and `ItemQuery` language
- [ ] Integration tests: million-message agent run, cross-type graph traversal, mbox round-trip

### Phase 1: Imbib Migration (Proving Ground)

- [ ] Map imbib's current data model onto the unified item protocol
- [ ] Migrate tag hierarchy and flagging into `impress-core` **as operation items per ADR-0002**
- [ ] Replace imbib's storage layer with `ItemStore` implementation (including `effective_state()` API per ADR-0002)
- [ ] Verify imbib functions identically from user's perspective
- [ ] **Milestone**: imbib's data queryable by other apps through shared store
- [ ] **Litmus test**: migration takes weeks, not months

### Phase 2: Impart from Scratch

- [ ] Build impart on `impress-core`
- [ ] Chat view and email view as two `ViewTemplate` configurations
- [ ] Agent append channel with ring buffer
- [ ] Attention routing as core service
- [ ] Digest/collapse renderer for agent output
- [ ] Mbox export as on-demand projection
- [ ] **Milestone**: 1000+ messages/sec from test agents without UI degradation

### Future (Aspirational — Not Driving Current Design)

- **Phase 3**: Impel integration (agent contract, suspension/resumption)
- **Phase 3.5**: Collaboration and graph coherence (see position paper)
- **Phase 4**: Imprint/implore migration
- **Phase 5**: Impress mode (see position paper)

---

## Consequences

### Positive

- Reproducibility by design: complete provenance in the item graph
- Data sovereignty: mbox and open format export at any time
- Agent scale: async channel and tiered storage handle high-volume workloads
- Reduced duplication: tagging, flagging, attention, storage implemented once
- Future optionality: data model does not preclude collaboration or impress mode

### Negative

- Upfront investment delays app-specific features
- Migration effort for imbib
- Abstraction risk: if the model is wrong, it's wrong everywhere
- Complexity exceeds six independent stores

### Mitigations

- Phase 1 is the proving ground — if it doesn't work cleanly, we stop and reassess
- `ItemStore` trait allows storage engine evolution
- Schema inheritance allows starting concrete and generalizing only when forced
- Guardrails section provides explicit over-abstraction detection criteria

---

## Open Questions (Phase 0–2 Scope)

1. **Storage engine**: LMDB vs. sled vs. SQLite vs. custom. Requires benchmarking.
2. **View template format**: TOML, YAML, or custom DSL.
3. **Query language**: `ItemQuery` needs a concrete syntax. Datalog worth evaluating.
4. **App Group vs. single process**: How apps share the store.
5. **Cold tier format**: mbox sufficient for all item types?
6. **Plugin security**: Sandboxing third-party view renderers.
7. **Device sync**: CloudKit, iCloud Drive, or custom. Relevant for Phase 1.
8. **Schema evolution**: Handling items written under v1 when schema is at v3. Must be solved before Phase 1 ships.

---

## References

- Imbib architecture and tag hierarchy implementation (existing codebase)
- Prior impress suite ADRs on CRDT collaboration, Typst compilation, and CloudKit sync
- Matrix protocol and matrix-rust-sdk (evaluated for impart federation)
- RFC 4155 — mbox format specification
- Rosenberg, S. (2007). *Dreaming in Code* — case study of the Chandler/OSAF failure mode
- Companion document: "Cognitive Architecture for Research Software" (position paper draft)
