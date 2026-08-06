# Impress Reuse Audit for Domain Expert Systems

**Audit date:** 2026-08-05  
**Repository snapshot:** `main` at `f3ce3e95`, plus the current local working tree  
**Scope:** architecture evidence plus the initial expert-system implementation checkpoint

## Executive finding

Impress already has a credible substrate for expert applications, but it does
not yet have a general expert-system framework. The strongest reusable parts
are the unified item graph, SQLite store, attributed operations, task kernel,
generated service inventory, MCP server, local-first sync, and shared native UI
contracts. Those should be reused directly.

The original audit found the weakest area in the path from heterogeneous source
material to citable, domain-neutral knowledge. The implementation now adds the
canonical `SourceLocator`, `SourceCitation`, `ExtractionRun`, and
`ContentChunk` primitives plus immutable persistence and bounded FTS retrieval.
The implementation also consolidates the existing narrow Vision use into a
reusable Apple-platform OCR package with scanned-PDF rendering, resumable page
cache, extraction manifests, portable SQLite output, and positioned text
observations. Task-backed orchestration, semantic figure/table extraction, and
generalized embeddings remain the important follow-on gaps.

The audit does **not** recommend adding `Observation`, `Measurement`,
`Hypothesis`, or VW diagnostic rules to `impress-core`. They should first be
concrete types in a VW domain crate. Extraction into an expert-profile library
is justified only after a second non-VW implementation uses the same semantics.

## Method and maturity scale

Claims were checked against Rust and Swift source, tests, manifests, and ADRs.
An ADR marked “accepted” is not treated as implementation evidence by itself.
The current tree contains substantial unrelated uncommitted work, especially
the provenance-first AI stack; those capabilities are labelled **working-tree
WIP** even when their ADR says implemented.

| Rating | Meaning |
|---|---|
| Established | Implemented on primary paths, exercised by focused tests, and already shared by multiple apps |
| Active | Implemented and used, but still has important convergence or rollout limits |
| Narrow | Works for its current app/domain but its API or data model is not general |
| Prototype | Code exists, but integration, test coverage, or operational proof is incomplete |
| Working-tree WIP | Present only in the current uncommitted tree; do not make a release dependency until committed and gated |
| Planned | Described but not implemented sufficiently for reuse |

## 1. Repository survey

This map groups code by responsibility rather than merely listing directories.

