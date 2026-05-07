# ADR-0011: The impress Journal

**Status:** Proposed
**Date:** 2026-05-05
**Authors:** Tom (with architectural exploration via Claude)
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0003 (Operations and Provenance), ADR-0004 (Schema Registry and Type System), ADR-0005 (Task Infrastructure and Agent Integration), ADR-0006 (Retention Tiers and Compaction), ADR-0008 (FFI Bridge and Swift Integration), ADR-0012 (Knowledge Objects and Episodic Memory — companion), ADR-0013 (Multi-Persona Agents — companion), impel ADR-001 (Stigmergic Coordination)
**Supersedes:** imbib ADR-021 (Manuscript Tracking, Proposed 2026-01-19) — see *Reconciliation with imbib ADR-021* below
**Scope:** `crates/impress-core/src/schemas/` (new manuscript and submission schemas); `apps/imbib/PublicationManagerCore/` (Journal library, blob tier, list and detail views, mbox export); `apps/imprint/Shared/` (lifecycle event emission, content reference); `apps/impel/Packages/CounselEngine/` (journal pipeline orchestration, submission HTTP route); `packages/ImpressKit/` (new well-known events on `ImpressNotification`).

---

## Context

The impress suite has accumulated, across more than a year of researcher–agent collaboration, hundreds of manuscript drafts: scratch derivations, full papers, partial sections lifted across documents, response-to-reviewer letters, frozen submissions. Each lives somewhere — in a Claude conversation transcript, in a `.tex` file on disk, in an iCloud-synced `.imprint` package, in an email attachment, in `~/.claude/projects/{project}/{uuid}.jsonl`. None of them have a stable identity in the impress item graph. None of them carry provenance back to the conversation that produced them. None of them are queryable as "what reviews exist for this manuscript?" or "what was the state of the introduction at submission?"

This ADR introduces the **impress Journal**: a self-contained scientific publication pipeline composed entirely over the existing item graph, operations, schemas, tasks, knowledge objects, and personas. No new storage primitive is introduced. No new agent infrastructure is invented. The journal is layered.

The Product Design Requirements document `The impress Journal — A Self-Contained Scientific Publication Pipeline` (delivered as the PDR for this ADR) sets the requirements; this ADR specifies the architecture. Where the PDR's design and the actual repo state diverge — and they diverge in three substantive places — this ADR follows the repo and flags the deviation in the **PDR Deviations** section below.

