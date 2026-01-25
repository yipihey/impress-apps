# Source Plugin Implementation Guide

This document describes how to implement a `SourcePlugin` for PublicationManager. Each plugin provides search and BibTeX retrieval for a specific publication database.

## Plugin Protocol

```swift
public protocol SourcePlugin: Sendable {
    /// Static metadata about this source
    var metadata: SourceMetadata { get }
    
    /// Search the source
    /// - Parameter query: Free-text search query
    /// - Returns: Array of search results
    func search(query: String) async throws -> [SearchResult]
    
    /// Fetch BibTeX for a specific result
    /// - Parameter result: A search result from this source
    /// - Returns: Parsed BibTeX entry
    func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry
    
    /// Normalize entry to consistent formatting (default implementation provided)
    func normalize(_ entry: BibTeXEntry) -> BibTeXEntry
    
    /// Fetch PDF if available (default implementation provided)
    func fetchPDF(for result: SearchResult) async throws -> Data?
}
```

## Core Types

### SourceMetadata

```swift
public struct SourceMetadata: Codable, Identifiable, Sendable {
    public let id: String                    // Unique identifier: "arxiv", "crossref"
    public let name: String                  // Display name: "arXiv"
    public let description: String           // Short description
    public let iconName: String?             // SF Symbol or asset name
    public let homepage: URL?                // Source website
    public let requiresAuthentication: Bool  // Needs API key?
    public let rateLimit: RateLimit?         // Request throttling
    
    public struct RateLimit: Codable, Sendable {
        public let maxRequests: Int          // Requests per window
        public let perSeconds: TimeInterval  // Window size
    }
}
```

### SearchResult

```swift
public struct SearchResult: Identifiable, Sendable {
    public let id: String              // Source-specific ID (DOI, arXiv ID, PMID)
    public let title: String
    public let authors: [String]       // ["First Last", "First Last"]
    public let year: Int?
    public let venue: String?          // Journal, conference, etc.
    public let abstract: String?
    public let sourceID: String        // Plugin ID that produced this
    public let externalURL: URL?       // Link to source page
    public let pdfURL: URL?            // Direct PDF link if available
}
```

### BibTeXEntry

```swift
public struct BibTeXEntry: Sendable {
    public var citeKey: String         // "Einstein1905"
    public var entryType: String       // "article", "book", etc.
    public var fields: [String: String] // All BibTeX fields
    public var rawBibTeX: String?      // Original for round-trip
}
```

## Implementation Template

```swift
import Foundation

public actor MySource: SourcePlugin {
    
    // MARK: - Metadata
    
    public let metadata = SourceMetadata(
        id: "mysource",
        name: "My Source",
        description: "Description of the source",
        iconName: "magnifyingglass",
        homepage: URL(string: "https://example.com"),
        requiresAuthentication: false,
        rateLimit: .init(maxRequests: 10, perSeconds: 1)
    )
    
    // MARK: - Private Properties
    
    private let baseURL = "https://api.example.com"
    private var lastRequestTime: Date?
    
    // MARK: - Initialization
    
    public init() { }
    
    // MARK: - SourcePlugin
    
    public func search(query: String) async throws -> [SearchResult] {
        try await respectRateLimit()
        
        // Build request
        var components = URLComponents(string: "\(baseURL)/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "25")
        ]
        
        // Execute request
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        
        // Handle HTTP errors
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(underlying: URLError(.badServerResponse))
        }
        
        switch httpResponse.statusCode {
        case 200: break
        case 429:
            let retry = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw SourceError.rateLimited(retryAfter: retry)
        case 401, 403:
            throw SourceError.authenticationRequired
        default:
            throw SourceError.networkError(underlying: URLError(.badServerResponse))
        }
        
        // Parse response
        return try parseSearchResponse(data)
    }
    
    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        try await respectRateLimit()
        
        // Fetch BibTeX (implementation varies by source)
        let url = URL(string: "\(baseURL)/bibtex/\(result.id)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        
        guard let bibtexString = String(data: data, encoding: .utf8) else {
            throw SourceError.parseError(message: "Invalid encoding")
        }
        
        let entries = try BibTeXParser.parse(bibtexString)
        guard let entry = entries.first else {
            throw SourceError.notFound
        }
        
        return entry
    }
    
    public func normalize(_ entry: BibTeXEntry) -> BibTeXEntry {
        var normalized = entry
        
        // Source-specific normalization
        // Example: ensure DOI field is present
        if normalized.fields["doi"] == nil,
           let url = normalized.fields["url"],
           url.contains("doi.org") {
            normalized.fields["doi"] = url.replacingOccurrences(of: "https://doi.org/", with: "")
        }
        
        return normalized
    }
    
    // MARK: - Private Methods
    
    private func respectRateLimit() async throws {
        guard let rateLimit = metadata.rateLimit,
              let lastRequest = lastRequestTime else {
            lastRequestTime = Date()
            return
        }
        
        let elapsed = Date().timeIntervalSince(lastRequest)
        let required = rateLimit.perSeconds / Double(rateLimit.maxRequests)
        
        if elapsed < required {
            let delay = UInt64((required - elapsed) * 1_000_000_000)
            try await Task.sleep(nanoseconds: delay)
        }
        
        lastRequestTime = Date()
    }
    
    private func parseSearchResponse(_ data: Data) throws -> [SearchResult] {
        // Parse JSON/XML/etc. into SearchResult array
        // Implementation varies by source
        fatalError("Implement for your source")
    }
}
```

