# Implementation Plan — imprint as the Source of Truth for Manuscript→PDF Compilation

**Status:** Draft for review
**Date:** 2026-05-05
**Author:** Tom Abel (with implementation planning via Claude)
**Implements:** Resolves OQ-10 of `docs/plan-journal-pipeline.md` (the imprint compile API surface). Closes the placeholder-PDF deferral that runs through Phases 3, 4, and 5 of the journal pipeline.
**Related:** ADR-0011 (The impress Journal) D2 (manuscript-revision schema, `pdf_artifact_ref` field), D4 (PDF blob tier), D7 (Archivist persona). ADR-0011 D3 (`Contains` edge with `kind: "imprint-source"`).

---

## Context

The journal pipeline defines `manuscript-revision/v1` items that carry a `pdf_artifact_ref` pointing at a content-addressed PDF in `BlobStore`. Phases 3 / 4 / 5 of the implementation plan ship the surrounding workflow (snapshot job, reviews, revisions, exports) but write a placeholder UUID for `pdf_artifact_ref` because no journal-pipeline component currently knows how to invoke imprint's compile pipeline. Researchers see "(real PDF written when imprint compile is wired)" in the detail view, RO-Crate exports, and mbox attachments — useful but unfinished.

This plan closes that gap. It establishes **imprint as the canonical compile authority for the impress suite**: any caller that needs a PDF from a manuscript (or any Typst / LaTeX source) routes through imprint. No other process re-implements the Typst toolchain. No other crate links typst-as-lib. PDFs that land in BlobStore are produced by the same compile pipeline that the imprint editor preview uses.

### What already exists (verified in code)

- **`crates/imprint-core/src/render.rs`** — full Typst rendering pipeline behind `typst-render` feature: `TypstRenderer` trait, `PersistentTypstRenderer` (thread-local with comemo cache), `RenderOptions`, `RenderOutput::Pdf(Vec<u8>)`. Stable, performant.
- **`crates/imprint-core/src/lib.rs:215`** — UniFFI export `pub fn compile_typst_to_pdf(source: String, options: CompileOptions) -> CompileResult`. Returns `{ pdf_data, error, warnings, page_count, source_map_entries }`. Wraps the renderer in `catch_unwind` so panics don't cross the FFI boundary.
- **`apps/imprint/Packages/ImprintCore/Sources/ImprintCore/ImprintCore.swift:595`** — Swift wrapper `await ImprintRustCore.compileTypstToPdf(source:options:)` already used by the imprint editor preview.
- **`apps/imprint/Shared/Services/ImprintHTTPServer.swift`** — HTTP server on `127.0.0.1:23121`.
- **`apps/imprint/Shared/Services/ImprintHTTPRouter.swift`** — `POST /api/documents/{id}/compile` exists for compiling a document already loaded in imprint by its UUID. `GET /api/documents/{id}/pdf` downloads the latest compiled PDF.

### What is missing

- A **stateless compile endpoint** that accepts source bytes (and minimal options) directly in the request body. The existing `/api/documents/{id}/compile` requires the document to be open in imprint and addressable by UUID — it's an editor concern, not a journal-pipeline concern.
- An **`ImprintCompileClient`** in impel's `CounselEngine` package that wraps the new HTTP route and returns PDF bytes.
- Wiring in **`JournalSnapshotJob`** to call the client, push the resulting bytes through `BlobStore`, and write the real `pdf_artifact_ref`.
- A **fallback policy** for when imprint isn't running. Per the existing snapshot policy in ADR-0011 D5, snapshots can be deferred. Phase 3's autonomy gate ("auto-act if compile clean AND hash differs") becomes meaningful once compile is wired — without imprint running, the snapshot still creates the revision item with a placeholder PDF and posts an event so a later compile run can backfill.

---

## Source-of-truth principle

The contract this plan establishes:

1. **imprint owns the compile pipeline.** All manuscript Typst (and, in a follow-up, LaTeX) compilation happens inside the imprint process via `imprint-core::compile_typst_to_pdf`. Only imprint links typst dependencies.
2. **PDFs that land in the journal store come from imprint compile.** `JournalSnapshotJob` does not invoke any other compiler. If imprint is unavailable, the snapshot item is created with the placeholder ref and re-tried later — never substituted with a different compiler.
3. **The cross-app interface is HTTP, not direct FFI.** impel does not link `imprint-core`. The boundary is a network call; the network call IS the API. This keeps the dependency graph clean and makes the contract testable end-to-end with `curl`.
4. **The compile call is content-only.** Stateless inputs: source bytes, output options. Stateless output: PDF bytes (or a typed error). No document UUIDs, no editor state, no sync side effects.
5. **Cache locality belongs to imprint.** The `PersistentTypstRenderer` thread-local + comemo machinery already exists. The journal compile route reuses the same renderer instance, so successive compiles of similar manuscripts get the same incremental-render benefits the imprint editor preview already enjoys.