| Subsystem | What it actually does | Principal dependencies | Maturity | Expert-system reuse |
|---|---|---|---|---|
| Unified record kernel (`impress-core`) | Defines the `Item` envelope, dynamic typed payloads, schema registry, typed references, queries, operations, task states, and SQLite implementation | `serde`, `uuid`, `chrono`, `rusqlite`; no UI | Established | Reuse unchanged as the persistence and graph substrate |
| Store projections and bridges (`impress-store-service`, `impress-store-ffi`, `ImpressStoreKit`) | Provides store-generic collection, triage, browse, search, watched-folder, and Swift bridge operations; shapes results for callers | `impress-core`, UniFFI, generated service macros | Established/active | Reuse; add domain repositories above it, not domain rules inside it |
| Operation and provenance journal | Represents durable mutations as attributed operation items, materializes current state, supports batches, undo, retention, and time-oriented inspection | SQLite store and `core/operation` schema | Established | Reuse unchanged for session and evidence edits; it is audit provenance, not source citation provenance |
| Graph and query layer | Stores edges in `item_references`; supports typed forward/reverse predicates and bounded neighbors; compiles `ItemQuery` into SQL | SQLite/JSON1 | Established but modest | Reuse for relations; extend only when measured queries cannot be expressed |
| Schema registry and record kinds | Registers Rust-coded, additive payload schemas; Swift `RecordKindDescriptor` declares presentation and triage capabilities | `impress-core`; shared chassis/PMC on Swift side | Active | Reuse the schema mechanism; do not force expert semantics into the chassis descriptor |
| Collections and watched folders | Implements one generic collection kernel plus hash-tracked filesystem discovery, deterministic identities, provenance rows, and idempotent rescans | Store kernel, Swift platform discovery, generated services | Established on current kinds | Strong reuse for knowledge-source import; extraction/OCR remains a separate stage |
| Bibliography and document ingestion (`imbib-core`) | Parses BibTeX/RIS/mbox, resolves identifiers and sources, handles publication PDFs, metadata, annotations, deduplication, and enrichment | PDFium, source clients, Tantivy/SQLite paths, UniFFI | Established for publications; narrow generally | Reuse algorithms and adapters selectively; do not make VW documents pretend to be publications |
| Extraction and embeddings (`ImpressEmbeddings`, `imbib-core::search`) | PDFKit/PDFium text extraction, word/paragraph chunking, provider registry, vector persistence, HNSW ANN, and scholarly RAG assembly | PDFKit Swift package plus Rust embedding SQLite/index | Active but split and publication-shaped | Extract/generalize IDs, locators, and storage before treating it as an Impress-wide retrieval service |
| OCR (`ImpressOCR`) | Provides an Apple Vision library and CLI for images and scanned PDFs, bounded page rendering, resumable page caches, exact extraction profiles, confidence/geometry capture, SQLite/FTS output; reMarkable now delegates to it | Apple Vision, PDFKit, CoreGraphics, SQLite | Active on Apple platforms | Reuse unchanged for Mac/iPhone ingestion; add task scheduling and a non-Apple adapter only when required |
| Task kernel (`impress-core`, `impel-core`) | Stores task DAGs as items, validates state transitions, schedules registered `TaskExecutor`s, retries, records runs, and supports review suspension | Unified store, Tokio, impel | Kernel established; broader impel runtime mixed | Reuse for ingestion/indexing and long jobs; keep interactive diagnosis in a domain service |
| Agent orchestration (`impel-core`, CounselEngine, `impel-tools`) | Provides threads, events, personas, task orchestration, generated tool projection, and native agent loops | Item/task store plus a separate older event/GRDB lineage in places | Prototype/active; `impel-core` explicitly allows stubs and dead code | Reuse the task executor and tool inventory; do not make diagnosis depend on the older thread model |
| Provenance-first AI (`impress-ai*`) | Adds graph-authoritative conversations, content blobs, queued inference, run/tool provenance, oMLX, HTTP/NDJSON, and native presentation projections | Unified store, taskd, generated services, Axum | Working-tree WIP | Architecturally aligned and useful later; avoid making VW v1 depend on uncommitted code |
| Service code generation (`impress-service-core`, macros, `*-service`) | Turns one Rust service trait into inventory descriptors used by MCP, CLI, and impel; supplies JSON schemas and common dispatch | Procedural macros, `inventory`, `schemars`, async runtime | Established and well tested | Primary integration seam for every expert-domain operation |
| MCP (`impress-mcp`) | Serves stdio JSON-RPC, generated tools, grouped/flat projections, reachability gating, and live store resources | Service inventory, app HTTP backends, semantic-search legacy tools | Established/active | Reuse protocol and inventory; extract a reusable host/assembly seam and add a domain-only profile so expert clients do not see or link every app service |
| App automation and networking | Each native app exposes local HTTP status/actions; typed Rust clients install live backends; Axum is used by impel and AI services | `ImpressAutomation`, `impress-app-client`, app routers | Active | Reuse transport patterns; keep HTTP as an adapter over the same domain service |
| Sync and local-first storage | Trigger-fed outbox, HLC conflict resolution, tombstones, CloudKit codec/engine, leases, and conflict backups | SQLite core plus Swift CloudKit transport | Active, feature-gated rollout | Reuse for native apps; a browser PWA needs an HTTP change-feed bridge and IndexedDB |
| Shared Apple UI | Provides chassis contracts, command palette, keyboard grammar, sidebar/list chrome, theme, logs, settings, and thin app shells | SwiftUI/AppKit packages and PublicationManagerCore | Active; some chassis remains imbib-entangled | Reuse when a native expert UI is built; not relevant to MCP v1 and not directly reusable in a PWA |
| Domain engines (`imprint`, `implore`, `impart`) | Typst manuscripts, scientific I/O/plots/selections, and communication respectively | Shared store/services plus domain libraries | Mixed active/development | Evidence that concrete domain crates can sit above Impress without changing the store |
| Documentation and architectural governance | ADR chain, capability matrix, schema-ref manifest, migration ledger, parity tests, CI gates | Repository conventions and tests | Strong but some top-level documentation is stale | Reuse the ADR/parity-test discipline for the expert-system work |

### Important repository-level observations

1. The top-level README understates the present system. The current workspace
   contains more than the originally documented app cores, including the
   unified store, collection kernel, service generator, MCP projection, sync,
   and AI work.
