# ADR-0017: The Legible Graph — Connection Surfaces over the Unified Store

**Status:** Proposed
**Date:** 2026-07-21
**Authors:** Claude (Fable 5 session), for Tom's review
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0003 (Operations and Provenance), ADR-0004 (Schema Registry and Type System), ADR-0009 (Cognitive Views), ADR-0012 (Knowledge Objects), ADR-0015 (Task Kernel), ADR-0016 (Throughline — first consumer)
**Scope:** shared SwiftUI connection components (`packages/`), read-only projections + one suggestion pipeline in `crates/impress-core` / app cores, one new schema (`query@1.0.0` usage promotion), editor mention grammar in imprint/imbib

---

## Context

ADR-0001 gave the suite a typed graph: every paper, manuscript, section,
figure, dataset, capture, review, task, and throughline is an item, and every
relationship is a typed, directed edge. ADR-0003 made every mutation an
attributed operation, so the store also carries a complete, queryable record
of *what happened, when, and by whom* — human and agent alike.

Almost none of this structure is visible at the point of work.

A publication's detail view does not say which manuscripts cite it. A dataset
does not reveal which figures were derived from it. The operation stream —
the richest activity record any research tool could ask for — has no daily
surface. Two items with nearly identical content sit unconnected unless a
human happens to remember both. The graph is load-bearing but illegible: we
built the substrate ADR-0009's cognitive views were promised on, and then
exposed it only to agents.

The cost is felt exactly where the suite's philosophy says it must not be:
in flow. Rediscovering a connection means leaving the current context to
search for it. Reconstructing "what did I do yesterday" means scrolling
per-app lists. Structure the researcher already paid for — by importing,
capturing, linking, writing — returns no compounding interest.

The thesis of this ADR: **the store already knows; the suite should show
it.** Every decision below is a projection or a proposal over existing
machinery — no new sources of truth, no background mutation, no exceptions
to the provenance discipline.

## Decision

### D1. The Connections pane

Every item detail view, in every app, gains the same section: the item's
incoming and outgoing typed edges, grouped by edge type and peer schema,
rendered as navigable rows —

> Cited by **2 manuscripts** · Visualized in **1 figure** · Narrated by
> **throughline** · Annotated in **3 reviews** · Derived from **1 dataset**

Mechanics:

- One shared component (new `ImpressConnections` package or an ImpressFTUI
  addition), one query over the references table (both directions), grouped
  client-side. No caching layer; the store's `neighbors()`/reference index
  is already fast at suite scale.
- Keyboard-first: `c` focuses the pane, `j`/`k` move, `Enter` navigates to
  the peer (cross-app via the `impress://` router when the peer lives in a
  sibling app). `.keyboardGuarded` throughout.
- Edge metadata renders inline where present (e.g. a throughline anchor's
  section keys, ADR-0016).
- Adopted suite-wide under "Consistency Creates Capability": imbib
  publication detail, imprint document/section views, implore figure
  library, capture detail. One learned surface, five apps.

This is a pure projection. It writes nothing.

### D2. Today

A day-scoped projection over the operation stream and item envelopes: what
was created, edited, captured, resolved, and proposed today — grouped by
app and schema, with the actor visible on every row (`human:` vs `agent:`
per ADR-0003 D15). Yesterday and any past day are the same query shifted.

- **Not a subsystem.** This ADR reaffirms ADR-0012 D42 (episodic memory is
  a query pattern over the store) and ADR-0003 D13 (projections are never
  truth). Today is a view; there is no "daily note item" unless the user
  writes one (a `note` artifact created from the Today surface dates
  itself naturally).
- **Capture lands here.** Cmd+Shift+Space captures (Universal Research
  Capture) appear in Today with zero filing pressure; the expected flow is
  capture now, connect later from D1's pane. Inbox anxiety is replaced by
  a self-assembling record.
- **Agents are first-class in the record.** Enrichment runs, sync
  proposals, review resolutions — the researcher sees what their
  colleagues (human or agent) did to the corpus today, with one keystroke
  to the underlying item. No other research tool can show this because no
  other research tool logs agent work as attributed operations.
- Surface: a `Today` sidebar section in imbib first (the hub app), backed
  by a service query exposed over HTTP/MCP so agents can read the same
  digest they appear in.

### D3. Resonance — suggested connections, propose-only

The suite's embedding infrastructure (publication and chunk indexes, the
exact-search-hardened ANN layer) is extended to surface cross-schema
similarity: a manuscript section that resembles three papers the author
never cited; a captured webpage that relates to an open draft; two figures
built on the same dataset.

The governing rule, stated as a design principle:

> **Agents propose edges; humans make them true.** An unexplained edge in
> a research graph is worse than a missing one — it rots trust in every
> edge around it.

Mechanics:

- A `Resonance` section inside D1's Connections pane (and a Today digest
  line) lists suggestions with their evidence: similarity score, model id,
  and the matching excerpt. Suggestions are knowledge-object-style items
  authored by the suggesting agent with full provenance (ADR-0012 field
  conventions: `subject_ref`, `evidence_refs`, `agent_id`).
