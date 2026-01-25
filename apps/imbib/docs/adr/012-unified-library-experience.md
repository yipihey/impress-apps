# ADR-012: Unified Library and Online Search Experience

## Status

Accepted

## Date

2026-01-04

## Context

Users need to:
1. Manage local libraries (BibDesk-compatible .bib files with PDFs)
2. Search online databases (arXiv, ADS, Crossref, etc.)
3. Preview online results with the same UX as local papers
4. Save smart searches that re-execute queries
5. Import papers from online to local with minimal friction

Currently, `LibraryViewModel` manages `CDPublication` (Core Data) and `SearchViewModel` manages `SearchResult` (transient). These are completely separate code paths with different UI components.

### User Requirements

- **Multiple libraries**: Like BibDesk, open/switch between .bib files
- **Show with indicator**: Display all search results, mark papers already in library
- **Download to temp**: Preview PDFs before import, auto-cleanup on session end
- **Temporary metadata**: Allow tags/notes before import, prompt to persist

## Decision

Introduce a **unified paper abstraction** with three content sources:

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PaperListView                                │
│   (Same UI for all sources - virtual scrolling, detail panel, PDF)  │
├─────────────────────────────────────────────────────────────────────┤
│                         PaperProvider                                │
│   (Protocol: provides papers, handles caching, knows source type)   │
├──────────────────┬──────────────────┬───────────────────────────────┤
│  LocalLibrary    │  SmartSearch     │  AdHocSearch                  │
│  (.bib + PDFs)   │  (saved query)   │  (session-only)               │
│  - Persistent    │  - Executes on   │  - Ephemeral                  │
│  - CloudKit sync │    demand        │  - Session cache              │
│  - Full CRUD     │  - Cached results│  - Temp PDF storage           │
└──────────────────┴──────────────────┴───────────────────────────────┘
```

## Rationale

### Unified Paper Protocol

```swift
/// Common interface for papers from any source
public protocol PaperRepresentable: Identifiable, Sendable {
    var id: String { get }
    var title: String { get }
    var authors: [String] { get }
    var year: Int? { get }
    var venue: String? { get }
    var abstract: String? { get }
    var doi: String? { get }

    // Source info
    var sourceType: PaperSourceType { get }
    var isInLibrary: Bool { get }

    // File access
    var pdfURL: URL? { get async }
    var bibtex: String { get async throws }
}

public enum PaperSourceType: Sendable {
    case local(libraryID: UUID)
    case smartSearch(searchID: UUID)
    case adHocSearch(sourceID: String)
}
```

### Paper Provider Protocol

```swift
public protocol PaperProvider: Sendable {
    associatedtype Paper: PaperRepresentable

    var id: UUID { get }
    var name: String { get }
    var papers: [Paper] { get async }
    var isLoading: Bool { get }

    func refresh() async throws
}
```

### Three Content Sources

#### 1. LocalLibrary (Persistent)

```swift
public actor LocalLibrary: PaperProvider {
    let id: UUID
    let bibFileURL: URL
    private let repository: PublicationRepository

    var papers: [LocalPaper] {
        await repository.fetchAll().map { LocalPaper(publication: $0) }
    }

    func importPaper(_ paper: any PaperRepresentable) async throws {
        // Convert to BibTeX, create CDPublication, copy PDF
    }
}
```

- Backed by .bib file + Core Data
- PDFs stored with human-readable names (ADR-004)
- Full CRUD operations
- CloudKit sync

#### 2. SmartSearch (Query-based)

```swift
public actor SmartSearch: PaperProvider {
    let id: UUID
    let name: String
    let query: String
    let sourceIDs: [String]

    private var cachedResults: [OnlinePaper] = []
    private var lastFetched: Date?

    var papers: [OnlinePaper] {
        // Return cached if fresh, else fetch
    }

    func refresh() async throws {
        cachedResults = try await sourceManager.search(query: query)
        lastFetched = Date()
    }
}
```

- Stores query definition (not results)
- Results cached for session
- User-defined name and source filters
- Persisted in Core Data (just the query metadata)

#### 3. AdHocSearch (Ephemeral)

```swift
public final class AdHocSearchProvider: PaperProvider {
    var papers: [OnlinePaper] = []
    var isLoading = false

