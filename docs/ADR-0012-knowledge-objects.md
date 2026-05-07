# ADR-0012: Knowledge Objects and Episodic Memory

**Status:** Proposed
**Date:** 2026-05-05
**Authors:** Tom (with architectural exploration via Claude)
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0003 (Operations and Provenance), ADR-0004 (Schema Registry and Type System), ADR-0005 (Task Infrastructure and Agent Integration), ADR-0006 (Retention Tiers and Compaction)
**Scope:** `crates/impress-core/src/schemas/` — adds two new schema modules; downstream consumers (the journal pipeline of ADR-0011, future review-based pipelines)

---

## Context

ADR-0001 introduces the unified item; ADR-0003 makes every meaningful change a provenance-bearing operation; ADR-0004 gives schemas their registration mechanism. Together these three ADRs cover *facts* — bibliographic entries, manuscript sections, figures, datasets — and *changes to facts*. They do not cover **knowledge produced by an actor about a fact**: a review of a manuscript draft, a structured note explaining why a revision was rejected, an agent's recollection of how it handled a similar artifact last week.

These items are not facts about external reality. They are first-person artifacts authored by humans or agents. They share a structural pattern that distinguishes them from regular items:

- They have a **subject** (the item the knowledge is about).
- They have an **author** stance (a position, a verdict, a recollection — not just an assertion).
- They are **evidentiary**: they cite or reference the inputs that produced them.
- They are **superseded over time**: a follow-up review supersedes the prior one rather than amending it.
- They have **agent-readable structure** so future agent invocations can consult them as episodic memory.

The journal pipeline (ADR-0011) needs two such items immediately: `review/v1` for Counsel's structured critique of a manuscript draft, and `revision-note/v1` for the explanation an Artificer or human attaches to a proposed revision. Neither fits cleanly into existing schemas. Treating them as bare `chat-message@1.0.0` items loses the structural commitments above; treating them as `annotation@1.0.0` items is wrong because they are not anchored to a text range — they are about an entire revision.

Beyond the immediate schemas, this ADR establishes the **knowledge-object** abstraction so that future schemas of the same shape (referee response, decision memo, post-mortem) can be added without re-litigating the design. The abstraction is also the substrate for **episodic memory**: an agent's retrieval of "what reviews did I produce on similar manuscripts in the past?" is a query over knowledge-object items targeting the same schema, optionally filtered by `agent_id`.

### Why now

The journal pipeline is the forcing function. Without `review/v1` and `revision-note/v1` defined, ADR-0011 D7 (persona-action contracts) has no structured-output target for Counsel and Artificer. With them defined ad hoc inside ADR-0011, the abstraction is invisible — a future ADR adding a "post-mortem" knowledge object would have nothing to inherit from and would re-invent the same shape.

ADR-0004 D19 deferred "schemas as items" to Phase 4. This ADR does *not* reopen that deferral. Knowledge objects are themselves regular items registered through the existing Rust-code-driven registry. The "knowledge object" label is a category in the documentation and a convention in field naming; it is not a runtime type or a registry concern.

---

## Decision

### D38. Knowledge Objects Are a Documented Category, Not a Runtime Type

A **knowledge object** is any item whose schema follows the conventions of D39 below. There is no `KnowledgeObject` trait in Rust, no `is_knowledge_object()` method on `Item`, and no special handling in `SchemaRegistry`. The category is a documentation convention that lets schema authors share design intent and consumers (UI, agent retrieval) recognize the pattern.

**Why not a runtime type.** Per ADR-0001's guardrails (specifically Guardrail 1: write concrete types first, extract protocol second), introducing a runtime category before three knowledge-object schemas exist would generalize prematurely. With two schemas in this ADR (`review/v1` and `revision-note/v1`), we are below the bar. Future ADRs may promote the category to a runtime type if a third schema makes the abstraction load-bearing.

**The convention applies to schema design**, not to item representation. A knowledge object is an `Item` like any other — same envelope, same operations, same FTS handling.

### D39. The Knowledge-Object Field Convention

A schema is a knowledge object if it follows these rules:

1. **It has a `subject_ref` field** (StringArray or String, required) that identifies the item the knowledge is about. The field stores `ItemId` strings; the corresponding `RelatesTo` or `Annotates` edge is added to the item's reference graph alongside the field.

   *Why both a field and an edge?* The edge is the queryable graph structure; the field is the schema-validated commitment. Future schema versions may tighten the field's type (e.g., constrain to a specific subject schema) without breaking edge traversal.

