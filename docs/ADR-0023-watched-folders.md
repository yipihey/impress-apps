# ADR-0023: Watched Folders — the filesystem as a feed

**Status:** Accepted — **fully implemented (W0–W5 shipped, 2026-07-31 / 2026-08-01)**
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
| impart | `.mbox`, `.eml` | file, index-only — **the fan-out is declined** (W4) |
| implore | `.vsz` | file, reference-in-place — **no figure row minted** (W4) |
| **Phase 2 (imbib)** | PDFs adjacent to a watched `.bib`, matched to entries | attachment (`Bdsk-File` model) — **W5, shipped** |

## Work packages

| WP | Content | Gate |
|----|---------|------|
| W0 | `FileDiscoveryCapability` + parity tests; `watched-folder@1.0.0` schema + schema-refs.json entry; `DocsImportService.import_discovered` with provenance + incremental re-scan (Rust tests over a scratch tree) | cargo green; lint green; capability↔table parity |
| W1 | Chassis `FolderWatchService` (NSMetadataQuery + bookmark persistence + FSEvents fallback), feed-shaped sidebar rows, degraded-volume states | PMC tests; UI test with a temp watched dir |
| W2 | **imbib phase**: watched `.bib`/`.ris` folders end-to-end — add folder (panel + bookmark), live discovery, entry ingest with dedup + provenance, missing-file handling, folder badge/refresh | **SHIPPED 2026-07-31.** `SharedStore.watched*` (the eight verbs, Swift twin of the service's); `WatchedFolderIngestCoordinator` (watcher → `import_discovered` → imbib's real importer → `record_produced_rows` → `finish_watched_scan`); NSOpenPanel (macOS) / `fileImporter` (iOS); sidebar rows both platforms; provenance tag = the folder's list scope; Source File row in both Info tabs. 6 headless end-to-end tests + 2 simulator UI tests (live drop, deduped) + 8 FFI tests |
| W3 | **imprint phase**: watched manuscript folders, reference-in-place rows, open-in-place vs import-copy affordance, `missing` state | **SHIPPED 2026-07-31.** `external_source` (a new OPTIONAL `manuscript` payload field, declared in Rust); `ExternalManuscriptSource` + `ManuscriptStoreAdapter.upsertExternalManuscript` / `markExternalManuscript{Missing,Present}` / `importCopyOfExternalManuscript`; `WatchedManuscriptFolders` supplies the per-kind `produceRows` fan-out to W4's coordinator registry; sidebar rows both platforms (macOS `watchedFileFolder` node under Manuscripts, iOS via `RecordSidebarSectionContent.additionalNodes`); folder scope = `watched/<folder name>` (W2's tag), as `ManuscriptListScope.tag` / `ManuscriptStoreScope.tag`; 7 headless tests + 3 simulator UI tests |
| W4 | **impart + implore phase**: watched `.mbox`/`.eml` and `.vsz` folders, file unit, index-only | **SHIPPED 2026-07-31.** The coordinator became per-KIND (`WatchedFolderImportHooks.produceRows`, one closure; `WatchedFolderIngestCoordinator.coordinator(forKindScope:)`, a registry); `.recordingOnly` is W4's fan-out and is the DECISION, not a stub. `ImbibSidebarNodeType.watchedFileFolder` rows in the Mail and Figures sections; they resolve to `.record(RecordRoute)` on W1's `.host` scope, so no new tab or content-route case. `WatchedFilesPane` is the surface (files, sizes, missing state, per-kind explanation, `Count Messages` through the real Rust mbox parser). iOS iCloud spike recorded below. 13 headless tests |
| W5 | imbib phase 2: adjacent-PDF matching → attachments | **SHIPPED 2026-08-01.** `imbib_core::attachments` (the matcher — four signals, named thresholds, 23 golden cases); a third `FileIngestUnit`, `.attachment`, declared as `FileDiscoveryCapability.attachmentTypes` on the publication kind (`.pdf`, pinned to `UTType.pdf`), so ONE folder registration discovers the `.bib` and its PDFs together; the role marker is DERIVED (`ingestUnit(forFileName:)`), not a `watched-file` column; `WatchedAttachmentMatching` runs the pass at scan close, attaches unique high-confidence matches reference-in-place through `AttachmentManager.linkExistingPDF`, and publishes the rest as `WatchedAttachmentOffer`s; `ImbibStore::export_bibtex` now emits `Bdsk-File-*` from linked-file rows, which is what makes export-after-attach true. 23 Rust golden cases + 12 headless end-to-end tests + 5 new parity tests + a Rust export round-trip test |

Sequencing: W0 → W1 → W2 ship together as the feature's proof; W3–W5 follow
independently. Every WP updates the capability matrix row for its surface.

