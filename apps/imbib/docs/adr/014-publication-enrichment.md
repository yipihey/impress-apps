# ADR-014: Publication Enrichment System

## Status

Accepted and Implemented

## Date

2026-01-04 (Updated 2026-01-05)

## Implementation Notes

The enrichment system is now fully wired up:
- **EnrichmentCoordinator** (`EnrichmentCoordinator.swift`) connects EnrichmentService to Core Data persistence
- Papers are automatically queued for enrichment on BibTeX/RIS import
- Background sync starts on app launch via `EnrichmentCoordinator.shared.start()`
- PDF URLs from OpenAlex are saved to `pdfLinks` via `addPDFLink()` helper
- Enrichment results (citation count, abstract, PDF URLs) persisted via `PublicationRepository.saveEnrichmentResult()`

## Context

Publications in a library or from online searches often have incomplete metadata. While we can retrieve basic information (title, authors, year, venue) from sources during search, there's valuable additional metadata that users need:

1. **Citation counts** - Essential for evaluating paper impact
2. **References** - Papers this publication cites (bibliography)
3. **Citations** - Papers that cite this publication (forward citations)
4. **Abstracts** - For papers imported via BibTeX without abstracts
5. **PDF URLs** - Alternative download locations (arXiv, PMC, publisher open access)
6. **Author statistics** - h-index, publication counts

Different sources have different strengths:
- **Semantic Scholar**: Best for citation counts, reference/citation lists, author stats, open access PDFs
- **OpenAlex**: Comprehensive coverage, concepts/topics, open access detection
- **ADS**: Astronomy-specific, excellent abstract coverage, bibcode linking

Users may prefer one source over another based on their field or trust in data quality.

### Requirements

1. Enrich library publications automatically (background sync)
2. Enrich online search results on-demand (before import decision)
3. Handle conflicting data from multiple sources via user-configurable priority
4. Enable sorting library by citation count
5. Provide easy exploration of references and citations
6. Cache enrichment data to reduce API calls

## Decision

Implement a comprehensive enrichment system with:

1. **EnrichmentPlugin protocol** - Extension of sources that can provide enrichment data
2. **EnrichmentService actor** - Coordinates on-demand and background enrichment
3. **Priority queue** - Batches requests with priority levels
4. **Background scheduler** - Periodic refresh of stale enrichments
5. **Identifier resolver** - Maps between DOI, arXiv ID, bibcode, OpenAlex ID, Semantic Scholar ID
6. **UI integration** - Citation badges, refs/cites tab, citation explorer

## Rationale

### Multi-Source vs Single-Source

We could use only Semantic Scholar (best overall coverage), but:
- Different fields have different source strengths (ADS for astronomy)
- Redundancy improves reliability
- Users have source preferences
- Data quality varies by paper

A priority-ordered multi-source approach gives best coverage with user control.

### Background Sync vs On-Demand Only

Pure on-demand would reduce complexity but:
- Users want to sort by citation count across all papers
- Citation counts change over time
- References/citations lists update as new papers appear

Background sync keeps library data current while on-demand handles search results.

### Identifier Resolution

Papers have multiple identifiers (DOI, arXiv, bibcode, etc.) but sources use different ones:
- Semantic Scholar: DOI or arXiv ID or S2 paper ID
- OpenAlex: DOI or OpenAlex ID
- ADS: Bibcode

An identifier resolver maps between these, enabling cross-source enrichment.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    EnrichmentService                        │
│                        (Actor)                              │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ EnrichmentQ  │  │ Background   │  │ Identifier       │  │
│  │   (Actor)    │  │ Scheduler    │  │ Resolver         │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│  EnrichmentPlugin Protocol (extends existing sources)       │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐              │
│  │ Semantic   │ │ OpenAlex   │ │ ADS        │              │
│  │ Scholar    │ │            │ │            │              │
│  └────────────┘ └────────────┘ └────────────┘              │
└─────────────────────────────────────────────────────────────┘
```

## Implementation

### Core Data Schema Extension

```swift
// Add to CDPublication entity
@NSManaged public var citationCount: Int32      // -1 = never enriched
@NSManaged public var enrichmentSource: String? // Which source provided data
@NSManaged public var enrichmentDate: Date?     // When last enriched
```

The `citationCount` field is indexed for efficient sorting.

### EnrichmentPlugin Protocol

```swift
public protocol EnrichmentPlugin: Sendable {
    var metadata: SourceMetadata { get }
    var enrichmentCapabilities: EnrichmentCapabilities { get }

