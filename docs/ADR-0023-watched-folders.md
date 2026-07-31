# ADR-0023: Watched Folders — the filesystem as a feed

**Status:** Accepted
**Date:** 2026-07-31
**Depends on:** ADR-0001 (unified items), ADR-0021 (record-kind descriptors), ADR-0022 (collection kernel, docs-import service), imbib ADR-002 (BibTeX as portable format)

## Context

Researchers arrive with decades of files already on disk: `.bib` files scattered
through paper-writing directories, manuscript folders per project, mbox
archives, Veusz documents. The suite's current model is one-shot import — drag
a file in, or run an importer once. Everything discovered after that moment is
invisible until the user remembers to import again.

macOS has already indexed all of it. Spotlight answers
`kMDItemContentTypeTree == "com.impress.bibtex-entry"` scoped to a directory
instantly, and `NSMetadataQuery` — the API form of `mdfind` — delivers **live
updates**: a `.bib` dropped three levels deep in a watched folder can appear in
imbib without a scan, a poll, or a recursive walk.

The campaign that closed in July 2026 left every hard piece of this feature
already built:

- **File types are declarative data.** `DocumentFormat`'s extension table is a
  Rust table (`impress_core::manuscript_format`); the suite's UTIs are declared
  once (`apps/chassis-utis.yml` + per-app document types — imbib claims
  `public.filename-extension: bib` via `com.impress.bibtex-entry`).
- **Ingest is Rust and idempotent.** `DocsImportService.import_directory`
  derives deterministic UUIDv5 ids from paths; `im-bibtex`/RIS parsing and the
  dedup identifier machinery are canonical Rust with golden corpora.
- **The UI shape exists.** imbib's inbox *feeds* are "a recurring external
  source that produces rows", with refresh, badges and dismissal semantics. A
  watched folder is a local feed.

## Decisions

### D1 — Watchable file types are declared, not coded

A new **`FileDiscoveryCapability`** on `RecordKindDescriptor` (data, no
closures — ADR-0021 D3): the UTIs/extensions this kind can ingest, and the
**ingest unit** (D3). The Spotlight query for any watched folder is *derived*
from the capability; no app names a file extension in discovery code. Where the
authority already lives elsewhere it is referenced, not restated: manuscript
extensions come from the Rust `manuscript_format` table, `.bib`/`.ris` from the
schema-refs-adjacent constants the parsers own. A parity test pins capability ↔
authoritative table, in the `ChassisPayloadVocabularyTests` style.

### D2 — A watched folder is a feed

Watched folders are rows of a new **`watched-folder@1.0.0`** schema (path
bookmark, kind scope, enabled, last-scan stats), surfaced in each app's sidebar
through the existing feed machinery — not a new sidebar concept. Refresh is the
feed refresh verb; per-folder counts are feed badges; a folder on an unindexed
volume shows a *declared* degraded state (D6), never a silent empty.

### D3 — The ingest unit differs by kind, and the capability says so

- **`entries` (imbib):** a discovered `.bib`/`.ris` fans out to publication
  entries — the file is a *container*, deduped through the Rust identifier
  machinery against the whole library. This is BibDesk's model generalized and
  matches imbib's standing "BibTeX is the source of truth" decision.
- **`file` (imprint, implore, impart archives):** the file is the record.
  These ingest **reference-in-place** (D4).

### D4 — Reference-in-place, one-way, hash-tracked

Discovered file-unit records carry a security-scoped bookmark, the path, a
content hash and mtime. The store row is an *index entry*; the file stays the
user's. Re-scan updates rows whose hash changed; a vanished file marks the row
`missing` (kept, flagged) rather than deleting it. **No write-back** in v1:
editing a referenced manuscript in imprint either opens in place (explicit
user choice, file becomes authoritative for body) or imports a copy — but the
watcher itself never writes user files. Entry-unit ingest (imbib) imports
entries into the store as today's importer does, tagged with provenance
(source file path + hash) so re-scans are incremental and deletions are
detectable.

