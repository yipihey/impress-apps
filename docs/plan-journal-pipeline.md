# Implementation Plan — The impress Journal Pipeline

**Status:** Draft for review
**Date:** 2026-05-05
**Author:** Tom Abel (with implementation planning via Claude)
**Implements:** ADR-0011 (The impress Journal), ADR-0012 (Knowledge Objects), ADR-0013 (Multi-Persona Agents)
**Companion to:** PDR §9.2 — this is the Implementation Plan deliverable
**Status of dependencies:** ADR-0011, ADR-0012, ADR-0013 must be Accepted before any code in Phase 0 lands. Per the PDR, no implementation begins before these are reviewed.

---

## How to read this plan

Sections 1–3 (decision-to-code mapping, new schemas, new code surface) are reference material — the agent picking up implementation work consults them but does not work through them linearly. Sections 4–8 (phasing, dependencies, fixtures, effort, risks) are the working plan: a contributor reads them top-to-bottom, claims a phase, executes.

Every entry that names a file path or function has been verified to exist (or be a deliberate new file) at the time of writing. If a reference no longer matches the codebase, the implementation has drifted; pause and re-grep before assuming.

---

## 1. ADR-0011 D-point → code-seam map

Each D-point in ADR-0011 maps to a specific code location. New files are marked `[NEW]`; everything else is an extension of existing code.

| D | Decision | Files |
|---|---|---|
| **D44** | `manuscript@1.0.0` schema | `crates/impress-core/src/schemas/manuscript.rs` `[NEW]`; `crates/impress-core/src/schemas/mod.rs` (register) |
| **D45** | `manuscript-revision@1.0.0` schema + immutability | `crates/impress-core/src/schemas/manuscript_revision.rs` `[NEW]`; `crates/impress-core/src/sqlite_store.rs` `apply_operation()` (immutability check) |
| **D46** | `imprint:source` Contains-edge bridge | `apps/imprint/Shared/Models/ImprintDocument.swift` (already has `linkedImbibManuscriptID`); `apps/imprint/Shared/Services/URLSchemeHandler.swift` (existing); `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Manuscript/ManuscriptBridge.swift` `[NEW]` |
| **D47** | PDF blob tier (content-addressed) | `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Files/BlobStore.swift` `[NEW]`; integrates with existing `PDFManager.computeSHA256` |
| **D48** | Snapshot policy + idempotency | `apps/impel/Packages/CounselEngine/Sources/CounselEngine/Pipelines/JournalSnapshotJob.swift` `[NEW]` |
| **D49** | `manuscript-submission@1.0.0` + HTTP/MCP/CLI submission API | `crates/impress-core/src/schemas/manuscript_submission.rs` `[NEW]`; `apps/impel/Shared/Services/ImpelHTTPRouter.swift` (extend with `/api/journal/submissions`); `packages/impress-mcp/src/tools/journal.rs` `[NEW]`; `apps/impel/CLI/journal-submit.swift` `[NEW]` |
| **D50** | Pipeline stages + persona contracts | `apps/impel/Packages/CounselEngine/Sources/CounselEngine/Pipelines/JournalPipeline.swift` `[NEW]`; `apps/impel/Packages/ImpelCore/Sources/ImpelCore/Persona.swift` (Artificer added; existing `mockPersonas()` extended) |
| **D51** | Journal Library type + collections | `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Domain/Library.swift` (extend `LibraryType` enum); `apps/imbib/imbib/imbib/Views/TabSidebar/ImbibSidebarViewModel.swift` (Submissions inbox section); `apps/imbib/imbib/imbib/Views/Detail/ManuscriptDetailView.swift` `[NEW]` |
| **D52** | Cross-app events | `packages/ImpressKit/Sources/ImpressKit/ImpressNotification.swift` (add 5 event names); subscription wired in `JournalPipeline.swift` and `ImbibSidebarViewModel.swift` |
| **D53** | Provenance + RO-Crate + mbox export | `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Mbox/MboxExporter.swift` (extend); `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Export/ROCrateExporter.swift` `[NEW]` |

---

## 2. New schemas (concrete contents)

