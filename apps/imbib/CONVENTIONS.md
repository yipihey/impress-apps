# Coding Conventions

This document defines the coding standards for PublicationManager. Consistency across the codebase makes it easier for Claude Code to generate correct code and for humans to review it.

## Swift Version and Language Features

- **Swift 5.9+** required
- **Strict concurrency checking** enabled (`SWIFT_STRICT_CONCURRENCY = complete`)
- Use `async/await` for all asynchronous code
- Use `actor` for thread-safe stateful services
- Avoid Combine for new code; prefer async sequences

## File Organization

### Directory Structure

```
Sources/
├── Models/                 # Core Data entities and DTOs
│   ├── Publication.swift
│   ├── Author.swift
│   └── BibTeXEntry.swift
├── Persistence/            # Core Data stack
│   ├── PersistenceController.swift
│   ├── PublicationManager.xcdatamodeld
│   └── Migrations/
├── Repositories/           # Data access layer
│   ├── PublicationRepository.swift
│   └── AuthorRepository.swift
├── Services/               # Business logic
│   ├── BibTeXParser.swift
│   ├── BibTeXExporter.swift
│   └── PDFManager.swift
├── Sources/                # Plugin system
│   ├── SourcePlugin.swift
│   ├── SourceManager.swift
│   └── BuiltIn/
│       ├── ArXivSource.swift
│       └── CrossrefSource.swift
├── ViewModels/             # Presentation logic
│   ├── LibraryViewModel.swift
│   └── SearchViewModel.swift
└── SharedViews/            # Cross-platform SwiftUI
    ├── PublicationListView.swift
    └── PublicationDetailView.swift
```

### File Structure

Each file follows this organization:

```swift
//
//  FileName.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import CoreData  // Group by framework

// MARK: - Public Types

public struct SomePublicType { }

// MARK: - Public Interface

public protocol SomeProtocol {
    func method()
}

// MARK: - Implementation

public final class SomeClass: SomeProtocol {
    
    // MARK: - Properties
    
    private let dependency: Dependency
    
    // MARK: - Initialization
    
    public init(dependency: Dependency) {
        self.dependency = dependency
    }
    
    // MARK: - Public Methods
    
    public func method() { }
    
    // MARK: - Private Methods
    
    private func helper() { }
}

// MARK: - Protocol Conformance

extension SomeClass: CustomStringConvertible {
    public var description: String { "..." }
}

// MARK: - Private Types

private struct InternalHelper { }
```

## Naming Conventions

### Types

| Type | Convention | Example |
|------|------------|---------|
| Protocols | Verb+ing or Noun+able | `BibTeXParsing`, `Identifiable` |
| Classes/Structs | Noun | `BibTeXParser`, `Publication` |
| Actors | Noun | `SourceManager`, `PDFManager` |
| Enums | Singular noun | `EntryType`, `SourceError` |
| View Models | Noun+ViewModel | `LibraryViewModel` |
| Views | Noun+View | `PublicationDetailView` |

### Functions and Methods

```swift
// Actions: verb + noun
func fetchPublications() async throws -> [Publication]
func deletePublication(_ publication: Publication)
func importBibTeX(from url: URL) throws

// Predicates: is/has/can/should prefix
func isValidCiteKey(_ key: String) -> Bool
func hasLinkedPDF(_ publication: Publication) -> Bool
func canSync() -> Bool

// Factories: make prefix
func makeSearchPredicate(for query: String) -> NSPredicate
func makeViewModel() -> LibraryViewModel

// Conversions: to prefix or target type name
func toBibTeX() -> String
func normalized() -> BibTeXEntry
```

### Properties

```swift
// Booleans: is/has/can/should prefix
var isLoading: Bool
var hasUnsavedChanges: Bool
var canExport: Bool

// Collections: plural nouns
var publications: [Publication]
var selectedTags: Set<Tag>

// Others: descriptive nouns
var currentQuery: String
var lastSyncDate: Date?
```

### Constants

```swift
// Type-level constants: static let
struct BibTeXConstants {
    static let defaultEntryType = "article"
    static let maxTitleLength = 40
}

// File-level constants: private let at top
private let defaultTimeout: TimeInterval = 30
```

## Type Design

### When to Use Each Type

| Type | Use For |
|------|---------|
| `struct` | Data transfer objects, value types, BibTeX entries |
| `class` | Reference semantics needed, NSManagedObject subclasses |
| `final class` | ViewModels, non-inheritable reference types |
| `actor` | Stateful services with async methods |
| `enum` | Finite set of cases, errors, entry types |

### Access Control

Default to minimal visibility:

