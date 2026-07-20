# Implementation Plan: Throughline (ADR-0016)

**Companion to:** `docs/ADR-0016-throughline.md`
**Date:** 2026-07-20
**Ground rules for every phase:**

- **Opt-in invariant (ADR-0016 D1):** at the end of every phase, a document
  without a throughline sidecar incurs zero storage, zero tasks, zero UI. Each
  phase's acceptance checklist repeats this check explicitly.
- **Isolation:** implement in a git worktree; other sessions work imprint/imbib
  concurrently. All changes are additive; the only edits to shared files are
  the enumerated integration points (FileWrapper, router, `schemas/mod.rs`,
  sidebar/pane registration), each a small, gated addition.
- **Verification-first:** no phase is done until its selftest capabilities pass
  headlessly (`cargo run -p imprint-selftest -- --tier a`) and, where UI is
  involved, the behavior is confirmed over the live HTTP surface (port 23121)
  with three-point trace logging (`throughline` category) visible in the
  console. Console logging is liberal (`*Capture` variants) — the user watches
  the in-app console while testing.
- Run `xcodegen generate` only if project.yml changes (Phase 2 adds no new
  targets; new Swift files land in existing groups).

---

## Phase 1 — Representation and read surface (no agents, no sync, no UI)

Deliverable: a throughline can be created, stored, round-tripped, and inspected
headlessly. Everything below is inert for documents without the sidecar.

### 1.1 impress-core schema

- `crates/impress-core/src/schemas/throughline.rs` — `throughline_schema()`
  (`id: "throughline"`, `version: "1.0.0"`, fields per ADR-0016 D3,
  `expected_edges: [RelatesTo, Supersedes]`), `register_throughline_schema()`,
  typed accessors (`title()`, `document_ref()`, `anchor_map_hash()`, …).
- Wire into `schemas/mod.rs::register_core_schemas()`; `pub mod` + re-exports.
- Unit tests beside existing schema tests: registration, validation of
  required fields, accessor round-trip.
- **No SQL migration** (single items table; ADR-0004). Confirm with a test that
  inserts a throughline item into `SqliteItemStore` and queries it back.

### 1.2 imprint-service: anchor map + staleness derivation

New module `crates/imprint-service/src/throughline.rs`:

- `AnchorMap` (serde) matching the ADR-0016 D2 JSON schema, with
  `parse`/`serialize` and a `version` gate (reject > 1 with a typed error).
- `ThroughlineParagraph { label, span, body, content_hash }` extraction from
  `throughline.typ` — a line scanner in the style of `extract_outline`
  (paragraph = text run under a `<tl-*>` label; SHA-256 via the same hashing
  used by `SectionStore`).
- `derive_anchor_states(map, section_records, paragraphs) -> Vec<AnchorState>`
  — pure function implementing the four states (D5). **This is the core
  invariant-bearing function**: property tests (see 1.5) before anything
  consumes it.
- `derive_coverage(map, section_records) -> Vec<SectionKey>` (D7) — pure.
- Store mirror: `upsert_throughline_item(...)` creating/updating the
  `throughline@1.0.0` item + `Custom("narrates")` edge with anchor metadata,
  called only from create/save paths of opted-in documents.

### 1.3 Service trait (MCP/CLI/HTTP for free)

- `crates/imprint-service/src/throughline_service.rs` —
  `#[impress_service] trait ImprintThroughlineService`:
  - `create_throughline(document_id) -> ThroughlineInfo` (writes both sidecars
    with a scaffold: one `<tl-overview>` paragraph, empty anchors)
  - `get_throughline(document_id) -> ThroughlineInfo` (text + paragraphs)
  - `get_anchor_states(document_id) -> Vec<AnchorStateDto>`
  - `get_coverage(document_id) -> CoverageDto`
  - `set_anchor(document_id, label, section_keys)` / `remove_anchor(...)`
  - `mark_supporting(document_id, section_key, supporting: bool)`
- `DefaultImprintThroughlineService` + `impress_service_impl!` block; instance
  in `backend.rs`. Verify tools appear via `impress-mcp` inventory and
  `imprint-cli` subcommand list.
- All getters return a typed "no throughline" result for non-opted documents —
  cheap file-existence check, no store touch.

### 1.4 Swift FileWrapper round-trip

`apps/imprint/Shared/Models/ImprintDocument.swift` (small, additive edits at
the two chokepoints):

- `init(configuration:)`: read `throughline.typ` + `throughline.anchors.json`
  into `throughline: ThroughlineSidecar?` (nil when absent — the opt-in bit).
- `fileWrapper(configuration:)`: write both back **iff present**. Add a
  regression test asserting a package saved by a document *with* sidecars
  retains them byte-identical through open→save, and a package *without* them
  gains no files.
- No `DocumentSchemaVersion` bump (additive; revisit per ADR-0016 D2 guard if
  throughline-bearing documents circulate before all builds have this).