2. **It has a `verdict` or `stance` field** (String, optional, free vocabulary) that summarizes the author's position. Examples: `"approve"`, `"approve-with-changes"`, `"request-revision"`, `"reject"` for reviews; `"propose"`, `"accept"`, `"reject"`, `"defer"` for revision notes. The vocabulary is per-schema; the field name `verdict` is reserved for this purpose.

3. **It has an `evidence_refs` field** (StringArray, optional) that lists the items consulted to produce the knowledge. For a review, this is the manuscript revision plus any cited prior reviews or referee guidance; for a revision note, this is the source review plus the manuscript section being revised.

   *Evidence is for reproducibility*, not for citation. A reader of the knowledge object can re-invoke the same agent with the same evidence and a hash-comparable prompt to check for drift.

4. **It carries `agent_id` and `agent_run_ref` fields** (both optional) when authored by an agent. `agent_id` is the persona ID per ADR-0013 D29 (`"counsel"`, `"artificer"`, etc.). `agent_run_ref` points to the `agent-run@1.0.0` item (per ADR-0005 D5) that produced this knowledge object.

   For human-authored knowledge objects, both fields are absent.

5. **Replacement is via `Supersedes` edge**, not in-place edit. A second pass of Counsel reviewing the same revision creates a new `review/v1` item with a `Supersedes` edge to the prior review. The prior review remains in the graph for audit and time-travel.

6. **The schema's FTS fields include the prose body** (e.g., `body`, `notes`, `summary`) but not the structured verdict or refs fields. This makes knowledge objects discoverable by content search while keeping the verdict-driven UI fast (it queries the materialized columns or the structured payload directly).

### D40. The `review/v1` Schema

```
review@1.0.0:
  Required:
    subject_ref:   String        — ItemId of the manuscript-revision being reviewed
    verdict:       String        — "approve" | "approve-with-changes" | "request-revision" | "reject"
    body:          String        — The reviewer's prose critique (markdown)

  Optional:
    summary:       String        — One-paragraph summary of the verdict and key concerns
    sections:      Object        — Structured per-section comments: { "intro": "...", "methods": "...", ... }
    confidence:    Float         — 0.0–1.0; reviewer's confidence in the verdict
    evidence_refs: StringArray   — ItemIds consulted to produce this review (prior reviews, cited works)
    agent_id:      String        — Persona ID if agent-authored (per ADR-0013)
    agent_run_ref: String        — agent-run@1.0.0 ItemId if agent-authored

  FTS: body + summary

  Typical edges:
    Annotates  →  manuscript-revision (the subject)
    Cites      →  bibliography-entry  (sources cited in the review)
    Supersedes →  review              (prior review of the same subject)
    ProducedBy →  agent-run           (mirror of agent_run_ref)
```

**Field rationale.**

- `verdict` is a closed vocabulary. The four values mirror the standard journal-review taxonomy (accept / accept with revisions / major revisions / reject). UI can render verdict as a colored badge without per-call interpretation.
- `sections` is an `Object` (per the `FieldType::Object` variant in `crates/impress-core/src/schema.rs`) keyed by section name. The keys are not validated by the schema — they match the `section_type` values from `manuscript-section@1.0.0` by convention but allow arbitrary strings for non-standard sections.
- `confidence` is normative: pipelines may suppress low-confidence reviews from auto-routing, or surface them only when no high-confidence review exists.
- `body` is markdown for human consumption. Agents producing reviews emit markdown as well; the agent loop's structured-output adapter is responsible for ensuring the markdown is well-formed.

### D41. The `revision-note/v1` Schema

```
revision-note@1.0.0:
  Required:
    subject_ref:   String        — ItemId of the manuscript-revision the note is about
    verdict:       String        — "propose" | "accept" | "reject" | "defer"
    body:          String        — Prose explanation of the revision rationale

  Optional:
    diff:          String        — Unified diff (RFC 6902-compatible patch or unified-diff text)
    target_section: String       — section_type value (e.g., "methods") if the note is scoped to one section
    review_ref:    String        — ItemId of the review/v1 item that motivated this note (if any)
    evidence_refs: StringArray   — ItemIds consulted (the review, the section being revised, related papers)
    agent_id:      String        — Persona ID if agent-authored (typically "artificer")
    agent_run_ref: String        — agent-run@1.0.0 ItemId if agent-authored

  FTS: body

  Typical edges:
    Annotates  →  manuscript-revision     (the subject)
    InResponseTo → review                  (the motivating review, if any)
    Supersedes →  revision-note            (prior proposal that this one replaces)
    ProducedBy →  agent-run                (mirror of agent_run_ref)
```