These are the four new schemas this plan adds to `crates/impress-core/src/schemas/`. Each is registered in `register_core_schemas()` after its dependencies. The order: `manuscript_submission` (depends on `task`) → `manuscript` → `manuscript_revision` (depends on `manuscript`) → `review`, `revision_note` (knowledge objects per ADR-0012, registered in a new `knowledge_objects` module).

### 2.1 `crates/impress-core/src/schemas/manuscript.rs` (NEW)

```rust
use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

pub fn manuscript_schema() -> Schema {
    Schema {
        id: "manuscript".into(),
        name: "Manuscript".into(),
        version: "1.0.0".into(),
        fields: vec![
            field("title", FieldType::String, true),
            field("status", FieldType::String, true),
            field("current_revision_ref", FieldType::String, true),
            field("authors", FieldType::StringArray, false),
            field("journal_target", FieldType::String, false),
            field("submission_id", FieldType::String, false),
            field("topic_tags", FieldType::StringArray, false),
            field("notes", FieldType::String, false),
        ],
        expected_edges: vec![
            EdgeType::HasVersion,
            EdgeType::Contains,
            EdgeType::Cites,
            EdgeType::Visualizes,
            EdgeType::Annotates,
            EdgeType::DerivedFrom,
        ],
        inherits: None,
    }
}

pub fn register_manuscript_schema(registry: &mut SchemaRegistry) {
    registry.register(manuscript_schema()).expect("manuscript schema registration");
}
```

### 2.2 `crates/impress-core/src/schemas/manuscript_revision.rs` (NEW)

```rust
pub fn manuscript_revision_schema() -> Schema {
    Schema {
        id: "manuscript-revision".into(),
        name: "Manuscript Revision".into(),
        version: "1.0.0".into(),
        fields: vec![
            field("parent_manuscript_ref", FieldType::String, true),
            field("revision_tag", FieldType::String, true),
            field("content_hash", FieldType::String, true),
            field("pdf_artifact_ref", FieldType::String, true),
            field("source_archive_ref", FieldType::String, true),
            field("predecessor_revision_ref", FieldType::String, false),
            field("compile_log_ref", FieldType::String, false),
            field("snapshot_reason", FieldType::String, false),
            field("abstract", FieldType::String, false),
            field("word_count", FieldType::Int, false),
        ],
        expected_edges: vec![
            EdgeType::IsPartOf,
            EdgeType::Supersedes,
            EdgeType::Attaches,
            EdgeType::Cites,
            EdgeType::Visualizes,
            EdgeType::DerivedFrom,
        ],
        inherits: None,
    }
}
```

