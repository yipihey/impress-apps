# PublicationManager Architecture

## System Overview

PublicationManager is a scientific publication and reference management application for macOS and iOS. It provides BibTeX-native bibliography management with cloud sync, multi-source search, and PDF organization.

### Design Goals

1. **BibDesk Compatibility**: Seamless round-trip with existing `.bib` files
2. **Cross-Platform**: Shared codebase for macOS and iOS
3. **Offline-First**: Full functionality without network; sync when available
4. **Extensible**: Plugin architecture for new publication sources
5. **Native Experience**: SwiftUI with platform-appropriate UX

## Package Architecture

```
PublicationManager/
├── PublicationManagerCore/          # Swift Package (shared code)
│   ├── Package.swift
│   └── Sources/
│       ├── Models/                  # Core Data entities
│       ├── Persistence/             # Core Data stack, migrations
│       ├── Services/                # BibTeX, PDF, file management
│       ├── Sources/                 # Plugin system
│       ├── ViewModels/              # Presentation logic
│       └── SharedViews/             # Cross-platform SwiftUI
│
├── PublicationManager-macOS/        # macOS application target
│   ├── App.swift
│   ├── Platform/                    # macOS-specific implementations
│   └── Views/                       # macOS-specific views
│
├── PublicationManager-iOS/          # iOS application target
│   ├── App.swift
│   ├── Platform/                    # iOS-specific implementations
│   └── Views/                       # iOS-specific views
│
└── PublicationManagerTests/         # Unit and integration tests
```

## Data Model

### Core Data Entities

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Publication   │────<│ PublicationAuthor│>────│     Author      │
├─────────────────┤     ├─────────────────┤     ├─────────────────┤
│ id: UUID        │     │ order: Int      │     │ id: UUID        │
│ citeKey: String │     └─────────────────┘     │ familyName: Str │
│ entryType: Str  │                             │ givenName: Str  │
│ title: String?  │                             │ nameSuffix: Str?│
│ year: Int?      │     ┌─────────────────┐     └─────────────────┘
│ abstract: Str?  │     │   LinkedFile    │
│ doi: String?    │────<├─────────────────┤
│ url: String?    │     │ id: UUID        │
│ rawBibTeX: Str? │     │ relativePath:Str│
│ rawFields: Str? │     │ filename: String│
│ dateAdded: Date │     │ fileType: String│
│ dateModified:Dt │     │ sha256: String? │
└────────┬────────┘     └─────────────────┘
         │
         │              ┌─────────────────┐
         └─────────────<│      Tag        │
                       ├─────────────────┤
         │              │ id: UUID        │
         │              │ name: String    │
         │              │ color: String?  │
         │              └─────────────────┘
         │
         │              ┌─────────────────┐
         └─────────────<│   Collection    │
                        ├─────────────────┤
                        │ id: UUID        │
                        │ name: String    │
                        │ isSmartCollection│
                        │ predicate: Str? │
                        └─────────────────┘
```

### Field Storage Strategy

BibTeX has arbitrary fields. We handle this with a hybrid approach:

```swift
// Core fields as attributes (for queries and UI)
@NSManaged public var title: String?
@NSManaged public var year: Int16
@NSManaged public var doi: String?

// All fields as JSON (for completeness)
@NSManaged public var rawFields: String?  // JSON: {"journal": "Nature", ...}

// Original BibTeX (for round-trip fidelity)
@NSManaged public var rawBibTeX: String?
```

**Query Strategy**:
- Common queries use indexed Core Data attributes
- Full-text search uses `rawFields` with `CONTAINS`
- Export regenerates BibTeX from `rawFields` + relationships

## Service Layer

### BibTeXParser

Parses `.bib` files into `BibTeXEntry` structs.

```swift
public struct BibTeXParser {
    /// Parse a .bib file
    static func parse(_ content: String) throws -> [BibTeXEntry]
    
    /// Parse a single entry
    static func parseEntry(_ content: String) throws -> BibTeXEntry
    
    /// Decode Bdsk-File-* field to extract relativePath
    static func decodeBdskFile(_ base64: String) throws -> BdskFileInfo
}

public struct BdskFileInfo {
    let relativePath: String
    let bookmarkData: Data?  // macOS alias data (may be nil on iOS)
}
```

**Parsing Challenges**:
- Nested braces in field values
- String concatenation with `#`
- Macro expansion (`@string{nature = "Nature"}`)
- TeX special characters (`{\"o}` → `ö`)
- Crossref inheritance

### BibTeXExporter

Exports Core Data publications to `.bib` format.