## Built-in Sources Reference

### arXiv

| Property | Value |
|----------|-------|
| ID | `arxiv` |
| Search API | Atom feed (`export.arxiv.org/api/query`) |
| BibTeX | `arxiv.org/bibtex/{id}` |
| Rate Limit | 1 req/3 sec |
| Identifiers | arXiv ID (e.g., `2401.12345`) |

**Normalization**:
- Add `eprint` field with arXiv ID
- Add `archiveprefix = {arXiv}`
- Add `primaryclass` if available

### Crossref

| Property | Value |
|----------|-------|
| ID | `crossref` |
| Search API | REST (`api.crossref.org/works`) |
| BibTeX | Content negotiation (`Accept: application/x-bibtex`) |
| Rate Limit | 50 req/sec (polite pool) |
| Identifiers | DOI |

**Normalization**:
- Ensure `doi` field is present
- Standardize journal names
- Fix author name ordering

### PubMed

| Property | Value |
|----------|-------|
| ID | `pubmed` |
| Search API | E-utilities (`eutils.ncbi.nlm.nih.gov`) |
| BibTeX | Convert from MEDLINE format |
| Rate Limit | 3 req/sec (without API key) |
| Identifiers | PMID |

**Normalization**:
- Add `pmid` field
- Map MeSH terms to keywords
- Standardize journal abbreviations

### NASA ADS

| Property | Value |
|----------|-------|
| ID | `ads` |
| Search API | REST (`api.adsabs.harvard.edu`) |
| BibTeX | Export endpoint |
| Rate Limit | 5000 req/day (with API key) |
| Identifiers | Bibcode |

**Normalization**:
- Add `adsurl` field
- Convert ADS-specific fields

### Semantic Scholar

| Property | Value |
|----------|-------|
| ID | `semantic-scholar` |
| Search API | REST (`api.semanticscholar.org/graph/v1`) |
| BibTeX | Build from structured data |
| Rate Limit | 100 req/sec (with API key) |
| Identifiers | Semantic Scholar Paper ID, DOI, arXiv ID |

**Normalization**:
- Extract DOI, arXiv ID, PMID when present
- Map `tldr` field to abstract if abstract missing
- Include citation count metadata

**Notes**:
- Excellent coverage across all fields
- Returns structured data (authors, citations, references)
- Free API key for higher rate limits
- Good for citation graph exploration

### OpenAlex

| Property | Value |
|----------|-------|
| ID | `openalex` |
| Search API | REST (`api.openalex.org/works`) |
| BibTeX | Build from structured data |
| RIS | Build from structured data |
| Rate Limit | 100,000 req/day (with email), 100 req/day without |
| Identifiers | OpenAlex ID, DOI, PMID, PMC ID |
| Enrichment | Citation count, references, citations, abstract, PDF URLs, OA status, venue |