**Immutability enforcement.** `crates/impress-core/src/sqlite_store.rs::apply_operation()` adds a check: if `target` item has `schema == "manuscript-revision"` and `op_type` is one of `SetPayload`, `RemovePayload`, `PatchPayload`, return `StoreError::InvariantViolation("revision items are immutable")`. AddTag, SetRead, SetStarred, AddReference remain permitted (these are envelope-level operations that do not modify the revision's payload).

### 2.3 `crates/impress-core/src/schemas/manuscript_submission.rs` (NEW)

Inherits from `task@1.0.0` per ADR-0011 D6.

```rust
pub fn manuscript_submission_schema() -> Schema {
    Schema {
        id: "manuscript-submission".into(),
        name: "Manuscript Submission".into(),
        version: "1.0.0".into(),
        fields: vec![
            field("submission_kind", FieldType::String, true),
            field("title", FieldType::String, true),
            field("source_format", FieldType::String, true),
            field("source_payload", FieldType::String, true),
            field("parent_manuscript_ref", FieldType::String, false),
            field("parent_revision_ref", FieldType::String, false),
            field("submitter_persona_id", FieldType::String, false),
            field("origin_conversation_ref", FieldType::String, false),
            field("metadata_json", FieldType::String, false),
            field("bibliography_payload", FieldType::String, false),
            field("similarity_hint", FieldType::String, false),
        ],
        expected_edges: vec![EdgeType::DependsOn, EdgeType::OperatesOn],
        inherits: Some("task".into()),
    }
}
```

### 2.4 `crates/impress-core/src/schemas/knowledge_objects.rs` (NEW)

Hosts `review@1.0.0` and `revision-note@1.0.0` per ADR-0012 D40, D41.

```rust
pub fn review_schema() -> Schema { /* per ADR-0012 D40 */ }
pub fn revision_note_schema() -> Schema { /* per ADR-0012 D41 */ }
pub fn register_knowledge_object_schemas(registry: &mut SchemaRegistry) {
    registry.register(review_schema()).expect("review schema registration");
    registry.register(revision_note_schema()).expect("revision-note schema registration");
}
```

### 2.5 `mod.rs` registration order

```rust
// crates/impress-core/src/schemas/mod.rs (extension)
pub mod manuscript;
pub mod manuscript_revision;
pub mod manuscript_submission;
pub mod knowledge_objects;

pub fn register_core_schemas(registry: &mut crate::registry::SchemaRegistry) {
    register_bibliography_schemas(registry);
    register_communication_schemas(registry);
    register_task_schemas(registry);                // task must precede manuscript_submission
    register_document_schemas(registry);
    register_git_project_schemas(registry);
    register_artifact_schemas(registry);
    register_operation_schema(registry);
    register_implore_schemas(registry);
    register_imprint_schemas(registry);             // manuscript-section
    register_citation_usage_schema(registry);
    // NEW (in dependency order):
    register_manuscript_schema(registry);
    register_manuscript_revision_schema(registry);
    register_manuscript_submission_schema(registry);
    register_knowledge_object_schemas(registry);
}
```

---

## 3. New code surface (Swift)

### 3.1 BlobStore (D47)

`apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Files/BlobStore.swift` `[NEW]`. Actor with three methods:

```swift
public actor BlobStore {
    public static let shared = BlobStore()
    private let rootURL: URL  // ~/.local/share/impress/content/

    public func store(data: Data, ext: String) async throws -> (sha256: String, url: URL) { … }
    public func locate(sha256: String, ext: String) -> URL? { … }
    public func unreferencedSweep(referencedHashes: Set<String>) async throws -> [URL] { … }
}
```

Reuses `PDFManager.computeSHA256` for hash computation. ~200 lines. Tests use a temp directory injected via `init(rootURL:)`.

### 3.2 ManuscriptBridge (D46)

`apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Manuscript/ManuscriptBridge.swift` `[NEW]`. Actor managing the `Contains` edge with `kind: "imprint-source"` metadata. Public surface:

```swift
public actor ManuscriptBridge {
    public static let shared = ManuscriptBridge()
    public func attachSource(manuscriptID: UUID, documentUUID: UUID, libraryUUID: String, packagePath: URL?) async throws
    public func resolveSource(manuscriptID: UUID) async throws -> ManuscriptSourceRef?
    public func openInImprint(manuscriptID: UUID) async throws  // calls existing imprint:// URL
}
```

Uses `RustStoreAdapter.shared` to write/read the `Contains` edge with metadata.

### 3.3 JournalPipeline + JournalSnapshotJob (D48, D50)

`apps/impel/Packages/CounselEngine/Sources/CounselEngine/Pipelines/JournalPipeline.swift` `[NEW]` (~400 lines). Hosts the five-stage pipeline per ADR-0011 D7. Subscribes to `ImpressNotification.documentSaved`, `manuscriptSubmissionReceived`, manuscript status transitions; dispatches to per-stage handlers.

`JournalSnapshotJob.swift` `[NEW]` (~200 lines): the Archivist worker. Compiles via imprint, hashes, registers revision via `RustStoreAdapter`. Idempotent (per ADR-0011 D5: hash check skips if unchanged).

### 3.4 ManuscriptDetailView + Submissions inbox (D51)

`apps/imbib/imbib/imbib/Views/Detail/ManuscriptDetailView.swift` `[NEW]` (~500 lines). Tabs: Overview (current revision PDF), Revisions (timeline), Reviews (knowledge objects), Provenance (operation log + linked items). Reuses `ArtifactDetailView` patterns where applicable.

`apps/imbib/imbib/imbib/Views/Detail/SubmissionsInboxView.swift` `[NEW]` (~300 lines). The pending-submission queue per ADR-0011 D6. Each row shows similarity scores, source preview (first 40 lines of `.tex`), proposed action, accept/reject buttons.

### 3.5 ROCrateExporter (D53)

`apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Export/ROCrateExporter.swift` `[NEW]` (~250 lines). Walks revision provenance graph, gathers source archive + PDF + cited bibliography subset + figure source files, writes `ro-crate-metadata.json` per the [RO-Crate 1.1 spec](https://www.researchobject.org/ro-crate/1.1/).

### 3.6 Submission API (D49) — three entry points

| Entry | File | Contents |
|---|---|---|
| HTTP | `apps/impel/Shared/Services/ImpelHTTPRouter.swift` (extend) | `POST /api/journal/submissions` route handler; thin wrapper over `submitManuscript()` |
| MCP | `packages/impress-mcp/src/tools/journal.rs` `[NEW]` | `journal.submit_manuscript` tool definition; calls impel HTTP route internally |
| CLI | `apps/impel/CLI/journal-submit.swift` `[NEW]` | Command-line tool; same wrapper |
| **Core** | `apps/impel/Packages/CounselEngine/Sources/CounselEngine/JournalSubmission.swift` `[NEW]` | `func submitManuscript(_ payload: ManuscriptSubmission) async throws -> TaskID` — the function all three entries call |

### 3.7 Backfill CLI

`apps/impel/CLI/journal-backfill.swift` `[NEW]` (~150 lines). Walks `~/.claude/projects/{project-id}/`, parses JSONL, extracts `.tex` blocks via regex, calls `submitManuscript()` for each. One-off tool; not a daemon. Per ADR-0011 D6 explicitly distinguished from steady-state submission.

---

## 4. Phasing (diff against PDR §8)

The PDR proposed six phases (0–5). After ADR-0011's redesign — notably the structured submission API replacing the directory watcher — the phasing collapses and reorders. The proposed phasing:

| # | Phase | Duration | What | Why this order |
|---|---|---|---|---|
| **0** | Schemas + blob tier | 1 sprint | Four new schemas + revision immutability + `BlobStore` actor + tests | All later phases depend on these primitives. Pure-additive; cannot break existing code. |
| **1** | Submission API + Scout | 1.5 sprints | `JournalSubmission` core function; HTTP/MCP/CLI entries; Scout validation logic; backfill CLI; submissions stored as `manuscript-submission` items (no UI yet) | Earliest end-to-end demonstration: a `curl` command produces a stored submission with similarity scores. Validates the redesigned ingestion model before UI cost is sunk. |
| **2** | imbib Journal library + manuscript creation flow | 2 sprints | `LibraryType.journal`, sidebar wiring, `ManuscriptDetailView` shell, `ManuscriptBridge`, `SubmissionsInboxView` (accept/reject only, no rich preview yet), manual manuscript creation | First user-visible surface. Manuscripts can be created and viewed; submissions can be triaged. |
| **3** | Snapshot pipeline + status lifecycle | 1.5 sprints | Archivist `JournalSnapshotJob`; status transition operations; cross-app events (D52); `imprintDocumentDidSave` → snapshot trigger; revision PDFs visible in detail view | The first persona pipeline runs end-to-end. Status transitions become observable in imbib without imprint integration changes. |
| **4** | Counsel review + Artificer revision | 2 sprints | Counsel structured-output adapter (Apple Intelligence `@Generable` precedent); `review/v1` rendering in detail view; Artificer diff proposal; diff viewer + "Apply to imprint source" button | Knowledge objects in action. Per-task model overrides land here. |
| **5** | Steward dedup + RO-Crate + mbox export + backfill polish | 1.5 sprints | Steward periodic sweep; `ROCrateExporter`; manuscript mbox extension; backfill CLI hardening; documentation | Closes out PDR FR-PR3, FR-IB6, FR-DOC4 (recursive ingestion of the ADRs themselves). |

**Total: ~9.5 sprints** (estimate, see §7 for assumptions).

**Diff against PDR §8:**

- PDR Phase 3 was "transcript ingestion" — replaced and folded into Phase 1 (submission API) plus a one-off backfill in Phase 5.
- PDR Phase 4 (implement/implore reference graph) — deferred to a future plan; FR-IM1 and FR-IM2 are not in this MVP.
- PDR Phase 5 (archive/mbox/RO-Crate) — moved earlier (combined with Steward dedup) to land before any external use of the journal.
- New: explicit Phase 1 for the submission API as standalone deliverable. The PDR did not separate ingestion from UI; doing so lets us validate the API independently.

---

## 5. PDR FR/NFR coverage matrix

Every PDR functional and non-functional requirement traced to its phase. FRs that the PDR or ADR-0011 explicitly removed are marked **n/a (replaced by …)**.

### Functional requirements

| FR | Description (abbreviated) | Phase | Code seam |
|---|---|---|---|
| FR-S1 | manuscript/v1 schema | 0 | §2.1 |
| FR-S2 | manuscript-revision/v1 schema | 0 | §2.2 |
| FR-S3 | review/v1, revision-note/v1 | 0 | §2.4 (per ADR-0012) |
| FR-S4 | ingestion-proposal/v1 | n/a | Replaced by manuscript-submission/v1 (§2.3) per ADR-0011 D6 |
| FR-ST1 | Content-addressed PDF tier | 0 | §3.1 BlobStore |
| FR-ST2 | Source archive snapshots | 0 | BlobStore stores `.tar.zst`; snapshot job in Phase 3 produces them |
| FR-ST3 | Revisions immutable | 0 | §2.2 immutability check in `apply_operation()` |
| FR-ST4 | Cold-tier mbox archive | 5 | §3.5 mbox extension |
| FR-IB1 | Journal library + collections | 2 | §3.4 + `LibraryType.journal` extension |
| FR-IB2 | Manuscript detail view (PDF + sidebar + provenance) | 2 (shell), 3 (PDF), 4 (reviews), 5 (RO-Crate button) | §3.4 ManuscriptDetailView |
| FR-IB3 | Open in imprint action | 2 | §3.2 ManuscriptBridge.openInImprint |
| FR-IB4 | Compare revisions view | 4 | Side-by-side diff using existing diff infrastructure or third-party (see §6) |
| FR-IB5 | Search includes manuscript content | 2 | `PDFSearchService.search` extended to receive manuscript revision PDF URLs |
| FR-IB6 | Mbox export with manuscript attachments | 5 | `MboxExporter.export(manuscriptIds:libraryId:to:)` extension |
| FR-IP1 | imprint loads on imprint:source ref | 2 | Existing URL scheme; ManuscriptBridge resolves the document UUID |
| FR-IP2 | imprint emits lifecycle events | 3 | imprint extends `imprintDocumentDidSave` to also post `ImpressNotification.documentSaved` Darwin notification with manuscriptID; cross-app per D52 |
| FR-IP3 | Compile output → blob tier | 3 | Snapshot job invokes imprint compile (see §6 OQ on compile API), pushes results to BlobStore |
| FR-IP4 | Reviews + revisions surfaced in imprint | 4 | imprint subscribes to `manuscriptReviewCompleted`; renders inline panel |
| FR-IL1 | Journal pipeline policy bundle | 3 | §3.3 JournalPipeline.swift |
| FR-IL2 | Scout submission receiver | 1 | §3.6 + Scout logic in JournalPipeline |
| FR-IL3 | Archivist snapshot job | 3 | §3.3 JournalSnapshotJob.swift |
| FR-IL4 | Counsel review with structured output | 4 | Reuses Apple Intelligence `@Generable` precedent in imbib RAGChatViewModel; or post-process Anthropic SDK response into `review/v1` payload |
| FR-IL5 | Artificer diff proposal | 4 | New executor; output is `revision-note/v1` |
| FR-IL6 | Steward dedup sweep | 5 | Steward executor + scheduled task |
| FR-IM1 | implement code-commit linkage | **deferred** | Out of MVP per §4 phasing diff |
| FR-IM2 | implore figure stale indicator | **deferred** | Out of MVP per §4 phasing diff |
| FR-TW1–5 | Transcript watcher | n/a | All replaced by submission API per ADR-0011 D6 |
| FR-PR1 | Revision → conversation refs | 1 | submission payload's `origin_conversation_ref` becomes `DerivedFrom` edge on the revision |
| FR-PR2 | Persona attribution on operations | 3 | Operations created by JournalPipeline carry `author = persona_id` per ADR-0013 D37 |
| FR-PR3 | RO-Crate "Reproduce this revision" | 5 | §3.5 ROCrateExporter |
| FR-DOC1 | ADR-0006 (now ADR-0011) | **done** | `docs/ADR-0011-impress-journal.md` |
| FR-DOC2 | Implementation Plan | **this document** | — |
| FR-DOC3 | Companion ADRs | **done** | ADR-0012, ADR-0013 |
| FR-DOC4 | ADRs ingested into journal | 5 | First test of backfill CLI on `docs/ADR-001{1,2,3}*.md` |

### Non-functional requirements

| NFR | Description | Verification |
|---|---|---|
| NFR-1 | Local-first; offline-complete | Phase 0 `cargo test` runs offline; Phase 3+ end-to-end test runs with network disabled (verify in CI) |
| NFR-2 | No third-party AI without explicit policy | Per ADR-0013 D32 (tool policies) and ADR-0011 D7 (per-stage autonomy gates); enforced by `Persona.canUse()` checks in CounselToolRegistry |
| NFR-3 | Idempotent snapshots | ADR-0011 D5: hash check skips no-op; tested in Phase 3 |
| NFR-4 | Library responsive at 10⁴ manuscripts, 10⁵ revisions | Bench harness in §7; SQL EXPLAIN over manuscript queries; FTS index audit |
| NFR-5 | Mbox/RO-Crate round-trip | Phase 5 acceptance test: export → re-import (mbox importer is OOS for this plan, but RO-Crate is single-direction publishable) |

---

## 6. External dependencies

The vast majority of this plan reuses existing dependencies. Only one new third-party crate or library is needed:

| Dependency | Purpose | Where | Notes |
|---|---|---|---|
| `zstd` (Rust) | `.tar.zst` source archive compression | `crates/imbib-core` Cargo.toml | Already used elsewhere in the workspace; no new add. Verify before assuming. |
| `tar` (Rust) | Archive packaging | same | As above; verify. |
| `walkdir` (Rust) | Backfill CLI directory walk | `apps/impel/CLI/` | Standard; commonly used. |
| Apple `MDQuery` / Spotlight | Search extension to manuscript PDFs | `PDFSearchService` extension | macOS-native; no third-party. |
| RO-Crate JSON-LD writer | RO-Crate metadata generation | `ROCrateExporter` | Hand-rolled JSON encoding (the spec is small enough to not warrant a dependency); ~50 lines. |

**No new Rust crates are introduced for ML/embeddings** — the existing `EmbeddingService` and `crates/imbib-core/src/search/semantic.rs` cover similarity needs (per ADR-0011 D6).

**No new Swift packages.** The journal adds modules to existing packages (`PublicationManagerCore`, `CounselEngine`, `ImpressKit`).

---

## 7. Test fixtures and verification

### Fixture set (committed to `crates/impress-core/tests/fixtures/journal/`)

| Fixture | Used for |
|---|---|
| `manuscript-empty.json` | Bare manuscript item, no revisions; status=draft |
| `manuscript-with-2-revisions.json` | Manuscript + revision-v1 + revision-submitted, with PDF blobs at known hashes |
| `submission-new-manuscript.json` | A `manuscript-submission` for a new manuscript |
| `submission-new-revision.json` | A submission targeting an existing manuscript |
| `submission-fragment.json` | A submission with similarity ≥ 0.9 to existing manuscript (Scout should propose fragment) |
| `review-counsel-approve-with-changes.json` | A `review/v1` knowledge object authored by Counsel |
| `revision-note-artificer-propose.json` | A `revision-note/v1` with diff |
| `transcript-jsonl-sample.jsonl` | Two `.tex` blocks in a synthetic Claude session for backfill CLI test |

### Per-phase tests

**Phase 0:**
- `cargo test -p impress-core schemas::manuscript` — all four new schemas register without panic.
- `cargo test -p impress-core sqlite_store::revision_immutability` — `apply_operation(SetPayload)` on a revision item returns `InvariantViolation`.
- `cargo test -p imbib-core blobstore::round_trip` — store + retrieve by hash.

**Phase 1:**
- `curl -X POST localhost:23124/api/journal/submissions -d @submission-new-manuscript.json` returns `{"task_id": "...", "status": "queued"}` within 100ms.
- Subsequent `GET /api/tasks/{id}` shows the submission stored as a `manuscript-submission` item.
- `journal-backfill ~/.claude/projects/{test-project}/` produces N submissions for N transcripts.

**Phase 2:**
- imbib launches, Journal library appears in sidebar.
- Creating a manuscript via `RustStoreAdapter` makes it visible in the Drafts smart collection within one frame.
- "Open in imprint" launches imprint with the document loaded.

**Phase 3:**
- A status transition from `draft` to `submitted` triggers Archivist; a new revision item appears within 5 seconds (compile-dependent).
- The same transition repeated produces no new revision (idempotency).
- `ImpressNotification.observe(manuscriptSnapshotCreated, …)` fires exactly once.

**Phase 4:**
- Counsel review: invoking "Request review" on a revision produces a `review/v1` item attached via `Annotates` within 30 seconds (model-dependent).
- The review's `verdict` is one of the four allowed values.
- Artificer revision: a review with `verdict: "request-revision"` produces a `revision-note/v1` with non-empty `diff`.

**Phase 5:**
- Steward sweep with two manuscripts having title Jaccard > 0.85 produces a propose-merge revision-note.
- RO-Crate export of a manuscript-revision produces a directory with `ro-crate-metadata.json`, the source `.tar.zst`, the PDF, and a bibliography subset.
- mbox export of a manuscript opens in Apple Mail with a message-per-revision.

### NFR-4 bench harness

`crates/imbib-core/benches/journal_query.rs` `[NEW]` — Criterion benchmark. Generates 10,000 manuscript items + 100,000 revision items in a temp store, then measures:

- List of all `status:draft` manuscripts (target: < 10ms p99)
- Provenance graph for one revision (target: < 1s p99)
- Submissions inbox query (`schema = 'manuscript-submission' AND state = 'pending'`) (target: < 5ms p99)

Runs in CI on any change to indexing or query layers.

---

## 8. Effort estimates and risk callouts

Estimates in **agent-days** (one focused session of ~6 hours of effective work). Multiplier for human time depends on context-switching overhead.

| Phase | Estimate | Confidence | Risks |
|---|---|---|---|
| 0 | 5 days | High | Low — additive schemas; immutability check is a one-line guard; BlobStore is familiar pattern |
| 1 | 8 days | Medium | Submission API has three entry points; getting the shared core function right (and the three thin wrappers consistent) takes care. Backfill CLI's transcript regex needs validation against real Claude JSONL. |
| 2 | 11 days | Medium-Low | First substantial new UI surface. ManuscriptDetailView interacts with several existing patterns (DetailView, ArtifactDetailView). SwiftUI deep-hierarchy update issues per CLAUDE.md may bite. |
| 3 | 8 days | Medium | Cross-app event subscription is well-trodden; compile-pipeline integration (FR-IP3) is the unknown — see §9 OQ-1. |
| 4 | 11 days | Low | Counsel structured output is the highest-risk piece. Apple Intelligence `@Generable` works for imbib's RAGChat, but extending to Anthropic SDK responses is uncharted. May need to land a structured-output post-processor in Phase 4 itself. |
| 5 | 8 days | Medium | Steward dedup sweep is mechanical given existing similarity infrastructure. RO-Crate output format requires careful spec compliance. |

**Total: ~51 agent-days** ≈ 10 weeks at ~5 productive days/week.

**Risk-weighted estimate: 60–65 agent-days** (15% buffer for the medium-low/low confidence phases).

### Top three risks

1. **Counsel structured output (Phase 4).** The Anthropic SDK returns free-form text. Producing a guaranteed-valid `review/v1` payload requires either: (a) Apple Intelligence `@Generable` adapter (mature in imbib RAGChatViewModel, but ties Counsel to on-device models), or (b) post-processing the Anthropic response with retry-on-parse-failure logic. Recommend (b) with a specific JSON-schema-constrained prompt; fall back to (a) if Anthropic's response quality is insufficient. Plan a 2-day spike at the start of Phase 4 to validate before committing.

2. **imprint compile API surface (Phase 3, FR-IP3).** ADR-0011 OQ-10 names this — the snapshot job needs to invoke imprint compile from impel, and imprint does not currently expose a documented external API. Two paths: (a) HTTP route on imprint (consistent with other apps), (b) function in `ImprintCore` package called via Swift import. Decide during Phase 3 kickoff. **Mitigation:** if neither is ready, Phase 3 can ship with manual snapshots only; auto-snapshot-on-status-change becomes Phase 3.5.

3. **Per-task model override schema migration (ADR-0013 D31).** Adding `model_override: PersonaModelConfig?` to `TaskRequest` requires a GRDB migration on `CounselTask`. Migrations are reversible but mistakes cost. Test the migration on a copy of a real `counsel.sqlite` before landing.

### Lower risks worth noting

- **NFR-4 bench may surprise.** The query for "all manuscripts with status X" is a payload field filter (`json_extract`), which is slower than indexed columns. If the bench fails the 10ms target, status may need to become a tag (`status/draft`) rather than a payload field — a small refactor that touches D44's schema and §2.1.
- **Submissions inbox UX.** The PDR did not design this; ADR-0011 D8 only sketches it. The accept/reject affordance is straightforward but the rich-preview side-by-side comparison view (similarity hint vs. computed similarity) needs design iteration. Reserve a half-day in Phase 2 for UX exploration.

---

## 9. Open questions deferred to implementation

These are the ADR-0011 OQs that remain open after the ADRs were accepted. Each must be resolved during the named phase.

| OQ | Phase | Resolution mechanism |
|---|---|---|
| OQ-1 | 1 | `conversation@1.0.0` schema. **Defer:** treat `origin_conversation_ref` as opaque path string for MVP; add proper conversation schema in a follow-up plan once impart conversations become items |
| OQ-2 | 4 | UI affordance for "Request review" — likely a button in ManuscriptDetailView and a command-palette command |
| OQ-3 | 4 | Diff-application UX — build the side-by-side diff viewer; the "Apply to imprint source" button opens imprint with the patched source |
| OQ-4 | 2 | Smart-collection status filter — recommend implementing as a tag (`status/draft`) per the lower-risk note above |
| OQ-5 | 5 | mbox round-trip — ship export-only in Phase 5; mbox import is a future plan |
| OQ-6 | n/a | Multi-author manuscripts — out of scope; flagged for future major ADR |
| OQ-7 | n/a | Schema versioning suffix — depends on ADR-0004 OQ-2 resolution; journal schemas migrate when that does |
| OQ-8 | 5 | Steward sweep cost — bound to recently-modified manuscripts (last 90 days) by default |
| OQ-9 | 0 | Manuscript deletion cascades to revisions cascades to blobs — implement in Phase 0's BlobStore as the GC sweep |
| OQ-10 | 3 | imprint compile API — see Risk 2 above |

---

## 10. What this plan does NOT cover

- **FR-IM1, FR-IM2** (implement and implore reference graph): deferred to a follow-up plan.
- **Multi-author collaboration**: out of scope for v1.
- **Mbox import**: only export in Phase 5.
- **Conversation schema** (OQ-1): treated opaquely; future plan defines it properly.
- **Per-user persona customization**: deferred per ADR-0013 D35.
- **Declarative pipeline rules**: pipelines are Rust code per ADR-0005 D22; declarative form is Phase 4+ project-wide work.
- **Journal-specific impart UI**: surface manuscript status events in conversations is interesting but not in scope.

A follow-up plan will pick up FR-IM1/2 and the conversation schema once this plan ships and the patterns are settled.

---

## 11. Acceptance gate to begin Phase 0

Before any code lands, all of the following must be true:

- [ ] ADR-0011 status moved from `Proposed` to `Accepted` by Tom.
- [ ] ADR-0012 status moved from `Proposed` to `Accepted` by Tom.
- [ ] ADR-0013 status moved from `Proposed` to `Accepted` by Tom.
- [ ] This plan reviewed and accepted by Tom.
- [ ] Test fixture directory `crates/impress-core/tests/fixtures/journal/` created with the eight files in §7.
- [ ] A 90-second startup-render-loop bench (per CLAUDE.md "Background Services Must Defer Startup Work") confirms no new background service in the journal pipeline fires during the first 90 seconds of imbib launch. The JournalPipeline must inherit the existing 60–90s startup grace period.

If any of the six checkboxes is empty, Phase 0 does not begin. The recursive ingestion test (PDR §9.3) — the ADRs themselves becoming the journal's first manuscripts — happens at the end of Phase 5, after the backfill CLI ships.
