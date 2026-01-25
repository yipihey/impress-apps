# imbib Architecture Guide

This document provides a comprehensive overview of imbib's architecture for developers and contributors.

## System Overview

imbib is a cross-platform scientific publication manager with a shared core that runs on both macOS and iOS.

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
├─────────────────────────────────────────────────────────────┤
│                    imbib-core (Rust FFI)                    │
│              Parsing │ Deduplication │ Identifiers          │
└─────────────────────────────────────────────────────────────┘
```

### Layer Responsibilities

| Layer | Purpose |
|-------|---------|
| **Platform Apps** | Window management, menu commands, platform-specific views |
| **Shared Views** | Reusable SwiftUI components that work on both platforms |
| **PublicationManagerCore** | Business logic, services, view models, data access |
| **Core Data + CloudKit** | Persistent storage and sync |
| **imbib-core (Rust)** | High-performance parsing and deduplication |

## Data Flow

### User Action → Persistence

```
┌──────────────┐    ┌───────────────┐    ┌────────────────┐    ┌────────────┐
│   User       │───▶│  Notification │───▶│  ViewModel /   │───▶│  Repository │
│   Action     │    │  Center       │    │  Service       │    │             │
│              │    │               │    │                │    │             │
│ • Keyboard   │    │  post(name:)  │    │  Business      │    │  Core Data  │
│ • Menu       │    │               │    │  Logic         │    │  Writes     │
│ • Gesture    │    │               │    │                │    │             │
└──────────────┘    └───────────────┘    └────────────────┘    └────────────┘
```

### Data Source → UI

```
┌──────────────┐    ┌───────────────┐    ┌────────────────┐    ┌────────────┐
│   Core Data  │───▶│  Repository   │───▶│  ViewModel     │───▶│  SwiftUI   │
│   Store      │    │               │    │  (@Observable) │    │  View      │
│              │    │  Fetch        │    │                │    │            │
│  CDLibrary   │    │  Requests     │    │  Transform     │    │  Bindings  │
│  CDPublication│   │               │    │  Filter        │    │  Lists     │
│  CDCollection │   │               │    │  Sort          │    │            │
└──────────────┘    └───────────────┘    └────────────────┘    └────────────┘
```

## Command System

imbib uses a notification-based command dispatch pattern for app-wide actions.

### Why Notifications?

1. **Decoupling**: Input sources don't need references to handlers
2. **Multi-platform**: Same notifications work on macOS and iOS
3. **Multiple entry points**: Keyboard, menu, URL scheme, Siri all use the same pattern
4. **SwiftUI-friendly**: Works with `.onReceive()` view modifiers

### Command Flow

```
┌─────────────────┐    ┌──────────────────┐    ┌───────────────────┐
│  Input Source   │───▶│  NotificationCenter │───▶│  View / Handler   │
│                 │    │                   │    │                   │
│ • Keyboard      │    │  post(name:)      │    │ .onReceive()      │
│ • Menu command  │    │                   │    │ ViewModifier      │
│ • URL scheme    │    │                   │    │                   │
│ • Siri/Shortcut │    │                   │    │                   │
└─────────────────┘    └──────────────────┘    └───────────────────┘
```

### Example: Keep Paper to Library

1. User presses `K` (keyboard shortcut)
2. KeyboardShortcutHandler posts: `.keepToLibrary`
3. ContentView receives via `.onReceive()`
4. ContentView calls `libraryViewModel.keepToLibrary()`
5. ViewModel saves to Core Data via Repository
6. ViewModel posts `.publicationKeptToLibrary` for UI refresh

### Notification Categories

- **Navigation**: `.showLibrary`, `.showSearch`, `.showInbox`, `.showPDFTab`
- **Paper Actions**: `.toggleReadStatus`, `.keepToLibrary`, `.dismissFromInbox`
- **Clipboard**: `.copyPublications`, `.pastePublications`, `.copyAsCitation`
- **PDF Viewer**: `.pdfZoomIn`, `.pdfPageDown`, `.pdfGoToPage`
- **Window**: `.detachPDFTab`, `.flipWindowPositions`

## Plugin System

imbib supports multiple types of plugins for extensibility.

### Source Plugins

Source plugins provide search and BibTeX fetching from academic databases.

```swift
public protocol SourcePlugin: Actor, Sendable {
    /// Plugin metadata (name, ID, rate limits, credential requirements)
    var metadata: SourceMetadata { get }

    /// Search for publications matching a query
    func search(query: String, maxResults: Int) async throws -> [SearchResult]

    /// Fetch full BibTeX for a search result
    func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry
}
```

**Built-in sources**: ArXiv, ADS, SciX

**Registration**: Sources register with `SourceManager.registerBuiltInSources()` at app launch.

### Enrichment Plugins

Enrichment plugins augment publication metadata after import.

```swift
public protocol EnrichmentPlugin: Actor, Sendable {
    /// Enrich a publication with additional metadata
    func enrich(_ publication: CDPublication) async throws
}
```

**Built-in enrichers**: DOI resolver, abstract fetcher, PDF linker

### Browser URL Providers

Browser URL providers enable interactive PDF downloads from paywalled sources.

```swift
public protocol BrowserURLProvider: Actor {
    /// Generate a browser-viewable URL for a publication
    func browserURL(for publication: CDPublication) async -> URL?
}
```

## Core Data Model

### Entity Relationships

```
CDLibrary (1) ──────────────── (*) CDPublication
    │                              │
    │                              │
    └───── (*) CDCollection (*)────┘
                │
                │