2. There are two notions of “plugin.” `SourcePlugin` is a Swift protocol for
   publication search providers; `RecordViewerRegistry` and the generated
   service inventory are compile-time registries. There is no general dynamic
   binary/plugin ABI, and one is not required for the VW validation.
3. The repository is deliberately TypeScript-free. The existing browser UI is
   static HTML/CSS/JavaScript served by Rust. A PWA proposal must preserve that
   constraint unless the repository policy changes.
4. The same database is opened by multiple apps. Domain code must write through
   `impress-core`/service APIs so operation, sync, FTS, and outbox invariants are
   preserved.

## 2. Existing capability audit

| Capability | Current implementation | Reusable unchanged? | Needs extension? | Not reusable? | Comments |
|---|---|:---:|:---:|:---:|---|
| OCR | `ImpressOCR` Apple Vision image/PDF API and resumable CLI; legacy reMarkable service delegates to it | Yes on Apple platforms | Yes |  | Native scanned-PDF path is implemented; task-backed execution, richer table/figure semantics, and cross-platform engines remain extensions |
| PDF ingestion | PDFKit/PDFium text and metadata extraction plus `ImpressOCR` page rendering; publication import and watched files |  | Yes |  | OCR page boundaries, extraction manifest, hashes, and domain-neutral IDs now exist; automatic text-first/OCR-fallback orchestration remains |
| Filesystem ingestion | Watched-folder schemas, deterministic IDs, hashes, missing-state tracking, bounded batches | Yes | Minor |  | Strong fit for manual drops; file discovery remains platform-specific by design |
| Indexing | SQLite FTS5 on selected payload fields, including canonical `ContentChunk.body`; Tantivy paths in document apps; HNSW ANN | Yes for exact text | Yes |  | Expert chunks now have one page-addressable FTS projection; semantic/vector convergence remains |
| Semantic retrieval | `ImpressEmbeddings`, publication/chunk vectors, HNSW, scholarly RAG |  | Yes |  | Publication IDs, BibTeX-shaped citations, and separate embedding DB prevent unchanged reuse |
| Exact lookup | `ItemStore::get`, typed query predicates, identifiers and domain services | Yes | Minor |  | Expose through semantic domain operations, not raw IDs alone |
| Structured retrieval | `ItemQuery`, shaped rows, store service, typed references | Yes | Yes |  | Add expert repository queries and applicability filters; raw dynamic payload access stays internal |
| Provenance of mutations | Operation items, actor identity, intent, batches, HLC, run records | Yes | Minor |  | Strong; distinguish “who changed the record” from “which source supports the fact” |
| Source citations | Canonical source citation, locator, extraction-run, immutable hash validation, and MCP resolution; legacy annotation/bibliography shapes remain | Yes | Yes |  | Core gap is closed; compatibility adapters and reviewer UI remain |
| Metadata | Universal item envelope, schema payloads, artifact/publication fields | Yes | Yes |  | Add source/extraction metadata through typed schemas, not universal envelope fields |
| Document model | Publication + linked files, artifacts, manuscripts, annotations |  | Yes |  | Reuse items/assets; do not invent one universal document class |
| Binary assets/CAS | App-specific blob stores; `content-blob` and `FileBlobStore` in AI WIP; CloudKit asset work |  | Yes |  | Ownership should move below AI/app domains before a third implementation is added |
| Storage | SQLite WAL, reader pool, JSON payloads, relational edge/tag tables | Yes | Minor |  | Recommended authority for expert records; no second DB for sessions or rules |
| Relational features | Materialized columns, indexes, transactions, FTS, migrations | Yes | Minor |  | Use relational projections for hot filters; avoid a new PostgreSQL requirement |
| Graph structures | Typed references, reverse lookup, neighbors, impel DAGs | Yes | Yes |  | Sufficient for v1; edge metadata querying and paths may be useful later |
| Serialization | Serde JSON, Schemas, UniFFI DTOs, `schemars` service inputs | Yes | Minor |  | Domain DTOs should be concrete Rust types; persisted payload compatibility needs golden tests |
| Configuration | Rust/TOML personas, Swift settings/keychain, environment-backed servers |  | Yes |  | Domain pack/config versioning is missing; secrets must stay outside the item graph |
| IPC | Shared SQLite, Darwin notifications, local HTTP, generated service inventory | Yes | Minor |  | Use HTTP only at process/platform boundary; never scrape UI |
| Networking | Typed source clients, reqwest, Axum, app automation routers | Yes | Minor |  | Adequate for sync/PWA adapters; no need for a new networking framework |
| MCP | Generated inventory, grouped surfaces, resources, stdio server | Yes | Yes |  | Add expert surface/profile metadata and semantic VW resources/tools |
| CLI | Generated subcommands from the same inventory | Yes | Minor |  | Valuable for headless fixtures and deterministic acceptance tests |
| Agent framework | Task DAG/executors, agent runs, impel tools, native loop | Partial | Yes |  | Use deterministic services first; LLM orchestration is a client, not the inference authority |
| Long-running jobs | Task state machine, retries, taskd, review suspension | Yes | Minor |  | Appropriate for OCR, ingestion, re-indexing, and model work |
| Persistent sessions | Items/operations can model them; AI conversations exist in WIP |  | Yes |  | Diagnostic session is a domain aggregate, not a generic chat thread |
| Workflows/procedures | Task DAGs and manuscript workflows; no domain procedure runner | Partial | Yes |  | A user-facing, stepwise procedure has different semantics from a background task DAG |
| Caching | FTS/ANN projections, embedding persistence, HTTP/app caches, content hashes | Partial | Yes |  | Define derivation keys and invalidation by content/model/extractor versions |
| Sync | CloudKit graph sync, outbox, tombstones, HLC | Yes for native | Yes for web |  | PWA requires scoped sync protocol; large asset availability remains a known limit |
| UI/views | Record descriptors, viewer registry, shared chassis packages | Partial | Yes |  | Native reuse is real but still partly publication-hosted; PWA is a separate view adapter |
| Event systems | Store subscriptions, Darwin notifications, task events, app logs | Partial | Yes |  | In-process store subscriptions are simple channels; durable domain state remains items/operations |
| Rendering | PDFKit, Typst, plotting, shared native viewer registry | Partial | Yes |  | Manual page/figure rendering can reuse PDFKit; expert views should not enter rendering core |