The journal is a forcing function for several latent decisions: how content-addressed blobs live in imbib (latent in `manuscript_section.rs`'s 64 KiB threshold); how cross-app lifecycle events extend `ImpressNotification` (the bus exists; new event names are needed); how impel orchestrates a multi-stage pipeline with per-stage personas (TaskOrchestrator handles single tasks well; pipelines are the next step). Each of these is addressed below as a journal-pipeline decision but the resolution generalizes — future pipelines will reuse the same mechanisms.

### What already exists

This subsection makes the inheritance from existing ADRs and code explicit. Implementation should not re-invent these.

- **Items, operations, references, schemas** — ADR-0001, ADR-0003, ADR-0004; implemented in `crates/impress-core/src/{item,operation,reference,schema,registry}.rs`.
- **Edge types** — `EdgeType` in `crates/impress-core/src/reference.rs` already includes every edge the journal needs: `Cites`, `Contains`, `Attaches`, `IsPartOf`, `HasVersion`, `Supersedes`, `Annotates`, `Visualizes`, `DependsOn`, `OperatesOn`, `ProducedBy`, `DerivedFrom`, `Mentions`, `TriggeredBy`, `Exports`, plus `Custom(String)`. **No new edge type is added by this ADR.**
- **Tasks** — `task@1.0.0` schema (ADR-0005) plus `TaskOrchestrator` in `apps/impel/Packages/CounselEngine/Sources/CounselEngine/TaskOrchestrator.swift`. The journal's pipeline stages are tasks; the submission interface returns task IDs.
- **Personas** — Per ADR-0013: Scout, Archivist, Counsel, Steward, Artificer. Bound to journal stages in D7.
- **Knowledge objects** — Per ADR-0012: `review/v1` and `revision-note/v1`. Used as Counsel and Artificer outputs respectively.
- **Cross-app events** — `ImpressNotification` in `packages/ImpressKit/Sources/ImpressKit/ImpressNotification.swift`; nine well-known events exist. The journal adds five more (D9).
- **Content-addressed storage convention** — Already documented in `crates/impress-core/src/schemas/manuscript_section.rs:11–15`: bodies > 64 KiB go to `~/.local/share/impress/content/{sha256}/`. The journal's PDF blob tier reuses this convention (D4).
- **imprint–imbib bridge fields** — `apps/imprint/Shared/Models/ImprintDocument.swift:61–66` already declares `linkedImbibManuscriptID: UUID?` and `linkedImbibLibraryID: String?`, with `imprint://open?imbibManuscript={citeKey}&documentUUID={uuid}` URL-scheme handling at `Services/URLSchemeHandler.swift:15–67`. The journal completes this bridge (D3) rather than designing it from scratch.
- **Similarity utilities** — Jaccard + Jaro-Winkler in `crates/imbib-core/src/deduplication/orchestration.rs`; cosine + HNSW ANN in `crates/imbib-core/src/search/semantic.rs` and Swift `EmbeddingService.shared`. Reused for submission deduplication (D6).

### Forces

1. **Submission, not surveillance.** The original PDR concept — Scout watching `/mnt/transcripts/` and proposing ingestion — was rejected during planning. Directory polling is fragile, unsustainable, and conflates two different things: the steady-state mechanism (agents submit manuscripts they have authored) and the one-off backfill (ingest already-existing transcripts). The architecture must distinguish these.
2. **Composition over invention.** Per ADR-0001's Guardrail 3, every abstraction must justify itself with two concrete use cases. The journal does not justify any new core primitive — it justifies new schemas, new persona bindings, new event names, and new UI surfaces. The line is sharp.
3. **Provenance is everything.** The point of the journal is that any revision can be traced back to: the conversation(s) that produced the source, the bibliography it cites, the reviews it survived, the agent(s) that touched it. This is non-negotiable. Each decision below is gated on whether it preserves this trace.
4. **Local-first, offline-complete.** A researcher in a basement with no network must still be able to draft, snapshot, review, revise, and export manuscripts. Per ADR-0013 D32 and ADR-0005 D8, agent calls that require network are gated by per-persona policy and per-task autonomy.
5. **Minimal new code.** The journal should be implementable as additive schemas + a thin orchestration layer + a Library type in imbib + a few view extensions. If the implementation requires substantial new core code, the design is wrong.

---

## Decision

### D44. Manuscript as Compound Item — `manuscript/v1`

A **manuscript** is a long-lived `Item` with `schema = "manuscript"` (no version suffix in the registry key per ADR-0004 OQ-2; the version is durable in the payload as `schema_version: "1.0.0"` and on the wire when ADR-0004 D17 wiring lands).

```
manuscript@1.0.0:
  Required:
    title:         String      — Working title; updates create operation items
    status:        String      — "draft" | "internal-review" | "submitted" | "in-revision" | "published" | "archived"
    current_revision_ref: String — ItemId of the most recent manuscript-revision

  Optional:
    authors:       StringArray — Authors at the time of last revision; updated by snapshot operation
    journal_target: String     — Target journal name (free text; not validated)
    submission_id: String      — External submission identifier (e.g., "PRD-123456")
    topic_tags:    StringArray — Topic classifications used by smart collections
    notes:         String      — Free-form notes on the manuscript as a whole

  FTS: title + notes + authors

  Typical edges:
    HasVersion →  manuscript-revision      (every revision the manuscript has ever had)
    Contains   →  imprint:source           (Custom edge to the imprint document; see D3)
    Cites      →  bibliography-entry       (papers this manuscript cites — materialized from current revision)
    Visualizes →  figure                   (figures referenced — materialized from current revision)
    Annotates  →  review                   (reviews of any revision — knowledge objects per ADR-0012)
    DerivedFrom →  conversation            (originating conversations; payload schema TBD per OQ-3)
```

**The manuscript is a long-lived envelope.** Its `title`, `status`, `journal_target`, `submission_id`, `topic_tags`, and `notes` change over the manuscript's life via the standard `OperationType::SetPayload` and `OperationType::AddTag` mechanisms. Its `current_revision_ref` advances forward on each new revision. Reviews and revision notes accumulate as Annotated edges. Authors and the citation/figure graphs are materialized from the current revision (changes when revision pointer advances) but remain queryable on the manuscript itself for fast filtering.

**The manuscript is not the source.** The actual `.tex`/`.typ` source lives in imprint's CRDT document store (per D3). The manuscript item carries a reference, never a copy.

**Status state machine:**

```
                  ┌──────────┐
      (created)   │          │
    ─────────────►│  draft   │
                  │          │
                  └────┬─────┘
                       │  user/Steward action
                       ▼
                  ┌────────────────┐
                  │ internal-review │──┐
                  │                 │  │
                  └────┬────────────┘  │
                       │                │
                       ▼                │
                  ┌──────────┐          │
                  │submitted │◄─────────┘
                  │          │
                  └────┬─────┘
                       │  external editor returns reviewers
                       ▼
                  ┌─────────────┐
                  │ in-revision │
                  │             │
                  └────┬────────┘
                       │  resubmission, eventually accepted
                       ▼
                  ┌───────────┐    ┌──────────┐
                  │published  │───►│ archived │
                  │           │    │          │
                  └───────────┘    └──────────┘
```

Status transitions are operation items (per ADR-0003). Each transition may trigger pipeline stages (per D7). `archived` is terminal; once archived, the manuscript moves to the cold tier (D4) and is no longer touched by background services.

### D45. Revision Lineage — `manuscript-revision/v1`

A **manuscript-revision** is an immutable item snapshotting the manuscript's source and compiled output at a point in time.

```
manuscript-revision@1.0.0:
  Required:
    parent_manuscript_ref: String — ItemId of the manuscript this revision belongs to
    revision_tag:          String — User-meaningful tag ("v1", "submitted", "referee-response-1", "published")
    content_hash:          String — SHA-256 of the source archive (D4); also the addressing key
    pdf_artifact_ref:      String — ItemId of the artifact item carrying the compiled PDF (using the artifact schemas registered in `crates/impress-core/src/schemas/artifact.rs`)
    source_archive_ref:    String — ItemId of the artifact item carrying the .tar.zst source snapshot

  Optional:
    predecessor_revision_ref: String — ItemId of the prior revision (null for v1 of a manuscript)
    compile_log_ref:       String  — ItemId of the artifact item carrying the compile log (if any)
    snapshot_reason:       String  — "status-change" | "user-tag" | "stable-churn" | "manual" — why this revision was created
    abstract:              String  — Extracted abstract text for FTS and preview
    word_count:            Int     — Approximate word count

  FTS: abstract

  Typical edges:
    IsPartOf   →  manuscript                  (mirror of parent_manuscript_ref)
    Supersedes →  manuscript-revision         (the prior revision; mirror of predecessor_revision_ref)
    Attaches   →  artifact (PDF and source)   (mirrors of *_ref fields)
    Cites      →  bibliography-entry          (citations resolved at snapshot time)
    Visualizes →  figure                      (figures embedded at snapshot time)
    DerivedFrom →  conversation               (conversations contributing to this revision)
```

**Revisions are immutable.** No operation type may modify a revision item's payload. To "edit a revision" you create a new revision with a `Supersedes` edge. The corresponding ADR-0003 enforcement: `OperationType::SetPayload` and `OperationType::PatchPayload` operations on revision items are rejected at the store boundary. (Implementation note: this is a small validation in `apply_operation()`; the schema cannot enforce it on its own.)

**Revisions are content-addressed.** `content_hash` is SHA-256 of the source archive bytes. Two revisions with identical source produce identical hashes — the duplicate-detection mechanism for D6 inherits this for free.

**Revisions are linear, not branched.** A manuscript has a single linear chain of revisions. Branching (parallel revisions for different submission targets) is out of scope for v1; it is not precluded by the schema (predecessor_revision_ref could be multi-valued in a future version) but is not supported by the pipeline.

### D46. Source Bridge — `imprint:source` Reference

The PDR proposed a new `imprint:source` TypedReference. Inspection of `EdgeType` in `crates/impress-core/src/reference.rs` shows that `Custom(String)` already exists as the extension point. The bridge is:

```
manuscript --[Contains, metadata: { kind: "imprint-source", document_uuid: "...", library_uuid: "..." }]--> imprint-document-handle item
```

The `Contains` edge with structured `metadata` carries the bridge information. No new `EdgeType` variant is added. The metadata fields:

| Key | Type | Meaning |
|---|---|---|
| `kind` | String | Always `"imprint-source"` for this bridge |
| `document_uuid` | String | The `ImprintDocument.id` (UUID string) |
| `library_uuid` | String | The `linkedImbibLibraryID` from `DocumentMetadata` |
| `package_path` | String? | File path to the `.imprint` package on disk; nullable for content-only bridges |

**Why `Contains`, not `IsPartOf` or a Custom edge.** The manuscript "contains" its source the way an envelope contains a letter — the source is an internal component of the manuscript identity, not an external reference. `IsPartOf` is the wrong direction (the source is part of the manuscript, not the other way around — but `IsPartOf` flows from part to whole; here the manuscript is the whole). `Custom("imprint-source")` would work but loses the queryability of the standard edge type. `Contains` with structured metadata is the right primitive.

**The reverse mapping.** `ImprintDocument.linkedImbibManuscriptID` already exists (lines 61–62). The journal extends this so that on imprint document save (the existing `imprintDocumentDidSave` NotificationCenter event), if `linkedImbibManuscriptID` is set, imprint posts an `ImpressNotification.documentSaved` Darwin notification with the manuscript's ID in the resourceIDs payload. The Steward subscribes to this event (per D9) and may schedule a snapshot per D5.

**One imprint document per manuscript.** A manuscript has at most one source bridge. The `Contains` edge with `kind: "imprint-source"` is a singleton; adding a second is rejected by the journal's submission and snapshot logic (not by the store, which is content-agnostic).

### D47. PDF Blob Tier — Content-Addressed Storage Reuses the Existing Convention

The PDR Open Question 1 asked whether content-addressed PDF storage exists in imbib. It does not, but the convention is documented at `crates/impress-core/src/schemas/manuscript_section.rs:11–15`: large bodies live at `~/.local/share/impress/content/{sha256}/`. SHA-256 is computed for every linked file by `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Files/PDFManager.swift` (lines 89–92, the `computeSHA256` function); the hash is stored on `LinkedFileModel.sha256` but is not used for deduplication.

The journal's PDF blob tier is the reification of this latent convention.

**Storage layout:**

```
~/.local/share/impress/content/
  {sha256[0:2]}/
    {sha256[2:4]}/
      {sha256}.pdf            ← compiled PDF artifact
      {sha256}.tar.zst        ← source snapshot archive
      {sha256}.log            ← compile log (if applicable)
```

The two-level prefixing (4-character path) keeps any directory's child count under 65,536, well below filesystem limits.

**Adding a blob:**

1. Compute SHA-256.
2. If `~/.local/share/impress/content/{prefix}/{sha256}.{ext}` exists, return the existing `ItemId` for the artifact (registered in the item store).
3. Otherwise, write the blob, register an artifact item with payload referencing `{sha256}.{ext}`, return the new `ItemId`.

**Schema for the PDF artifact item.** Reuse the existing `impress/artifact/general` schema from `crates/impress-core/src/schemas/artifact.rs` with `artifact_subtype: "manuscript-pdf"` for revision PDFs and `artifact_subtype: "manuscript-source-archive"` for source snapshots. This avoids introducing a new schema for what is structurally the same as other file artifacts.

**Garbage collection.** A blob is unreferenced when no item in the store has it as a `file_hash`. Steward runs a periodic sweep that identifies unreferenced blobs and moves them to `~/.local/share/impress/content/.tombstones/{date}/` (not deletes — a researcher may wish to recover an orphaned snapshot). After a configurable window (default 90 days), tombstones are deleted.

**Why not a new `impress-blobstore` crate.** The PDR floated this as an option for OQ-1. The volume of code involved (a hash-prefix path computer, a blob writer, a deduper) is roughly 200 lines. Embedding it as a module in imbib (`apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Files/BlobStore.swift`) keeps the dependency surface narrow. If a third app later needs the same primitive, extraction to a shared package is straightforward.

### D48. Snapshot Policy — When and Who

A snapshot creates a new `manuscript-revision` item per D45. The policy answers: when is a snapshot triggered, and who can trigger one.

**Triggers** (any one suffices):

| Trigger | Source | Auto-snap? | Notes |
|---|---|---|---|
| **Status transition** | User or Steward changes `status` (draft → internal-review, internal-review → submitted, etc.) | Yes, gated on D49 | Default snapshot tag derives from the new status (`"submitted"`, `"internal-review-1"`) |
| **Explicit user tag** | User invokes "Snapshot Now" with a tag | Always | Manual, immediate |
| **Stable churn** | imprint reports no edits for N days AND last compile was clean | Yes, with Steward confirmation | N defaults to 7; configurable in settings |
| **Pipeline request** | A persona (typically Counsel before review) requests a snapshot | Per autonomy gate (D49) | If gate denies, falls back to "propose-only" — Steward decides |

**Idempotency.** Each snapshot is gated on `content_hash` of the source archive. If the hash matches the current revision's hash, no new revision is created — the trigger is a no-op. This makes status transitions safe to retry: clicking "Submit" twice produces one revision, not two.

**Who can trigger a snapshot:**

- **Human user** — always, with no gate.
- **Steward persona** — always, per ADR-0013 D33's `tools: imbib: full`. Subject to autonomy gate (D49) for whether the snapshot operation is auto-confirmed or proposed.
- **Archivist persona** — per ADR-0013 D33's role; primary worker for snapshots. Always proposes; Steward (or human) confirms.
- **Other personas** — never directly. They request a snapshot via the Steward route.

### D49. Submission Interface — Replaces the PDR's Directory Watcher

**The PDR's Scout-watches-`/mnt/transcripts/` design is replaced.** Per the planning conversation: agents that produce manuscripts must provide structured metadata, not drop files into directories.

A new schema captures the submission payload:

```
manuscript-submission@1.0.0  (inherits: task@1.0.0):
  Required (in addition to task fields):
    submission_kind:    String      — "new-manuscript" | "new-revision" | "fragment"
    title:              String      — Submitter-provided title
    source_format:      String      — "tex" | "typst"
    source_payload:     String      — Either the inline source content, OR a reference like "blob:sha256:..."

  Optional:
    parent_manuscript_ref: String   — If submission_kind != "new-manuscript", the manuscript this submits against
    parent_revision_ref:   String   — If submission_kind == "new-revision", the predecessor revision
    submitter_persona_id:  String   — Persona ID that authored this submission (per ADR-0013)
    origin_conversation_ref: String — ItemId of a conversation item or transcript anchor (see OQ-3)
    metadata_json:      String      — Free-form JSON sidecar with submitter-provided structure
    bibliography_payload: String    — Optional .bib content if the submitter has a bibliography
    similarity_hint:    String      — Submitter's belief about which manuscript this resembles (advisory only)

  FTS: title

  Typical edges:
    DependsOn  →  task               (inherited from task@1.0.0; downstream stages depend on this)
    OperatesOn →  manuscript         (if updating an existing manuscript)
```

**The submission interface has three entry points, all converging on the same handler:**

1. **HTTP route** on impel: `POST /api/journal/submissions` (JSON body matching the schema). Returns `{ task_id, status: "queued" }`. Consistent with the existing TaskOrchestrator routes on port 23124 (`apps/impel/Shared/Services/ImpelHTTPRouter.swift`).
2. **MCP tool** exposed by `packages/impress-mcp/`: `journal.submit_manuscript(kind, title, source_payload, ...)`. Agents call this directly.
3. **CLI command**: `impress journal submit --kind new-manuscript --title "..." --source-file path/to/draft.tex --metadata path/to/metadata.json`. For scripts and one-off backfill (see below).

All three paths construct a `manuscript-submission@1.0.0` item, store it in the impress-core item graph as a pending task, and return the task ID to the submitter. Scout receives the task per D7.

**Scout's job is no longer to find candidate `.tex` files.** Scout receives a structured submission and:

1. **Validates** the payload against the schema; if invalid, transitions task to `failed` with `OperationIntent::Anomaly`.
2. **Resolves source content**: if `source_payload` is `"blob:sha256:..."`, looks up the blob; if inline, hashes and stores in the blob tier per D4.
3. **Computes similarity** to existing manuscripts: title Jaccard via `crates/imbib-core/src/deduplication/orchestration.rs::title_jaccard_similarity` (threshold 0.85), then content cosine similarity via `EmbeddingService.shared` for confirmation. If `similarity_hint` is provided, the hint is checked against the computed result and the submitter is notified of any disagreement.
4. **Decides outcome**: new manuscript / new revision under existing / fragment under existing. The decision is encoded as a proposed action in a `revision-note@1.0.0` knowledge object (per ADR-0012 D41) with `verdict: "propose"`.
5. **Routes for confirmation**: emits an `ImpressNotification.submissionProposed` event (D9). The proposal appears in imbib's "Submissions" inbox UI (D8). Steward or the human accepts or rejects.

**On acceptance**, the Archivist takes over: compiles, snapshots, registers the revision. **On rejection**, the submission task is marked `cancelled` and the submitted source remains in the blob tier (referenced by the proposal item) but no manuscript or revision is created.

**One-off transcript backfill.** A separate CLI tool `impress-journal backfill --source ~/.claude/projects/{project-id}/` walks existing transcripts, extracts inline `.tex` blocks, synthesizes `manuscript-submission` items via the CLI route, and exits. This is **not the steady-state mechanism** — it runs once when a researcher starts using the journal, and again only if they want to import additional transcript collections. The PDR's continuous transcript-watcher concept is explicitly out of scope.

**Why structured submission and not directory watching:**

- Steady-state: agents that authored a manuscript know its title, kind, parent, and intended audience. They should declare this, not leave it to a downstream classifier.
- Backfill: a one-off CLI tool that reads existing transcripts is sustainable; a daemon polling forever is not.
- Provenance: the submission payload is a first-class item with author, intent, and origin reference. A directory watcher would have to reconstruct this from filesystem timestamps and content sniffing.

### D50. Persona-Action Contracts — The Pipeline

The journal pipeline is a sequence of stages, each bound to a persona per ADR-0013. Pipelines are not declarative items in this phase (per ADR-0005 D22 — spawn rules are Rust code in impel until Phase 4). The journal's pipeline is a Rust file in `apps/impel/Packages/CounselEngine/Sources/CounselEngine/Pipelines/JournalPipeline.swift`.

| Stage | Triggered by | Persona | Action | Autonomy gate |
|---|---|---|---|---|
| **Submission validation** | `manuscript-submission` task created | Scout | Validate, dedupe, propose outcome | Auto-act (Scout is bounded by schema validation; deterministic outcome) |
| **Snapshot** | Status transition or explicit user/Steward request | Archivist | Compile via imprint, hash, register revision | Auto-act if compile clean AND hash differs from current revision; propose-only otherwise |
| **Internal review** | User invokes "Request review" on a revision | Counsel | Produce `review/v1` knowledge object | Auto-run; the review is surfaced for human disposition |
| **Revision drafting** | Review attached with verdict "request-revision" or "approve-with-changes" | Artificer | Produce `revision-note/v1` with proposed `diff` | Propose-only (per ADR-0013 Artificer's `defaultAccess: .none` semantics) |
| **Periodic dedup sweep** | Scheduled (default daily, configurable) | Steward | Scan for near-duplicate manuscripts | Propose-only |

**Per-stage autonomy gates** override the ADR-0013 D36 default rule. Reasoning per stage:

- **Submission validation auto-act:** Scout's outcome is deterministic given the submission payload. Auto-act produces a *proposal*, not a manuscript or revision — there is no irreversible action.
- **Snapshot auto-act conditional:** A snapshot is irreversible (the revision is immutable). Auto-act is gated on the compile being clean (no errors in the log) AND the hash differing from the current revision. Both checks are mechanical. If either fails, snapshot proposes rather than acts.
- **Internal review auto-run:** The review is a knowledge object, not a state change. It can always be ignored. Auto-running gives the human a fresh review without latency; rejecting it costs nothing.
- **Revision drafting propose-only:** Per ADR-0013 Artificer is constrained. A diff applied to imprint source without human review can corrupt months of work.
- **Steward dedup propose-only:** Marking two manuscripts as duplicates is a research-judgment call. Always propose.

**Model bindings per stage** (per ADR-0013 D31, may be overridden via `model_override` on the `TaskRequest`):

- Scout: persona default (claude-sonnet, t=0.7) — the validation work is largely deterministic; the LLM is only invoked for edge cases like ambiguous title matching.
- Archivist: **no LLM call**. Snapshot is mechanical: invoke imprint compile, hash, register. Archivist's persona definition is used only for autonomy-policy reads.
- Counsel: persona default (claude-opus-4-7, t=0.5) — review quality justifies using the strongest reasoning model. No per-task override needed.
- Artificer: persona default (claude-sonnet, t=0.5) — diff drafting is craft work, not novel reasoning.
- Steward: persona default (claude-sonnet, t=0.4) — orchestration and routing.

**Pipeline stages emit `agent-run@1.0.0` items** per ADR-0005 D5, with `agent_id` set to the persona ID per ADR-0013 D37. The journal pipeline thus produces a complete provenance trace by construction.

### D51. Library Type — The Journal in imbib

A new `LibraryType.journal` value extends imbib's `LibraryModel` (`apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Domain/Library.swift:12–34`).

```swift
enum LibraryType: String, Codable {
    case bibliography  // existing default; library of papers
    case artifacts     // existing per Universal Research Capture
    case journal       // new — manuscripts + revisions + reviews
}
```

A Journal library hosts manuscripts (items with `schema = "manuscript"`), their revisions (queried via `HasVersion` edges), and the knowledge objects attached to them (queried via `Annotates` edges from the revisions back).

**Default smart collections** in a Journal library, defined as smart collections (per imbib's existing `SmartSearch` mechanism extended with status filters per OQ-1):

- **Drafts** — `status:draft OR status:internal-review`
- **Submitted** — `status:submitted`
- **In Revision** — `status:in-revision`
- **Published** — `status:published`
- **Archive** — `status:archived`
- **Submissions** (the inbox) — items with `schema:manuscript-submission AND state:pending`

Plus user-defined topic collections via the existing tag-query mechanism: `topic_tags:cosmology` etc.

**The Submissions inbox is special.** It is the UI surface for D6's submission proposal queue. Selecting a pending submission shows the proposed action (new manuscript / revision / fragment), the similarity scores, the source preview, and accept/reject buttons. Accept advances the submission task; reject cancels it.

### D52. Cross-App Events — New Names on `ImpressNotification`

The journal pipeline emits five new events on the `ImpressNotification` Darwin notification bus (`packages/ImpressKit/Sources/ImpressKit/ImpressNotification.swift:12–30`):

```swift
// Journal pipeline events (added)
public static let manuscriptSubmissionReceived = "manuscript-submission-received"
public static let manuscriptSubmissionProposed = "manuscript-submission-proposed"  // Scout has a recommendation
public static let manuscriptSnapshotCreated   = "manuscript-snapshot-created"
public static let manuscriptReviewCompleted   = "manuscript-review-completed"
public static let manuscriptStatusChanged     = "manuscript-status-changed"
```

All events use the existing `ImpressNotification.post(_:from:resourceIDs:)` API. Consumers:

- imbib subscribes to `manuscriptSubmissionProposed` to update the Submissions inbox badge.
- imbib subscribes to `manuscriptSnapshotCreated` and `manuscriptReviewCompleted` to refresh the manuscript detail view.
- impart (when wired) subscribes to `manuscriptStatusChanged` to surface lifecycle events in conversation streams.
- The journal pipeline itself subscribes to `documentSaved` (existing event) from imprint, filtering for manuscripts (`linkedImbibManuscriptID` present in the payload), to consider stable-churn snapshots per D5.

No payload extensions to `NotificationPayload` are needed; the existing `event/source/timestamp/resourceIDs` shape is sufficient.

### D53. Provenance and Reproducibility

Every revision must be reproducible from its provenance graph. This is the recursive acceptance test: given a `manuscript-revision`, a researcher can answer the following queries against the impress item store, all in under one second on a laptop-scale store (≤ 100k items):

1. **Source conversations:** `revision.derived_from.where(target.schema == 'conversation')` → the transcripts that contributed.
2. **Bibliography:** `revision.cites.collect(target)` → every cited bibliography entry.
3. **Figures:** `revision.visualizes.collect(target)` → every figure embedded.
4. **Reviews:** `revision.annotated_by.where(source.schema == 'review')` → every review of this revision.
5. **Predecessors:** `revision.supersedes.recursive` → the full revision chain back to v1.
6. **Operations:** `operations.where(target_id == revision.id OR target_id == revision.parent_manuscript_ref)` → every operation on this revision or its parent manuscript.
7. **Agent runs:** `revision.produced_by.collect(target)` ∪ `reviews.flat_map(r => r.produced_by)` → every agent invocation that touched this revision or its reviews.

These are queries over the existing item-graph schema. No new query layer is needed.

**RO-Crate export.** A "Reproduce this revision" action exports an [RO-Crate](https://www.researchobject.org/ro-crate/) bundle containing: source archive (from `source_archive_ref`), PDF (from `pdf_artifact_ref`), bibliography subset (cited entries only), figure source files (where available), and a `ro-crate-metadata.json` describing the provenance graph above. The export is implemented as a method on the manuscript detail view; no new schema is required.

**mbox export.** The existing `MboxExporter` in `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Mbox/MboxExporter.swift` is extended with `export(manuscriptIds:libraryId:to:)`. Each manuscript produces an mbox message with: subject = manuscript title; body = a markdown rendering of the revision history (one section per revision, summarizing snapshot tag, date, and key changes); attachments = one PDF per revision plus the most recent source archive. Reviews are inlined as quoted text in the body. The mbox file opens in Apple Mail with full revision timeline and attachments.

---

## Reconciliation with imbib ADR-021

This ADR was drafted three months after imbib's local **ADR-021 (Manuscript Tracking, Proposed 2026-01-19)** and was unaware of it. ADR-021 took the position that "manuscripts are not a separate entity — they are `CDPublication` entries representing papers the user is authoring, with additional metadata stored in `rawFields`." It defined `ManuscriptStatus`, `ManuscriptCollectionManager`, `ManuscriptContextMenuActions`, `ManuscriptCitationViews`, `ManuscriptMetadataKey`, and other support code (~2300 lines) under `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Manuscript/`. A parallel Rust scaffolding existed at `crates/impress-domain/src/manuscript.rs` (different field set again).

When this ADR's Phase 2 implementation began, the collision surfaced: ADR-021's "publication-with-metadata" identity is incompatible with this ADR's D1 ("manuscripts are first-class items with `schema = 'manuscript'`"). The two cannot coexist as identity claims for the same logical entity.

**Decision (confirmed by Tom 2026-05-05):** This ADR's identity model wins. ADR-021 is marked Superseded.

**Rationale.**

- ADR-021 was Proposed, not Accepted. Its model code had **zero production view consumers** (verified by repository grep across all of `apps/imbib/imbib/imbib/Views/` and downstream packages) — it shipped as scaffolding for a workflow that was never wired up.
- The journal pipeline already has 28 passing unit tests, three companion ADRs (0011/0012/0013), an Implementation Plan, the four schemas registered, the BlobStore actor, the submission API on three entry points (HTTP/MCP/CLI), and Scout's title-Jaccard triage. Reversing course would discard substantially more committed work than it would salvage.
- ADR-021's "manuscripts are part of your corpus" insight is preserved by other means: a manuscript can `Cites → bibliography-entry` per D1, so a manuscript still relates to the corpus through the standard edge graph. Smart collections that surface "published manuscripts alongside cited papers" remain expressible by querying both schemas in one view.
- Cross-app workflows (impart routes manuscript-related email, impel runs personas against manuscripts, imprint authors source bound to manuscripts) require manuscripts to be queryable in the unified workspace store. ADR-021's Core-Data-only model could not support this — the cross-app need is what ADR-0011 was designed to solve.

**What was deleted (clean slate per Tom's preference, 2026-05-05):**

- The 6 Swift files under `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Manuscript/`: `ManuscriptTypes.swift`, `ManuscriptCollections.swift`, `ManuscriptContextMenuActions.swift`, `ManuscriptCitationViews.swift`, `ImprintLaunchService.swift`, `CompiledPDFWatcher.swift`.
- `crates/impress-domain/src/manuscript.rs` and its `pub mod manuscript;` / `pub use manuscript::*;` lines in `lib.rs`.
- The empty `Manuscript/` directory.

The Phase 2 implementation reimplements imprint launch (a small wrapper around the existing `imprint://` URL scheme handler at `apps/imprint/Shared/Services/URLSchemeHandler.swift`) and revision-tag conventions (the `revision_tag` field on `manuscript-revision@1.0.0`) from scratch with no historical baggage.

**What's preserved from ADR-021's design intent.**

- The lifecycle vocabulary (drafting → submitted → under-review → revision → accepted → published) maps onto this ADR's status enum (`draft → internal-review → submitted → in-revision → published → archived`) with minor renames; the workflow is structurally the same.
- The version-tag convention (`submission-v1`, `revision-r1`, etc.) is captured in the `revision_tag` payload field of `manuscript-revision@1.0.0` per D2 — the journal pipeline accepts those tag strings unchanged.
- The "imprint integration via stable UUID" idea survives intact in D3's `Contains` edge with `kind: "imprint-source"` metadata containing the imprint document UUID.

## PDR Deviations

This ADR diverges from the original PDR in three substantive places. Each deviation is enumerated for explicit confirmation by the user.

### Deviation 1: Submission API replaces directory watching

**PDR §3.6 / §4 / §5.7** specified a Scout job watching `/mnt/transcripts/` and configurable directories, extracting `.tex` blocks, computing similarity, and proposing ingestion.

**ADR-0011 D6** replaces this with a structured submission interface (HTTP / MCP / CLI). Agents producing manuscripts must declare them with metadata; Scout receives validated submissions, not raw files. A separate CLI backfill tool addresses the one-off case of importing existing transcripts.

**Rationale:** Per the planning conversation with Tom, directory polling is unsustainable. The submission API is more sustainable, more agent-native (per Design Principle 3 in CLAUDE.md), and gives the system better metadata than filename heuristics could ever produce.

### Deviation 2: PDF blob tier extends an existing convention rather than introducing a new crate

**PDR OQ-1** floated `impress-blobstore` as a possible new crate.

**ADR-0011 D4** instead reuses the convention already documented in `crates/impress-core/src/schemas/manuscript_section.rs:11–15` (`~/.local/share/impress/content/{sha256}/`) and implements the tier as a small module in `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Files/BlobStore.swift`. The convention is now load-bearing for two distinct subsystems (large manuscript-section bodies and journal artifacts), justifying the existing convention without creating a new crate.

**Rationale:** Per Tom's plan-time decision: extend impress-core + apps; no new crate. The blob tier qualifies as "in-app extension" — roughly 200 lines of code, narrow surface area.

### Deviation 3: Scout role redefinition

**PDR §3.5 Table** assigned Scout the role "discover transcript .tex, propose ingestion." This is the directory-watcher role.

**ADR-0011 D7** redefines Scout as the **submission validation and routing** persona. Scout receives structured submissions (per D6), validates them, computes deduplication, and proposes outcomes. The validation work is bounded and largely deterministic; the LLM is only invoked for ambiguous similarity cases.

**Rationale:** Direct consequence of Deviation 1. Scout's behavioral configuration in ADR-0013 D33 (high risk tolerance, rapid working style) remains correct for the new role — exploratory work on an incoming submission is structurally similar to exploratory work on a discovered file.

---

## Consequences

### Positive

- The journal is fully composed over existing primitives: items, operations, schemas, tasks, knowledge objects, personas, content-addressed blobs, the cross-app event bus. No new core abstraction is introduced.
- Provenance is intrinsic. Every revision traces back to source conversations, citations, figures, reviews, and the agent runs that produced them, all queryable via the existing item-graph API.
- The submission API decouples manuscript ingestion from filesystem polling. Steady-state behavior is event-driven, not poll-driven, with backfill as an explicit one-off operation.
- imprint and imbib already share the bridge fields (`linkedImbibManuscriptID`, `linkedImbibLibraryID`); the journal completes the bridge by formalizing the `Contains` edge with `kind: "imprint-source"` metadata.
- Five built-in personas cover all journal stages without adding more (Artificer is the only new one, codified in ADR-0013).
- The PDF blob tier reifies a convention that was already latent in the codebase (`manuscript_section.rs`), so a future use case for content-addressed storage benefits from the same primitive.
- Reviews and revision notes as knowledge objects (ADR-0012) compose with episodic memory: future Counsel invocations consult past reviews of related manuscripts via standard graph queries.
- mbox export of manuscripts is portable: a researcher can drag the mbox into Apple Mail and see the full revision history without impress installed. This is the cold-tier, walk-away guarantee from ADR-0001.

### Negative

- The submission API is a new HTTP route, MCP tool, and CLI command — three implementations of the same interface. Each must be tested and documented. Adding a fourth (e.g., a Raycast extension) means a fourth implementation. A future `journal-submit` library function could collapse this, but adds an abstraction layer with no immediate use case.
- Revision immutability is enforced at the store boundary by validation, not by the schema or by the SQLite schema itself. A buggy caller could in principle write a `SetPayload` operation on a revision item; the store must reject it. This adds a special case to `apply_operation()`.
- The journal's autonomy gates (D7) are baked into Rust code in `JournalPipeline.swift`. Per ADR-0005 D22 this is correct for Phase 3, but it means changing autonomy policy requires a code change. A user wanting Counsel reviews to be propose-only rather than auto-run cannot do so without rebuilding the app.
- The blob garbage-collection policy (D4) requires Steward to walk the entire item graph periodically to identify unreferenced blobs. At small scale this is trivial; at large scale (multi-year, multi-thousand-revision archives) it may become slow. No measurement available yet.
- The Submissions inbox (D8) is a new UI surface in imbib. It must be designed, built, and maintained. The closest existing pattern is the artifact inbox; reuse where possible.
- Cross-app event payloads only carry resource IDs. A consumer of `manuscriptSubmissionProposed` must look up the proposal item from the impress-core store to find similarity scores and source preview. This is consistent with the existing event bus design but means the inbox UI must query on every event delivery.

### Mitigations

- The submission API's three implementations all delegate to a single Swift function `submitManuscript(_ payload: ManuscriptSubmission) async throws -> TaskID` in `CounselEngine`. The HTTP route, MCP tool, and CLI command are all thin wrappers. A test suite on the underlying function covers all three.
- Revision-immutability validation is one `if` statement in `apply_operation()`. The cost is negligible.
- Per-user autonomy customization is deferred to a follow-up ADR. In the meantime, propose-only mode is the safe default for any stage where uncertainty is high.
- Blob garbage collection is a Steward task, not a synchronous operation. It runs at low priority and can be paused entirely if performance is a concern.
- The Submissions inbox can be a simple list with accept/reject buttons in v1; richer UI (similarity-score visualization, side-by-side source preview) is incremental.

---

## Open Questions

1. **Conversation reference format.** D44 mentions `DerivedFrom → conversation` edges. The `conversation` item type is not yet defined in `crates/impress-core/src/schemas/`. The closest existing schema is `chat-message@1.0.0`, but a conversation is a thread, not a message. A future ADR (likely a small one) should define `conversation@1.0.0` as a parent item type with `Contains → chat-message` edges. Until then, the journal can reference Claude Code session JSONL files by path in the manuscript-submission's `origin_conversation_ref` as an opaque string.

2. **How does a user "request a review"?** D7 lists "user invokes 'Request review'" as the trigger for the Counsel stage. The UI affordance is unspecified. Likely a button in the manuscript detail view or a command-palette command. Decide during implementation.

3. **How does Artificer's diff get applied to imprint?** D7 says Artificer produces a `revision-note/v1` with a unified-diff `body`. The journal does not auto-apply the diff. What is the UI for a human to review the diff and accept it? Likely a side-by-side diff viewer in imbib (the manuscript detail's review pane) with an "Apply to imprint source" button that opens imprint with the patched source loaded. This is a significant UI design task; flagged for Phase 2 implementation.

4. **Smart-collection status filter syntax.** D8 describes status-filtered smart collections (`status:draft`). The current `SmartSearchService` query language does not support this. Either (a) extend the query language to recognize `status:` and translate it to a payload-field filter, or (b) introduce status as a tag (every manuscript carries a `status/draft` tag) and reuse the existing tag-filter mechanism. Decide before D8 implementation.

5. **Mbox round-trip fidelity.** D10 specifies that mbox export round-trips: re-importing the mbox into a fresh impress installation reconstructs manuscripts, revisions, and inlined reviews. The mbox import path does not exist yet (only export). Without import, "fully portable" is a one-way promise. A future ADR may add `MboxImporter`.

6. **Multi-author manuscripts.** PDR OQ-6 deferred multi-author to a future ADR. The schema in D44 has `authors: StringArray` which permits multiple names but does not model collaborative editing semantics. When real multi-author work happens (Tom + Cathy on the same manuscript), the imprint CRDT layer plus impart messaging plus the journal's shared item store must compose into a coherent model. Out of scope here; flagged as a major future ADR.

7. **Schema versioning strictness.** ADR-0004 D17 says items should store `name@1.0.0` in their `schema` field, but actual code stores bare names. The journal schemas in D1, D2 register as bare names (`"manuscript"`, `"manuscript-revision"`, `"manuscript-submission"`) for consistency with existing schemas. When ADR-0004 OQ-2 is resolved (the version-suffix wiring), all journal schemas migrate together.

8. **Steward dedup sweep cost.** D7's periodic dedup sweep walks all manuscripts, computes pairwise similarity, and proposes merges for high-scoring pairs. At 100 manuscripts this is 4,950 pairs — trivial. At 10,000 manuscripts it is 50 million pairs — not trivial. Bound the sweep to recently-modified manuscripts (default: last 90 days), with a full sweep as an explicit user-triggered action.

9. **Artifact garbage collection vs. revision immutability.** D4 garbage-collects unreferenced blobs after 90 days. A revision references its source archive and PDF. If a manuscript is deleted, the revisions are orphaned — but per D2 revisions are immutable. The cascade rule: deleting a manuscript also deletes all its revisions (which then frees their blobs). This is consistent with ADR-0003's `op_target_id ON DELETE CASCADE`. Specify this explicitly in the implementation.

10. **Compile pipeline ownership.** D7's snapshot stage invokes "imprint compile" but the compile entry point is not exposed to impel. imprint has a compile pipeline (referenced by the `.compileDocument` notification) but no documented API for triggering compile from outside. The journal needs imprint to expose `compileDocument(id) async throws -> CompileResult` either as an HTTP route on imprint or as a function in `ImprintCore`. Decide which path during Phase 1 implementation.

---

## Tests / Acceptance

The recursive acceptance test from PDR §9.3: this ADR (and ADR-0012 and ADR-0013) becomes the journal's first manuscript once Phase 0 ships. The submission flow, snapshot mechanism, and provenance trace are exercised by the journal pipeline ingesting its own design documents. If the system can store, snapshot, review, and export ADR-0011 itself, the architecture is validated end-to-end.

Acceptance criteria for the journal MVP (functional):

- A `manuscript-submission@1.0.0` POSTed to `/api/journal/submissions` produces a Submissions inbox entry within 60 seconds.
- Accepting a submission for `kind: new-manuscript` creates a `manuscript@1.0.0` and `manuscript-revision@1.0.0` pair, with the source archive and PDF in the blob tier and `Contains` edge to the imprint document handle.
- A status transition from `draft` to `submitted` triggers an Archivist snapshot that, given a clean compile, registers a new revision with `revision_tag: "submitted"`.
- A user-initiated "Request review" produces a `review/v1` item attached to the current revision via `Annotates`, queryable in both the manuscript detail view and the revision detail view.
- The full provenance graph for any revision (per D10) is queryable in under a second on a laptop-scale store.
- mbox export produces a file that opens in Apple Mail with revision timeline and per-revision PDF attachments.
- All operations work fully offline.

---

## References

### Code (existing, this ADR composes over)

- `crates/impress-core/src/item.rs` — `Item`, `ItemId`, `ActorKind`, `Value`
- `crates/impress-core/src/operation.rs` — `OperationType::SetPayload`, `AddTag`, `AddReference`; `OperationIntent`
- `crates/impress-core/src/reference.rs` — `EdgeType` taxonomy (no new types added)
- `crates/impress-core/src/schema.rs` — `Schema`, `FieldDef`, `FieldType`
- `crates/impress-core/src/registry.rs` — `SchemaRegistry::register`
- `crates/impress-core/src/schemas/mod.rs` — `register_core_schemas`
- `crates/impress-core/src/schemas/artifact.rs` — `general_schema()` reused for manuscript blobs
- `crates/impress-core/src/schemas/manuscript_section.rs` — content-addressed convention precedent
- `crates/impress-core/src/schemas/task.rs` — `task@1.0.0` (parent for `manuscript-submission`)
- `crates/imbib-core/src/deduplication/orchestration.rs` — `title_jaccard_similarity`, `DeduplicationConfig`
- `crates/imbib-core/src/search/semantic.rs` — `cosine_similarity`, ANN index
- `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Domain/Library.swift` — `LibraryModel` (extended with `LibraryType.journal`)
- `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Files/PDFManager.swift` — `computeSHA256`, file storage layout (extended with blob tier)
- `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Mbox/MboxExporter.swift` — `export()` (extended with manuscript export)
- `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Search/EmbeddingService.swift` — `EmbeddingService.shared` (used for semantic dedup in D6)
- `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/SmartSearch/SmartSearchService.swift` — query language (extended with status filters per OQ-4)
- `apps/imprint/Shared/Models/ImprintDocument.swift` — `linkedImbibManuscriptID`, `linkedImbibLibraryID`, `imprintDocumentDidSave` (consumed by D9)
- `apps/imprint/Shared/Services/URLSchemeHandler.swift` — `imprint://open?imbibManuscript=...` (consumed by D3)
- `apps/impel/Packages/CounselEngine/Sources/CounselEngine/TaskOrchestrator.swift` — `TaskRequest`, `TaskResult`, agent loop
- `apps/impel/Shared/Services/ImpelHTTPRouter.swift` — HTTP router (extended with `/api/journal/submissions`)
- `packages/ImpressKit/Sources/ImpressKit/ImpressNotification.swift` — Darwin notification bus (extended with five journal events per D9)
- `packages/impress-mcp/` — MCP server (extended with `journal.submit_manuscript` tool)

### ADRs (cited)

- ADR-0001: Unified Item Architecture
- ADR-0002: Operations as Overlay Items (superseded by ADR-0003; cited for historical context)
- ADR-0003: Operations and Provenance
- ADR-0004: Schema Registry and Type System
- ADR-0005: Task Infrastructure and Agent Integration
- ADR-0012: Knowledge Objects and Episodic Memory (companion)
- ADR-0013: Multi-Persona Agents (companion)
- impel ADR-001: Stigmergic Coordination

### External

- [RO-Crate](https://www.researchobject.org/ro-crate/) — Research Object Crate specification (D10 export format)
- RFC 4155 — mbox format specification (D10 cold-tier export)