### 1.5 Tests & selftest

- Property tests (invariant-fortress convention — new invariant-bearing code
  gets properties): anchor-map JSON round-trip identity; `derive_anchor_states`
  determinism and exhaustiveness (every anchor yields ≥1 state; `broken` iff
  key unresolvable; hash-equal ⇒ `synced`); ledger untouched by derivation.
- Selftest Tier A capabilities in `crates/imprint-selftest`
  (`cap_throughline_create`, `cap_throughline_anchor_states`,
  `cap_throughline_coverage`, `cap_throughline_broken_anchor`) over fixture
  bundles, registered in `tier_a::run()`.

**Phase 1 acceptance:** Tier A green headlessly; MCP tool + CLI subcommand
visible; FileWrapper round-trip test green; a document without sidecars
produces no items, no files, no log lines (grep console for `throughline`
category = 0 entries).

---

## Phase 2 — imprint UI (read + author; still no agents)

Deliverable: create/edit a throughline and see anchor states, keyboard-first.
All surfaces are gated on `document.throughline != nil` plus a
`throughlineEnabled` UserDefault (default true, but zero-surface without the
sidecar; the toggle exists to hide even the command-palette entry).

### 2.1 Creation & pane

- Command-palette action **"Throughline: Create for this document"**
  (ImpressCommandPalette registry) → service `create_throughline` → opens pane.
  This is the *only* surface for non-opted documents.
- Throughline pane as a new `PaneLayout` participant (declarative layout work
  from the ergonomics project): editor for `throughline.typ` (reuse the
  existing Typst editing stack), paragraph gutter showing per-anchor state
  badges (synced/stale-in/stale-out/broken — color + symbol, not color-only).
- Pane registration is additive and revertible (sidebar-fragility rule): a
  single gated entry in the layout options, no restructuring of existing
  panes. `.keyboardGuarded` for all char-key handlers; no `.focusable()` on
  the editor's parents.

### 2.2 Anchor editing & navigation

- Anchor editor: with a paragraph selected, `a` opens a section picker
  (reuse the citation-picker interaction pattern /
  `CitationPickerCoordinator` style) listing outline sections from
  `OutlineSnapshot.shared` (canonical identity per ADR-0016 D4 — no parallel
  Swift derivation).
- Click/keyboard through: paragraph → first anchored section in the editor;
  section → owning paragraph(s). Reuse `DocumentOutlineView`'s
  `onNavigateToLine` plumbing.
- Coverage: passive dot in `DocumentOutlineView` rows for uncovered sections
  (opted-in docs only); context/keyboard dispositions **anchor it** / **mark
  supporting** (writes `supporting` via service).

### 2.3 HTTP routes (Swift router parity)

`ImprintHTTPRouter.swift` additions (thin delegations to the Rust service via
`ImprintRustHandlersBridge`):
`GET /api/documents/{id}/throughline`, `GET …/throughline/anchors`,
`GET …/throughline/coverage`, `POST …/throughline` (create),
`PATCH …/throughline/anchors` (set/remove/mark-supporting).

### 2.4 Logging & verification

- Three-point trace on every mutation (`throughline` category): requested →
  saved (file + mirror) → displayed (pane state count).
- Tier B selftest capabilities driving the live app over HTTP: create via
  POST, verify GET anchors reflects an edit made through `PATCH`.
- Startup check: launching with a throughline-bearing document open must not
  add background work in the first 90 s (no new services; derivation runs on
  demand only). Verify with the standard `SHKSharingServicePicker` grep.

**Phase 2 acceptance:** full authoring loop with hands on keyboard; HTTP
verify green; opt-in invariant re-checked (fresh document: no pane, no badges,
no routes returning data, single palette entry only).

---

## Phase 3 — Sync proposals (agents enter; propose-never-commit)

Deliverable: drift produces reviewable proposals; accepting applies and
updates the ledger; rejecting leaves visible staleness. Nothing auto-commits.

### 3.1 Spawn rule

- `ThroughlineSpawnRule` (template: `EnrichmentSpawnRule` in
  `crates/impel-enrichment/src/spawn.rs`): subscribes to the broadcast bus for
  section-content operations; **first** filters against the opted-in document
  set (maintained from throughline item create/delete events, loaded once at
  startup — an in-memory set, so the non-opted path is a hash lookup and
  return); then debounces per (document, anchor) with a quiet period so an
  editing session yields one `throughline-sync` task per drifted anchor.
- Task DAG: one task per drifted anchor, `DependsOn` nothing (independent);
  repair tasks (`broken`) are the same kind with `context_reason = broken`.
- Readiness via `ready_tasks` (never `neighbors()` for `DependsOn` —
  bidirectional).

### 3.2 Executor