**Field rationale.**

- `verdict` for a revision note is the proposer's stance: `propose` (Artificer or human suggests an edit), `accept` (the edit was accepted into a new revision), `reject` (the edit was declined), `defer` (the edit was queued for later consideration).
- `diff` carries the actual edit. Format is unified-diff text by default; structured patch formats (RFC 6902 JSON Patch) are permitted for non-text edits if the journal pipeline ever needs them. The schema does not enforce parsability — that is the consumer's responsibility.
- `target_section` lets a note be scoped to one section without requiring a full multi-section diff. When set, `diff` applies to that section's `body` only.
- `review_ref` is the link back to the originating review. It is materialized as both a field and an `InResponseTo` edge.

**Why diff is a string, not parsed.** The diff format may evolve (line-based today, semantic-tree-based tomorrow). Storing the diff as opaque text behind a content-type marker (implied by being part of a Typst manuscript revision in the journal context) lets the format change without schema migration. Agents producing diffs are responsible for emitting valid unified-diff text against the current revision's source.

### D42. Episodic Memory Is a Query Pattern

Knowledge objects authored by agents form the substrate for episodic memory: the ability for an agent invocation to consult its own and other personas' prior outputs on similar artifacts. There is no separate "memory" subsystem — the operation is a query over the existing item graph.

**The canonical query** for "what has Counsel previously said about manuscripts on this topic?" is:

```
items
  WHERE schema = 'review'
    AND payload->>'agent_id' = 'counsel'
    AND subject_ref IN (
      SELECT id FROM items
      WHERE schema = 'manuscript'
        AND tags && {'topic/cosmology', 'topic/large-scale-structure'}
    )
  ORDER BY created DESC
  LIMIT 10
```

**Two practical considerations** for episodic memory consumers:

1. **Token budget.** Past reviews can be large. Retrieval should select by relevance (subject overlap, tag overlap, citation overlap) and summarize rather than concatenating raw bodies. The `summary` field on `review/v1` exists for this reason — episodic-memory consumers default to retrieving summaries, not bodies.

2. **Recency vs. authority.** A review from a year ago authored by a human is more authoritative than a fresh agent review. Consumers should weight by author kind (`Human > Agent`) before recency. The retrieval pattern is application-level; this ADR does not standardize it.

**This ADR does not introduce a memory subsystem or a memory schema.** The point is that knowledge objects, queried with the existing item-store API, *are* the memory substrate. Future ADRs may introduce memory-specific ergonomics (a `memory.recall(persona, subject_filter)` helper, a memory-relevance scorer) but the storage and provenance are already settled.

### D43. Retention Tier and Compaction

Knowledge objects are durable, not compactable. They sit in the **Durable** retention tier per ADR-0003.

**Why Durable.** A review represents a distinct intellectual act — a researcher or agent making a judgment at a point in time. Compacting a review (or its operation history) destroys the audit trail of how a manuscript revision was evaluated. The journal pipeline's reproducibility commitment (ADR-0011 D10) requires every review to remain queryable indefinitely.

**Operations on knowledge objects.** Operation items targeting a review (e.g., a tag added to the review for filing purposes, or a `Supersedes` edge added when a follow-up review is created) follow the standard ADR-0003 retention rules. Routine operations are compactable; the review item itself is not.

**Storage growth.** A pessimistic estimate: 100 manuscripts in the journal, each with 5 reviews and 20 revision notes over their lifetime, yields 2,500 knowledge-object items. This is negligible compared to the operation-stream volume ADR-0003 already accommodates. No special handling needed.

---

## Consequences

### Positive

- The journal pipeline (ADR-0011) gets concrete schemas for review and revision proposals without re-inventing the field convention.
- The "knowledge object" category is a vocabulary that future ADRs can reuse: a post-mortem schema, a referee-response schema, a decision-memo schema all inherit the same field shape.
- Episodic memory becomes a query pattern, not a subsystem. Agents consult past knowledge objects through the existing item-store API; no new infrastructure.
- The `Supersedes` edge gives reviews and revision notes a natural revision history without conflating them with the manuscript-revision lineage.
- Reviews and revision notes are first-class `Item`s; FTS works, tagging works, sharing works, mbox export works. Nothing about the integration is special.

