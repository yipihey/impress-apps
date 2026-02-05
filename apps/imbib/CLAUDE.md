# imbib - Claude Code Briefing

Cross-platform (macOS/iOS) scientific publication manager. BibTeX/BibDesk-compatible, multi-source search (arXiv, ADS, Crossref, etc.), CloudKit sync.

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
│                    Core Data + CloudKit                     │
└─────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

| Area | Decision | Details |
|------|----------|---------|
| Data | Core Data + CloudKit | Repository pattern via `PublicationRepository` |
| BibTeX | Source of truth | Round-trip fidelity, `Bdsk-File-*` support, cite keys: `{LastName}{Year}{TitleWord}` |
| PDFs | Human-readable names | `Author_Year_Title.pdf`, relative paths from .bib location |
| Plugins | Actor-based | `SourcePlugin` protocol, built-in: ArXiv, Crossref, ADS, PubMed, Semantic Scholar, OpenAlex, DBLP |
| Papers | Unified model (ADR-016) | All papers are CDPublication, search results auto-import |
| Formats | BibTeX + RIS | First-class RIS support with bidirectional conversion |
| Automation | URL schemes + AppIntents | `imbib://...` for AI agents, Siri Shortcuts, CLI tool |

## Platform Parity

| Component | macOS | iOS |
|-----------|-------|-----|
| Detail view | `DetailView.swift` | `IOSDetailView.swift` |
| Sidebar | `SidebarView.swift` | `IOSSidebarView.swift` |
| Settings | `SettingsView.swift` | `IOSSettingsView.swift` |

**Shared in Core**: `PDFViewerWithControls`, `BibTeXEditor`, `PublicationListView`, `MailStylePublicationRow`, `ScientificTextParser`

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

The app has an internal console window (Cmd+Shift+C). Use `*Capture()` methods to log to both OSLog and the console:

```swift
Logger.library.infoCapture("message", category: "tags")  // shows in console
Logger.library.info("message")                             // OSLog only
logInfo("message", category: "tags")                       // global convenience
```

When adding new features that touch Core Data, always add console logging for:
- The mutation (what changed, before/after counts)
- The save (did `context.hasChanges` report true?)
- The display extraction (did the snapshot see the data?)

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

### macOS SwiftUI Form Gotchas

- `TextField` inside `HStack` inside `Form` `.formStyle(.grouped)` can have broken hit-testing. Use `LabeledContent` rows instead.
- `List` inside a Form `Section` renders poorly. For inline list-like UI, use a `VStack` with manual bordered styling.
- Keyboard shortcuts that require Shift (like `*` = Shift+8) include `.shift` in the `KeyPress.modifiers`. Strip Shift when matching non-letter characters.

## Project Status

**Complete**: Foundation, PDF import, multi-library, smart searches, RIS format, automation API, Siri Shortcuts

**In Progress**: CloudKit sync, PDF annotation, flagging & tagging integration

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
