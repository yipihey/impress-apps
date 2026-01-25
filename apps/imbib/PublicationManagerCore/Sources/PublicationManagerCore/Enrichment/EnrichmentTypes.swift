//
//  EnrichmentTypes.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// NOTE: IdentifierType is defined in SearchResult.swift and extended here for enrichment use.
// Available cases: doi, arxiv, pmid, pmcid, bibcode, semanticScholar, openAlex, dblp

// MARK: - Enrichment Source

/// Sources that can provide enrichment data.
public enum EnrichmentSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case ads
    case wos
    case openalex

    public var id: String { rawValue }

    /// The source plugin ID (lowercase, matching SourceMetadata.id)
    public var sourceID: String {
        switch self {
        case .ads: return "ads"
        case .wos: return "wos"
        case .openalex: return "openalex"
        }
    }

    public var displayName: String {
        switch self {
        case .ads: return "NASA ADS"
        case .wos: return "Web of Science"
        case .openalex: return "OpenAlex"
        }
    }

    /// Create from a source plugin ID
    public init?(sourceID: String) {
        switch sourceID.lowercased() {
        case "ads": self = .ads
        case "wos": self = .wos
        case "openalex": self = .openalex
        default: return nil
        }
    }
}

// MARK: - Open Access Status

/// Open access availability status.
public enum OpenAccessStatus: String, Codable, Sendable {
    case gold       // Published in OA journal
    case green      // Self-archived (preprint/postprint)
    case bronze     // Free to read but not licensed
    case hybrid     // OA in subscription journal
    case closed     // Not freely accessible
    case unknown    // Status not determined
}

// MARK: - Enrichment Capabilities