**API Endpoints**:
- Search: `GET /works?search={query}&per-page={limit}`
- Single work: `GET /works/{id}`
- Citations: `GET /works?filter=cites:{id}`
- Author works: `GET /works?filter=authorships.author.id:{id}`

**Authentication**:
- No API key required
- Add `mailto` parameter for polite pool access (100K req/day vs 100/day)
- Example: `api.openalex.org/works?search=quantum&mailto=user@example.com`

**Key Filter Fields**:
- `title.search`, `abstract.search` - Text search
- `authorships.author.display_name.search` - Author name
- `publication_year` - Year or range (e.g., `2020-2024`)
- `open_access.is_oa` - Open access only (`true`)
- `open_access.oa_status` - OA type (`gold`, `green`, `hybrid`, `bronze`, `closed`)
- `type` - Work type (`article`, `book-chapter`, `dataset`, etc.)
- `cited_by_count` - Citation count filter (`>100`)
- `has_doi`, `has_abstract`, `has_pdf_url` - Boolean filters

**Open Access Status Types**:
- `gold` - Published in OA journal
- `green` - Self-archived in repository
- `hybrid` - OA in subscription journal
- `bronze` - Free to read but not open license
- `diamond` - OA journal with no APCs
- `closed` - Not freely accessible

**Unique Features**:
- **Open Access Detection**: Identifies OA status and best free PDF location
- **Institutional Affiliations**: Author-institution links with ROR IDs
- **Research Topics**: 4-level hierarchical classification (Domain > Field > Subfield > Topic)
- **Funding Information**: Grant funder and award ID
- **Citation Trends**: Year-by-year citation counts

**Normalization**:
- Map OpenAlex topics to keywords
- Extract institutional affiliations with ROR IDs
- Include open access status and best OA location
- Decode inverted index abstracts to plain text
- Build PDF links from all OA locations

**Notes**:
- Completely free (CC0 license) and open
- Successor to Microsoft Academic Graph
- Excellent coverage (240M+ works, ~50K new daily)
- Rich metadata including affiliations, topics, funding, OA info
- No API key needed - just add email for polite pool (higher rate limits)
- Supports batch queries with `filter=doi:doi1|doi2|doi3`

### DBLP

| Property | Value |
|----------|-------|
| ID | `dblp` |
| Search API | REST (`dblp.org/search/publ/api`) |
| BibTeX | Direct export |
| Rate Limit | None specified |
| Identifiers | DBLP key |

**Normalization**:
- Computer science focus
- Good conference coverage

## Response Parsing Examples

### JSON (Crossref style)

```swift
private func parseSearchResponse(_ data: Data) throws -> [SearchResult] {
    struct Response: Decodable {
        let message: Message
        struct Message: Decodable {
            let items: [Item]
        }
        struct Item: Decodable {
            let DOI: String
            let title: [String]?
            let author: [Author]?
            let issued: Issued?
            let containerTitle: [String]?
            let abstract: String?
            
            struct Author: Decodable {
                let given: String?
                let family: String?
            }
            struct Issued: Decodable {
                let dateParts: [[Int]]?
                enum CodingKeys: String, CodingKey {
                    case dateParts = "date-parts"
                }
            }
            
            enum CodingKeys: String, CodingKey {
                case DOI, title, author, issued, abstract
                case containerTitle = "container-title"
            }
        }
    }
    
    let response = try JSONDecoder().decode(Response.self, from: data)
    
    return response.message.items.map { item in
        SearchResult(
            id: item.DOI,
            title: item.title?.first ?? "Untitled",
            authors: item.author?.compactMap { author in
                [author.given, author.family]
                    .compactMap { $0 }
                    .joined(separator: " ")
            } ?? [],
            year: item.issued?.dateParts?.first?.first,
            venue: item.containerTitle?.first,
            abstract: item.abstract,
            sourceID: "crossref",
            externalURL: URL(string: "https://doi.org/\(item.DOI)"),
            pdfURL: nil
        )
    }
}
```

### XML (arXiv Atom style)