**All five work packages are shipped.** The remaining open items are the ones
each phase recorded as debt below (W3's editor deferral and imprint-iOS folder
add, W5's PDF-content signal and its iOS surface) and the D6 iOS spike, which is
research rather than a work package. Nothing in this table is outstanding.

### What W2 settled that W0 and W1 left open

- **`removed_ids` disposition** (W0 recorded it as "a product decision"). An
  entry the source file no longer contains is **tagged** `watched/removed-from-source`,
  never deleted, and **un-tagged automatically if it comes back**. A tag renders
  on the row and in the detail pane, is removable with a gesture the user already
  knows, survives relaunch (it is a store row), and `PublicationSource.tag(_:)`
  makes the whole set a list. Rejected: deletion (D4 forbids it), a status change
  (imbib's statuses are the *reading* workflow), and the review queue (its rows
  await an accept/reject decision, and there is no accept verb here — the paper is
  fine, only its source moved on).
- **Where a folder's papers are seen.** The same tag, per folder
  (`watched/<folder name>`), so the folder row's list is an existing, fully
  Rust-backed scope: no new `PublicationSource` case, no new query, no per-folder
  collection in the Libraries tree. Folder display names are uniquified when a
  folder is added, because that name is now an identity.
- **The macOS sidebar row** (W1's matrix left the choice to W2): a
  `ImbibSidebarNodeType.watchedFolder` case, not the `customSurface` seam — a
  custom surface is by construction childless, badgeless and menuless, and this
  row needs all three.
- **The kernel's address.** `watched_folder.rs` moved from
  `impress-store-service` to `impress_core::watched_folder_ops`, so the FFI can
  front it without the MCP/CLI crate (`inventory`, `tokio`) entering every app
  binary. Same triangle `collection_ops` already has; every W0 path still
  resolves through a re-export.

Two defects the phase surfaced and fixed, both silent:

- **A watched file could never be re-read after an edit.** `DiscoveryDiff` was a
  URL set difference, so a `.bib` whose contents changed produced no event at all
  and the live half of the feature was unreachable. The diff now has a third
  bucket (`changed`, by mtime/size) and a `filesChanged` event; a touched file is
  still never an *add*, and whether its bytes really moved is still decided by the
  hash-keyed Rust layer.
- **`import_bibtex_into` dropped the ids it deduped** unless filing into a
  collection, so a re-scan reported every deduped entry as *dropped by the
  source*. `existing` is now always populated.

### What W3 settled that D3 and D4 left open

- **What a reference-in-place manuscript IS.** A new **optional
  `external_source` field on the `manuscript` payload** (declared in
  `crates/impress-core/src/schemas/manuscript.rs`; the schema ref is unchanged,
  `kind_scope` stays `manuscript`, and `schema-refs.json` needed only a
  description edit). It carries `{path, bookmark_base64, content_hash,
  size_bytes, watched_file_id, watched_folder_id, folder_name, read_at,
  state}`. It is deliberately NOT `import_source`, whose documented meaning is
  the opposite claim — "a copy was taken and the original is detached".
  `body_content` still holds a body, but a **snapshot**, replaced wholesale on
  every re-read; `external_source.content_hash` is the hash of the FILE at
  `read_at`, so every existing reader (list row, search, preview, Info tab)
  keeps working while the row can still say "the file has moved on".
- **Why the row cannot fight the file.** Three structural properties, not
  three careful call sites. (1) **No editor session is ever created for an
  external manuscript** — `WatchedManuscriptGuard.allowsEditorSession(_:)` is
  read where a session is minted, so there is no debounced compare-and-set save
  to fire late over a file somebody else is editing (the delete-session-discard
  invariant's cousin, and worse in kind, because the loser would be a user's
  file). (2) The snapshot is **replaced, never merged**, so the store can never
  hold text the file does not. (3) The only verb that touches disk is a read.
  The manuscript row's **id is derived from the path**, so a re-scan updates one
  row instead of accumulating rows — the same rule `watched_file_id` follows.
- **Open-in-place vs import-copy** (D4 named both and left the mechanism open).
  `ManuscriptEditorSession.saveCAS` writes `RustStoreAdapter.setManuscriptBody`
  and has **no file-writing seam**; its lifecycle is frozen. So W3 ships the
  honest v1 the session supports: a **read-only reference pane** with **"Open in
  Another App"** (the explicit handoff — from that moment the user's editor owns
  the file and imprint re-reads it) and **"Import a Copy"** (an ordinary
  manuscript with `import_source`, an editor and no claim on the file). Editing
  a watched file *inside imprint's editor* is the recorded deferral; building it
  means giving the session a file writer, which is ADR-0023's first listed risk
  and not a thing to smuggle into a work package whose contract is "the editor
  invariants are untouched".
- **The `missing` state, imprint's idiom.** Two rows exist per external
  manuscript by design — W0's `watched-file` index row (which the kernel marks
  `missing`) and imprint's `manuscript` row. `WatchedManuscriptFolders
  .reconcileMissing()` mirrors the first into the second as
  `external_source.state = "missing"` **plus the tag
  `watched/removed-from-source`** — W2's spelling reused, because a second word
  for the same situation in a second app is a second thing to learn. The body
  snapshot is KEPT: discarding it would turn "your file moved" into "your text is
  gone", which is D4 in its other direction. Both halves are reversible when the
  file returns.
- **Where a folder's manuscripts are seen.** W2's answer, reused verbatim: the
  provenance tag `watched/<folder name>` IS the scope
  (`ManuscriptListScope.tag` on macOS, `ManuscriptStoreScope.tag` on iOS). No
  per-folder collection, no new query, no second membership truth.
- **A chassis seam W3 needed and W1/W2 did not have.**
  `RecordSidebarSectionContent.additionalNodes` — rows a host CONTRIBUTES to a
  section, appended after the role-derived ones. The pre-existing `nodes`
  REPLACES, which is right for imbib's Libraries (no declaration derives those
  rows) and wrong for imprint's Manuscripts, where All + the six declared
  statuses + the folder tree all come from the descriptor: supplying `nodes`
  there would have put a third copy of the status list in a host.
- **One UI-testing defect fixed, of exactly the shape W2 fixed for imbib.**
  `ManuscriptStoreAdapter.shared` opened `SharedStore.openInMemory()` under
  `--ui-testing` while `WatchedFolderStoreAdapter` opened the scratch FILE — two
  databases, and attribution is a cross-handle claim, so the kernel would
  (correctly) refuse to record that a file produced a manuscript it cannot see.
  Both now open `UITestingEnvironment.scratchDatabasePath`, which is keyed by
  process id and therefore still hermetic per launch.

W3's recorded debt, so it is not re-discovered as a surprise:

- **Editing a watched manuscript inside imprint.** The deferral above. It needs
  a save target on `ManuscriptEditorSession`, which is a decision about the
  frozen editor lifecycle and about ADR-0023's first risk, not a refactor.
- **Adding a watched folder from imprint-iOS.** macOS has the panel (the
  section menu's "Watch Folder for .typ / .tex / .md / .txt Files…"); iOS
  RENDERS folders and lists their manuscripts but has no `fileImporter` entry
  point of its own yet. imbib's `IOSSidebarHost` is the pattern to copy.
- **A body over 4 MB is indexed without a snapshot.** The row, the path, the
  hash and both affordances are all there; only `body_content` is withheld,
  because a multi-megabyte string in a payload is a store problem. The
  manuscript schema's own `blob:sha256:` escape hatch is the eventual answer.
- **Four pre-existing imprint-iOS UI failures** (`LibraryShellUITests` ×3,
  `SeededLibraryShellUITests` ×1 — all "the Manuscripts section header comes
  from AppShellConfiguration" and its two dependents) reproduce identically at
  `bf0c09aa` in a clean worktree. They are not W3's, and they are the reason
  that suite is not currently a usable gate.

### What W4 settled that the ingest map left open

**The mbox fan-out: declined for v1, and this is the decision, not a deferral.**
The ingest map said "file → messages (phase 3 decision)". W4 answers **no**, and
records why so the question does not get re-asked as if it were open:

- **There is no import flow to hand off to.** The premise that impart has an
  mbox importer is false. `MessageManagerCore/Mbox/MboxConversationStore` is a
  *research-conversation* store (RFC 4155 as a transcript format) with its own
  private parser and no path-taking import verb; `crates/impart-core/src/mbox.rs`
  is the same thing in Rust and is not reachable from Swift at all
  (`ImpartRustCore/Exports.swift` is still a placeholder). PMC's
  `MboxImporter`/`EverythingImporter` *are* real and *do* take a file path — but
  they import **imbib library exports** that happen to use mbox as a container
  (`[imbib Library Export]`, `X-Imbib-*` headers), and pointing them at a user's
  mail archive would try to make publications out of email. So the "wire the
  per-archive Import… action if the flow takes a path" branch resolves to: there
  is no such flow, and inventing one is a feature, not a wiring job.
- **The lifecycle has no owner.** `MessageRecordKind` declares neither dismissal
  nor deletion because mail's lifecycle is IMAP-owned (Stage 2-A). Rows minted
  from a file would have read state and threading that nothing reconciles, and
  no verb could move or delete them.
- **It is D7's burst hazard in its purest form.** A 2 GB archive fanning out to
  50,000 message rows *at the moment the user picks a folder in a panel* is the
  exact shape the write gate exists to prevent, and the gate does not help: the
  rows are legitimately owed, they are just owed at a time nobody chose.

What ships instead is the honest remainder, and it is not nothing: which
archives exist, where, how large, whether their bytes moved, whether they
vanished — the whole hash-tracked `watched-file` row from W0 — plus an
**offer**. The offer is `Count Messages`, which runs the REAL parser
(`imbib_core::mbox::parse_content`, the Stage-7.9 port pinned by 23 golden
archives) **under a declared 64 MB ceiling**, and refuses above it in a sentence
the row renders. A refusal is not an error state: the archive is fine, and
reading a multi-gigabyte file to draw a subtitle is the thing that is not.

**implore mints no figure rows, and the code said so before ambition could.**
The ingest map's "reference-in-place" turned out to have nowhere to put the
reference: `figure`'s store payload is `{title, format, caption, data_hash,
script_hash}` (`FigureStoreWriter.figureRow`) and has **no path field** — the
in-place file reference lives in implore's Rust `LibraryFigure.dataset_source`,
which the store mirror does not carry. And there is no Veusz reader anywhere in
the suite, in Rust or Swift, so a figure minted from a `.vsz` would have a name
and nothing else, and its View tab would be correctly hidden (`data_hash` is
optional, so the row would at least not lie about having a rendering). implore's
v1 is therefore the watched-file rows and a listing, deliberately: implore has
**no unit-test target of its own and no test oracle beyond the macOS build**
(hardening C3, `docs/chassis-capability-matrix.md`), so its blast radius is kept
to a sidebar row and a read-only pane, with its row wiring pinned by tests in
PMC — the only place such a test can live.

**The coordinator became per-kind, with one closure.** W2 hard-wired
`importBibTeX` because one kind existed. D3 says the ingest UNIT differs by
kind, so exactly one thing varies: *one discovered file → the store rows it
accounts for*. That is `WatchedFolderImportHooks.produceRows`; everything around
it (recording the discovery, deciding by hash whether the fan-out is owed,
attributing, sweeping) is kind-agnostic and stayed put. imbib's BibTeX
initializer is kept verbatim, so W2's six end-to-end tests are untouched by the
generalization. A process now runs one coordinator per kind
(`coordinator(forKindScope:)`), and `restorePersistedFolders` grew a
`limitedToFilterIDs` narrowing — without it every coordinator restores every
bookmark and impart writes imbib's `.bib` folder into the store a second time
under `kind_scope: message`.

W3 and W4 were built concurrently against the same chassis files, and the
extraction above is the seam they met at: W3 adopted `coordinator(forKindScope:)`
and added its own `.manuscript: .manuscripts` row to W4's declared
`watchedFileSections` table, which is exactly what a declared table is for. One
real collision surfaced and was fixed rather than papered over: the registry
lookup is `@MainActor` (it returns a main-actor object) while
`RecordRouteScope.init?(routeScope:)` — the requirement that turns a sidebar
selection into a list scope — is **nonisolated**, so W3's manuscript arm could
not read `rows` at all. The fix is on the API's side, not the call site's:
`WatchedFolderIngestCoordinator.provenanceTagPath(ofFolder:kindScope:)`
publishes the id→name map behind a lock. Publishing beats the three
alternatives — the initializer is synchronous so it cannot hop, it runs inside a
view body so it must not block, and `assumeIsolated` traps the first time a
route is decoded from anywhere else.

**The sidebar row needed no new tab.** W2's macOS row bought a
`ImbibSidebarNodeType` case *and* an `ImbibTab` case, because a `.bib` folder
opens a publication list. A file-unit folder opens the files, and Stage 3
already made `.record(RecordRoute)` the one destination every kind's rows
resolve to — over `RecordSidebarScope.host`, which is what
`WatchedFolderRoute.scope(kind:)` has returned since W1. So the row is one node
case and a prefix arm in the kind's viewer factory; `ImbibTab`,
`ImbibContentRoute` and `SectionContentView` are unchanged. The one thing that
DID need care: a host scope the kind's list scope correctly declines to parse
would otherwise fall through to the registry's `EmptyView()` — a selectable
sidebar row that opens nothing.

### What W5 settled that the ingest map left open

The ingest map's phase-2 row said "PDFs adjacent to a watched `.bib`, matched to
entries — attachment (`Bdsk-File` model)" and left every mechanism open. Here is
each answer and the argument for it.

**The matcher is Rust, in imbib-core, and it reuses rather than reinvents.**
`imbib_core::attachments` takes (entries with their fields, candidate PDF paths)
and returns per-pairing verdicts. It lives in imbib-core rather than beside the
watched-folder kernel because every signal it needs is already there —
`bibtex::bdsk_file` decodes what BibDesk wrote, `deduplication::{normalization,
similarity}` owns the suite's NFKD-then-ASCII title/author folding and its
0.6·Jaro-Winkler + 0.4·Levenshtein blend, and `filename` owns imbib's own
`Author_Year_Title.pdf` scheme (imbib ADR-004). `impress_core`, where the kernel
lives, depends on none of those and must not: it is the suite-wide store crate.
The one change to the machinery being reused was to widen
`similarity::title_similarity` from private to `pub(crate)` — the thresholded
`titles_match` bool is the wrong granularity for a scorer, and writing a second
blend would have been a second answer to "how alike are two titles".

**Four signals, in credibility order, with the boundary as the point.**

| Signal | Confidence | Why it ranks there |
|---|---|---|
| `Bdsk-File-*` / `file` / `local-file` naming the PDF | 1.00 exact path, 0.97 basename-only | The entry names the file. This is BibDesk's data, written by the user's own tool. |
| filename stem = cite key | 0.95 exact, 0.93 normalised | A cite key is unique within a `.bib` by construction. |
| filename = imbib's own `Author_Year_Title` | 0.92 | imbib named it, or a user followed imbib's documented scheme. |
| title/author/year similarity | ≤ 0.88 | A guess, however good. |

`AUTO_ATTACH_CONFIDENCE` is **0.90**, and it sits deliberately *between* house
naming and the fuzzy ceiling. That is the design, not a tuned number: the three
signals above the line are cases where somebody **stated** the association, the
one below it is a case where we **inferred** it, and assertion gets acted on
while inference gets offered. A consequence worth naming — **no re-tuning of the
fuzzy weights can ever turn a guess into a silent write to a user's library**,
because the ceiling is a hard clamp below the threshold. `OFFER_CONFIDENCE`
(0.55) is the floor below which a candidate is not shown at all: offering a 0.2
match trains a user to dismiss the offer surface, which costs more than the
occasional missed match.

Two rules make uniqueness work. `AMBIGUITY_MARGIN` (0.08): a leader must be
clear of its runner-up or nothing is automatic. And a **declaration outranks
every inference categorically** — 1.00 vs 0.95 is inside the margin, so without
this rule an entry's explicit `Bdsk-File-1` would lose an argument to another
entry that merely happened to share the file's name. Two entries that BOTH
declare the same file are genuinely ambiguous and fall through to the margin,
which they fail, so they are offered.

**The golden corpus is 23 cases** (`test_fixtures/golden/pdf_match_golden.json`,
`tests/pdf_match_golden.rs`), size-pinned, every case carrying a `why` the test
itself asserts is present — a golden number with no argument beside it is a
number that gets changed to make a test pass. Writing it found three real
defects before any Swift existed:

- **`Noether 1918.pdf` did not match cite key `Noether1918`.** The name
  comparison collapsed separators to spaces, which is right for
  `Author_Year_Title` and wrong for a cite key, which is ONE token. Cite keys
  now compare in a squashed form.
- **The fuzzy blend could not serve both of its jobs.** The original
  `0.6·title + 0.25·surname + 0.15·year`, scaled by the ceiling, put
  `Einstein 1905.pdf` at 0.48 — below the offer floor — so the classic
  two-papers-one-author case produced *no offer at all*, which is worse than a
  wrong one. Reweighted to `0.55·title + 0.30·surname + 0.15·year` summing to
  exactly 1.0 and clamped by the ceiling: a file named for the title alone and a
  file named `Author Year.pdf` both now clear the floor, which are the two
  shapes real filenames take.
- **The same-author-same-year case was testing the wrong rule.** A fuzzy leader
  can never auto-attach anyway, so that case exercises the *ceiling*, not the
  *margin*. The margin needed a case where the leader is above 0.90:
  `adversarial/house-naming-collides-on-two-entries` — a two-part paper whose
  halves generate an identical `Author_Year_Title` name, both at 0.92. Only the
  margin stops that from attaching to whichever sorted first.

The corpus's adversarial half also pins: a PDF matching nothing (unmatched, not
forced), `ell` not matching `Russell` (word-boundary containment, not
substring), a declared `per.pdf` not being satisfied by `paper.pdf` (path
components, not `ends_with` — the worst failure this module could have is a
wrong file at confidence 1.0), NFD-on-disk vs NFC-in-the-`.bib`, LaTeX escapes
(`K\"orper` vs `Körper`), spaces-vs-underscores in both the cite-key and
house-naming shapes, an entry with no title being unguessable, and two entries
claiming one file.

