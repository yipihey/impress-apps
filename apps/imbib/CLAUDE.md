# imbib - Claude Code Briefing

Cross-platform (macOS/iOS) scientific publication manager. BibTeX/BibDesk-compatible, multi-source search (arXiv, ADS, Crossref, etc.).

> ⚠️ **SUPERSEDED — data layer is the Rust store, not Core Data.**
> imbib migrated off Core Data + CloudKit onto the unified impress-core
> SQLite item store (ADR-023). The single data path is
> `RustStoreAdapter.shared` (`@MainActor @Observable`) over `ImbibStore`
> (imbib-core UniFFI) + `SharedStore` (impress-store-ffi), both opening
> `SharedWorkspace.databasePath`. **Ignore the Core Data / `CDPublication` /
> `PublicationRepository` / CloudKit descriptions below** — they document the
> retired architecture and are kept only for historical context. Value-type
> models (`PublicationModel`, `LibraryModel`, `CollectionModel`, …) replace
> the managed objects; the to-many / `mutableSetValue` / actor-boundary
> pitfalls no longer apply. As of GUI-meld (ADR-0018), the macOS GUI chassis
> also lives in `PublicationManagerCore` (`Chassis/`, `Manuscript/`) and is
> shared with imprint; manuscripts are first-class store rows.

> **imbib surfaces PUBLICATIONS ONLY (2026-07-27).** The Manuscripts section
> left imbib's sidebar — manuscript organization lives in imprint (and
> eventually impress). `AppShellConfiguration.imbib.visibleSections` is now an
> EXPLICIT set (inbox, libraries, sharedWithMe, scixLibraries, search,
> exploration, flagged, citedInManuscripts, artifacts, reviewQueue,
> dismissed); it was `nil`, which opted imbib into every section the chassis
> grew. A new section must opt IN there. This is GUI SURFACING only: the
> chassis manuscript/figure code (`Chassis/Manuscripts/`, `Chassis/Figures/`,
> `CollectionStoreAdapter`, `ManuscriptSectionView`) is untouched and is what
> imprint and implore run on, and manuscripts remain first-class store rows.
> Regression sweeps of the manuscript sidebar/section belong to **imprint**,
> not imbib. See docs/chassis-capability-matrix.md ("Frozen shell-preset
> truth table" + Known gaps) and ADR-0022 D9.

> **imbib's window is NOT a chassis root (plan wave 6 W5, 2026-09-24).** Every
> other app's macOS window is the ADR-0031 layout tree (`ChassisRootView` →
> `LayoutTreeHost`; the `impress.layoutTree.enabled` flag is gone). imbib's
> own window is its pre-chassis `ContentView`, which hosts `TabContentView`
> directly and still reads `PaneLayoutState` — so its ⌘0 / ⌥⌘0 / ⌃⌘S pass
> `PaneLayoutChordTarget.imbibPreChassisWindow` and its `/api/layout` routes
> still drive that model. Since W5 pass B that model and `FocusedPane` live
> in THIS app target (`imbib/PaneLayoutStore.swift`, `imbib/FocusedPane.swift`),
> not in PublicationManagerCore: the shared views read it through the
> `hostWindowPanes` environment value `ContentView` injects, and the router
> forwards `/api/layout*` to the host `imbibApp.init` registers
> (`PreChassisLayoutRoutes`). Its tests are `imbibTests/PaneLayoutStoreTests`.
> Moving this window onto the tree is its own decision, not a side effect of a
> chassis change.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  macOS App              │           iOS App                 │
├─────────────────────────┴───────────────────────────────────┤
│                    Shared SwiftUI Views                     │
├─────────────────────────────────────────────────────────────┤
│                 PublicationManagerCore (95% of code)        │
│    Models │ Repositories │ Services │ Plugins │ ViewModels │
├─────────────────────────────────────────────────────────────┤
│         Rust graph store (impress-core, SQLite)             │
└─────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

| Area | Decision | Details |
|------|----------|---------|
| Data | Rust graph store (SQLite) | All access via `RustStoreAdapter.shared`; Core Data is migration-only legacy |
| BibTeX | Source of truth | Round-trip fidelity, `Bdsk-File-*` support, cite keys: `{LastName}{Year}{TitleWord}` |
| PDFs | Human-readable names | `Author_Year_Title.pdf`, relative paths from .bib location |
| Plugins | Actor-based | `SourcePlugin` protocol, built-in: ArXiv, Crossref, ADS, PubMed, Semantic Scholar, OpenAlex, DBLP |
| Papers | Unified model (ADR-016) | All papers are CDPublication, search results auto-import |
| Formats | BibTeX + RIS | First-class RIS support with bidirectional conversion |
| Automation | URL schemes + AppIntents | `imbib://...` for AI agents, Siri Shortcuts, CLI tool |

## Platform Parity