### D5 — Discovery is Swift, everything below it is Rust

`NSMetadataQuery` (live) with an FSEvents + manual-walk fallback is
platform code — a thin chassis `FolderWatchService` publishing discovered
paths. Parsing, id derivation, dedup, provenance, and re-scan diffing run
through the existing Rust services (`DocsImportService` grows
`import_discovered(paths, kind_scope, provenance)`; `#[impress_service]` gives
MCP/CLI/Tier-A for free, so an agent can say "watch this directory" too). The
same split SmartSearch used: platform *policy* in Swift, logic in Rust.

### D6 — Honest platform and volume limits

Security-scoped bookmarks persist directory access across launches. Spotlight
does not index some volumes (external disks with indexing off, network
mounts); the folder row states this and falls back to FSEvents + walk where
possible, or declares itself scan-on-demand. iOS has no `mdfind`; v1 is
macOS-only by declared `SettingsPlatform`-style availability, with
iCloud-Drive folders as the recorded iOS follow-up.

### D7 — Startup discipline and scale

The watcher obeys the 90-second background-service rule; initial ingest of a
large folder is batched through the store-mirror-style write gate (≤500 rows,
ordered) with three-point tracing. Re-scans are incremental by hash;
Spotlight's live updates make the steady state event-driven, not polled.

## Ingest map (v1 targets)

| App | Types (from the declared authority) | Unit |
|-----|--------------------------------------|------|
| imbib | `.bib`, `.ris` | entries (dedup by identifier) |
| imprint | `manuscript_format` extensions (`.typ`, `.tex`, `.md`, `.txt`) | file, reference-in-place |
| impart | `.mbox`, `.eml` | file → messages (phase 3 decision) |
| implore | `.vsz` | file, reference-in-place |
| **Phase 2 (imbib)** | PDFs adjacent to a watched `.bib`, matched to entries | attachment (`Bdsk-File` model) |

## Work packages

| WP | Content | Gate |
|----|---------|------|
| W0 | `FileDiscoveryCapability` + parity tests; `watched-folder@1.0.0` schema + schema-refs.json entry; `DocsImportService.import_discovered` with provenance + incremental re-scan (Rust tests over a scratch tree) | cargo green; lint green; capability↔table parity |
| W1 | Chassis `FolderWatchService` (NSMetadataQuery + bookmark persistence + FSEvents fallback), feed-shaped sidebar rows, degraded-volume states | PMC tests; UI test with a temp watched dir |
| W2 | **imbib phase**: watched `.bib`/`.ris` folders end-to-end — add folder (panel + bookmark), live discovery, entry ingest with dedup + provenance, missing-file handling, folder badge/refresh | imbib UI suite + a live-drop simulator test; dedup golden additions |
| W3 | **imprint phase**: watched manuscript folders, reference-in-place rows, open-in-place vs import-copy affordance, `missing` state | imprint suites; editor invariants untouched |
| W4 | impart mbox + implore vsz; iOS iCloud-folder spike recorded | per-app suites |
| W5 | imbib phase 2: adjacent-PDF matching → attachments | golden matches; Bdsk round-trip preserved |

Sequencing: W0 → W1 → W2 ship together as the feature's proof; W3–W5 follow
independently. Every WP updates the capability matrix row for its surface.

## Risks

- **Two-writers on manuscripts** if reference-in-place ever silently gains
  write-back — D4's one-way rule is the invariant; the open-in-place
  affordance is an explicit user handoff, not a sync.
- **Spotlight blind spots** read as data loss — D6's declared states are the
  mitigation; the folder row must never render an unindexed volume as "0
  files".
- **Ingest bursts** on first watch of a huge tree — D7's gate + the enrichment
  burst-analysis precedent (bounded batches, idempotent, resumable).