**Discovery scope: a declared attachment TYPE, a derived role, and no schema
change.** The ADR left this as a choice between a `watched-file` row per PDF
with a role marker and a coordinator-internal second filter. The answer is
neither exactly:

- The publication kind's `FileDiscoveryCapability` grew
  **`attachmentTypes: [FileTypeSpec]`** — a second list beside `types`, not two
  more rows in it. `types` is pinned against
  `impress_core::bibliography_format`, whose own test freezes it to the
  BibTeX/RIS pair, and **a PDF is not a bibliography interchange format**;
  adding a row saying it is would make the authority table lie in order to move
  a file through a filter. The two lists also answer different questions and
  callers depend on the difference: `fileExtensions` means "becomes a record of
  this kind" and is what `descriptor(forFileExtension:)` reads, which must keep
  returning `nil` for `.pdf` (dropping a PDF on imbib is not "import a
  publication"). `discoveryExtensions`, the union, is what the watcher's filter
  is built from — so it really is **one folder, one registration, one gather**.
- PDFs therefore **do** get full `watched-file` rows (`kind_scope: publication`),
  which is where their hash tracking, their re-scan diffing and their missing
  sweep come from for free. W0 built that bookkeeping unit-agnostically and this
  is the payoff.
- **The role marker is DERIVED, not stored.** `FileDiscoveryCapability
  .ingestUnit(forFileName:)` answers "`.bib` → entries, `.pdf` → attachment"
  from the declaration. A `role` column on `watched-file@1.0.0` was rejected for
  the reason the schema's own test already encodes: `folder_does_not_restate_the
  _capability` refuses to let a watched-folder row carry the extensions or the
  ingest unit, on the grounds that the capability is the authority and a column
  would be a second one — and a per-file role is that same restatement one row
  down. Deriving also means **no migration and no backfill**: every row W2 wrote
  reads correctly under W5.
- The PDF's UTI is `UTType.pdf.identifier`, read from `UniformTypeIdentifiers`
  rather than spelled. D1's "reference the authority, do not restate it" applies
  to Apple's tables exactly as it applies to ours, and unlike
  `com.impress.bibtex-entry` it needs no `project.yml` claim of ours.

**Attachment mechanics, and the round-trip defect this surfaced.** A matched PDF
attaches through `AttachmentManager.linkExistingPDF` — reference-in-place, the
absolute path on an ordinary `imbib/linked-file` row, no copy into imbib's
`Papers/` directory. That verb had existed since imbib ADR-004 with **no caller
anywhere**; W5 is what it was for. Two things had to change for it to work:

- **`resolveURL` could not resolve what it linked.** Every other linked file in
  imbib lives inside the library container, so `relativePath` is relative to
  that container; appending an absolute path to it yields `<container>//Users/…`,
  which exists nowhere. The ladder would have missed every candidate and handed
  back a URL that cannot open — indistinguishable from "the PDF is missing".
  An absolute path is now resolved as itself, in both `resolveURL` and
  `linkExistingPDF`.
- **`ImbibStore::export_bibtex` never emitted `Bdsk-File-*` from an
  attachment.** The only code in the suite that did was `UnifiedExportView`,
  splicing text into an exported string, opt-in, in one SwiftUI view — so
  attaching a PDF and then reading the entry's BibTeX anywhere else (the detail
  tab, the CLI, the MCP tool, an agent) produced a `.bib` that silently did not
  mention the file. W5's gate is *export-after-attach*, and it cannot be met by
  a code path one window can reach. `export_bibtex` and `export_all_bibtex` now
  join the publication's `imbib/linked-file` children and encode each path with
  `bdsk_file_encode`. One deliberate asymmetry: an entry that arrived carrying
  `Bdsk-File-1` keeps it **verbatim**, and only attachments it does not already
  declare are added — re-encoding a field we did not write would replace the
  user's BibDesk alias data (which carries a bookmark and a container path) with
  our smaller `relativePath`-only plist.