| Component | macOS | iOS |
|-----------|-------|-----|
| Detail SHELL | `Chassis/Detail/DetailView.swift` | `Chassis/Detail/IOS/IOSPublicationDetailPane.swift` — **in PMC and PUBLIC since I2** |
| Detail TABS | `Chassis/Detail/Tabs/{Info,PDF,Notes}Tab.swift` | `Chassis/Detail/IOS/{IOSInfoTab,IOSPDFTab,IOSNotesTab}.swift` — chrome only; the DATA/logic is shared (Stage 5b), and the chrome moved into PMC in I2 |
| BibTeX tab | `Chassis/Detail/Tabs/BibTeXTab.swift` | **the same view** — `IOSBibTeXTab` deleted |
| Publication LIST | `UnifiedPublicationListWrapper` | imbib: `IOSUnifiedPublicationListWrapper` (app-target; imbib's triage + BibTeX sheet + sort controls). OTHER hosts: `Chassis/Shared/IOSPublicationListPane.swift`, read-only |
| Manuscript detail | `Chassis/Manuscripts/ManuscriptDetailPane.swift` (editor host, macOS-only) | imprint-iOS: `IOSManuscriptEditorHost`. Viewer-only hosts: `Chassis/Manuscripts/IOSManuscriptReadOnlyPane.swift` (I2) |
| Sidebar | `SidebarView.swift` | `Chassis/Shared/RecordSidebar/RecordSidebarView.swift` + `ImbibSidebarBindings` / `IOSSidebarHost` (wave 3; `IOSSidebarView.swift` deleted) |
| Settings | `SettingsView.swift` | `IOSSettingsView.swift` (both on the chassis registry, Stage 6 phase 2) |
| Console | `ImpressLogging.ConsoleView` | **the same view**, presented by `ConsoleScreen`; `IOSConsoleView` is a 6-line entry point |

**I2 (2026-07-30) moved the iOS detail CHROME into PMC.** `IOSDetailView`,
`IOSInfoTab`, `IOSPDFTab`, `IOSNotesTab` and their three private dependencies
(`IOSNoPDFView`, `IOSPDFBrowserView`, `IOSNotesEditorView`) left the imbib-iOS
target for `Chassis/Detail/IOS/`. imbib-iOS CONSUMES them; its two call sites in
`IOSContentView` name `IOSPublicationDetailPane`. Three injection points were
parameterised and nothing else changed — `LibraryViewModel` (Copy BibTeX) and
`LibraryManager` (the Explore row) are now OPTIONAL environment reads, and
`libraryID` is optional (the pane resolves the record's own). A host that
injects neither gets the pane with the store's BibTeX export and no Explore row.
**A new detail affordance still goes in `Chassis/Detail/Shared/`; a new piece of
iOS CHROME now goes in `Chassis/Detail/IOS/`, not in the app.**

**Shared in Core**: `PDFViewerWithControls`, `BibTeXEditor`, `BibTeXTab`,
`PublicationListView`, `MailStylePublicationRow`, `ScientificTextParser`, and
the detail pane's shared halves in `Chassis/Detail/Shared/`
(`PublicationIdentifierLink`, `PublicationFlagAndTagsSection`,
`PublicationExploration`, `PublicationNotesDocument` + `PublicationNotesWriter`,
`PublicationPDFSwitcher`, `PublicationPDFAvailability`,
`publicationDetailLifecycle`). **A new detail affordance goes in one of those
files, not in a per-platform copy** — see docs/chassis-capability-matrix.md
("Publication detail pane") for the six bugs the previous copies were hiding,
including iOS showing the user their own YAML notes front matter as prose.

**The `note` field has a FORMAT**: YAML front matter (quick annotations,
label-keyed) + freeform markdown. Read and write it through
`PublicationNotesDocument`, never as a raw string — that was the iOS notes bug.

**Platform gotchas**:
- `Color(nsColor: .controlBackgroundColor)` → `Color(.secondarySystemBackground)`
- `NSViewRepresentable` → `UIViewRepresentable`
- Notes in `publication.fields["note"]`, not a `notes` property

## Coding Conventions

- Swift 5.9+, strict concurrency
- `actor` for stateful services, `struct` for DTOs, `final class` for view models
- Prefer `async/await` over Combine
- Domain errors conform to `LocalizedError`
- Tests: `*Tests.swift` in `PublicationManagerTests/`

**Naming**: Protocols `*ing`/`*able`, implementations no suffix, view models `*ViewModel`, platform-specific `+platform.swift`

## Key Types

```swift
CDPublication: NSManagedObject  // Core Data model (citeKey, entryType, rawBibTeX, relationships)
BibTeXEntry: Sendable           // Interchange (citeKey, entryType, fields, rawBibTeX)
RISEntry: Sendable              // RIS format (type, tags, rawRIS)
SearchResult: Sendable          // Cross-source (id, title, authors, year, sourceID, pdfURL)

protocol SourcePlugin: Sendable {
    func search(query: String) async throws -> [SearchResult]
    func fetchBibTeX(for: SearchResult) async throws -> BibTeXEntry
}
```

## Core Data Pitfalls

These are hard-won lessons from debugging sessions. Violating them causes silent data loss or display bugs.

### To-Many Relationship Mutations

**Always use `mutableSetValue(forKey:)` for to-many relationships.** Never use direct property assignment.

```swift
// CORRECT — Core Data's documented approach for to-many mutations
let tagSet = publication.mutableSetValue(forKey: "tags")
tagSet.add(tag)

// WRONG — may not trigger Core Data change tracking reliably
var currentTags = publication.tags ?? []
currentTags.insert(tag)
publication.tags = currentTags  // Core Data may not detect the change
```

`mutableSetValue(forKey:)` returns a live proxy `NSMutableSet` that properly notifies Core Data of individual additions/removals. Direct property assignment requires Core Data to diff the old and new sets, which can fail silently — especially across actor boundaries or with CloudKit containers.

### Actor Boundaries with Managed Objects

`PublicationRepository` is an `actor`. Core Data managed objects (`CDPublication`, `CDTag`, etc.) are **not Sendable**. They are passed across actor boundaries as reference types. This works because:

1. All operations use `viewContext.perform { }` which dispatches to the main queue
2. The `viewContext` is a main queue context
3. The calling code (SwiftUI views) is also on the main actor

**Do not** create background contexts in the repository without careful consideration of object ownership.

### Data Flow Pipeline

Data flows through a multi-layer pipeline. When something "doesn't display," trace each layer:

```
Core Data (CDPublication.tags)
  → PublicationRowData.extractTagDisplays()  // snapshot at rebuild time
    → rowDataCache[id]                        // cached in PublicationListView
      → MailStylePublicationRow(data:)         // passed to row view
        → TagLine / FlagStripe                  // rendered component
```

Key insight: **data persistence and data display are independent failure modes.** A feature can save correctly to Core Data but not display because the snapshot layer (`PublicationRowData`) wasn't rebuilt, or vice versa.

To force a row data rebuild after in-place mutations (flag/tag changes that don't add/remove publications), bump `listDataVersion += 1`. This triggers `.onChange(of: dataVersion)` in `PublicationListView`, which calls `rebuildRowData()`.

### Console Logging

The app has an internal console window (⌃⌘C — View ▸ Show Console; ⇧⌘C is Copy as Citation in imbib). Use `*Capture()` methods to log to both OSLog and the console:

```swift
Logger.library.infoCapture("message", category: "tags")  // shows in console
Logger.library.info("message")                             // OSLog only
logInfo("message", category: "tags")                       // global convenience
```

When adding new features that touch Core Data, always add console logging for:
- The mutation (what changed, before/after counts)
- The save (did `context.hasChanges` report true?)
- The display extraction (did the snapshot see the data?)

### Structured Citation Resolution (`POST /api/papers/resolve`)

For callers that already have parsed bibliographic fields (e.g. imprint with a LaTeX `\bibitem` line), the endpoint accepts a `citation` object instead of the free-text `query` / `bibtex` shape:

```json
POST /api/papers/resolve
{
  "citation": {
    "authors": ["Bardeen", "Bond", "Kaiser", "Szalay"],
    "title": "...",
    "year": 1986,
    "journal": "ApJ",
    "volume": "304",
    "pages": "15",
    "doi": null, "arxiv": null, "bibcode": null,
    "rawBibtex": "...",
    "freeText": "...",
    "preferredDatabase": "astronomy"
  },
  "library": "<optional UUID>",
  "download_pdfs": false
}
```

Cascade (implemented in `AutomationService.resolveStructuredCitation`):

1. Identifier from DOI/arXiv/bibcode (or scanned from `rawBibtex`) → local lookup → return `via: "local-identifier"`. If missing locally: `addPapers(...)` → `via: "imported-identifier"`.
2. Local title search → `via: "local-text"` when unique.
3. Structured ADS query via `SearchFormQueryBuilder.buildClassicQuery(...)`; score each hit by (author+year+journal+page match); auto-accept ≥ 0.85 confidence → `via: "ads-high-confidence"` (auto-imported). Otherwise return top N ranked candidates → `via: "ads-candidates"`.
4. If ADS returns zero: all-sources fan-out via `SourceManager.search(query: freeText, options:)`, dedup by identifier, rank → `via: "all-sources-fallback"`.
5. No hits anywhere → `via: "not-found"`.

Response shape:

```json
{ "status": "ok", "via": "...",
  "paper": {...}?, "candidates": [ {..., "confidence": 0.0–1.0 }, ... ]?,
  "reason": "..."?
}
```

LaTeX decoding is applied to authors/title/journal/rawBibtex via `LaTeXDecoder`. Title words shorter than 4 chars (or matching a stopword list) are filtered out of the ADS title clause so a reference like `"The gravity-induced..."` doesn't over-constrain the query.

Used by `ImbibBridge.resolveCitation(_:library:)` in `ImpressKit` — impress apps should call this instead of building source-specific query strings themselves.

### Live Log Access via HTTP

When the HTTP server is enabled (Settings > General > Automation), logs are accessible at `http://localhost:23120/api/logs`. Use this in Claude Code sessions to verify features work at runtime:

```bash
# Watch recent logs
curl 'http://localhost:23120/api/logs?limit=20&level=info,warning,error'

# Filter by category (tags, sync, pdfbrowser, etc.)
curl 'http://localhost:23120/api/logs?category=tags&limit=20'

# Only entries after a timestamp
curl 'http://localhost:23120/api/logs?after=2026-02-05T10:30:00Z'
```

The MCP tool `imbib_get_logs` provides the same access for AI agents. **Always verify new features by checking logs after testing** -- do not assume code works just because it compiled.

### @State Capture in Task Closures

**Always capture `@State` values into local variables before entering `Task { }`.**

```swift
// CORRECT — capture before async context
let targetIDs = tagTargetIDs
Task {
    for id in targetIDs { ... }  // uses captured snapshot
}

// WRONG — reads @State inside Task body
Task {
    for id in tagTargetIDs { ... }  // may be empty by the time Task runs
}
```

SwiftUI `@State` properties are backed by heap storage. Reading them inside a `Task` closure reads the *current* value when the Task body executes, not the value when `Task { }` was called. If another view (e.g., an overlay dismissing) clears the state between creation and execution, the Task sees the cleared value. This was the root cause of tags not being applied to publications — `tagTargetIDs` was empty by the time the async work started.

### Startup Render Loop Prevention

**Never use `try? await Task.sleep` inside a loop for long delays.** This pattern silently swallows cancellation and keeps actor methods alive during startup, causing cascading `.storeDidMutate` notifications that create a perpetual SwiftUI body re-evaluation loop (manifests as a spinning beach ball).

```swift
// WRONG — cancellation is swallowed, loop runs all chunks even when cancelled
for _ in 0..<chunks {
    try? await Task.sleep(for: .seconds(5))  // try? eats CancellationError
}

// CORRECT — use a single sleep (cancellation works) or check Task.isCancelled
try? await Task.sleep(for: .seconds(60))  // cancels cleanly
```

**How to detect:** Use `log show --process imbib --last 15s | grep -c SHKSharingServicePicker`. After 90s of runtime, this should be 0. If it's > 0, there's a render loop. The 2 ShareLinks in the toolbar cause 2 `SHKSharingServicePicker` inits per body re-evaluation, making this a reliable proxy.

**Background services that mutate data (InboxScheduler, EnrichmentCoordinator) must defer their first work cycle** until after the UI has settled (~60-90s). The 90s delay in InboxScheduler serves this purpose — do not reduce or remove it.

### Sidebar Selection Patterns

The sidebar uses `SidebarOutlineView` (NSOutlineView wrapper from ImpressSidebar). Selection flows through a **binding-only** pipeline — there is no `onSelect` callback.

**How it works:**
1. User clicks a row → NSOutlineView's `outlineViewSelectionDidChange` fires
2. Coordinator writes to `selectionBinding.wrappedValue` (the `$viewModel.selectedNodeID` binding)
3. `selectedNodeID`'s `didSet` calls `resolveSelectedTab()` → sets `selectedTab`
4. SwiftUI views observe `selectedTab` via `@Observable` to update content

**The `.id(source.id)` rule:** Any view that receives a "source" or "route" as a `let` property inside a `NavigationSplitView` detail closure **MUST** have `.id(source.id)` applied. This forces SwiftUI to recreate the view when the source changes, bypassing `detail:` closure caching. Example:
```swift
UnifiedPublicationListWrapper(source: source, ...).id(source.id)
```

Without `.id()`, NavigationSplitView caches the `detail:` closure and `let` properties of child views go stale — switching between sidebar items with the same view type (e.g., Red → Grey flags) won't update the content.

### The BibTeX import path has TWO entry points (ADR-0023 W2)

Every real import still funnels into the same Rust verb — `ImbibStore
::import_bibtex_into(bibtex, library, collection:)`, which owns the identifier
dedup. What differs is which half of its answer the Swift caller keeps:

| Swift entry point | Returns | Used by |
|---|---|---|
| `RustStoreAdapter.importBibTeX(_:libraryId:)` | ids it CREATED | every manual path (⌘I panel → `ImportPreviewView`, drag-drop, automation, Safari, SciX) |
| `RustStoreAdapter.importBibTeXOutcome(_:libraryId:)` | `(imported, existing)` | watched folders |
| `RustStoreAdapter.importBibTeXIntoCollection(_:libraryId:collectionId:)` | `(imported, existing)` | filing an import into a collection |

**A watched folder cannot use the first one**, and the reason is worth keeping:
it reports which store rows a source FILE accounts for
(`SharedStore.watchedRecordProduced`), and an entry that deduped onto a paper
already in the library is still an entry that file contains. Passing only the
created ids made every re-scan claim the source had *dropped* every deduped
entry. `importBibTeXOutcome` is the same call with the same dedup, the same undo
entry and the same `dataVersion` discipline — it just does not throw away
`existing`. (The watched-folder hooks run it inside
`UndoCoordinator.performAutomatic`, so a re-scan's import and provenance tags
never reach the user's undo stack — see Critical Invariants.) (Fixed in the same phase: `import_bibtex_into` only populated
`existing` when filing into a collection, so the field read as "nothing was
deduped" on the plain-library path.)

`.ris` is converted to BibTeX before any of this — `BibliographyFileText`
(watched folders) and `LibraryViewModel.importRIS` (the manual path) both do it
with `RISParserFactory` + `toBibTeX()`. A watched folder imports each file as ONE
blob so the dedup pass runs once per file rather than once per entry, which is
what the manual path does too.

### Watched folders (ADR-0023)

`WatchedFolderIngestCoordinator.shared` is the whole loop: W1's
`FolderWatchService` → `SharedStore.watchedImportDiscovered` → the importer above
→ `watchedRecordProduced` → `watchedFinishScan`. Three things about it are easy
to get wrong later:

- **An entry the source file no longer contains is TAGGED**
  (`watched/removed-from-source`), never deleted, and un-tagged if it comes back.
  Nothing in this feature deletes a publication, ever (ADR-0023 D4).
- **A folder's papers are its provenance tag** (`watched/<folder name>`), which is
  why the display name is uniquified at add time — it is an identity, not a
  label. This is also the first constructor of `PublicationSource.tag(_:)`, a
  scope that had been fully Rust-backed and never built.
- **Under `--ui-testing` every store handle opens ONE scratch FILE**
  (`UITestingEnvironment.scratchDatabasePath`), not `openInMemory()`. Two
  in-memory opens are two databases; provenance is a cross-handle claim and the
  kernel correctly refuses to attribute rows it cannot see.

**W5 added a THIRD ingest unit, `.attachment`** (PDFs beside a watched `.bib`).
Four things about it are easy to get wrong later:

- **A PDF is discovered by the SAME folder, but it is NOT in `fileExtensions`.**
  The publication kind declares `FileDiscoveryCapability.attachmentTypes`
  separately from `types`, and the watcher's filter is built from
  `discoveryExtensions` (the union). `types` stays pinned to
  `impress_core::bibliography_format`, which is frozen to the BibTeX/RIS pair —
  a PDF is not a bibliography interchange format. `RecordKindRegistry
  .descriptor(forFileExtension: "pdf")` must keep returning `nil`: dropping a
  PDF on imbib is not "import a publication".
- **The role marker is DERIVED**
  (`FileDiscoveryCapability.ingestUnit(forFileName:)`), not a column on
  `watched-file@1.0.0`. The schema's own test already forbids a row restating
  the capability; a per-file `role` is that restatement one row down. Deriving
  also means no migration — every row W2 wrote reads correctly under W5.
- **A watched PDF attaches REFERENCE-IN-PLACE**, through
  `AttachmentManager.linkExistingPDF` and never `importAttachment` (which
  copies). Its `relativePath` is therefore an ABSOLUTE path, and both
  `resolveURL` and `linkExistingPDF` have a branch for that — every other
  linked file in imbib is relative to the library container, and appending an
  absolute path to a container yields a path that exists nowhere.
- **`ImbibStore::export_bibtex` now emits `Bdsk-File-*` from linked-file rows.**
  It did not before: the only code in the suite that did was `UnifiedExportView`
  splicing text into an exported string. An entry that arrived carrying its own
  `Bdsk-File-1` keeps it verbatim — re-encoding would replace BibDesk's alias
  data with our smaller `relativePath`-only plist.

- **`Bdsk-File-*` does NOT reach `PublicationModel.fields`.** It lands in the
  payload's nested `extra_fields` object, and `item_to_publication_detail`
  flattens only top-level payload strings. `AttachmentEntry(publication:)`
  recovers it from `rawBibTeX`. Any future reader of a BibDesk-only field has
  the same problem and will pass every hand-built unit test while doing nothing
  in the app.

**Never auto-attach an ambiguous match.** The thresholds live in
`imbib_core::attachments` and are read over the FFI
(`ImbibRustCore.attachmentThresholds()`), never restated in Swift. The
structural rule: `CONFIDENCE_FUZZY_CEILING` (0.88) is below
`AUTO_ATTACH_CONFIDENCE` (0.90), so a fuzzy match can never auto-attach no
matter how the weights are tuned.

**W4 made the coordinator per-KIND** (`WatchedFolderIngestCoordinator
.coordinator(forKindScope:)`, a registry; `.shared` is still imbib's
publication one and every W2 call site is unchanged). Three things that are
easy to get wrong in the generalized shape:

- **`WatchedFolderImportHooks.produceRows` is the ONE thing that varies per
  kind** — one discovered file → the store rows it accounts for. imbib's is the
  BibTeX initializer, kept verbatim; impart's and implore's is `.recordingOnly`,
  which mints nothing *by decision* (ADR-0023 W4), not as a stub.
- **`restorePersistedFolders(limitedToFilterIDs:)` must be narrowed** when more
  than one coordinator runs. The bookmark store is ONE suite; without the
  narrowing every coordinator restores every bookmark, and impart writes imbib's
  `.bib` folder into the store a second time under `kind_scope: message`.
- **`provenanceTagPath(ofFolder:kindScope:)` is nonisolated on purpose.**
  `RecordRouteScope.init?(routeScope:)` — the requirement that turns a sidebar
  selection into a list scope — is nonisolated, and the coordinator is
  `@MainActor`. Read the published snapshot; do not `assumeIsolated`.

### Critical Invariants

**Sidebar tree builders take snapshot data, never store handles — the ratchet
test is the law.** (Sidebar plan P0–P5, 2026-09-01.) A `childrenOf:` builder or
section gate in `ImbibSidebarViewModel` reads `SidebarTreeData` /
`SidebarSnapshot.shared` (produced off-main by `SidebarSnapshotMaintainer`,
one Rust `sidebar_snapshot()` crossing) or, flag-off, the per-`dataVersion`
memo caches — never a fresh adapter/store query per node visit. That
per-node-query shape is how three separate regressions shipped (tag-vocabulary
walk, planner-stats scan, refresh-burst rebuilds; 96.7% of store calls on main
at the audit). `SidebarStoreCallRatchetTests` pins the call count and it only
ratchets down; the per-builder source-of-truth table is
[docs/chassis-capability-matrix.md](../../docs/chassis-capability-matrix.md)
§ Sidebar data sources. New data a builder needs = a new `SidebarTreeData`
field gathered in BOTH maintainer paths, not a new query in the builder.

**The undo stack is the user's; automatic work never registers on it.** (2026-09-24.) Every adapter verb registers undo (`importBibTeX` → "Import Paper", `setRead`, `addToCollection`, `updateIntField`, …), and the feed pipeline calls exactly those verbs, so after a refresh ⌘Z undid "Import Paper" — deleting a paper the next refresh brings back — instead of the user's last action. Work nobody asked for runs inside `UndoCoordinator.performAutomatic(reason) { … }`, a `@TaskLocal` scope that follows it across `await MainActor.run` hops and child tasks (not `Task.detached`) and never reaches a user event, which runs in its own task; `registerUndo` / `registerUndoClosure` drop registrations inside it (debug log `Undo: not registering '…' — automatic work (…)`, category `undo`). Wrapped today: `PaperFetchService.performInboxFetch` + `fetchForFeed`, `GroupFeedRefreshService.runRefreshLocked`, `SmartSearchProvider.refresh`, the watched-folder hooks. NOT wrapped, deliberately: `sendToInbox` (the user's Send to Inbox) and every manual import (⌘I, drop, automation). A NEW background writer must run in the scope. Guarded by `AutomaticWorkUndoTests`.

**Dismissed papers must never re-enter the inbox.** Enforced in: `batch_import_search_results` (Rust `filter_dismissed` checks both new and existing papers), `GroupFeedRefreshService` (Swift `wasDismissed`). Risk: any new import path that doesn't check dismissed status.

**Collection tree parent is payload `parent_id`, never `item.parent`.** For every collection, `item.parent` is the owning LIBRARY (that's what `list_collections` filters on via `HasParent`); the sub-collection tree lives in payload `parent_id` (written by `handleReparent`/`createInboxCollection`) and manuscript folders in payload `parent_collection_ref`. c902a22f briefly returned `item.parent` from `item_to_collection_row`, which made every collection's `parentID` equal its library UUID and flattened the sidebar tree (root filter `parentID == nil` matched nothing). Guarded by `collection_parent_id_is_payload_not_owning_library` in `imbib-core/tests/manuscript_unification.rs`.

**Manuscript UUID strings crossing the FFI must be lowercased.** The Rust store's canonical id form is lowercase and payload refs (`parent_collection_ref`) are matched by string equality; Swift's `UUID().uuidString` is uppercase. Normalize at the adapter boundary — `CollectionStoreAdapter` is where every collection id crosses now, and lowercasing on the way in is rule 1 in its file header. (The old exemplar, `RustStoreAdapter.createManuscriptCollection`, was deleted by ADR-0022 F3: it was the last legacy manuscript-folder writer and had zero callers.)

**The manuscript editor session is owned by the HOST view, never by `ManuscriptDetailPane`.** (Chassis invariant — the surface it protects is **imprint's** Manuscripts section since imbib went publications-only; it lives here because the code lives in PMC.) `ManuscriptSectionView` (and imprint's standalone `ManuscriptEditorView`) resolve the session and pass it in. Holding it as `@State` inside the pane made Source/Preview show the *previously selected* manuscript while the Info tab — which reads `manuscriptID` directly — updated correctly: the pane is reused across selection changes, so its local state outlived the input it was derived from. The pane additionally ignores a session whose `manuscriptID` doesn't match (`liveSession`). Resolution is debounced ~90 ms in the section view so holding ↓ flies through the list instead of loading an editor per row. Do NOT "fix" staleness here by adding `.id(manuscriptID)` to the pane — that rebuilds the whole NSTextView per selection and is what made the list feel sluggish.

**Deleting a manuscript must discard its live editor session first** (`ManuscriptSessionRegistry.discard(id:)`, no flush) — otherwise the debounced CAS save fires after the delete and resurrects the body.

**A manuscript whose payload carries `external_source` must never take an editor session** (ADR-0023 D4/W3; the predicate is `WatchedManuscriptGuard.allowsEditorSession(_:)`). It is the invariant above with a worse loser: the row indexes a FILE the user owns and edits elsewhere, so a debounced save landing late would write the store's older copy over somebody's working file. The guard is at session CREATION, not at save, because a session that is never made has no debounce to fire and no buffer to go stale. `body_content` on such a row is a SNAPSHOT — replaced wholesale on every re-read, authoritative nowhere — and imprint-iOS's `IOSManuscriptEditorHost`, which has its own 300 ms debounce rather than the shared session, reads the same guard.

**Manuscript bodies are Automerge documents (ADR-0027); write them ONLY through `commitManuscriptBody` / `setManuscriptBody` / imprint's `ManuscriptStoreAdapter.commitBody`, never as a raw `body_content` payload write.** The editor session pins `savedHeads` at load (`RustStoreAdapter.manuscriptCollabHeads`) and commits against them; a stale base MERGES (both sides' edits survive, the buffer adopts the returned `body` when `mergedExternal`), so there is no conflict banner and no case that loses work. `body_content` / `body_content_hash` on the row are a *materialization* the kernel rewrites; `collab_materialized_hash == body_content_hash` marks the row as collab-owned, and a row where they disagree is folded in as a deterministic recovery change on next touch (D4) — a raw write is therefore not lost, but it is last-writer-wins instead of merged. `manuscript-change@1.0.0` chunk items are payload-immutable and invisible in the UI by design; the daemon compacts them into snapshots. Deleting a manuscript orphans its chunks (FK sets parent NULL); `compact_manuscript_changes` sweeps them.

**E-ink sync state lives in `imbib/eink-mirror` rows and the engine decides; Swift never writes a mirror state.** (ADR-025, 2026-09-07.) The marker a list row shows is `BibliographyRow.eink_state`, computed in Rust and `nil` unless a device in individual mode is configured — no view decides visibility. Every automatic e-ink action (sync, source fetch, OCR sweep, settings migration) waits on the ONE `EInkStartupGate` (a timestamp, one `Task.sleep`); the connection monitor probes off-main and never touches the store; only "Sync now" / "Import now" bypass the gate. The USB interface cannot create, move, rename or delete (one `GET /documents/…`, one `POST /upload` with a single `file` field — re-confirmed from the tablet's own bundle 2026-09-08), so an unmark leaves the tablet copy in place with an explicit state. A folder only the user can make must not become a dead end: by default (`file_in_nearest_folder`) a paper whose folder is missing is filed in the deepest one on its path that exists, keeping `desired_path` on the row — never above the root folder, so papers are never scattered among the user's own documents, and a missing root still holds with a message naming that one folder. `AnnotationPersistence.applyAnnotations` skips rows with `authorName == "reMarkable"` — burning imported rows into the primary PDF would change its hash and make every mirrored copy read `stale`.

**Only shells that permit `.search` may read the ADS/SciX keychain credentials.** The keychain items (`com.imbib.credentials.ads.apiKey` etc.) are ACL'd to imbib's code signature; when a sibling app (impart/impel/implore, each signed differently) reads them, macOS pops a SecurityAgent password prompt and the synchronous `SecItemCopyMatching` blocks the caller's cooperative-pool thread until the user answers — impart's `/api/logs` (@MainActor route) hung on exactly this. `TabContentView`'s boot task gates the read on `shellConfiguration.permits(.search)`; `testOnlyImbibPermitsSearchSection` keeps the presets honest. Any new chassis code that touches imbib-owned keychain items needs the same gate (or the suite needs a shared keychain access group).

**A paper's files live under the paper's OWN library container, and PDF bytes enter the library only if PDFKit opens them.** (2026-09-11.) Every reader — `AttachmentManager.resolveURL`, Open, Show in Finder, Delete, `GET /api/papers/{citeKey}/pdf` — looks under the library the paper belongs to (its store parent, `PublicationModel.libraryIDs.first`). The Info tab's browser import filed under `libraryManager.activeLibrary` (the Inbox at the time), so an APS PDF was invisible to all of them, and deleting its record left the file behind (which then forced a `_2` name on the next import). `AttachmentManager.importAttachment` now files under the owning library whatever library the caller passes, and `resolveURL` finds a file an older build misfiled under another library — only when its size matches the record, so another paper's same-named file is never taken. Separately, the PDF browser kept ONE slot for downloads in flight; publisher pages start the same PDF twice, so the first to finish read the other's half-written temp file and imported the first 770 KB of a 2.2 MB PDF. Downloads are tracked per entry now (`PDFDownloadLedger`), and `PDFDataValidator` — PDFKit must open the bytes, and a download must deliver every byte it announced — guards the browser capture, `importAttachment(data:)` and the `/pdf` route (422 for a damaged copy). **`%PDF` magic bytes are never enough: a truncated download starts with them too.**

**…and that library container lives in the suite app group, not in imbib's sandbox.** (2026-09-24.) The root is `LibraryFilesLocation.sharedRoot` = `<suite group>/workspace/imbib` (beside `impress.sqlite`), so a paper's files are `<group>/workspace/imbib/Libraries/<library id>/Papers/…` — the same `relativePath` as ever, only the root moved. It was `<Application Support>/imbib`, which under the App Sandbox is each APP's own container: imbib wrote into `~/Library/Containers/com.impress.imbib/…`, and impress, imprint's papers window and the tree's `pdf` pane — the same PMC code in other sandboxes — computed their own empty containers and showed every library PDF as "not found" (no sandbox denial is ever logged: they never tried imbib's path). Every suite app already holds the `…com.impress.suite` group, so no entitlement changed. imbib copies its private files across on every launch (`LibraryFilesMigrationRunner` → `LibraryFilesMigration`): copy under a staging name, verify size + SHA-256 + PDFKit-opens (a PDF that was already unreadable is copied byte for byte and logged), rename into place, never overwrite, **keep the original** (an APFS clone, so nearly free; older builds keep working; undo = delete the shared tree). Idempotent (already-present is a size check), logged per file under `files-migration`, `libraryFilesMigration=dry-run|off` (defaults or `IMBIB_LIBRARY_FILES_MIGRATION`). Because originals are kept, the private root stays on every reader's ladder (`resolveURL`, the Rust `eink::paths` ladder, the e-ink ink-image resolver), and **Delete removes the private twin too** — otherwise the next launch's migration would copy a deleted file back. **Never compute a library path from `.applicationSupportDirectory` again**; ask `AttachmentManager.containerURL(for:)` / `resolveURL` (the iOS PDF viewer, the mail composer and `PDFSearchService` each had their own copy of the ladder — the last one built `imbib/<library NAME>/…`, a folder nothing ever wrote).

**A child record's mutation must name its PARENT in the event.** (2026-09-11.) Every per-publication surface — the Info tab's attachment list, `PDFTab`, `NotesTab`, `publicationDetailLifecycle`, the list row's PDF marker — subscribes to the store event stream and filters by the publication id it is showing. A linked file is a child item, so an event carrying its own id (or a bare `.structural`, which those filters drop) reaches none of them: deleting an attachment removed the file and left its row on screen until the user selected another paper and came back. `RustStoreAdapter.deleteLinkedFile` / `addLinkedFile` / `setLocallyMaterialized` / `setPdfCloudAvailable` emit `.itemsMutated(kind: .attachment, ids: [publication])`, which is also cheaper than `.structural` (that one costs a full sidebar recount — 467 ms, measured). The refresh used to happen by accident, via the `has_pdf_downloaded` write that only fires when the LAST PDF goes away, which is why deleting one of two attachments looked different from deleting one. Annotations and e-ink mirror rows are children too — the same rule applies to any new child kind, and `NotificationCenter` is not the place for it (the retired `.attachmentDidChange` had two posters disagreeing about `object` vs `userInfo`, so half its posts reached nobody).

**A manuscript's papers are an imbib collection, shown in imbib's own window — imprint has no paper panel.** (ADR-0032, 2026-09-12.) `Chassis/Windows/ManuscriptPapersWindow.swift` hosts `UnifiedPublicationListWrapper` + `DetailView` with no sidebar, scoped to the manuscript's collection (payload `manuscript_ref`), and adds exactly two verbs: Cite (⏎ / ⌘⏎) and Keep for this manuscript. Do NOT grow a second list, inspector, catalog search or PDF path for manuscripts again — that is what the deleted panel was (~1,200 lines, all of it imbib's job). Every entry point goes through `ManuscriptPapersOpener`, which syncs first (`impress_core::manuscript_reading_list::sync_reading_collection`, idempotent and additive) so no caller can show a window missing the cited papers; cite keys imbib has no paper for come back as `missing_cite_keys` and are named in a sheet rather than silently dropped. Citing writes through `ManuscriptCitationInserter`, a registry of live editors keyed by manuscript id (`SourceEditorView` registers while mounted, unregisters in `dismantleNSView`): in-process first, else `ImprintBridge.insertCitation` over HTTP, and the answer says whether it landed — 409 "no open editor" is a real outcome, not silence. **The two channels this replaced both reported success while doing nothing** (`POST /api/documents/{id}/insert-citation` posted an unobserved notification; `ImpressURL.insertCitation` built a URL imprint never handled), which is the failure mode to watch for in any new cross-app "do this for me" seam. A programmatic insert must also suppress the inline palette while the caret sits on the key it just wrote — a finished `@key` under the caret looks exactly like one being typed — and it must space the citation apart from the text on BOTH sides (`Coordinator.spaced`): a Typst `@key` runs until a non-word character, so inserting one immediately before existing text yields `@a@b` or `@key= Heading`, i.e. ONE mangled label that the compiler then reports as "label `<a@b…>` does not exist", naming a key nobody typed. Punctuation that naturally follows a citation stays tight.

### macOS SwiftUI Form Gotchas

- `TextField` inside `HStack` inside `Form` `.formStyle(.grouped)` can have broken hit-testing. Use `LabeledContent` rows instead.
- `List` inside a Form `Section` renders poorly. For inline list-like UI, use a `VStack` with manual bordered styling.
- Keyboard shortcuts that require Shift (like `*` = Shift+8) include `.shift` in the `KeyPress.modifiers`. Strip Shift when matching non-letter characters.

### macOS Detail Pane Layout (FRAGILE — Read Before Modifying)

The imbib macOS main view is `NavigationSplitView` > `SectionContentView` (HSplitView) > list pane | detail pane. The toolbar and detail pane vertical positioning was extensively debugged — see root CLAUDE.md "macOS Toolbar & Split View Layout" for the general pattern.

**Key implementation details in `SectionContentView.swift` (~lines 230-240):**
- `.ignoresSafeArea(.container, edges: .top)` on the detail ZStack (line 232) — removing this re-introduces a large empty strip above the detail pane
- `.toolbar { ToolbarItem(placement: .primaryAction) { ... } }` (line 238) — all detail items (tab picker, copy, link, share, pop-out) in the window toolbar, clustered left with list items. This is intentional.
- `InfoTab.swift` has `.padding(.top, 40)` (line 77) on `headerSection` for scroll clearance

**If you need to modify the detail pane or toolbar:** read the root CLAUDE.md section first, then make targeted changes without restructuring the HSplitView or toolbar hierarchy.

**Stage 5b kept this invariant while sharing the pane's logic with iOS**, and the
shape of that is the precedent for the next pass: the DATA/logic moved to
`Chassis/Detail/Shared/`, and each macOS tab kept its own body. Two places where
the shared model is deliberately NOT iterated, because iterating it would change
these pixels:
- `InfoTab.macExplorationKinds` lists the FOUR Explore buttons macOS ships.
  `PublicationExplorationModel.offeredKinds` has five (iOS surfaces WoS
  Related), so `ForEach(model.offeredKinds)` here would grow the row.
- The Record Info section keeps its own `Grid` and its own row selection. The
  data is shared but the two platforms show different rows in different layouts;
  unifying them adds or drops a row and is a product decision.

## Project Status

**Complete**: Foundation, PDF import, multi-library, smart searches, RIS format, automation API, Siri Shortcuts, suite-wide CloudKit sync of the graph store (ADR-0020; feature-flagged, default OFF)

**In Progress**: PDF annotation, flagging & tagging integration

**Not Yet**: JSON plugin bundles, JavaScriptCore transforms, CSL formatting

## Commands

```bash
cd PublicationManagerCore && swift build    # Build package
swift test                                   # Run tests
xcodebuild -scheme imbib -configuration Debug build  # Build macOS app
```

## ADR Quick Reference

| ADR | Summary |
|-----|---------|
| 001-002 | Core Data, BibTeX as portable format |
| 003-004 | Plugin architecture, human-readable PDF names |
| 005-006 | SwiftUI + NavigationSplitView, iOS file handling |
| 007-009 | Conflict resolution, API keys, deduplication |
| 010 | Custom BibTeX parser (swift-parsing) |
| 011-012 | Console window, unified library/online experience |
| 013-015 | RIS format, enrichment service, PDF settings |
| 016 | Unified Paper Model (all papers are CDPublication) |
| 017 | Paper threading (proposed) |
| 018 | AI Assistant Integration |

## Session Continuity

When resuming: `git status`, check `docs/adr/`, review phase checklist above.

**Full changelog**: [CHANGELOG.md](CHANGELOG.md)