    /// Enrich a paper with additional metadata
    func enrich(
        identifiers: [IdentifierType: String],
        existingData: EnrichmentData?
    ) async throws -> EnrichmentResult

    /// Resolve identifiers to this source's preferred format
    func resolveIdentifier(
        from identifiers: [IdentifierType: String]
    ) async throws -> [IdentifierType: String]
}

public struct EnrichmentCapabilities: OptionSet, Sendable {
    public let rawValue: UInt

    public static let citationCount = EnrichmentCapabilities(rawValue: 1 << 0)
    public static let references    = EnrichmentCapabilities(rawValue: 1 << 1)
    public static let citations     = EnrichmentCapabilities(rawValue: 1 << 2)
    public static let abstract      = EnrichmentCapabilities(rawValue: 1 << 3)
    public static let pdfURL        = EnrichmentCapabilities(rawValue: 1 << 4)
    public static let authorStats   = EnrichmentCapabilities(rawValue: 1 << 5)
    public static let openAccess    = EnrichmentCapabilities(rawValue: 1 << 6)

    public static let all: EnrichmentCapabilities = [
        .citationCount, .references, .citations, .abstract, .pdfURL, .authorStats, .openAccess
    ]
}
```

### EnrichmentData and PaperStub

```swift
/// Enrichment data for a publication
public struct EnrichmentData: Codable, Sendable, Equatable {
    public let citationCount: Int?
    public let references: [PaperStub]?
    public let citations: [PaperStub]?
    public let abstract: String?
    public let pdfURLs: [URL]?
    public let openAccessStatus: OpenAccessStatus?
    public let source: EnrichmentSource
    public let fetchedAt: Date

    public enum OpenAccessStatus: String, Codable, Sendable {
        case gold, green, bronze, hybrid, closed, unknown
    }
}

/// Lightweight representation of a referenced/citing paper
public struct PaperStub: Codable, Sendable, Identifiable, Equatable {
    public let id: String              // Source-specific ID
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let venue: String?
    public let doi: String?
    public let arxivID: String?
    public let citationCount: Int?
    public let isOpenAccess: Bool?
}

/// Result of an enrichment request
public struct EnrichmentResult: Sendable {
    public let data: EnrichmentData
    public let resolvedIdentifiers: [IdentifierType: String]
}
```

### EnrichmentService Actor

```swift
public actor EnrichmentService {
    private let plugins: [EnrichmentPlugin]
    private let settings: EnrichmentSettingsProvider
    private let queue: EnrichmentQueue
    private let resolver: IdentifierResolver
    private var scheduler: BackgroundScheduler?

    // MARK: - On-Demand Enrichment

    /// Enrich a publication immediately
    public func enrichNow(publicationID: UUID) async throws -> EnrichmentData {
        let identifiers = await fetchIdentifiers(for: publicationID)
        return try await enrichWithPriority(identifiers, priority: .userTriggered)
    }

    /// Enrich a search result (cached for session)
    public func enrichSearchResult(_ result: SearchResult) async throws -> EnrichmentData {
        let cacheKey = result.id
        if let cached = await SessionCache.shared.getCachedEnrichment(for: cacheKey) {
            return cached
        }

        let identifiers = extractIdentifiers(from: result)
        let data = try await enrichWithPriority(identifiers, priority: .userTriggered)
        await SessionCache.shared.cacheEnrichment(data, for: cacheKey)
        return data
    }

    // MARK: - Background Sync

    /// Start background enrichment scheduler
    public func startBackgroundSync() async {
        scheduler = BackgroundScheduler(service: self, settings: settings)
        await scheduler?.start()
    }

    /// Queue a publication for enrichment
    public func queueForEnrichment(publicationID: UUID, priority: EnrichmentPriority) async {
        await queue.enqueue(publicationID, priority: priority)
    }

    // MARK: - Private Implementation

    private func enrichWithPriority(
        _ identifiers: [IdentifierType: String],
        priority: EnrichmentPriority
    ) async throws -> EnrichmentData {
        let priorityOrder = await settings.sourcePriority

        for source in priorityOrder {
            guard let plugin = plugins.first(where: { $0.metadata.id == source.rawValue }) else {
                continue
            }

            do {
                let resolved = try await resolver.resolve(identifiers, for: plugin)
                let result = try await plugin.enrich(identifiers: resolved, existingData: nil)
                return result.data
            } catch {
                // Try next source
                continue
            }
        }

        throw EnrichmentError.noSourceAvailable
    }
}
```

### Identifier Resolution

```swift
public enum IdentifierType: String, Codable, Sendable, Hashable {
    case doi
    case arxiv
    case pmid
    case pmcid
    case bibcode
    case semanticScholarID
    case openAlexID
}