/// Capabilities that an enrichment source can provide.
public struct EnrichmentCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let citationCount = EnrichmentCapabilities(rawValue: 1 << 0)
    public static let references    = EnrichmentCapabilities(rawValue: 1 << 1)
    public static let citations     = EnrichmentCapabilities(rawValue: 1 << 2)
    public static let abstract      = EnrichmentCapabilities(rawValue: 1 << 3)
    public static let pdfURL        = EnrichmentCapabilities(rawValue: 1 << 4)
    public static let authorStats   = EnrichmentCapabilities(rawValue: 1 << 5)
    public static let openAccess    = EnrichmentCapabilities(rawValue: 1 << 6)
    public static let venue         = EnrichmentCapabilities(rawValue: 1 << 7)

    public static let all: EnrichmentCapabilities = [
        .citationCount, .references, .citations, .abstract,
        .pdfURL, .authorStats, .openAccess, .venue
    ]

    /// Human-readable description of capabilities
    public var description: String {
        var parts: [String] = []
        if contains(.citationCount) { parts.append("citations") }
        if contains(.references) { parts.append("references") }
        if contains(.citations) { parts.append("citing papers") }
        if contains(.abstract) { parts.append("abstract") }
        if contains(.pdfURL) { parts.append("PDF") }
        if contains(.authorStats) { parts.append("author stats") }
        if contains(.openAccess) { parts.append("open access") }
        if contains(.venue) { parts.append("venue") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Paper Stub

/// Lightweight representation of a referenced or citing paper.
///
/// Used for displaying references and citations lists without fetching full paper data.
public struct PaperStub: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: String              // Source-specific ID
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let venue: String?
    public let doi: String?
    public let arxivID: String?
    public let citationCount: Int?
    public let referenceCount: Int?
    public let isOpenAccess: Bool?
    public let abstract: String?

    public init(
        id: String,
        title: String,
        authors: [String],
        year: Int? = nil,
        venue: String? = nil,
        doi: String? = nil,
        arxivID: String? = nil,
        citationCount: Int? = nil,
        referenceCount: Int? = nil,
        isOpenAccess: Bool? = nil,
        abstract: String? = nil
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.doi = doi
        self.arxivID = arxivID
        self.citationCount = citationCount
        self.referenceCount = referenceCount
        self.isOpenAccess = isOpenAccess
        self.abstract = abstract
    }

    /// First author's last name for display
    public var firstAuthorLastName: String? {
        guard let first = authors.first else { return nil }
        // Handle "Last, First" format
        if first.contains(",") {
            return first.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
        }
        // Handle "First Last" format
        return first.components(separatedBy: " ").last
    }

    /// Short author display string (e.g., "Einstein et al.")
    public var authorDisplayShort: String {
        guard !authors.isEmpty else { return "Unknown" }
        if authors.count == 1 {
            return firstAuthorLastName ?? authors[0]
        }
        return "\(firstAuthorLastName ?? authors[0]) et al."
    }

    /// Available identifiers for this paper
    public var identifiers: [IdentifierType: String] {
        var result: [IdentifierType: String] = [:]
        if let doi = doi { result[.doi] = doi }
        if let arxiv = arxivID { result[.arxiv] = arxiv }
        return result
    }
}

// MARK: - Author Stats

/// Statistics about an author.
public struct AuthorStats: Codable, Sendable, Equatable {
    public let authorID: String
    public let name: String
    public let hIndex: Int?
    public let citationCount: Int?
    public let paperCount: Int?
    public let affiliations: [String]?

    public init(
        authorID: String,
        name: String,
        hIndex: Int? = nil,
        citationCount: Int? = nil,
        paperCount: Int? = nil,
        affiliations: [String]? = nil
    ) {
        self.authorID = authorID
        self.name = name
        self.hIndex = hIndex
        self.citationCount = citationCount
        self.paperCount = paperCount
        self.affiliations = affiliations
    }
}

// MARK: - Enrichment Data

/// Enrichment data for a publication.
///
/// Contains citation count, references, citations, and other metadata
/// fetched from an enrichment source.
public struct EnrichmentData: Codable, Sendable, Equatable {
    public let citationCount: Int?
    public let referenceCount: Int?
    public let references: [PaperStub]?
    public let citations: [PaperStub]?
    public let abstract: String?
    public let pdfURLs: [URL]?
    public let pdfLinks: [PDFLink]?  // Typed PDF links with source info
    public let openAccessStatus: OpenAccessStatus?
    public let venue: String?
    public let authorStats: [AuthorStats]?
    public let source: EnrichmentSource
    public let fetchedAt: Date

    public init(
        citationCount: Int? = nil,
        referenceCount: Int? = nil,
        references: [PaperStub]? = nil,
        citations: [PaperStub]? = nil,
        abstract: String? = nil,
        pdfURLs: [URL]? = nil,
        pdfLinks: [PDFLink]? = nil,
        openAccessStatus: OpenAccessStatus? = nil,
        venue: String? = nil,
        authorStats: [AuthorStats]? = nil,
        source: EnrichmentSource,
        fetchedAt: Date = Date()
    ) {
        self.citationCount = citationCount
        self.referenceCount = referenceCount
        self.references = references
        self.citations = citations
        self.abstract = abstract
        self.pdfURLs = pdfURLs
        self.pdfLinks = pdfLinks
        self.openAccessStatus = openAccessStatus
        self.venue = venue
        self.authorStats = authorStats
        self.source = source
        self.fetchedAt = fetchedAt
    }

    /// Age of the data in seconds
    public var age: TimeInterval {
        Date().timeIntervalSince(fetchedAt)
    }

    /// Whether the data is stale (older than threshold)
    public func isStale(thresholdDays: Int = 7) -> Bool {
        age > TimeInterval(thresholdDays * 24 * 60 * 60)
    }

    /// Merge with another enrichment data, preferring non-nil values from self
    public func merging(with other: EnrichmentData) -> EnrichmentData {
        EnrichmentData(
            citationCount: citationCount ?? other.citationCount,
            referenceCount: referenceCount ?? other.referenceCount,
            references: references ?? other.references,
            citations: citations ?? other.citations,
            abstract: abstract ?? other.abstract,
            pdfURLs: pdfURLs ?? other.pdfURLs,
            pdfLinks: pdfLinks ?? other.pdfLinks,
            openAccessStatus: openAccessStatus ?? other.openAccessStatus,
            venue: venue ?? other.venue,
            authorStats: authorStats ?? other.authorStats,
            source: source,  // Keep original source
            fetchedAt: fetchedAt  // Keep original timestamp
        )
    }
}

// MARK: - Enrichment Result

/// Result of an enrichment request.
///
/// Contains the enrichment data and any resolved identifiers.
public struct EnrichmentResult: Sendable {
    public let data: EnrichmentData
    public let resolvedIdentifiers: [IdentifierType: String]

    public init(
        data: EnrichmentData,
        resolvedIdentifiers: [IdentifierType: String] = [:]
    ) {
        self.data = data
        self.resolvedIdentifiers = resolvedIdentifiers
    }
}

// MARK: - Enrichment Priority

/// Priority levels for enrichment requests.
public enum EnrichmentPriority: Int, Comparable, Sendable, CaseIterable {
    case userTriggered = 0   // Immediate (user clicked "Enrich")
    case recentlyViewed = 1  // High (user viewed paper details)
    case libraryPaper = 2    // Normal (background library sync)
    case backgroundSync = 3  // Low (periodic refresh)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .userTriggered: return "User Triggered"
        case .recentlyViewed: return "Recently Viewed"
        case .libraryPaper: return "Library Paper"
        case .backgroundSync: return "Background Sync"
        }
    }
}

