# ADR-0016: Throughline — Anchored Narrative Companion Documents

**Status:** Proposed
**Date:** 2026-07-20
**Authors:** Claude (Fable 5 session), for Tom's review
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0003 (Operations and Provenance), ADR-0004 (Schema Registry and Type System), ADR-0012 (Knowledge Objects — relationship discussed in D3), ADR-0015 (Task Kernel Completion), imprint ADR-007 (FAIR Alignment — sidecar-overlay precedent)
**Scope:** `crates/impress-core/src/schemas/` (new throughline schema); `crates/imprint-service/` (anchor map, staleness derivation, throughline service trait); `apps/imprint/Shared/` (FileWrapper sidecars, pane UI, review resolution); `crates/impel-enrichment/` or successor (sync executor + spawn rule); `crates/imprint-selftest/` (Tier A/B capabilities)

---

## Context

A **throughline** is a short, curated narrative version of a manuscript — roughly
blogpost length — that tells the paper's story: what we claim, why it matters, how
the argument flows. It is *authored content*, not a generated summary. It lives
alongside the manuscript and is kept in sync with it by agents, under human review.

Four requirements define the feature:

1. **Anchoring.** Each throughline paragraph is explicitly linked to the manuscript
   sections it covers. Sync operates over these anchors, never text similarity.
2. **Bidirectional, asymmetric sync.** Anchored manuscript content changes → the
   throughline paragraph is marked stale and an update is proposed. Throughline
   edits → agents draft changes into the anchored manuscript sections. Authority is
   split: the throughline is authoritative for *claims and narrative order*; the
   manuscript is authoritative for *evidence, derivations, and numbers*. Agents
   never strengthen a claim beyond what the anchored manuscript supports.
3. **Propose, never auto-commit.** All sync actions are proposals for human review.
   Staleness is a visible state, not an error to be eagerly fixed.
4. **Unanchored content is a signal.** Manuscript sections with no throughline
   anchor get flagged — either they join the story or they are supporting detail.

Future direction (designed for, not built here): the throughline plus its anchor
map becomes the source for downstream renderers — blogposts, talk decks,
interactive websites with expandable detail panes.

A five-survey audit (2026-07-20) established that nearly all required machinery
exists:

- **Stable section identity:** `SectionExtractor.swift` derives deterministic
  section IDs (document id + normalized heading title + order index), explicitly
  designed for agents; `crates/imprint-service/src/sections.rs` mirrors this as
  `SectionStore::item_id` = UUID-v5 over `"<doc_id>::<section_key>"` with a frozen
  namespace, and `SectionRecord` already stores a SHA-256 `content_hash` per body.
- **Propose-never-commit is implemented:** ADR-0015's task kernel — executor
  computes a proposal, calls `open_review()` creating a `review-request@1.0.0`
  item, returns `ExecutionOutcome::Suspended`; the task cannot leave `running`
  until a human writes `resolution`. `KeywordTagExecutor` is a working template.
  imprint's UI already has the non-destructive grammar: `handleRunTask` returns
  `{result, applied: false}`, `InlineAITaskCard` Accept/Discard, and
  `POST /api/comments/{id}/accept|reject`.
- **Sidecar files are idiomatic:** a manuscript is a `.imprint` FileWrapper
  package (`main.typ`, `metadata.json`, `bibliography.bib`,
  `ro-crate-metadata.json`); imprint ADR-007 establishes the regenerated-overlay
  principle, and the bundle syncs as one file-wrapper, so sidecars ride through
  iCloud/CloudKit for free.
- **Service codegen:** an `#[impress_service]` trait + `impress_service_impl!`
  yields MCP tools, CLI subcommands, and JSON dispatch from one definition.
- **Nothing covers cross-document sync:** no staleness or document-to-document
  reconciliation concept exists anywhere in `docs/` or the crates. imprint
  ADR-006 (device sync) is silent on this axis. The staleness model below is the
  net-new contribution of this ADR.

## Decision

