# ADR-0002: Operations as Overlay Items and Data Model Foundations

**Status:** Proposed  
**Date:** 2026-02-09  
**Authors:** Tom (with architectural exploration via Claude)  
**Amends:** ADR-0001 (Unified Item Architecture), specifically the Item struct, ItemStore trait, and Phase 1 migration plan  
**Scope:** impress-core library, imbib migration (Phase 1)

---

## Context

ADR-0001 defines tags, flags, visibility, and priority as mutable fields on the item envelope. This means modifying any of these leaves no record of who made the change, when, or why — contradicting our own Guiding Principle 1 ("complete provenance") and undermining the measurement agenda.

In imbib today, tags and flags are mutable fields. The migration to impress-core is the moment to fix this. Retrofitting provenance later would require a second migration.

Beyond the provenance gap, we identified five additional areas where ADR-0001 leaves data model choices unspecified that would be painful to retrofit after migration. All six decisions touch every item and operation in the graph. This ADR records them together because they share the same forcing function: the imbib migration is the window to get the envelope right.

**Guiding principle for this ADR:** State the *what* and *why*. Leave the *how* to the implementer, who has the codebase.

---

## Decisions

### 1. Every Modification Is an Item

All changes to an existing item's classification, status, or content are recorded as separate **operation items** in the item graph. The target item's envelope is immutable after creation. Its effective state is a computed projection over the stream of operation items referencing it.

**Why now.** Mutable fields destroy provenance. "Who added this tag, when, and why?" must always be answerable. So must "what was this item's state on date X?" Event sourcing gives us this for free if we commit to it before the first item is written.

### 2. Operations Carry Intent

Every operation payload includes a structured `intent` field (a small enum: Routine, Hypothesis, Anomaly, Editorial, Correction, Escalation) and an optional free-text `reason`. Combined with the envelope's existing `priority` field, this gives two orthogonal filtering dimensions.

**Why now.** Operations are both provenance records and attention signals. If we omit intent, the attention router has only priority to work with — it cannot distinguish an urgent housekeeping task from an urgent anomaly. Adding intent to existing operations later means migrating every operation item.

**Why on the operation, not the target item.** The same item can be tagged by different actors for different reasons. A postdoc tags a paper as `to-cite` (Routine); an agent tags the same paper as `anomaly-relevant` (Anomaly). Intent belongs where the action is, not where the target is.

### 3. Two Mechanisms for Content Changes

**Patches** for incremental edits (typo fixes, field updates). The target item is not replaced; patches are applied in order to compute effective content.

**Supersedes** for substantial revisions (rewriting a review, new manuscript version). A new item replaces the old one via a `Supersedes` edge. Both remain in the graph.

**Rule of thumb:** If the change alters what the item *is*, use Supersedes. If it adjusts content without changing identity, use a patch.

### 4. Effective State Is a Computed Projection

An item's current tags, flags, visibility, priority, and content are computed by replaying all operations targeting it. The `tags`, `flags`, `visibility`, and `priority` fields on the item envelope become initial values at creation time only. The `modified` timestamp is removed — last modification is derived from the most recent operation.

The system must maintain materialized indices so that common queries ("all items tagged X") remain fast. Time-travel queries ("state as of last Tuesday") replay from the operation stream.

### 5. Causal Ordering

Operation replay depends on ordering. Wall-clock timestamps are unreliable across devices. For commutative operations (tag add/remove), order doesn't matter. For non-commutative operations (status transitions, visibility changes, content patches), incorrect ordering produces incorrect effective state.

**Decision.** Every item and operation carries a logical clock value in addition to its wall-clock timestamp. The logical clock establishes a causal partial order so that concurrent operations are explicitly identifiable and type-specific merge rules can be applied.

**Why now.** Adding a logical clock after migration means retroactively assigning synthetic values to every existing item, with no way to recover actual causal relationships.

### 6. Actor Identity Model

`ActorId` appears throughout ADR-0001 but is never defined. The identity model must distinguish at minimum:

- **Person or agent** — stable identity across devices and sessions.
- **Device or instance** — where something ran (already partially covered by `origin`).
- **Agent configuration** — for agents, what model/prompt/parameters were used. Referencing an agent-run item via `produced_by` is sufficient.