## 3. Missing abstractions and where they belong

| Candidate | Recommendation | Why |
|---|---|---|
| `SourceLocator` / `SourceCitation` | **Impress-wide, immediate** | PDF chunks, annotations, RAG, reviews, and expert facts all need one stable locator. It should identify asset hash/version, page label/index, optional region, section, figure/table label, quote hash, and extractor version. |
| `ContentChunk` | **Impress-wide, immediate** | Chunking already has two consumers. IDs and parents must be generic `ItemId`/asset IDs rather than publication IDs; page/offset locators and content hashes must be first-class. |
| `Asset` bytes and CAS port | **Impress-wide, immediate extraction/consolidation** | Manuscripts, publications, AI modalities, figures, and manuals already need immutable bytes. Keep artifact semantics in item schemas; centralize only byte identity, verification, and availability. |
| `ExtractionRun` | **Impress-wide, immediate** | Text/OCR is derived evidence. Recording extractor, version, input hash, output hash, warnings, and produced chunks makes retrieval reproducible. A task/agent-run alone does not locate source spans. |
| Embedding/index provider | **Impress-wide, immediate generalization** | Current protocols are good, but persistence/index APIs are publication-shaped and split across Swift/Rust. Generalize source IDs, model/version keys, and rebuild rules. |
| Observation | **Expert profile, concrete in VW first** | It is meaningful across expert domains, but value types, confidence, acquisition method, and privacy differ. Do not put it in the universal item envelope. |
| Measurement | **Expert profile, concrete in VW first** | Units, tolerances, conditions, uncertainty, and instrument calibration require a typed quantity model. Generalizing before a second domain risks a weak stringly abstraction. |
| Knowledge assertion | **Expert profile later** | A subject/predicate/object triple is sometimes useful, but many facts are better represented by typed domain records. Start with typed VW facts and extract only shared epistemic metadata. |
| Evidence | **Expert profile, concrete in VW first** | Evidence is a relation among an observation/source, a hypothesis, and an evaluation rule. It is not merely an Impress graph edge and should retain polarity and rationale. |
| Hypothesis | **Domain-owned, shared profile later** | Lifecycle is reusable; content and ranking semantics are domain-specific. Medical and mechanical hypotheses must not share an unvalidated scoring interpretation. |
| Procedure definition/run | **Expert profile candidate** | Stepwise human procedures, safety gates, expected outcomes, branching, and resumability recur across domains and differ from background tasks. Prove the model with VW plus one scientific workflow. |
| Decision tree | **Domain content, not a core type** | It is one inference representation and creates brittle single-path knowledge. The v1 engine should accept typed rules; trees can be imported as rule sets. |
| Rule/evaluation trace | **Expert profile candidate** | Deterministic explanations require a persisted trace of applicable rule version, inputs, effects, and citations. Keep the evaluator behind a port so probabilistic models can replace it later. |
| Diagnostic/session case | **Domain-owned initially** | A case is the aggregate root for observations, runs, and hypotheses. Conversation is not equivalent. Extract a generic `Case` only after another domain demonstrates the same lifecycle. |
| Knowledge graph database | **Do not add** | The SQLite item/reference hybrid already supplies graph relations with transactions, FTS, sync, and local ownership. Add projections or query operators only when measured. |
| Dynamic plugin ABI | **Do not add now** | Compile-time service, source, viewer, and provider registries cover the validation case. A dynamic ABI adds compatibility and security costs without a current distribution need. |