CDSmartSearch (*) ─────────────────┘
```

### Key Entities

| Entity | Purpose |
|--------|---------|
| `CDLibrary` | User's publication library (can have multiple) |
| `CDPublication` | A single publication with metadata, BibTeX, PDF link |
| `CDCollection` | A folder within a library (static or smart) |
| `CDSmartSearch` | Saved search query with source configuration |
| `CDFeed` | RSS/Atom feed for Inbox system |
| `CDInboxItem` | Publication in Inbox awaiting triage |

### BibTeX Round-Trip

Publications store their original BibTeX for lossless export:

- `rawBibTeX`: Original BibTeX string
- `fields`: Dictionary of parsed fields (for display/search)
- `citeKey`: Extracted for quick reference

When exporting, `rawBibTeX` is used if available, otherwise BibTeX is generated from fields.

## Platform-Specific Code

### View Mapping

| Component | macOS | iOS |
|-----------|-------|-----|
| Main view | `ContentView.swift` | `IOSContentView.swift` |
| Detail view | `DetailView.swift` | `IOSDetailView.swift` |
| Sidebar | `SidebarView.swift` | `IOSSidebarView.swift` |
| Settings | `SettingsView.swift` | `IOSSettingsView.swift` |

### Shared Views

These views work on both platforms:
- `PDFViewerWithControls`
- `BibTeXEditor`
- `PublicationListView`
- `MailStylePublicationRow`
- `ScientificTextParser`
- `GlobalSearchPaletteView`

### Platform Abstractions

```swift
// Use these patterns for platform differences:

#if os(macOS)
import AppKit
Color(nsColor: .controlBackgroundColor)
NSViewRepresentable
#else
import UIKit
Color(.secondarySystemBackground)
UIViewRepresentable
#endif
```

## Rust Integration (imbib-core)

The `imbib-core` Rust library provides high-performance operations:

### BibTeX Parsing
- Fast, streaming parser for large files
- Handles malformed BibTeX gracefully
- Unicode normalization

### Deduplication
- Fuzzy matching on title/authors
- DOI and arXiv ID matching
- Configurable similarity thresholds

### Identifier Extraction
- DOI extraction from text/URLs
- arXiv ID normalization
- PubMed ID parsing

### FFI Bridge

Swift communicates with Rust via the `ImbibRustCore` framework:

```swift
// Swift side
import ImbibRustCore

let entries = try RustBridge.parseBibTeX(content: bibtexString)
let isDuplicate = try RustBridge.isDuplicate(pub1, pub2, threshold: 0.8)
```

## Automation & Integration

### URL Scheme (`imbib://`)

External tools can interact via URL scheme:

```
imbib://search?query=quantum+computing
imbib://import?bibtex=...
imbib://open?doi=10.1234/example
```

### App Intents (Siri Shortcuts)

Published intents enable Siri and Shortcuts integration:

- `SearchPapersIntent`
- `ImportBibTeXIntent`
- `GetLibraryStatsIntent`

### CLI Tool (`imbib-cli`)

Command-line interface for automation:

```bash
imbib add --doi 10.1234/example
imbib search "quantum computing"
imbib export --library "My Library" output.bib
```

## Key Design Decisions

For detailed rationale, see the Architecture Decision Records in `docs/adr/`:

| ADR | Topic |
|-----|-------|
| ADR-001 | Core Data for persistence |
| ADR-002 | BibTeX as portable format |
| ADR-003 | Plugin architecture |
| ADR-004 | Human-readable PDF names |
| ADR-010 | Custom BibTeX parser |
| ADR-016 | Unified Paper Model |
| ADR-018 | AI Assistant Integration |

## Testing

### Unit Tests

```bash
cd PublicationManagerCore && swift test
```

### UI Tests

```bash
# Run from imbib/imbib directory
./fast_test.sh
```

### Test Data Seeding

For UI tests, use launch arguments:

```swift
app.launchArguments = ["--uitesting", "--uitesting-seed"]
```

## Directory Structure

```
imbib/
├── imbib/                    # macOS app
│   ├── imbib/               # Main app target
│   ├── imbib-iOS/           # iOS app target
│   ├── imbibBrowserExtension/# Chrome/Firefox extension
│   ├── imbibSafariExtension/ # Safari extension
│   └── imbibUITests/        # UI test suite
├── PublicationManagerCore/   # Shared Swift package
├── imbib-core/              # Rust library
├── imbib-cli/               # CLI tool
└── docs/                    # Documentation
    └── adr/                 # Architecture Decision Records
```