- `ThroughlineSyncExecutor` implementing the ADR-0015 `TaskExecutor` contract
  (structural template: `KeywordTagExecutor`):
  1. Re-derive the anchor's state from current hashes (not from the task
     payload — state may have moved).
  2. Build the proposal: direction-specific prompt contract per ADR-0016 D6
     (authority split + never-strengthen clause verbatim in the system
     prompt); context assembled from anchored section bodies + paragraph text;
     word-level diff via the existing `DiffCalculator` port or a Rust
     equivalent (small LCS, lives in `imprint-service`).
  3. `store.open_review(task_id, ReviewRequest { question, context_* })` with
     `context_direction`, `context_anchor`, `context_diff`,
     `context_proposed_text`, `context_target_sections`; return
     `ExecutionOutcome::Suspended`.
  4. On re-invocation with `resolution == "approved"`: apply via
     `put_section`/`replace_in_section` (manuscript side) or throughline file
     write (paragraph side); **then** update the ledger hashes — the accept
     path is the ledger's only writer; hash-mismatch at accept time (document
     moved meanwhile) ⇒ invalidate, respawn, report — never force-apply.
  5. Any other resolution ⇒ task `done`, no writes, anchor stays stale.
- Model calls go through the existing AI provider path used by author-tasks
  (on-device default per the AI author-tasks Phase 1 decision).
- Register with the scheduler keyed on `task_kind = "throughline-sync"`.

### 3.3 Review UX in imprint

- Proposal list: stale/broken badges in the throughline pane become
  actionable — `Enter` on a badge opens the proposal card (InlineAITaskCard
  grammar: diff preview, **Accept** `⏎` / Discard `esc` / Retry).
- Resolution writes the `review-request` `resolution` field via the service;
  the suspended task resumes and applies (3.2.4). The UI never applies
  directly — one apply path.
- Proposals are ordinary `review-request@1.0.0` items, so imbib's inbox can
  list them; resolving deep-links into imprint (`imprint://` URL scheme).

### 3.4 HTTP/MCP parity

- `POST /api/documents/{id}/throughline/sync` — computes and returns the
  proposal with `"applied": false` (the `handleRunTask` contract); optional
  `anchor` param to scope. Lets agents and tests exercise the proposal
  pipeline without the scheduler.
- Service methods `list_sync_proposals(document_id)` /
  `resolve_sync_proposal(review_id, resolution)`.

### 3.5 Verification

- §9-style end-to-end gate (Tier A where headless, Tier B live): edit an
  anchored section → task spawns (and only for opted-in docs) → review item
  appears with diff context → approve → paragraph updated + ledger hashes
  advanced + operation items attributed → anchor derives `synced`. Reject
  variant: anchor stays `manuscript-ahead`, no writes.
- Negative gate: same edit on a non-opted document spawns nothing (assert
  zero `throughline-sync` tasks).
- Console trace end-to-end under `throughline` category.

**Phase 3 acceptance:** both gates green; a full manuscript-ahead and
throughline-ahead round-trip performed live via HTTP; no auto-commit path
exists (code review + grep: ledger writes only in the accept branch).

---

## Phase 4 — Hardening & polish

- **Broken-anchor repair:** rename-detection heuristic (order-index +
  body-hash match) feeding repair proposals; property tests for the
  heuristic's no-false-rebind invariant.
- **Invariant fortress:** promote Phase 1 properties into the fortress suites;
  add: accept-path-is-sole-ledger-writer (structural test), spawn-rule
  opt-in-set correctness under create/delete races.
- **PerfMetrics:** wrap `derive_anchor_states` and proposal generation in
  `PerfMetrics` buckets with budgets (derivation ≤ 50 ms for a 50-section
  manuscript; visible in the Console Performance tab and `/api/performance`).
- **Deactivation UX:** remove-throughline action per ADR-0016 D1 (Dismissed
  convention: recoverable until next save), including opted-in-set eviction
  and mirror-item Supersedes/tombstone.
- **Docs:** README pointer in `docs/`; note in imprint app docs; amend/
  re-status imprint ADR-001 (flagged by ADR-0016 D9) as its own small PR.

**Explicitly out of scope (deferred with triggers, per ADR-0016 D9):**
renderers (D8 contract is the interface), Typst `#label()` anchors,
per-paragraph items, core `narrates` `EdgeType` variant, knowledge-object
promotion, multi-manuscript throughlines.

---

## Sequencing & effort

Phases are strictly ordered; each is independently shippable and revertible.
Rough sizing: Phase 1 ≈ 1 focused session (mostly Rust, headlessly testable);
Phase 2 ≈ 1–2 sessions (UI, gated); Phase 3 ≈ 1–2 sessions (executor + review
UX); Phase 4 ≈ 1 session. Phase 1 can begin immediately in a worktree with no
coordination; Phases 2–3 touch `ImprintHTTPRouter.swift` and pane/layout
registration, so coordinate merges with any concurrent imprint sessions at
those two files.