```swift
public struct BibTeXExporter {
    /// Export publications to BibTeX string
    static func export(_ publications: [Publication]) -> String
    
    /// Generate Bdsk-File-* field for a linked file
    static func encodeBdskFile(relativePath: String, bibFileURL: URL) -> String
    
    /// Generate cite key from publication metadata
    static func generateCiteKey(for entry: BibTeXEntry) -> String
}
```

**Cite Key Generation**:
```
Pattern: {LastName}{Year}{TitleWord}
Example: Einstein1905Electrodynamics

Collision handling: append a, b, c...
Example: Smith2020Deep, Smith2020Deepa, Smith2020Deepb
```

### PDFManager

Handles PDF file operations.

```swift
public actor PDFManager {
    /// Import a PDF, optionally auto-filing
    func importPDF(from url: URL, for publication: Publication) async throws -> LinkedFile
    
    /// Generate filename from publication metadata
    func generateFilename(for publication: Publication) -> String
    
    /// Resolve a LinkedFile to its actual file URL
    func resolveFile(_ file: LinkedFile, relativeTo bibURL: URL) -> URL?
    
    /// Extract text from PDF for search indexing
    func extractText(from url: URL) async throws -> String
}
```

**Auto-File Naming**:
```
Pattern: {Author}_{Year}_{TruncatedTitle}.pdf
Example: Einstein_1905_OnTheElectrodynamics.pdf

Rules:
- First author's last name only
- Title truncated to 40 chars, spaces → camelCase
- Invalid filename characters removed
```

## Plugin System

### Architecture

```
SourceManager (actor)
├── Built-in plugins (compiled)
│   ├── ArXivSource
│   ├── CrossrefSource
│   ├── PubMedSource
│   ├── ADSSource
│   ├── GoogleScholarSource
│   └── DBLPSource
│
└── Configured plugins (JSON bundles) [Phase 2]
    └── UserSource (ConfigurablePlugin)
```

### SourcePlugin Protocol

```swift
public protocol SourcePlugin: Sendable {
    /// Static metadata about this source
    var metadata: SourceMetadata { get }
    
    /// Search the source
    func search(query: String) async throws -> [SearchResult]
    
    /// Fetch BibTeX for a specific result
    func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry
    
    /// Normalize entry to consistent formatting (has default impl)
    func normalize(_ entry: BibTeXEntry) -> BibTeXEntry
    
    /// Fetch PDF if available (has default impl)
    func fetchPDF(for result: SearchResult) async throws -> Data?
}
```

### Rate Limiting

Each plugin manages its own rate limiting:

```swift
public actor ArXivSource: SourcePlugin {
    private var lastRequestTime: Date?
    
    private func respectRateLimit() async throws {
        guard let rateLimit = metadata.rateLimit,
              let lastRequest = lastRequestTime else {
            lastRequestTime = Date()
            return
        }
        
        let elapsed = Date().timeIntervalSince(lastRequest)
        let required = rateLimit.perSeconds / Double(rateLimit.maxRequests)
        
        if elapsed < required {
            try await Task.sleep(nanoseconds: UInt64((required - elapsed) * 1_000_000_000))
        }
        
        lastRequestTime = Date()
    }
}
```

### Source-Specific Normalization

Each source can override `normalize(_:)` for quirks:

| Source | Normalization |
|--------|---------------|
| arXiv | Add `eprint`, `archiveprefix` fields |
| Crossref | Convert author format, add `doi` |
| PubMed | Add `pmid`, standardize journal names |
| Google Scholar | Clean up title case, fix encoding |

## Sync Architecture

### CloudKit Integration

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   macOS App     │     │   CloudKit      │     │    iOS App      │
├─────────────────┤     │   Private DB    │     ├─────────────────┤
│ Core Data       │────>│                 │<────│ Core Data       │
│ NSPersistent-   │     │ Publications    │     │ NSPersistent-   │
│ CloudKitContainer     │ Authors         │     │ CloudKitContainer
└─────────────────┘     │ Files (CKAsset) │     └─────────────────┘
                        │ Tags            │
                        │ Collections     │
                        └─────────────────┘