**Why now.** Every item carries an `ActorId`. Changing its semantics later means reinterpreting every existing attribution. The `attestation` field (cryptographic signature) is unimplementable without a defined identity.

### 7. Namespacing

Tags, schemas, and custom edge types are currently bare strings. When two groups collaborate and merge item graphs, bare strings collide silently (`to-review` means different things in different groups).

**Decision.** Tags, schemas, and custom edge types carry a namespace prefix. Core edge types (`Cites`, `DerivedFrom`, etc.) live in a reserved `core/` namespace.

**Why now.** Adding prefixes to every string in an existing graph is a full migration. Defining the convention before Phase 1 means every tag and schema written during imbib migration is already namespaced and will merge cleanly later.

### 8. Batch/Transaction Grouping

"Move this item from project A to project B" is a visibility change + tag removal + tag addition — three operations. Without grouping, the system cannot distinguish three unrelated actions from one logical action. This affects undo (undo the move, not one leg), attention routing (one notification, not three), and measurement (one action, not three).

**Decision.** Operations carry an optional `batch_id`. All operations in a single logical action share the same `batch_id`. Consumers (undo, routing, measurement) treat a batch as one event.

**Why now.** Adding `batch_id` later requires migrating every existing operation. The field is optional, so it costs nothing when not used.

### 9. Schemas as Items

ADR-0001 says schemas are "registered at runtime" but not where they live. If schemas are items in the graph, they get provenance (who defined it, when), version history (`Supersedes` edges), sync (collaborators receive schemas automatically), and the full operation model.

**Decision.** Schema definitions are items in the item graph. The schema registry is a materialized index over schema-definition items, not a separate subsystem.

**Why now.** If the registry is implemented as a flat lookup table or config file, migrating it into the item graph later means creating items for every existing schema and rewiring the registry. Doing it from the start means the type system is self-describing at no additional architectural cost.

### 10. Prospective Dependency Edges

All existing edge types are retrospective — they describe what happened. `DerivedFrom` says "B was made using A's output." But agent orchestration (impel) and build systems (implement) need prospective edges: "B cannot proceed until A completes."

**Decision.** Add `DependsOn` as a core edge type, distinct from `DerivedFrom`. `DependsOn` is a constraint: the source item's workflow is blocked until the target item reaches a specified state. After execution, the `DependsOn` edge remains as a record of the workflow constraint, and a `DerivedFrom` edge is added to record what actually happened. The prospective edge becomes retrospective provenance.

**Why now.** This is a core edge type, not a domain-specific one. It meets Guardrail 3: impel needs it for agent task ordering; implement needs it for build dependencies. If it's absent from the core set, both applications will invent incompatible workarounds. Adding a core edge type after the graph is populated is straightforward (new edges, no migration of existing ones), but the *absence* of the type means impel and implement design their orchestration without it and may bake in assumptions that are hard to unwind.

---

## Amendments to ADR-0001

- **Item envelope:** `tags`, `flags`, `visibility`, `priority` become initial values at creation; effective state is computed from operations. `modified` timestamp removed (derived from latest operation). Add: logical clock, batch_id (optional). Namespace prefixes on TagPath, SchemaRef, custom EdgeType.
- **Core edge types:** Add `DependsOn` (prospective workflow constraint) to the core set alongside `Cites`, `DerivedFrom`, `Supersedes`, etc.
- **ActorId:** Define identity model per Decision 6.
- **ItemStore trait:** Add methods for operation queries, effective state computation, and index lookups by effective tag/flag. The default API should return effective state, not raw envelopes.
- **Schema registry:** Implement as materialized index over schema-definition items.
- **Phase 1 migration:** Import imbib entries with current tags/flags as initial values. All subsequent changes produce operation items. Existing UI behavior preserved — the difference is internal.

---

## Consequences

### Positive