```swift
// Internal by default (omit keyword)
struct InternalHelper { }

// Explicit public for API surface
public struct BibTeXEntry { }

// Private for implementation details
private func parseField(_ raw: String) -> String { }

// File-private when shared within file only
fileprivate let sharedCache = Cache()
```

### Protocols

```swift
// Define protocols in terms of behavior
public protocol BibTeXParsing {
    func parse(_ content: String) throws -> [BibTeXEntry]
}

// Provide default implementations via extensions
public extension BibTeXParsing {
    func parse(contentsOf url: URL) throws -> [BibTeXEntry] {
        let content = try String(contentsOf: url)
        return try parse(content)
    }
}

// Constrain Sendable for async contexts
public protocol SourcePlugin: Sendable { }
```

## Error Handling

### Define Domain Errors

```swift
public enum BibTeXError: LocalizedError {
    case parseError(line: Int, message: String)
    case invalidCiteKey(String)
    case missingRequiredField(String)
    
    public var errorDescription: String? {
        switch self {
        case .parseError(let line, let message):
            return "Parse error at line \(line): \(message)"
        case .invalidCiteKey(let key):
            return "Invalid cite key: \(key)"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        }
    }
}
```

### Error Propagation

```swift
// Throw errors, don't return optionals for failures
func parse(_ content: String) throws -> [BibTeXEntry]  // ✓
func parse(_ content: String) -> [BibTeXEntry]?        // ✗

// Use guard for early exit
func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
    guard let url = result.bibtexURL else {
        throw SourceError.notFound
    }
    // ...
}

// Catch at boundaries, not internally
// ✗ Don't do this
func search(_ query: String) async -> [SearchResult] {
    do {
        return try await source.search(query: query)
    } catch {
        return []  // Swallows error!
    }
}

// ✓ Do this
func search(_ query: String) async throws -> [SearchResult] {
    try await source.search(query: query)
}
```

## Concurrency

### Actor Usage

```swift
// Use actor for stateful services
public actor SourceManager {
    private var plugins: [String: any SourcePlugin] = [:]
    
    public func register(_ plugin: some SourcePlugin) {
        plugins[plugin.metadata.id] = plugin
    }
    
    public func search(query: String) async throws -> [SearchResult] {
        // Actor-isolated state access is safe
    }
}
```

### Task Groups

```swift
// Parallel searches across sources
public func search(query: String, sources: [String]) async throws -> [SearchResult] {
    try await withThrowingTaskGroup(of: [SearchResult].self) { group in
        for sourceID in sources {
            guard let plugin = plugins[sourceID] else { continue }
            
            group.addTask {
                try await plugin.search(query: query)
            }
        }
        
        var allResults: [SearchResult] = []
        for try await results in group {
            allResults.append(contentsOf: results)
        }
        return allResults
    }
}
```

### Sendable Conformance

```swift
// Value types are implicitly Sendable
public struct SearchResult: Sendable { }

// Reference types need explicit conformance
public final class Configuration: Sendable {
    let apiKey: String  // let properties are safe
}

// Use @unchecked for types you know are safe
final class MockSource: SourcePlugin, @unchecked Sendable {
    var searchResults: [SearchResult] = []  // Only accessed in tests
}
```

## SwiftUI Conventions

### View Structure

```swift
struct PublicationDetailView: View {
    // MARK: - Environment
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - State
    @State private var isEditing = false
    @State private var showDeleteAlert = false
    
    // MARK: - Properties
    let publication: Publication
    
    // MARK: - Body
    var body: some View {
        content
            .toolbar { toolbarContent }
            .alert("Delete?", isPresented: $showDeleteAlert) {
                deleteAlert
            }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var content: some View {
        // ...
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // ...
    }
    
    private var deleteAlert: some View {
        // ...
    }
}
```

### Platform Conditional Compilation

```swift
// Prefer ViewModifiers over inline #if
struct PlatformPadding: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.padding(20)
        #else
        content.padding(16)
        #endif
    }
}

extension View {
    func platformPadding() -> some View {
        modifier(PlatformPadding())
    }
}

// Use typealiases for platform types
#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif
```

### Observable Pattern

```swift
// Use @Observable for iOS 17+ / macOS 14+
@Observable
final class LibraryViewModel {
    private(set) var publications: [Publication] = []
    private(set) var isLoading = false
    var searchQuery = ""
    
    // Dependencies injected
    private let repository: PublicationRepository
    
    init(repository: PublicationRepository = .shared) {
        self.repository = repository
    }
    
    func loadPublications() async {
        isLoading = true
        defer { isLoading = false }
        
        publications = await repository.fetchAll()
    }
}

// In View
struct LibraryView: View {
    @State private var viewModel = LibraryViewModel()
    
    var body: some View {
        List(viewModel.publications) { pub in
            // ...
        }
        .task { await viewModel.loadPublications() }
    }
}
```