```

**PDF Sync**:
- PDFs stored as `CKAsset` (up to 250MB per file)
- Lazy download on iOS (on-demand)
- Full sync on macOS (optional)

**Conflict Resolution**:
- Last-writer-wins for most fields
- Merge for tags and collections
- Alert user for cite key conflicts

## View Architecture

### Navigation Structure

**macOS**: Three-column `NavigationSplitView`
```
┌──────────────┬────────────────┬─────────────────────────┐
│  Sidebar     │   List         │   Detail                │
├──────────────┼────────────────┼─────────────────────────┤
│ All Papers   │ [Publication]  │ Title                   │
│ Recent       │ [Publication]  │ Authors                 │
│ ─────────    │ [Publication]  │ Abstract                │
│ Collections  │ ...            │ [PDF Viewer]            │
│  └ Physics   │                │ [BibTeX Editor]         │
│  └ ML        │                │                         │
│ Tags         │                │                         │
│  └ ToRead    │                │                         │
└──────────────┴────────────────┴─────────────────────────┘
```

**iOS**: Collapsing `NavigationSplitView`
- Portrait: Stack navigation
- Landscape (iPad): Two or three columns

### View-ViewModel Binding

```swift
// ViewModel owns state and business logic
@Observable
final class LibraryViewModel {
    private(set) var publications: [Publication] = []
    private(set) var isLoading = false
    
    private let repository: PublicationRepository
    
    func loadPublications() async { ... }
    func delete(_ publication: Publication) async { ... }
    func search(_ query: String) async { ... }
}

// View observes and dispatches actions
struct LibraryView: View {
    @State private var viewModel: LibraryViewModel
    
    var body: some View {
        List(viewModel.publications) { pub in
            PublicationRow(publication: pub)
        }
        .task { await viewModel.loadPublications() }
    }
}
```

### Platform Abstraction

```swift
// Protocol for platform-specific implementations
protocol PDFViewing: View {
    init(url: URL)
}

// macOS implementation
#if os(macOS)
struct PDFViewer: PDFViewing, NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView { ... }
}
#endif

// iOS implementation  
#if os(iOS)
struct PDFViewer: PDFViewing, UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView { ... }
}
#endif
```

## Error Handling

### Error Hierarchy

```swift
public enum BibTeXError: LocalizedError {
    case parseError(line: Int, message: String)
    case invalidEntry(citeKey: String, reason: String)
    case encodingError
    case fileNotFound(path: String)
}

public enum SourceError: LocalizedError {
    case networkError(underlying: Error)
    case parseError(message: String)
    case rateLimited(retryAfter: TimeInterval?)
    case authenticationRequired
    case notFound
    case invalidQuery
}

public enum FileError: LocalizedError {
    case importFailed(reason: String)
    case exportFailed(reason: String)
    case fileNotFound(path: String)
    case permissionDenied
}
```

### Error Presentation

```swift
// ViewModels expose user-friendly errors
@Observable
final class SearchViewModel {
    private(set) var error: UserFacingError?
    
    func search(_ query: String) async {
        do {
            results = try await sourceManager.search(query: query)
        } catch let error as SourceError {
            self.error = UserFacingError(from: error)
        }
    }
}

// Views display via alert
struct SearchView: View {
    @State private var viewModel: SearchViewModel
    
    var body: some View {
        // ...
        .alert(item: $viewModel.error) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
    }
}
```

## Testing Strategy

### Unit Tests

| Component | Test Focus |
|-----------|------------|
| BibTeXParser | Parsing edge cases, encoding, macros |
| BibTeXExporter | Round-trip fidelity, Bdsk-File encoding |
| SourcePlugin | Response parsing, normalization |
| PDFManager | Filename generation, path resolution |

### Integration Tests

- Core Data ↔ BibTeX round-trip
- CloudKit sync simulation
- Multi-source search aggregation

### Mocking

```swift
// Mock for testing ViewModels
final class MockSourceManager: SourceManaging, @unchecked Sendable {
    var searchResults: [SearchResult] = []
    var searchError: Error?
    
    func search(query: String, sources: [String]?) async throws -> [SearchResult] {
        if let error = searchError { throw error }
        return searchResults
    }
}
```

## Performance Considerations

### Large Libraries

- Fetch with `NSFetchedResultsController` for lazy loading
- Batch imports (100 entries at a time)
- Background context for imports

### Search

- Core Data indexes on: `citeKey`, `title`, `year`, `doi`
- Full-text via `rawFields CONTAINS[cd]` (case/diacritic insensitive)
- Future: Spotlight integration for system-wide search

### Memory

- Thumbnails generated on-demand, cached to disk
- PDF text extraction is streaming, not loaded into memory
- CloudKit assets download on-demand (iOS)

## Security

### File Access

- Sandboxed on both platforms
- Security-scoped bookmarks for user-selected folders
- No network access to file system

### Network

- HTTPS only for all sources
- Certificate pinning for known APIs (optional)
- No credentials stored in UserDefaults (use Keychain)

### Privacy

- No analytics or telemetry
- CloudKit data in user's private database
- Local-only mode available