public actor IdentifierResolver {
    private var cache: [String: [IdentifierType: String]] = [:]

    /// Resolve identifiers to include source-specific IDs
    public func resolve(
        _ identifiers: [IdentifierType: String],
        for plugin: EnrichmentPlugin
    ) async throws -> [IdentifierType: String] {
        // Cache lookup
        let cacheKey = identifiers.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }.joined(separator: "|")

        if let cached = cache[cacheKey] {
            return cached
        }

        // Try plugin's own resolution
        let resolved = try await plugin.resolveIdentifier(from: identifiers)
        cache[cacheKey] = resolved
        return resolved
    }
}
```

### EnrichmentQueue and Priority

```swift
public enum EnrichmentPriority: Int, Comparable, Sendable {
    case userTriggered = 0   // Immediate (user clicked "Enrich")
    case recentlyViewed = 1  // High (user viewed paper details)
    case libraryPaper = 2    // Normal (background library sync)
    case backgroundSync = 3  // Low (periodic refresh)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public actor EnrichmentQueue {
    private struct QueuedItem: Comparable {
        let publicationID: UUID
        let priority: EnrichmentPriority
        let enqueuedAt: Date

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.enqueuedAt < rhs.enqueuedAt
        }
    }

    private var items: [QueuedItem] = []
    private var inProgress: Set<UUID> = []

    public func enqueue(_ publicationID: UUID, priority: EnrichmentPriority) {
        // Don't duplicate
        guard !inProgress.contains(publicationID),
              !items.contains(where: { $0.publicationID == publicationID }) else {
            return
        }

        items.append(QueuedItem(
            publicationID: publicationID,
            priority: priority,
            enqueuedAt: Date()
        ))
        items.sort()
    }

    public func dequeue() -> UUID? {
        guard let item = items.first else { return nil }
        items.removeFirst()
        inProgress.insert(item.publicationID)
        return item.publicationID
    }

    public func complete(_ publicationID: UUID) {
        inProgress.remove(publicationID)
    }
}
```

### Background Scheduler

```swift
public actor BackgroundScheduler {
    private weak var service: EnrichmentService?
    private let settings: EnrichmentSettingsProvider
    private var task: Task<Void, Never>?

    private let checkInterval: TimeInterval = 3600 // 1 hour
    private let batchSize = 50

    public init(service: EnrichmentService, settings: EnrichmentSettingsProvider) {
        self.service = service
        self.settings = settings
    }

    public func start() {
        task = Task {
            while !Task.isCancelled {
                await runCycle()
                try? await Task.sleep(for: .seconds(checkInterval))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func runCycle() async {
        guard await settings.autoSyncEnabled else { return }

        let staleThreshold = await settings.refreshIntervalDays
        let staleCutoff = Date().addingTimeInterval(-Double(staleThreshold * 24 * 3600))

        // Find stale publications
        let stalePublications = await fetchStalePublications(olderThan: staleCutoff, limit: batchSize)

        for publicationID in stalePublications {
            await service?.queueForEnrichment(publicationID: publicationID, priority: .backgroundSync)
        }
    }
}
```

### EnrichmentState

```swift
public enum EnrichmentState: Sendable {
    case neverEnriched
    case pending
    case enriching
    case complete(Date)
    case failed(Error)

    public var staleness: Staleness {
        switch self {
        case .neverEnriched:
            return .neverEnriched
        case .pending, .enriching:
            return .pending
        case .complete(let date):
            let age = Date().timeIntervalSince(date)
            if age < 86400 { return .fresh }           // <1 day
            if age < 7 * 86400 { return .recent }      // 1-7 days
            if age < 30 * 86400 { return .stale }      // 7-30 days
            return .veryStale                           // >30 days
        case .failed:
            return .failed
        }
    }
}

public enum Staleness: Sendable {
    case neverEnriched
    case pending
    case fresh       // <1 day
    case recent      // 1-7 days
    case stale       // 7-30 days
    case veryStale   // >30 days
    case failed

    public var color: Color {
        switch self {
        case .neverEnriched: return .gray
        case .pending: return .blue
        case .fresh: return .green
        case .recent: return .yellow
        case .stale: return .orange
        case .veryStale, .failed: return .red
        }
    }
}
```

### EnrichmentSettings

```swift
public enum EnrichmentSource: String, Codable, Sendable, CaseIterable {
    case semanticScholar
    case openAlex
    case ads
}

public struct EnrichmentSettings: Codable, Sendable, Equatable {
    public var preferredSource: EnrichmentSource
    public var sourcePriority: [EnrichmentSource]
    public var autoSyncEnabled: Bool
    public var refreshIntervalDays: Int

    public static let `default` = EnrichmentSettings(
        preferredSource: .semanticScholar,
        sourcePriority: [.semanticScholar, .openAlex, .ads],
        autoSyncEnabled: true,
        refreshIntervalDays: 7
    )
}

public protocol EnrichmentSettingsProvider: Sendable {
    var preferredSource: EnrichmentSource { get async }
    var sourcePriority: [EnrichmentSource] { get async }
    var autoSyncEnabled: Bool { get async }
    var refreshIntervalDays: Int { get async }
}
```

### Semantic Scholar Enrichment

```swift
extension SemanticScholarSource: EnrichmentPlugin {
    public var enrichmentCapabilities: EnrichmentCapabilities {
        [.citationCount, .references, .citations, .abstract, .pdfURL, .authorStats]
    }

    public func enrich(
        identifiers: [IdentifierType: String],
        existingData: EnrichmentData?
    ) async throws -> EnrichmentResult {
        // Get paper ID
        let paperID: String
        if let doi = identifiers[.doi] {
            paperID = "DOI:\(doi)"
        } else if let arxiv = identifiers[.arxiv] {
            paperID = "ARXIV:\(arxiv)"
        } else if let s2id = identifiers[.semanticScholarID] {
            paperID = s2id
        } else {
            throw EnrichmentError.noIdentifier
        }

        // Fetch paper with all fields
        let fields = "paperId,title,abstract,year,citationCount,referenceCount," +
                     "references.paperId,references.title,references.authors,references.year," +
                     "references.citationCount,references.venue," +
                     "citations.paperId,citations.title,citations.authors,citations.year," +
                     "citations.citationCount,citations.venue," +
                     "openAccessPdf"

        let url = URL(string: "https://api.semanticscholar.org/graph/v1/paper/\(paperID)?fields=\(fields)")!
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(S2PaperResponse.self, from: data)

        return EnrichmentResult(
            data: EnrichmentData(
                citationCount: response.citationCount,
                references: response.references?.map { $0.toPaperStub() },
                citations: response.citations?.map { $0.toPaperStub() },
                abstract: response.abstract,
                pdfURLs: response.openAccessPdf.map { [$0.url] },
                openAccessStatus: response.openAccessPdf != nil ? .green : .closed,
                source: .semanticScholar,
                fetchedAt: Date()
            ),
            resolvedIdentifiers: [.semanticScholarID: response.paperId]
        )
    }

    public func resolveIdentifier(
        from identifiers: [IdentifierType: String]
    ) async throws -> [IdentifierType: String] {
        // Semantic Scholar can resolve DOI and arXiv directly
        return identifiers
    }
}
```

### UI: Citation Metrics Badge

```swift
struct CitationMetricsBadge: View {
    let citationCount: Int?
    let staleness: Staleness
    let onRefresh: () async -> Void

    var body: some View {
        Button {
            Task { await onRefresh() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "quote.bubble")
                    .font(.caption)

                if let count = citationCount {
                    Text(formatCount(count))
                        .font(.caption.monospacedDigit())
                } else {
                    Text("--")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(staleness.color.opacity(0.2))
            .foregroundStyle(staleness.color)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(stalenessDescription)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    private var stalenessDescription: String {
        switch staleness {
        case .neverEnriched: return "Click to fetch citation count"
        case .pending: return "Fetching..."
        case .fresh: return "Updated today"
        case .recent: return "Updated this week"
        case .stale: return "Updated over a week ago - click to refresh"
        case .veryStale: return "Very stale - click to refresh"
        case .failed: return "Failed to fetch - click to retry"
        }
    }
}
```

## Test Strategy

### Test Coverage Requirements

| Source File | Test File | Coverage |
|-------------|-----------|----------|
| `EnrichmentTypes.swift` | `EnrichmentTypesTests.swift` | Codable round-trip, equality |
| `EnrichmentPlugin.swift` | `EnrichmentPluginTests.swift` | Protocol mocks, capabilities |
| `EnrichmentService.swift` | `EnrichmentServiceTests.swift` | All methods, error paths |
| `EnrichmentQueue.swift` | `EnrichmentQueueTests.swift` | Priority ordering, dedup |
| `BackgroundScheduler.swift` | `BackgroundSchedulerTests.swift` | Scheduling, staleness |
| `IdentifierResolver.swift` | `IdentifierResolverTests.swift` | All ID mappings |
| `SemanticScholarEnrichment.swift` | `SemanticScholarEnrichmentTests.swift` | Response parsing |

### Mock Infrastructure

```swift
// MockEnrichmentPlugin for testing EnrichmentService
actor MockEnrichmentPlugin: EnrichmentPlugin {
    var enrichResult: EnrichmentResult?
    var shouldFail = false
    var enrichCallCount = 0

    func enrich(
        identifiers: [IdentifierType: String],
        existingData: EnrichmentData?
    ) async throws -> EnrichmentResult {
        enrichCallCount += 1
        if shouldFail { throw EnrichmentError.networkError }
        return enrichResult ?? EnrichmentResult(...)
    }
}
```

### Test Fixtures

- `semantic_scholar_paper.json` - Full paper response with refs/cites
- `openalex_work.json` - OpenAlex work with concepts
- `ads_citations.json` - ADS citation response

### Minimum Test Counts

- Sprint 1: ~30 tests (types, protocol, S2 enrichment)
- Sprint 2: ~45 tests (service, queue, resolver, OpenAlex, ADS)
- Sprint 3: ~25 tests (scheduler, cache, settings)
- Sprint 4: ~20 tests (view models)
- Sprint 5: ~15 tests (integration)
- **Total: ~135+ new tests**

## Consequences

### Positive

- Users can sort and filter by citation impact
- Easy discovery of related papers via refs/cites
- Automatic refresh keeps data current
- Multi-source redundancy improves coverage
- User control via priority settings

### Negative

- Increased API call volume (mitigated by caching, background batching)
- Storage overhead for enrichment data (~1KB per paper)
- Complexity of multi-source coordination
- Rate limiting considerations for background sync

### Mitigations

- Aggressive caching (SessionCache for online, Core Data for library)
- Priority queue ensures user actions are responsive
- Graceful degradation when sources unavailable
- Rate limiter integration with existing infrastructure

## Alternatives Considered

### Single Source Only

Use only Semantic Scholar for simplicity.

**Rejected** because:
- Different fields have source preferences (astronomy → ADS)
- Reduces reliability if one source is down
- Misses data that only some sources have

### Lazy Enrichment Only

Never background sync, only enrich when user views paper.

**Rejected** because:
- Can't sort library by citation count
- First view of each paper has loading delay
- Citation data gets stale silently

### Per-Field Source Priority

Let users configure which source to use for each field type.

**Rejected** because:
- Too complex for users
- Minimal benefit over global priority
- Harder to implement and test

## References

- [Semantic Scholar API](https://api.semanticscholar.org/api-docs/)
- [OpenAlex API](https://docs.openalex.org/)
- [ADS API](https://ui.adsabs.harvard.edu/help/api/)