## Testing Conventions

### Test File Naming

```
PublicationManagerTests/
├── BibTeXParserTests.swift
├── BibTeXExporterTests.swift
├── ArXivSourceTests.swift
└── Mocks/
    ├── MockSourcePlugin.swift
    └── MockRepository.swift
```

### Test Structure

```swift
import XCTest
@testable import PublicationManagerCore

final class BibTeXParserTests: XCTestCase {
    
    // MARK: - Setup
    
    private var parser: BibTeXParser!
    
    override func setUp() {
        super.setUp()
        parser = BibTeXParser()
    }
    
    override func tearDown() {
        parser = nil
        super.tearDown()
    }
    
    // MARK: - Parsing Tests
    
    func testParseSimpleArticle() throws {
        // Given
        let input = """
        @article{Einstein1905,
            author = {Albert Einstein},
            title = {On the Electrodynamics}
        }
        """
        
        // When
        let entries = try parser.parse(input)
        
        // Then
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].citeKey, "Einstein1905")
        XCTAssertEqual(entries[0].entryType, "article")
    }
    
    func testParseErrorOnInvalidSyntax() {
        // Given
        let input = "@article{missing_brace"
        
        // When/Then
        XCTAssertThrowsError(try parser.parse(input)) { error in
            guard case BibTeXError.parseError = error else {
                XCTFail("Expected parseError")
                return
            }
        }
    }
    
    // MARK: - Async Tests
    
    func testSearchReturnsResults() async throws {
        // Given
        let source = ArXivSource()
        
        // When
        let results = try await source.search(query: "quantum")
        
        // Then
        XCTAssertFalse(results.isEmpty)
    }
}
```

### Mock Objects

```swift
// Mock protocol implementation
final class MockSourceManager: SourceManaging, @unchecked Sendable {
    var searchResults: [SearchResult] = []
    var searchError: Error?
    var searchCallCount = 0
    var lastSearchQuery: String?
    
    var availableSources: [SourceMetadata] {
        [SourceMetadata(id: "mock", name: "Mock", ...)]
    }
    
    func search(query: String, sources: [String]?) async throws -> [SearchResult] {
        searchCallCount += 1
        lastSearchQuery = query
        
        if let error = searchError {
            throw error
        }
        return searchResults
    }
}

// Usage in tests
func testSearchUpdatesResults() async {
    // Given
    let mockManager = MockSourceManager()
    mockManager.searchResults = [SearchResult(...)]
    let viewModel = SearchViewModel(sourceManager: mockManager)
    
    // When
    await viewModel.search("quantum")
    
    // Then
    XCTAssertEqual(viewModel.results.count, 1)
    XCTAssertEqual(mockManager.lastSearchQuery, "quantum")
}
```

## Documentation

### Public API Documentation

```swift
/// Parses BibTeX content into structured entries.
///
/// The parser handles standard BibTeX syntax including:
/// - All entry types (`@article`, `@book`, etc.)
/// - String macros (`@string{...}`)
/// - Crossref inheritance
/// - TeX special characters
///
/// - Parameter content: Raw BibTeX file content
/// - Returns: Array of parsed entries
/// - Throws: `BibTeXError.parseError` if syntax is invalid
///
/// ## Example
/// ```swift
/// let parser = BibTeXParser()
/// let entries = try parser.parse("""
///     @article{key, author = {Name}}
/// """)
/// ```
public func parse(_ content: String) throws -> [BibTeXEntry]
```

### Internal Comments

```swift
// Use // for implementation notes
private func normalizeAuthor(_ raw: String) -> String {
    // BibTeX uses "and" to separate authors
    // Names can be "First Last" or "Last, First"
    let authors = raw.components(separatedBy: " and ")
    // ...
}

// Use TODO: for future work
// TODO: Support BibLaTeX date fields

// Use FIXME: for known issues
// FIXME: Doesn't handle nested braces in abstracts
```

## Git Conventions

### Commit Messages

```
<type>: <subject>

<body>

<footer>
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `refactor`: Code change that neither fixes nor adds
- `docs`: Documentation only
- `test`: Adding tests
- `chore`: Build, CI, dependencies

Example:
```
feat: Add CrossrefSource plugin

Implements SourcePlugin for Crossref API:
- Search by title, author, DOI
- BibTeX fetch via content negotiation
- Rate limiting (50 req/sec)

Closes #42
```

### Branch Naming

```
feature/crossref-source
fix/bibtex-parser-nested-braces
docs/architecture-update
```