    func search(query: String, sources: [String]) async throws {
        // Populate papers, session-only
    }
}
```

- No persistence
- Cleared when view dismissed
- Used for quick exploratory searches

### Session Cache Architecture

```swift
public actor SessionCache {
    static let shared = SessionCache()

    // Search results (keyed by query hash)
    private var searchResults: [String: CachedSearchResults] = [:]

    // Temporary PDFs (auto-cleaned on quit)
    private let tempPDFDirectory: URL

    // Temporary metadata (tags/notes before import)
    private var pendingMetadata: [String: PendingPaperMetadata] = [:]

    func cachePDF(for paper: OnlinePaper) async throws -> URL {
        // Download to temp, return local URL
    }

    func cleanup() async {
        // Called on app termination
        try? FileManager.default.removeItem(at: tempPDFDirectory)
    }
}
```

### Library State Indicator

```swift
public struct LibraryStateIndicator: View {
    let paper: any PaperRepresentable
    @Environment(\.activeLibrary) var library

    var body: some View {
        if paper.isInLibrary {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
```

The `isInLibrary` property is computed by checking identifiers (DOI, arXiv, bibcode) against the current library.

### Multiple Library Support

```swift
public actor LibraryManager {
    private(set) var libraries: [LocalLibrary] = []
    private(set) var activeLibraryID: UUID?

    func open(_ url: URL) async throws -> LocalLibrary {
        // Parse .bib, create Core Data container, return library
    }

    func close(_ library: LocalLibrary) async {
        // Save, remove from list
    }

    func setActive(_ library: LocalLibrary) {
        activeLibraryID = library.id
    }
}
```

### Temporary Metadata Before Import

```swift
public struct PendingPaperMetadata: Sendable {
    var tags: Set<String> = []
    var notes: String = ""
    var customCiteKey: String?
}

extension SessionCache {
    func setMetadata(_ metadata: PendingPaperMetadata, for paperID: String) {
        pendingMetadata[paperID] = metadata
    }

    func getMetadata(for paperID: String) -> PendingPaperMetadata? {
        pendingMetadata[paperID]
    }
}
```

When importing, merge pending metadata:

```swift
func importToLibrary(_ paper: OnlinePaper, to library: LocalLibrary) async throws {
    let metadata = await SessionCache.shared.getMetadata(for: paper.id)
    let publication = try await library.importPaper(paper)

    if let metadata {
        await library.applyMetadata(metadata, to: publication)
        await SessionCache.shared.clearMetadata(for: paper.id)
    }
}
```

## Consequences

### Positive

- Single UI codebase for all paper sources
- Smooth preview-before-import workflow
- Smart searches enable "living queries" (e.g., "my field's new papers")
- Multiple library support matches BibDesk users' expectations
- Session cache prevents redundant API calls

### Negative

- Protocol-based design adds abstraction layer
- Two wrapper types (LocalPaper, OnlinePaper) to maintain
- Session cache memory usage for large result sets

### Mitigations

- Clear protocol documentation
- Automated tests for both paper types
- Memory limits on session cache (LRU eviction)
- Background PDF cleanup on low memory warning

## Alternatives Considered

### Single Paper Type

Could use one `Paper` class with optional persistence. Rejected because:
- Core Data entities have different lifecycle than transient objects
- Would require complex null handling throughout
- Harder to reason about persistence state

### Server-Side Caching

Could cache search results on our server. Rejected because:
- Privacy concerns (user queries logged)
- Server costs and maintenance
- Offline doesn't work
- Adds latency vs. local cache