---

## Critical files

### Create

| Path | Purpose |
|---|---|
| `apps/impel/Packages/CounselEngine/Sources/CounselEngine/ImprintCompileClient.swift` | Swift actor that POSTs source to imprint's stateless compile route and returns PDF bytes. ~120 lines. |
| `apps/impel/Packages/CounselEngine/Tests/CounselEngineTests/ImprintCompileClientTests.swift` | Unit tests with a mock `URLProtocol` so we don't depend on imprint actually running in CI. |

### Edit

| Path | Change |
|---|---|
| `apps/imprint/Shared/Services/ImprintHTTPRouter.swift` | Add `POST /api/compile/typst` route. Reads source from JSON body or raw `text/plain`, returns PDF binary on `application/pdf` or JSON `{ "error": "..." }` on failure. ~80 lines. |
| `apps/imprint/Shared/Services/ImprintHTTPRouter.swift` | (same file) extend the route doc-comment block at lines 27–55. |
| `apps/impel/Packages/CounselEngine/Sources/CounselEngine/JournalSnapshotJob.swift` | Replace the placeholder `pdf_artifact_ref` write with a call to `ImprintCompileClient.compile(...)` → `BlobStore.store(...)` → real `pdf_artifact_ref`. Add fallback path: on compile failure, keep the existing placeholder and post a `manuscriptSnapshotCreated` event annotated with `compile_status: "deferred"`. |
| `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Files/BlobStore.swift` | Already supports `store(data:ext:)` → `(sha256, url)`. No code change. (Track via cross-package note.) |
| `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Manuscript/ManuscriptBridge.swift` | Add `getRevisionPDFURL(revisionID:) -> URL?` that resolves a `pdf_artifact_ref` through the artifact item lookup → BlobStore. Used by ManuscriptDetailView and ROCrateExporter / MboxExporter to resolve real PDF bytes. ~40 lines. |
| `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Export/ROCrateExporter.swift` | Replace placeholder PDF write with a real read from BlobStore via `getRevisionPDFURL`. Drop the placeholder fallback note. |
| `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Mbox/MboxExporter.swift` | Same: read PDF bytes from BlobStore for the manuscript attachments. |
| `apps/imbib/imbib/imbib/Views/Detail/ManuscriptDetailView.swift` | Add a thumbnail / "Open PDF" button next to each revision row that resolves through the new bridge method. |
| `apps/impel/Packages/CounselEngine/Sources/CounselEngine/JournalPipeline.swift` | Optional: add a "compile re-try" sweep that re-runs `JournalSnapshotJob` for revisions still carrying the placeholder PDF ref when imprint becomes available. ~40 lines. |
| `packages/ImpressKit/Sources/ImpressKit/SiblingApp.swift` (or equivalent port lookup) | Confirm imprint's port is `23121` and exposed as `SiblingApp.imprint.httpPort`. (Likely already there; verify before coding.) |

### Reference (read-only)

- `crates/imprint-core/src/lib.rs:200-310` — `compile_typst_to_pdf` + `compile_typst_to_pdf_inner`; the persistent renderer pattern and the `CompileResult` return shape are the contract this plan exposes over HTTP.
- `crates/imprint-core/src/render.rs:550-578` — `render_pdf` (the actual compile call), confirming PDF bytes land as `RenderOutput::Pdf(Vec<u8>)`.
- `apps/impel/Packages/CounselEngine/Sources/CounselEngine/JournalSnapshotJob.swift:68-86` — current placeholder write that needs replacing.
- `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Files/BlobStore.swift` — `store(data:ext:)` API already in place.
- `apps/imprint/Shared/Services/ImprintHTTPRouter.swift:39` — the existing `POST /api/documents/{id}/compile` route is the closest precedent for shape and error handling.

---

## The new HTTP contract

### `POST /api/compile/typst`

**Request body** (JSON):

```json
{
  "source": "= Hello World\n\nBody text...",
  "page_size": "a4",
  "font_size": 11,
  "margins": { "top": 72, "right": 72, "bottom": 72, "left": 72 }
}
```

`page_size`, `font_size`, and `margins` are optional. Defaults match imprint's editor defaults (A4, 11pt, 72pt margins). The server normalizes through the same `ImprintRustCore.CompileOptions` constructor the editor uses.

**Success response**: `200 OK`, `Content-Type: application/pdf`, body = raw PDF bytes. `Content-Disposition: inline` (no filename — caller supplies one when storing). Custom response headers:

| Header | Meaning |
|---|---|
| `X-Imprint-Compile-Status` | `ok` |
| `X-Imprint-Page-Count` | integer page count |
| `X-Imprint-Compile-Ms` | wall-clock compile duration in ms (for telemetry) |
| `X-Imprint-Warnings` | comma-separated warning strings, if any |