## 4. Impress improvements: strict classification

This is the governing backlog. “Immediate” means required to build the VW
validation without adding another competing implementation. “Useful later”
requires an extraction trigger or measured need. “Never” identifies boundaries
that protect Impress from framework bloat.

### Immediate

| Improvement | Minimal change | Evidence that it is not speculative | Acceptance signal |
|---|---|---|---|
| Canonical source locator and citation DTO/schema | Add one versioned type usable by annotations, chunks, facts, rules, and MCP responses | Existing page numbers, annotation anchors, RAG sources, and `evidence_refs` already duplicate parts of it | A manual statement can round-trip to exact page/region and survive re-extraction detection |
| Domain-neutral chunk/embedding identity | Replace publication-only API assumptions with source item/asset IDs and `SourceLocator`; preserve compatibility adapters | Imbib publications and VW manuals are two concrete consumers | One index can store/search both without wrapping a manual as a publication |
| Extraction provenance | Persist extraction run/version/input hash and link produced chunks/figures/tables | Provenance-first operations do not say how derived text was created | Re-running unchanged input is a no-op; changed extractor is visibly a new derivation |
| Reusable native OCR adapter | Extract the reMarkable-specific Vision code into `ImpressOCR`; add PDFKit page rendering, resumable cache, portable index, and positioned observations | The VW manual and Imbib handwriting are two concrete consumers | A complete scanned manual can be rebuilt locally and Imbib still uses the same adapter |
| Consolidate byte-store ownership | Move or define the `BlobStore`/descriptor contract below `impress-ai`; adapt existing app stores rather than copy | Manuscripts, PDFs, AI modalities, and sync already have blob/CAS code | All consumers verify SHA-256 and report local/remote/missing availability consistently |
| Expert MCP surface profile | Let the existing MCP inventory expose an allowlisted domain projection with generated descriptions/schemas | Main MCP already supports flat/grouped projections; expert clients must not receive raw store tools | VW profile lists only orientation resources and semantic diagnostic operations |
| MCP host and product assembly seam | Make the protocol host reusable by a product binary that links an explicit service set; keep registration compile-time | The current binary target unconditionally links embeddings, Typst rendering, every app service, and working-tree AI code | A VW MCP binary reuses the tested host while linking only its declared domain and substrate services |
| Typed VW repository/service boundaries | New domain crates depend on ports; Impress adapters implement those ports | Existing app-core/service pattern is proven by imbib/imprint/implore | Rule engine tests run against an in-memory repository and MCP calls hit the same service |
| Knowledge curation states | Separate extracted/proposed/verified/rejected records or status on domain knowledge | LLM/OCR output is not safe as executable diagnostic knowledge | Only verified, version-pinned rules participate in diagnosis |
| Capability documentation refresh | Update repository/capability map when implementation starts; keep schema and MCP parity tests | Top README and some ADR statements lag the current tree | New domain kind and tools appear in machine-checked manifests and capability docs |

### Useful later