- **Accept** writes an attributed `AddReference` operation
  (`RelatesTo`, or an upgrade to `Cites` when the peer is a publication);
  **dismiss** marks the suggestion resolved-rejected and it never returns
  for that pair. Nothing is ever linked automatically.
- Generation runs through the task kernel (spawn on new/changed items,
  respecting the ADR-0016 opt-in discipline for throughline-related
  suggestions; batch nightly otherwise) — never in the first 90 s of app
  launch, per the startup invariant.
- Embedding coverage extends beyond publications to sections, captures,
  and artifact text as a prerequisite; coverage gaps are logged, not
  silently skipped.

### D4. Mention anything

imprint's `@citekey` autocomplete generalizes to every schema: typing `@`
in prose (imprint editor, notes, review comments) completes across the
unified store — papers, datasets, figures, artifacts, people (when a
person schema exists) — and inserting a mention writes a typed `Mentions`
edge from the containing item to the target, as an attributed operation.

- One grammar suite-wide; the completion UI is the existing citation
  picker generalized, keyed by schema icon.
- Removing the mention text proposes edge removal on next save (same
  propose-don't-surprise posture: the editor shows a one-line notice
  rather than silently deleting graph structure).
- Citations remain citations: `@` on a publication in a Typst context
  still inserts a cite key; the `Mentions` edge is additive.

### D5. Queries as items

Saved searches are promoted from imbib-local smart searches to store
items (`query@1.0.0`: name, scope schemas, predicate payload, sort). They
appear in sidebars, are shareable between apps, and — because they are
items — are runnable by agents through the same service surface humans
use. A digest agent evaluating "my queries with new results since
yesterday" into Today's view is the intended composition of D2 + D5.

### D6. Boundaries

- **No user-defined schemas.** ADR-0004 D16 stands: schemas are Rust
  code. The pressure this ADR's features create ("I want a custom object
  type for X") is answered by the general artifact + tags + queries, not
  by runtime schema editing. Revisit only via ADR-0004's own Phase 4
  ("schemas as items"), not as a side effect here.
- **No global graph visualization.** A typed, 2-hop *local* neighborhood
  view may later grow out of D1 (or be rendered by implore, dogfooding
  the suite); a whole-corpus graph is explicitly rejected as spectacle
  without workflow value.
- **Layout preferences, not layout editing.** Per-schema detail layouts
  may gain user preferences (section order, collapsed-by-default); they
  do not become user-programmable documents.
- **Projections stay projections.** If any D1/D2 surface is ever found
  caching state that can disagree with the store, that is a bug of the
  ADR-0003 D13 class, not a tuning opportunity.

## Consequences

**Positive.** The graph the researcher has been building all along becomes
visible where they work, at zero marginal filing cost. Rediscovery
("what touches this?", "what happened today?", "what am I missing?")
stops requiring context exits — the flow principle applied to memory.
Agent labor becomes legible in the same surfaces, which builds exactly the
trust the propose-only rules depend on. Every feature is a projection or a
gated proposal, so the blast radius on the store's integrity model is
zero by construction.

**Negative / costs.** Five apps × one new pane is real UI surface to keep
consistent (mitigated by the shared component). Resonance requires
embedding coverage growth and tuning to avoid suggestion noise — a bad
Resonance is worse than none, so it ships behind a quality bar (precision
over recall, capped daily suggestion counts). `Mentions` edges add graph
volume; retention/compaction posture is Durable (they are research
record), which is a deliberate storage cost.

**Sequencing.** D1 + D2 are projection-only and shippable per-app
immediately (imbib first; imprint's throughline anchors as the D1
showcase). D3 is the flagship and follows embedding-coverage work. D4
lands with the next editor iteration; D5 with the smart-search
generalization. Each decision is independently valuable; none blocks
another.

## Open questions

- (OQ1) Does `Mentions` deserve per-context metadata (surrounding
  sentence) on the edge for preview rendering, or is that retrievable
  cheaply enough at display time?
- (OQ2) Should Resonance suggestions expire (unreviewed after N days →
  auto-dismiss) to keep the surface calm, or accumulate with decay in
  ranking only?
- (OQ3) Person items (ORCID-keyed) would make D4 dramatically better for
  author mentions and are FAIR-aligned (ADR-0014) — separate ADR, but D4
  should reserve the completion namespace.

## References

- ADR-0001 (the graph this ADR makes visible), ADR-0003 (the operation
  stream Today projects), ADR-0009 (cognitive views this ADR begins to
  deliver), ADR-0012 (knowledge-object conventions Resonance suggestions
  follow), ADR-0016 (propose-never-commit precedent and first Connections
  consumer)
- `crates/imbib-core/src/search/` (embedding + ANN layer backing D3)
- `apps/imbib/.../CapturePanel` (Universal Research Capture, D2's inbox)