**Failure response**: `422 Unprocessable Entity` (compile error in source) or `500 Internal Server Error` (compiler crash). `Content-Type: application/json`, body:

```json
{
  "status": "error",
  "error": "expected closing brace at line 12, col 4",
  "warnings": ["unused symbol 'foo' at line 8"],
  "compile_ms": 142
}
```

The 422-vs-500 split lets clients tell "your source is wrong" from "imprint exploded" without parsing strings.

### Why a stateless route, not the existing document route

The existing `POST /api/documents/{id}/compile` requires the document to be loaded into imprint's `DocumentRegistry`. That's correct for the editor preview — the registry holds the CRDT, the parsed AST, the source map, etc. The journal pipeline doesn't have a document loaded; it has source bytes from a `manuscript-submission` payload. Forcing it to round-trip through document creation/deletion would:

1. Pollute the editor's recent-documents list.
2. Trigger save/sync hooks (FSEvents, iCloud, the share extension) that don't apply to a transient compile.
3. Add ~100ms of overhead per compile for document object construction.
4. Risk leaking partial documents on failure.

The stateless route shares the same `compileTypstToPdf` Rust call — same compiler, same cache, same fonts — without any of the document-lifecycle baggage.

---

## Execution strategy (parallel where reasonable)

| Track | What | When |
|---|---|---|
| 1 | imprint HTTP route `POST /api/compile/typst` + ad-hoc `curl` smoke test | First, main thread (small, isolated, can be tested in isolation) |
| 2 | `ImprintCompileClient` actor + mock-`URLProtocol` tests | After 1 (depends on the route's contract) |
| 3 | `JournalSnapshotJob` integration: compile → BlobStore → real `pdf_artifact_ref` | After 2 (uses the client) |
| 4 | `ManuscriptBridge.getRevisionPDFURL` resolver | Independent of 1–3, can run concurrent with 3 |
| 5 | `ROCrateExporter` + `MboxExporter` PDF wiring | After 4 (uses the resolver) |
| 6 | `ManuscriptDetailView` "Open PDF" button | After 4 |
| 7 | Optional `JournalPipeline` re-try sweep for placeholder revisions | After 3 lands; can ship as Phase 6.5 |

**Parallelism**: I'll write tracks 1, 2, 3 in the main thread sequentially (they form a chain). Track 4 can be built while track 3 is in progress — it's pure Swift in a different package. Tracks 5 and 6 can be drafted in parallel via two general-purpose agents on isolated files once 4 lands.

Estimate: **~5 agent-days** total. Smaller than any single phase of the journal pipeline because most of the lift is wiring an existing compiler through an existing HTTP server into existing storage.

---

## Failure modes and the fallback contract

The journal pipeline must keep working when imprint isn't running. The fallback contract:

| Condition | Snapshot job behaviour |
|---|---|
| imprint reachable, compile succeeds | `pdf_artifact_ref` = real BlobStore artifact. Status: green. |
| imprint reachable, compile fails (bad source) | `pdf_artifact_ref` = placeholder. `compile_status: "error"` field added to revision payload. `compile_error` field carries the compiler's error message. Detail view shows a red badge "compile error — see message". User can edit and re-snapshot. |
| imprint not reachable (timeout, refused) | `pdf_artifact_ref` = placeholder. `compile_status: "deferred"`. Detail view shows "compile deferred — start imprint to backfill". A `JournalPipeline` re-try sweep (track 7) runs whenever imprint heartbeat resumes. |
| imprint reachable but the route returns 500 | Same as "deferred" but `compile_status: "imprint-error"` and `compile_error` carries the diagnostic. |

The point: **the journal pipeline is never blocked by compile.** Snapshots, reviews, revisions, and the rest of the pipeline keep working with placeholder PDFs. When imprint is available, the placeholders get replaced. RO-Crate / mbox exports note "PDF deferred" in the metadata for placeholder revisions instead of writing the placeholder content as if it were the real thing.

This is critical for offline use: a researcher on a plane can submit a manuscript via CLI, accept it, advance status, and get reviews — even with imprint sleeping. The PDF gets compiled when they land and open imprint.

---

## Verification

### Per-track unit tests

- **Route** (`ImprintHTTPRouter` test target, if it exists; otherwise a Swift snippet via `swift run`):
  - POST a known-good Typst source, expect 200 + non-empty PDF bytes + `X-Imprint-Page-Count` header.
  - POST malformed Typst, expect 422 + JSON error body containing the parse error.
  - POST empty body, expect 400.
- **ImprintCompileClient**: mock `URLProtocol` returning canned PDF bytes; verify the actor unwraps the response, surfaces headers, throws on 422/500. ~5 cases.
- **JournalSnapshotJob integration**: existing tests use a mock `JournalSnapshotJob`; add a new test that injects a mock `ImprintCompileClient` returning fixed PDF bytes and confirms `BlobStore` receives the bytes + the revision payload's `pdf_artifact_ref` is the resulting blob's UUID, not the placeholder.
- **ManuscriptBridge.getRevisionPDFURL**: test against an in-memory store with a seeded artifact item pointing at a known BlobStore path.
- **ROCrateExporter / MboxExporter**: assertions that the written PDF file's bytes match what `BlobStore.locate(...)` returns for the revision's hash.

### End-to-end smoke test

```bash
# 1. Build everything.
cargo build -p impress-core
cd apps/imprint/imprint && xcodebuild -scheme imprint build
cd apps/impel && xcodebuild -scheme impel build

# 2. Launch imprint (UI). Confirm port 23121 is listening:
curl -sS http://127.0.0.1:23121/api/status

# 3. Compile a known-good Typst source via the new stateless route:
curl -sS -X POST http://127.0.0.1:23121/api/compile/typst \
  -H 'Content-Type: application/json' \
  -d '{"source":"= Hello\n\nBody."}' \
  --output /tmp/out.pdf
file /tmp/out.pdf            # → "PDF document"
pdfinfo /tmp/out.pdf | head  # → real PDF metadata

# 4. Trigger a snapshot via the journal pipeline (use submission-accept flow).
# Confirm the resulting revision's pdf_artifact_ref points at a real BlobStore
# entry (not the placeholder UUID 0x000…001).

# 5. Open the manuscript in imbib, confirm "Open PDF" button works for that
# revision; export RO-Crate, confirm pdfs/{revision-tag}.pdf is real PDF bytes.
```

### Acceptance criteria (closes OQ-10)

| # | Criterion | Status target |
|---|---|---|
| 1 | `POST /api/compile/typst` returns valid PDF for a known-good source within 1 second on a warm renderer | ✓ |
| 2 | `JournalSnapshotJob` produces revisions whose `pdf_artifact_ref` is a real BlobStore artifact when imprint is reachable | ✓ |
| 3 | When imprint is unreachable, snapshots still complete with placeholder + `compile_status: "deferred"` and a re-try sweep eventually backfills | ✓ |
| 4 | `ROCrateExporter` writes real PDF bytes (not placeholder text) when the source revision was compiled | ✓ |
| 5 | `MboxExporter` per-revision attachments contain real PDF bytes when available | ✓ |
| 6 | All existing tests still pass: 152 Rust + 53 CounselEngine + 28 PublicationManagerCore | ✓ |
| 7 | `imprint` and `impel` apps build clean | ✓ |

---

## Out of scope for this plan

- **LaTeX compilation.** imprint already has a `latex.rs` module; extending the stateless route to accept `engine: "latex"` is a follow-up. For now the journal's manuscripts are all Typst.
- **Multi-file Typst projects** (where the source is split across `.typ` files in a folder). The stateless route accepts a single source string. Multi-file support — needed for some real manuscripts — adds tar-archive upload to the endpoint and is a follow-up of ~3 agent-days.
- **Custom font / asset bundling.** Compile uses imprint's built-in fonts. Custom fonts come along with the multi-file path.
- **Streaming responses.** Compile is fast enough (sub-second on warm cache) that returning the full PDF in one response is fine. SSE / chunked responses for huge manuscripts can be a future optimization.
- **Compile farm / horizontal scaling.** This plan keeps compile in-process with imprint. If multiple manuscripts need parallel compilation later, a queue inside imprint or a separate impress-render service is the next step.

---

## Why this plan, this shape

A few alternatives were considered and rejected:

1. **Have impel link `imprint-core` directly.** Rejected: typst-as-lib is heavy (~30MB of fonts and code), forces impel to ship Typst even when no journal compile is happening, and binds two apps' release cycles.
2. **Build a separate `impress-render` micro-service.** Rejected: imprint already has the compile pipeline running and the renderer's persistent thread-local cache is most effective when reused across multiple consecutive compiles. Splitting render into a separate service throws away cache locality.
3. **Reuse `POST /api/documents/{id}/compile` by writing temp documents.** Rejected for the reasons in §"Why a stateless route" above — the document lifecycle has too many side effects.
4. **Have impel write source files to disk and ask imprint to open + compile + export them.** Rejected: filesystem coupling between processes is fragile, especially with iCloud / sandbox containers in the picture. HTTP is the right primitive.

The chosen design (new stateless HTTP route on imprint, network call from impel, BlobStore-mediated bytes) preserves the source-of-truth principle without entangling impel with imprint's compile dependencies and without breaking imprint's editor invariants. It's the smallest interface that closes OQ-10.