### D1. Opt-in by construction — zero cost when absent

A document has a throughline **only if the sidecar exists** in its `.imprint`
package. Absence of the sidecar is the off state, and the off state is free:

- **No storage or schema cost.** No item is created, nothing is mirrored, no
  Core Data or SQLite change applies to documents without a throughline.
- **No compute cost.** Staleness derivation, coverage queries, and anchor
  resolution run only for opted-in documents. The sync spawn rule filters on an
  opted-in document set (maintained from throughline create/delete events)
  *before* doing any work; documents without a throughline spawn zero tasks.
- **No UI cost.** No pane, no badges, no coverage flags, no toolbar or sidebar
  noise for documents without a throughline. The only surface a non-user ever
  sees is a single command-palette entry ("Throughline: Create for this
  document"), plus a Settings toggle that hides even that.
- **No migration.** The schema addition is purely additive (ADR-0004 D18); the
  FileWrapper reader tolerates the sidecar's absence; `DocumentSchemaVersion`
  does not change for documents that never opt in.

Activation is an explicit human act: the command-palette action (or
`create_throughline` service call) writes the two sidecar files. Deactivation is
deleting them (via UI action; files move to a `.throughline-removed/` folder
inside the package until the next save, mirroring the Dismissed-as-Trash
convention).

### D2. File representation: two plain sidecars; file is authoritative

Two plain, separately-diffable files inside the `.imprint` package:

```
Foo.imprint/
├── main.typ
├── throughline.typ          # the narrative — human-curated Typst
├── throughline.anchors.json # the anchor map — machine-maintained sync ledger
├── metadata.json
├── bibliography.bib
└── ro-crate-metadata.json
```

**`throughline.typ`** is Typst (Design Principle 6: Typst as the document
substrate — one substrate for authoring and for future renderers). Each
paragraph carries a stable Typst label, e.g. `<tl-claim>`, `<tl-why-it-matters>`.
Labels are authored once (auto-suggested at creation, editable) and are never
regenerated; they are the throughline-side half of every anchor identity.

**`throughline.anchors.json`** is the sync ledger (versioned schema, `"version": 1`):

```json
{
  "version": 1,
  "document_id": "6E2A…",
  "anchors": {
    "tl-claim": {
      "section_keys": ["introduction", "results"],
      "manuscript_hashes": { "introduction": "sha256:…", "results": "sha256:…" },
      "throughline_hash": "sha256:…"
    }
  },
  "supporting": ["appendix-a", "numerical-methods"]
}
```

Hashes are recorded **only when a sync proposal is accepted** (or at creation).
`supporting` lists section keys deliberately excluded from the narrative (D7).

The files on disk are authoritative. The store carries a derived mirror (a
`throughline@1.0.0` item plus edges, D3) exactly as `main.typ` is mirrored into
`SectionStore` — same source-of-truth split, same rebuild-from-file recovery
story. Both files diff cleanly in git and ride device sync inside the bundle.

**FileWrapper round-trip guard:** `ImprintDocument.fileWrapper(configuration:)`
constructs package contents explicitly, so it MUST be taught to preserve both
sidecars (and `init(configuration:)` to read them). A build predating this ADR
would silently drop the sidecars on save; this is acceptable during development
and is the trigger for bumping `DocumentSchemaVersion` if throughline-bearing
documents circulate before all builds carry the read/write support.

### D3. Item model: one content schema, one edge, anchors as metadata

**`throughline@1.0.0`** is a new *content* schema in
`crates/impress-core/src/schemas/throughline.rs`, registered in
`register_core_schemas()`, with typed accessors (per ADR-0004's "raw payload
access is an anti-pattern"). Fields: required `title`, `document_ref`; optional
`paragraph_count (Int)`, `anchor_map_hash`, `content_hash`, plus the FAIR quintet
(`orcid`, `affiliation`, `funder`, `license`, `embargo_until`) for parity with
ADR-0014. Expected edges: `RelatesTo`, `Supersedes`, plus the narrates edge below.

**It is a peer of `manuscript`, not a knowledge object.** ADR-0012 knowledge
objects are an actor's stance *about* a subject (`subject_ref` is 1:1, "about an
entire revision"); a throughline is authored narrative *content* with
paragraph-level, many-to-many anchors. The clean split: **the throughline
document is a content schema; each proposed sync is a review-request-carried
proposal** (D6), keeping ADR-0012's propose/accept vocabulary without minting a
knowledge-object schema here. If a dedicated `throughline-sync-proposal` schema
later proves necessary, note that it would be the *third* knowledge-object
schema and would trigger ADR-0012 D38's runtime-type promotion — deliberately
not exercised by this ADR.

**Edge:** throughline item —`Custom("narrates")`→ manuscript/document item.
Per ADR-0011's precedent, no new core `EdgeType` variant is added; `narrates`
is promoted to a core variant only if downstream renderers make it hot.

**Anchors are not items** (in this ADR). The anchor map is the authority;
the store mirror carries anchors as `TypedReference.metadata` on
section-targeted edges so agents can traverse them, but no per-paragraph items
exist. Per-paragraph items become worthwhile only if cross-cutting queries
demand them; that is an explicit future amendment, not a default.

### D4. Anchor identity: the Rust section key is canonical; rename breaks loudly

The **canonical** anchor coordinate is
(`throughline.typ` label) × (`section_key` → UUID-v5 `item_id` from
`crates/imprint-service/src/sections.rs`). The Swift `SectionExtractor` scheme
is convergent but not authoritative: any Swift surface that touches anchors
resolves them through the shared store (`OutlineSnapshot` /
`ManuscriptStoreAdapter`), never through a parallel derivation. This closes the
dual-extractor drift hazard (two independent heading parsers exist today; only
one may define identity).

**Heading renames break anchors, and that is the designed behavior.** The
heading-derived key is stable across body edits but rebinds on heading
add/rename/remove. When a `section_key` in the anchor map no longer resolves,
the anchor enters the `broken` state (D5) and a **repair proposal** is spawned
(rebind to the renamed section — detectable via order-index + body-hash match —
or drop the anchor). Repair is a proposal like any other: visible, reviewed,
never automatic. Finer-grained, rename-proof anchoring via native Typst
`#label()` extraction is explicitly deferred; nothing in the anchor-map schema
precludes adding a `label` coordinate alongside `section_keys` later.

### D5. Staleness: four derived anchor states, never stored as truth

Anchor state is **derived** by comparing current content hashes against the
ledger; it is never a stored flag that can rot:

| state | condition | meaning |
|---|---|---|
| `synced` | both sides match ledger | nothing owed |
| `manuscript-ahead` | anchored section hash ≠ ledger | throughline paragraph is stale; update proposal owed |
| `throughline-ahead` | paragraph hash ≠ ledger | manuscript draft owed in anchored sections |
| `broken` | `section_key` does not resolve | repair proposal owed |

If both sides drifted, `manuscript-ahead` and `throughline-ahead` coexist on the
same anchor and the proposal presents both directions for the human to sequence.

Staleness is a **visible, legitimate, human-paced state** — surfaced as badges
and a filterable list, never auto-resolved, never nagging. This is deliberately
distinct from ADR-0003 D13's store-integrity sense of the word ("if the
materialized columns are out of sync with the operation stream, the store is
corrupt, not stale"): D13 governs a projection that must always agree with its
source; a throughline is *independently authored* content whose divergence from
the manuscript is expected and meaningful. This ADR partially answers the
ADR-0002-overlay OQ4 gap (distinguishing durable products from stale derived
computations) for the specific case of authored companion documents: the ledger
hash-pair is the mechanism.

### D6. Sync is tasks + reviews; authority is asymmetric; nothing auto-commits

Drift spawns a `task@1.0.0` of kind `throughline-sync` via a spawn rule
(template: `EnrichmentSpawnRule`) that (a) consults the opted-in document set
first (D1), (b) debounces per-anchor so an editing session yields one task, not
one per keystroke. A `ThroughlineSyncExecutor` (registered like any ADR-0015
executor) computes the proposal and **opens a review instead of writing**:

- **manuscript-ahead** → drafts an updated throughline paragraph. Review context
  carries `context_direction`, `context_anchor`, `context_diff` (word-level, via
  the existing `DiffCalculator`), and the proposed text.
- **throughline-ahead** → drafts edits to the anchored manuscript sections. The
  executor's prompt contract encodes the authority split: *claims and narrative
  order flow from the throughline; evidence, derivations, and numbers flow from
  the manuscript; never strengthen a claim beyond what the anchored sections
  support — if the throughline asserts more than the manuscript shows, the
  proposal must say so rather than paper over it.* This invariant is enforced by
  the prompt contract **and the human review gate** — the review is the actual
  enforcement point, and the ADR is honest that no mechanical check can verify
  claim strength.
- **broken** → repair proposal (D4).

The executor returns `ExecutionOutcome::Suspended`. On `resolution == approved`,
the apply path is the existing surgical machinery — `put_section` /
`replace_in_section` for manuscript edits, the throughline file write for
paragraph updates — followed by the **ledger update (the only writer of ledger
hashes)**, all as attributed operation items with full provenance. On
rejection, nothing changes; the anchor simply remains visibly stale.

**Review resolution lives in imprint.** Sync proposals are document-local and
span-anchored; imprint's comments accept/reject flow and inline-card grammar fit
exactly. They remain `review-request@1.0.0` items, so any inbox surface
(including imbib's ADR-0011 Submissions inbox) can *list* them — but the
resolving UI is imprint. This is a deliberate choice against routing them
through the imbib inbox; revisit only if cross-app review proves confusing in
practice.

HTTP/MCP parity: `POST /api/documents/{id}/throughline/sync` follows the
`handleRunTask` contract — computes and returns the proposal with
`"applied": false`; application happens only through review resolution.

### D7. Coverage: unanchored sections are a query, not a nag

For opted-in documents only, coverage = manuscript sections targeted by no
anchor and not listed in `supporting`. Surfaced as a passive indicator in the
outline and a service query (`get_coverage`), with two one-keystroke human
dispositions: **anchor it** (opens the anchor editor) or **mark supporting**
(appends to `supporting` in the anchor map — deliberate detail, suppressed
thereafter). No task is spawned for coverage; it is pull, not push.

### D8. The renderer contract (designed for, not built)

The pair (`throughline.typ`, `throughline.anchors.json`) plus resolvable section
bodies is the **stable input contract** for future renderers — blogpost, talk
deck, interactive site with expandable detail panes (render paragraph; offer
anchored sections as the expansion). Consequences now:

- labels in `throughline.typ` are stable public identifiers;
- the anchor-map schema is versioned and additive-only;
- nothing in the sync machinery may depend on presentation;
- renderers are read-only consumers — they never write the ledger.

No renderer is built under this ADR.

### D9. Boundaries and guards

- **No CRDT.** This ADR builds on the shipped plain-text FileWrapper model.
  imprint ADR-001 (Automerge canonical model) does not describe shipped reality;
  this ADR does not adopt it and **flags ADR-001 for re-status/amendment**
  rather than silently diverging further.
- **No core `EdgeType` variant, no knowledge-object promotion, no per-paragraph
  items, no Typst-label anchors, no renderers** — all named above as explicit
  deferrals with their trigger conditions.
- **Numbering hygiene:** this is ADR-0016; note the pre-existing collision of
  two ADR-0002 files (`operations-as-overlay-items`, superseded by ADR-0003, and
  `sqlite-storage-architecture`, still live) so future references stay
  unambiguous.
- **Concurrency guard:** the ledger is updated only by the accept path, under
  the same write discipline as section persistence; a proposal computed against
  hashes that no longer match at accept time is invalidated and respawned, never
  force-applied.

## Consequences

**Positive.** The paper's story becomes a first-class, versionable artifact with
provenance; drift between story and evidence is visible instead of discovered at
submission time; agents get a structured, anchored surface for narrative work
instead of whole-document rewrites; the future renderer family gets a stable
source. Non-users are untouched (D1). Every mechanism reuses shipped
infrastructure — the net-new inventions are exactly two files and one derivation
(anchor states).

**Negative / costs.** Two more files in the bundle to explain; heading renames
produce visible anchor breaks that need a review action (accepted trade for
identity simplicity); the claim-strength invariant is procedurally, not
mechanically, enforced; the FileWrapper round-trip must be handled before
throughline-bearing documents circulate across builds.

**Open questions.** (OQ1) Should acceptance of a throughline-ahead proposal
auto-record the *manuscript*-side hash even when the human edits the draft
before applying — current answer: yes, ledger records what was actually applied.
(OQ2) Multi-manuscript throughlines (one story spanning a paper series) —
excluded; would require `document_ref` to become a list. (OQ3) Whether
`narrates` warrants a core `EdgeType` variant once renderers exist.

## Amendment (2026-07-20, post-implementation)

Recorded during the Phase 1–4 build (branch `worktree-throughline`); the
decisions above stand, with these refinements surfaced by the code:

1. **Unified-store pivot parity.** The manuscript unified-store pivot
   (`manuscript.body_content` et al., landed after this ADR's survey) moved
   the router's read path to the store. Accordingly `throughline@1.0.0`
   carries optional `body_content` / `anchor_map_json` payload fields: the
   sidecar files remain authoritative where they exist (D2), and the store
   mirror is a full copy, so store-resident manuscripts can carry their
   throughline wholly in-store. The HTTP routes and the headless service
   read the mirror — the same rows on both paths.
2. **Section-key canonicalization is concrete now:** slugified heading
   titles (`ThroughlineText.sectionKey(forHeading:)`) produced by the Swift
   mirror, matched by deterministic UUID-v5 ids on both sides
   (Rust `SectionStore::item_id` ↔ Swift `ThroughlineIdentity.sectionItemID`,
   parity vectors pinned in tests). Document ids are lowercase in payloads
   (Rust `Uuid::to_string` convention).
3. **Repair mechanics (D4):** the rename heuristic is
   `rebind_candidate` — a pure function matching the broken key's ledger
   hash against current section bodies, refusing zero/ambiguous matches;
   candidates feed the review's `repair_action = rebind | drop`, applied
   only on approval as a ledger edit.
4. **Broken-anchor spawn refinement (D6):** an edit to an *unanchored*
   section does spawn a sync task when any anchor is broken — a heading
   rename surfaces exactly as (new unanchored key + broken ledger key).
5. **Drafter boundary:** proposal text generation sits behind a
   `ProposalDrafter` trait; `TemplateDrafter` (deterministic) ships first,
   and the LLM drafter carries the D6 authority-split contract in its
   system prompt when wired.
6. **Verification caveat:** the `impel-taskd` registration compiles only
   on rustc ≥ 1.94 (pre-existing aws-* dependency floor); everything else
   is test-verified (see `docs/plan-throughline.md` status notes).

## References

- Implementation plan: `docs/plan-throughline.md`
- ADR-0015 task kernel (`transition_op`, `open_review`, `ExecutionOutcome::Suspended`)
- `crates/imprint-service/src/sections.rs` (section identity + content hashes)
- `apps/imprint/Shared/Services/SectionExtractor.swift` (Swift section IDs — convergent, non-authoritative per D4)
- `apps/imprint/Shared/Models/ImprintDocument.swift` (FileWrapper chokepoints)
- imprint ADR-007 (sidecar-overlay precedent), imprint ADR-006 (device sync — silent on cross-document reconciliation, by design)
- `crates/impel-enrichment/src/keyword_tag.rs` (executor + review template)