| Improvement | Trigger before implementation |
|---|---|
| Extract `impress-expert` observation/procedure/evidence/session types | A second non-VW domain implements equivalent semantics and the shared fields can be named without optional-field sprawl |
| Probabilistic inference port and Bayesian/factor-graph backend | Curated priors/likelihoods and calibration data exist; deterministic trace remains available |
| More expressive graph query language | Profiling finds repeated N+1 traversal or edge-metadata filters that cannot be served by shaped SQL queries |
| Generated HTTP adapter for service traits | VW PWA and at least one existing app need the same server projection and hand-written adapters begin to drift |
| Browser sync/change-feed protocol | PWA moves beyond a single-user validation and needs durable multi-device conflict handling |
| Cross-platform OCR adapter set | Non-Apple headless ingestion is a real deployment requirement |
| Layout-aware table/figure extraction | The VW corpus contains diagnostics materially dependent on tables/figures that page text and image crops cannot represent reliably |
| Dynamic domain-pack discovery/signing | Third parties must install independently released domains without rebuilding Impress |
| Generic procedure authoring UI | Two domains share author/review/version workflows; until then, domain-specific tooling is clearer |
| Shared regulated-data controls | A regulated domain is actually pursued with a defined threat model, retention policy, audit owner, and legal review |

### Should never belong in Impress core

| Exclusion | Reason |
|---|---|
| VW components, fault rules, repair thresholds, or vehicle configuration enums | Domain knowledge must ship as a versioned VW domain pack/library |
| Medical diagnostic rules, clinical terminology, or regulatory policy | Separate validated product/domain responsibility; sharing infrastructure does not transfer clinical validity |
| A universal EAV/ontology that replaces concrete domain Rust types | It sacrifices compile-time constraints and recreates a semantic database inside JSON |
| Raw SQL/database-query MCP tools as the expert interface | They bypass invariants and make the LLM responsible for joins, state transitions, and safety semantics |
| LLM-generated diagnoses as authoritative state | LLMs may parse language or explain traces; deterministic/domain evaluators own conclusions |
| Model-vendor, OCR-vendor, or vector-database-specific types in the item envelope | Providers are adapters and derived indexes are replaceable |
| A second graph database or mandatory cloud server | Duplicates the local-first authority and breaks the store/sync/provenance model |
| UI layout or PWA state in Rust domain models | Views consume projections; they do not define domain truth |
| Uncalibrated numbers labelled as probabilities | V1 ranking weights are ordinal priorities, never claimed failure probabilities |
| A general dynamic plugin ABI solely for the VW app | Compile-time registration is simpler, safer, and consistent with the existing suite |

## 5. Reuse verdict

The VW application fits Impress naturally if it is implemented as a new typed
domain library and generated service surface over the existing item/operation/
task substrate. It fits awkwardly only where Impress itself has an authentic
gap: citable source locations, domain-neutral derived chunks, and consolidated
asset/extraction infrastructure.

That awkwardness is useful evidence. It does **not** justify turning every VW
noun into a universal Impress noun.

## Primary implementation evidence

- [`crates/impress-core/src/item.rs`](../crates/impress-core/src/item.rs)
- [`crates/impress-core/src/sqlite_store.rs`](../crates/impress-core/src/sqlite_store.rs)
- [`crates/impress-core/src/operation.rs`](../crates/impress-core/src/operation.rs)
- [`crates/impress-core/src/task.rs`](../crates/impress-core/src/task.rs)
- [`crates/impress-core/src/reference.rs`](../crates/impress-core/src/reference.rs)
- [`crates/impress-store-service/src/docs_import_service.rs`](../crates/impress-store-service/src/docs_import_service.rs)
- [`crates/impress-service-core/src/lib.rs`](../crates/impress-service-core/src/lib.rs)
- [`crates/impress-mcp/src/server.rs`](../crates/impress-mcp/src/server.rs)
- [`packages/ImpressEmbeddings/Sources/ImpressEmbeddings/Chunking/DocumentPipeline.swift`](../packages/ImpressEmbeddings/Sources/ImpressEmbeddings/Chunking/DocumentPipeline.swift)
- [`crates/imbib-core/src/search/embedding_store.rs`](../crates/imbib-core/src/search/embedding_store.rs)
- [`crates/impel-core/src/task_scheduler.rs`](../crates/impel-core/src/task_scheduler.rs)
- [`docs/ADR-0020-sync-engine-implementation.md`](ADR-0020-sync-engine-implementation.md)
- [`docs/ADR-0024-mcp-surface-projection.md`](ADR-0024-mcp-surface-projection.md)
- [`docs/ADR-0026-provenance-first-ai-infrastructure.md`](ADR-0026-provenance-first-ai-infrastructure.md)