**A silent defect the phase found: the strongest signal was unreachable.** The
matcher's top-ranked signal is the entry's own `Bdsk-File-*`, and it worked in
every unit test and would have done nothing in the app. `bibtex_entry_to
_publication`'s catch-all puts unrecognised fields into `extra_fields`, which
persists as a **nested payload object**, and `item_to_publication_detail`
flattens only *top-level* `Value::String`/`Value::Int` entries into `fields` —
so a publication imported from a BibDesk `.bib` carries its `Bdsk-File-1`
faithfully in the store and shows none of it to any Swift caller. Every test
that builds a matcher input by hand passes regardless, which is exactly the
shape of bug this campaign has hit before (the schema-ref class: a reader that
returns nothing, silently, looking like "there is no data"). The fix is narrow —
`AttachmentEntry(publication:)` recovers the file fields from `raw_bibtex`,
which IS a top-level string, when the flat bag has none — and the guard is a
test that goes through the **real importer** rather than constructing an entry
(`testABibDeskFileFieldAttachesItsPDFThroughTheRealImporter`). Re-flattening
`extra_fields` into `PublicationDetail.fields` would be the deeper fix and is
not W5's to make: half the app reads that bag.

**The offer surface, and its honest limit.** Ambiguous and unmatched PDFs become
`WatchedAttachmentOffer` values the coordinator publishes per folder; the macOS
watched-folder row's context menu gains **"Review N PDF Matches…"**, which is
**omitted entirely when there is nothing to review** — the same "omit a dead
affordance, never show one" rule that row's Refresh and Choose Again… already
follow. The sheet lists each file with its candidates, each candidate's
confidence and the sentence explaining it, and Reveal in Finder; confirming
runs the same `linkExistingPDF` the automatic path runs, so there is no second
kind of attachment. **iOS gets no surface in v1**, and this is the honest note
rather than an oversight: imbib-iOS's watched-folder rows have no row menu at
all (W2's decision, recorded in the capability matrix), so the review verb has
nowhere to hang, and inventing an iOS-only presentation for it would be a
surface with no sibling. The matching itself is platform-neutral and runs on
both; only the review affordance is macOS-only.

**Provenance and missing.** An attached PDF that vanishes keeps its
`watched-file` row (W0's sweep marks it `missing`) **and keeps its
attachment**. Detaching would erase a fact the user established because a disk
was unplugged; the row says the file is gone, which is honest and is what
`PublicationPDFAvailability.fileMissing` already renders. A missing PDF is also
not re-offered — it is missing, not unclaimed.

**Idempotency is checked against the store, not against memory.** The attach
step skips any PDF the publication already links, read back through
`listLinkedFiles`. That holds on a re-scan even if the coordinator's "did
anything move?" reasoning is wrong, which is the only kind of guarantee worth
having when the failure mode is a duplicate row in a user's library. The
zero-write property W2 proved for the importer covers this for free in the
common case — an unchanged folder produces no discovery event, so the pass does
not even run.

W5's recorded debt:

- **The strongest signal is not used.** A DOI or arXiv id extracted from page 1
  of the PDF would outrank every filename heuristic here, and
  `im_identifiers::extract_all` plus `imbib_core::pdf` already supply both
  halves. It is deferred because it costs a full text extraction per candidate
  *at scan time*, which is D7's burst hazard spent on a subtitle. The right
  shape when it is built is on-demand per offer ("Identify this PDF"), not on
  gather.
- **`bdsk_file_encode` writes a `relativePath`-only plist.** Real BibDesk writes
  an `NSURL`-archived dict with `relativePath`, `containerPath` and bookmark
  data. imbib READS BibDesk's files correctly (it picks `relativePath` out and
  ignores the rest); what imbib WRITES is lossy by comparison. Pre-existing, not
  W5's, but W5 made it reachable from a new path and it should be recorded.
- **Two Swift `Bdsk-File` codecs.** `RustBdskFileCodec` (over the FFI) has no
  production callers; `BdskFileCodec` (a hand-written `PropertyListSerialization`
  implementation in `BibTeXExporter.swift`) is the one everything uses. A live
  Rust-first violation, found while mapping the model. W5 did not consolidate
  them because the export path it changed is the Rust one, and swapping the
  Swift codec is a separate change with its own blast radius.
- **`linkExistingPDF` writes `fileSize: 0`**, which defeats
  `checkForDuplicate`'s size pre-filter. Pre-existing on a verb that had no
  callers; now it has one.

### D6 follow-up: watched folders on iOS (spike, recorded — not built)

D6 declared v1 macOS-only "with iCloud-Drive folders as the recorded iOS
follow-up". This is that record. **Nothing here is implemented**; it is desk
research against the API surface and against what W0/W1 already assume.

**What the platform actually offers.** `NSMetadataQuery` exists on iOS, but
only over *ubiquitous* scopes: `NSMetadataQueryUbiquitousDocumentsScope`,
`NSMetadataQueryUbiquitousDataScope` and (iOS 13+)
`NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope`.
`NSMetadataQueryLocalComputerScope` — the scope W1's Spotlight engine uses — is
macOS-only, and there is no `mdfind` on iOS. So the live half of this feature
exists on iOS **exactly and only inside iCloud Drive**, and the scopes are the
app's own ubiquity container(s): there is no API that watches "a folder the user
picked in Files" with live updates.

The good news is that the query's *shape* maps one-to-one onto what W1 already
publishes. `NSMetadataQueryDidStartGathering` / `GatheringProgress` /
`DidFinishGathering` / `DidUpdate` — the last carrying
`NSMetadataQueryUpdateAddedItemsKey`, `…ChangedItemsKey`, `…RemovedItemsKey` —
are `FolderWatchEvent.gatheredBatch` / `.filesAdded` / `.filesChanged` /
`.filesRemoved`, in that order, with `enableUpdates()`/`disableUpdates()` giving
the batching D7 asks for. A `UbiquitousMetadataDiscoveryEngine` would be a third
`FolderDiscoveryEngine` beside Spotlight and Walk, and nothing above it changes.

**Three things that would bite.**

1. **The UTI clause matches nothing.** iCloud items are not Spotlight-indexed on
   device, so `kMDItemContentTypeTree` is unavailable and only the
   filesystem-level attributes are reliable (`NSMetadataItemFSNameKey`,
   `…ItemPathKey`, `…ItemURLKey`, `…ItemFSSizeKey`,
   `…ItemFSContentChangeDateKey`). A predicate built from UTIs would return zero
   rows forever — the *exact* failure W0 found for `.ris` and built
   `requiresFilenameFallback` to prevent. On iOS that fallback is not the
   exception, it is the whole predicate: `FileDiscoveryFilter` needs a
   `ubiquitousPredicateFormat` that emits the filename clause only.
2. **A discovered file may not exist locally.** `NSMetadataUbiquitousItem
   DownloadingStatusKey` (`.notDownloaded` / `.downloaded` / `.current`),
   `…IsDownloadingKey` and `…PercentDownloadedKey` are the truth; a watcher that
   reads bytes must call `startDownloadingUbiquitousItem(at:)` and wait, or
   hash a placeholder and record a lie. The kernel's content hash is what makes
   re-scans incremental, so this is not cosmetic. The honest v1 is a **fifth
   `WatchedFolderState`** (or a labelled `.fallback`): *"in iCloud — not
   downloaded"*, materialized on the user's explicit action, never eagerly (D7).
   `FileManager.url(forUbiquityContainerIdentifier:)` also returns `nil` when
   iCloud is off or nobody is signed in, and blocks — it must be called off the
   main thread, and its nil is another declared degraded state, which is exactly
   the shape D6 already has a vocabulary for.
3. **Bookmarks behave differently in the iOS sandbox.** `withSecurityScope` is a
   macOS-only bookmark option; on iOS a folder chosen through `fileImporter` /
   `UIDocumentPickerViewController` is bookmarked with `.minimalBookmark`,
   resolved with `bookmarkDataIsStale` checked, and wrapped in
   `startAccessingSecurityScopedResource()` / `stop…` around every access.
   Such a bookmark survives relaunch but **not** reinstall or
   restore-from-backup, and a folder living behind a third-party File Provider
   (Dropbox, Google Drive) can be unresolvable until that extension is running.
   `WatchedFolderBookmarkStore` would need an iOS branch and an honest
   "re-grant" path — which it already has an affordance for (`Choose Again…`).

**No FSEvents.** For a non-iCloud user-selected folder the options are
`NSFilePresenter`/`NSFileCoordinator` (works, one presenter per directory,
heavyweight), a `DispatchSource.makeFileSystemObjectSource` on an open directory
descriptor (works for the app's own container, unreliable across File
Providers), or polling on foreground. None is a watcher. **`scanOnDemand` is the
correct declared state for those folders — which is precisely what W2 already
reports on iOS**, so that half needs no change at all.

**Recommended shape, if this is ever built.** One engine, one scope, opt-in:
watch the app's **own ubiquity container's `Documents` directory**, exposed to
the user through Files by declaring `NSUbiquitousContainers` with
`NSUbiquitousContainerIsDocumentScopePublic = true`. The user drops a `.bib`
into "imbib" in Files and it appears — the same story as the macOS folder, in
the only place iOS can actually tell us about it live. Do **not** attempt to
watch arbitrary picked folders: they get the `scanOnDemand` row they already
get, with a Refresh verb, and that is honest. Materialize on demand, never on
gather. Everything below the engine — `import_discovered`, the hashes, the
provenance, the sweep — is unchanged Rust, which is the point of D5.

Two cautions on cost. This needs an iCloud container entitlement and a review
pass, and it must not be confused with **ADR-0020**'s suite-wide CloudKit sync
of the graph store (feature-flagged, default OFF): two iCloud mechanisms in one
binary, one syncing the store and one watching a folder, is a support
conversation waiting to happen and the settings copy has to distinguish them.

## Risks

- **Two-writers on manuscripts** if reference-in-place ever silently gains
  write-back — D4's one-way rule is the invariant; the open-in-place
  affordance is an explicit user handoff, not a sync. **W3's mitigation is
  structural**: a manuscript carrying `external_source` never takes an editor
  session (`WatchedManuscriptGuard.allowsEditorSession`), so the second writer
  cannot exist to race. The risk returns the day someone gives
  `ManuscriptEditorSession` a file-writing save target; that is the deferral,
  and it needs its own decision, not a follow-up commit.
- **Spotlight blind spots** read as data loss — D6's declared states are the
  mitigation; the folder row must never render an unindexed volume as "0
  files".
- **Ingest bursts** on first watch of a huge tree — D7's gate + the enrichment
  burst-analysis precedent (bounded batches, idempotent, resumable).