### Negative

- The "knowledge object" label appears in this ADR but not in the type system. New contributors must read this ADR to recognize the convention; the registry will not enforce it. A future violation (a schema that should be a knowledge object but isn't structured as one) will go undetected by tooling.
- `verdict` as a free-vocabulary string (per-schema closed vocabulary, not a global enum) means UI must know which vocabulary applies for which schema. Adding a third knowledge-object schema with a different verdict vocabulary requires UI extension.
- `evidence_refs` is honor-system: nothing in the store enforces that the listed refs were actually consulted. Reproducibility audits depend on agent loops emitting accurate evidence lists. A future ADR may tighten this with cryptographic attestation; for now, trust the agent.
- Knowledge objects are durable (D43). For pipelines that produce many short-lived agent reviews (e.g., a reviewer that re-runs every commit), storage grows linearly with no compaction relief. If this becomes a problem, the pipeline should set `retention: Compactable` on the operation that creates the review, not on the review itself — the review remains durable.

---

## Open Questions

1. **`verdict` vocabulary stability.** The four review verdicts (`approve`, `approve-with-changes`, `request-revision`, `reject`) are taken from the conventional journal taxonomy. If a research workflow requires more nuance (e.g., distinguishing minor from major revisions), the vocabulary must extend. ADR-0004 D18 says additive changes bump the minor schema version; clarify whether vocabulary additions count as additive (they should, since old readers tolerate unknown verdict strings).

2. **Agent prompt visibility.** Agent-authored reviews carry `agent_run_ref`, which links to the agent-run item with `prompt_hash`. The full prompt is not stored — only its hash. For "why did Counsel say what it said?" debugging, the prompt itself may be needed. Decide whether to store the rendered prompt alongside `prompt_hash` for knowledge-object-producing agent runs (a small storage cost for high diagnostic value).

3. **Revision-note diff format strictness.** The schema permits any string in `diff`. A future ADR may want to require a content-type tag (`unified-diff`, `json-patch`, `typst-section-replace`) so consumers can dispatch on format. Defer until a second diff format actually appears.

4. **Cross-revision review carry-forward.** When a manuscript-revision is created from its predecessor, should reviews on the predecessor automatically link to the new revision? Currently they do not — the new revision starts with no reviews. The journal pipeline may want a "carry forward unaddressed reviews" affordance. Out of scope for this ADR; flagged for ADR-0011.

5. **Episodic memory privacy.** Past reviews authored by Counsel are visible to future Counsel invocations. If a researcher wants to mark a review as "do not use as training context," the schema needs a `private: bool` field or a `Visibility::Private` envelope (ADR-0001 already supports the latter). Decide before episodic memory consumers are implemented in pipelines.

6. **Promotion to runtime type.** D38 defers a runtime `KnowledgeObject` trait until three schemas exist. The third candidate is most likely `referee-response/v1` (a reply to a journal referee, structurally close to a revision-note but with a different `verdict` vocabulary and an external addressee). When that schema is proposed, revisit whether the runtime promotion is now load-bearing.

---

## References

- `crates/impress-core/src/schema.rs` — `Schema`, `FieldDef`, `FieldType` (the shape of new schema definitions)
- `crates/impress-core/src/schemas/manuscript_section.rs` — example of an existing schema using `IsPartOf` and `Contains` edges; pattern to mirror
- `crates/impress-core/src/reference.rs` — `EdgeType::Annotates`, `Supersedes`, `InResponseTo`, `ProducedBy`, `Cites` (the existing edge types this ADR's schemas use)
- ADR-0001: Unified Item Architecture — the item envelope, edges, and graph model
- ADR-0003: Operations and Provenance — retention tiers, operation items
- ADR-0004: Schema Registry and Type System — schema registration, additive evolution, "schemas as items" deferral
- ADR-0005: Task Infrastructure — `agent-run@1.0.0`, the source for `agent_run_ref`
- ADR-0013: Multi-Persona Agents — the source for `agent_id` (persona ID)
- ADR-0011: The impress Journal — primary consumer (uses both `review/v1` and `revision-note/v1`)