```swift
private func parseSearchResponse(_ data: Data) throws -> [SearchResult] {
    let parser = AtomFeedParser(data: data)
    return try parser.parse().map { entry in
        SearchResult(
            id: entry.id,
            title: entry.title,
            authors: entry.authors,
            year: Int(entry.published.prefix(4)),
            venue: "arXiv",
            abstract: entry.summary,
            sourceID: "arxiv",
            externalURL: URL(string: entry.id),
            pdfURL: entry.pdfLink.flatMap { URL(string: $0) }
        )
    }
}
```

## BibTeX Fetching Strategies

### Direct BibTeX Endpoint

```swift
// arXiv, DBLP
let url = URL(string: "\(baseURL)/bibtex/\(result.id)")!
let (data, _) = try await URLSession.shared.data(from: url)
let bibtex = String(data: data, encoding: .utf8)!
```

### Content Negotiation

```swift
// Crossref
var request = URLRequest(url: URL(string: "https://doi.org/\(result.id)")!)
request.setValue("application/x-bibtex", forHTTPHeaderField: "Accept")
let (data, _) = try await URLSession.shared.data(for: request)
let bibtex = String(data: data, encoding: .utf8)!
```

### Convert from Other Format

```swift
// PubMed returns MEDLINE format
let medline = try await fetchMedline(pmid: result.id)
let bibtex = MedlineToBibTeXConverter.convert(medline)
```

## Testing Plugins

```swift
import XCTest
@testable import PublicationManagerCore

final class CrossrefSourceTests: XCTestCase {
    
    var source: CrossrefSource!
    
    override func setUp() {
        super.setUp()
        source = CrossrefSource()
    }
    
    func testMetadata() {
        XCTAssertEqual(source.metadata.id, "crossref")
        XCTAssertFalse(source.metadata.requiresAuthentication)
    }
    
    func testSearchReturnsResults() async throws {
        let results = try await source.search(query: "machine learning")
        
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.sourceID == "crossref" })
    }
    
    func testSearchResultHasDOI() async throws {
        let results = try await source.search(query: "10.1038/nature12373")
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "10.1038/nature12373")
    }
    
    func testFetchBibTeX() async throws {
        let result = SearchResult(
            id: "10.1038/nature12373",
            title: "Test",
            authors: [],
            sourceID: "crossref"
        )
        
        let entry = try await source.fetchBibTeX(for: result)
        
        XCTAssertFalse(entry.citeKey.isEmpty)
        XCTAssertNotNil(entry.fields["doi"])
    }
    
    func testNormalizationAddsDOI() {
        var entry = BibTeXEntry(
            citeKey: "test",
            entryType: "article",
            fields: ["url": "https://doi.org/10.1234/test"]
        )
        
        let normalized = source.normalize(entry)
        
        XCTAssertEqual(normalized.fields["doi"], "10.1234/test")
    }
}
```

## Registering Plugins

Plugins are registered in `SourceManager`:

```swift
public actor SourceManager {
    public static let shared = SourceManager()

    private var plugins: [String: any SourcePlugin] = [:]

    private init() {
        // Register built-in sources
        register(ArXivSource())
        register(CrossrefSource())
        register(PubMedSource())
        register(ADSSource())
        register(SemanticScholarSource())
        register(OpenAlexSource())
        register(DBLPSource())
    }

    public func register(_ plugin: some SourcePlugin) {
        plugins[plugin.metadata.id] = plugin
    }
}
```

## Phase 2: JSON Config Bundles

Future support for user-defined sources via JSON:

```json
{
  "id": "my-library",
  "name": "My University Library",
  "description": "Search our library catalog",
  "searchURL": "https://library.example.edu/api/search?q={query}",
  "resultFormat": "json",
  "resultMapping": {
    "id": "$.id",
    "title": "$.title",
    "authors": "$.authors[*].name",
    "year": "$.year"
  },
  "bibtexURL": "https://library.example.edu/api/bibtex/{id}",
  "rateLimit": {
    "maxRequests": 10,
    "perSeconds": 1
  }
}
```

This will be implemented via `ConfigurableSource` that reads JSON bundles.