1. **Full provenance** for every modification, including sub-item changes.
2. **Time-travel** — replay operations to any timestamp for reproducibility and audit.
3. **Consistent event sourcing** — no mutable state, only computed projections. Simplifies sync, backup, replication.
4. **Measurement agenda enabled** — operation stream is the data source for human-AI collaboration metrics.
5. **Undo is free** — a new operation reverses a previous one; both are in the record.
6. **Operations are attention signals** — intent × priority gives the attention router structured filtering without a separate notification system.
7. **Correct offline ordering** — logical clocks prevent replay errors from clock skew.
8. **Collaboration-ready from day one** — namespacing and defined identity mean Phase 1 items merge cleanly later.
9. **Self-describing type system** — schemas as items get provenance, versioning, and sync automatically.
10. **Workflow orchestration in the graph** — `DependsOn` edges let impel and implement express task ordering using the same edge system as all other relationships, with the constraint becoming provenance after execution.

### Negative

1. **Index maintenance** — effective state requires materialized indices, more complex than reading a field.
2. **More items** — operations add ~1.5–3× item count over a project lifetime. Small items, but they consume index space.
3. **Developer conceptual overhead** — initial-value-on-envelope vs. effective-state-from-projection must be understood. The default API must return effective state.
4. **Upfront complexity** — Decisions 5–10 add envelope fields and edge types before they are exercised in Phase 1. Deliberate trade: small cost now vs. painful retrofits later.

### Risks

1. **High-frequency operations** — agent bulk operations need batching via `batch_id`.
2. **Complexity creep** — new operation schemas must meet ADR-0001 Guardrail 3 (two concrete use cases).
3. **Over-specification** — some fields may be wrong in detail. The commitment is to *existence* of the field, not specific implementation. Details are for the coding agent to decide based on the codebase.

---

## Open Questions

1. **Patch format.** Line-level diffs for text, key-value replacement for structured fields, or something else. Decide during imbib migration.

2. **Conflict resolution for non-commutative concurrent operations.** Logical clock identifies concurrency; merge policy per operation type needs design.

3. **Intent taxonomy evolution.** Open enum (extensible without schema bump) vs. closed (version bump to add values).

4. **Computed/derived item marking.** Digests and recommendations are ephemeral — stale when the algorithm improves. No current way to distinguish durable research products from materialized computations. Worth designing but does not block Phase 1.

5. **Namespace authority.** How namespaces are allocated for cross-institution collaboration. Format should reserve room for hierarchy (e.g., `edu.stanford.kipac.abel/`).

6. **UI for operation history.** How to present tag/flag/status history in imbib. View design question for Phase 1.

7. **Investigation contexts.** Research "branching" — parallel lines of inquiry that are later reconciled — is a real pattern. Unlike code branches (which merge into one state), research branches are reconciled by synthesis items that cite both sides. Whether this needs a first-class concept or is sufficiently expressed by namespaced tag scopes (e.g., `abel/investigations/dirichlet-bc/` vs. `abel/investigations/periodic-bc/`) needs design.

8. **Git integration for code artifacts.** Implement should use git for code versioning, not reinvent it. Commits, branches, and merges become items with provenance edges. The open question is the import boundary: which git events produce items (every commit? only merges and tags?), how authorship maps to `ActorId`, and whether the item graph should reference git objects by hash or maintain copies.

---

## Summary

| # | Decision | Why now |
|---|---|---|
| 1 | Every modification is an item | Mutable fields destroy provenance |
| 2 | Operations carry intent | Attention routing needs structured signals |
| 3 | Patches vs. Supersedes | Two change scopes, two mechanisms |
| 4 | Effective state is computed | Immutable envelopes, consistent event sourcing |
| 5 | Causal ordering (logical clock) | Can't recover causal order retroactively |
| 6 | Actor identity model | Attribution and attestation require it |
| 7 | Namespacing | String collisions during graph merge |
| 8 | Batch grouping | Multi-op actions need atomic identity |
| 9 | Schemas as items | Type system should be self-describing |
| 10 | Prospective dependency edges | Orchestration needs constraints, not just provenance |

---

## References

- ADR-0001: Unified Item Architecture for the Impress Suite
- Position paper: Cognitive Architecture for Research Software, Sec 2.2
- Young, G. (2010). "CQRS Documents"
- Kleppmann, M. (2017). *Designing Data-Intensive Applications*, Ch. 11
