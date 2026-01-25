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

## Project Status

**Complete**: Foundation, PDF import, multi-library, smart searches, RIS format, automation API, Siri Shortcuts

**In Progress**: CloudKit sync, PDF annotation

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