// MARK: - Enrichment Error

/// Errors that can occur during enrichment.
public enum EnrichmentError: LocalizedError, Sendable {
    case noIdentifier
    case noSourceAvailable
    case authenticationRequired(String)
    case networkError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case parseError(String)
    case notFound
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noIdentifier:
            return "No identifier available for enrichment"
        case .noSourceAvailable:
            return "No enrichment source could provide data"
        case .authenticationRequired(let sourceID):
            return "Authentication required for \(sourceID)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds"
            }
            return "Rate limited. Please try again later"
        case .parseError(let message):
            return "Failed to parse response: \(message)"
        case .notFound:
            return "Paper not found in enrichment source"
        case .cancelled:
            return "Enrichment request was cancelled"
        }
    }
}

// MARK: - Enrichment State

/// State of an enrichment request.
public enum EnrichmentState: Sendable {
    case idle
    case pending
    case enriching
    case complete(EnrichmentData)
    case failed(EnrichmentError)

    public var isLoading: Bool {
        switch self {
        case .pending, .enriching: return true
        default: return false
        }
    }

    public var data: EnrichmentData? {
        if case .complete(let data) = self {
            return data
        }
        return nil
    }

    public var error: EnrichmentError? {
        if case .failed(let error) = self {
            return error
        }
        return nil
    }
}

// MARK: - Enrichment Settings

/// User preferences for enrichment behavior.
public struct EnrichmentSettings: Codable, Sendable, Equatable {
    public var preferredSource: EnrichmentSource
    public var sourcePriority: [EnrichmentSource]
    public var autoSyncEnabled: Bool
    public var refreshIntervalDays: Int

    public static let `default` = EnrichmentSettings(
        preferredSource: .ads,
        sourcePriority: [.ads, .openalex, .wos],
        autoSyncEnabled: true,
        refreshIntervalDays: 7
    )

    public init(
        preferredSource: EnrichmentSource = .ads,
        sourcePriority: [EnrichmentSource] = [.ads],
        autoSyncEnabled: Bool = true,
        refreshIntervalDays: Int = 7
    ) {
        self.preferredSource = preferredSource
        self.sourcePriority = sourcePriority
        self.autoSyncEnabled = autoSyncEnabled
        self.refreshIntervalDays = refreshIntervalDays
    }
}

// MARK: - Enrichment Settings Provider Protocol

/// Protocol for accessing enrichment settings.
public protocol EnrichmentSettingsProvider: Sendable {
    var preferredSource: EnrichmentSource { get async }
    var sourcePriority: [EnrichmentSource] { get async }
    var autoSyncEnabled: Bool { get async }
    var refreshIntervalDays: Int { get async }
}
