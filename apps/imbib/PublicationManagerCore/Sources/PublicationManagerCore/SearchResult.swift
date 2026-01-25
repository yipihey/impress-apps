//
//  SearchResult.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - PDF Link Type

/// Types of PDF links available from academic sources.
/// Maps to ADS esource types and BibDesk bdsk-url-* field numbers.
public enum PDFLinkType: String, Sendable, Codable, CaseIterable, Hashable {
    /// Publisher PDF (may require subscription)
    case publisher = "pub_pdf"
    /// Preprint/arXiv PDF (free)
    case preprint = "eprint_pdf"
    /// Author-provided PDF
    case author = "author_pdf"
    /// ADS-hosted PDF scan
    case adsScan = "ads_pdf"

    /// The BibDesk bdsk-url-* field number for this link type
    public var bdskUrlNumber: Int {
        switch self {
        case .publisher: return 1
        case .preprint: return 2
        case .author: return 3
        case .adsScan: return 4
        }
    }

    /// Create from BibDesk field number
    public init?(bdskUrlNumber: Int) {
        switch bdskUrlNumber {
        case 1: self = .publisher
        case 2: self = .preprint
        case 3: self = .author
        case 4: self = .adsScan
        default: return nil
        }
    }

    /// Display name for UI
    public var displayName: String {
        switch self {
        case .publisher: return "Publisher"
        case .preprint: return "Preprint"
        case .author: return "Author"
        case .adsScan: return "ADS Scan"
        }
    }
}

// MARK: - PDF Link

/// A PDF link with type and source information.
public struct PDFLink: Sendable, Codable, Equatable, Hashable {
    public let url: URL
    public let type: PDFLinkType
    public let sourceID: String?  // Which source API provided this link (e.g., "openalex", "ads")

    public init(url: URL, type: PDFLinkType, sourceID: String? = nil) {
        self.url = url
        self.type = type
        self.sourceID = sourceID
    }
}

// MARK: - Search Result

/// A search result from any source plugin.
/// This is the common currency for cross-source search deduplication.
public struct SearchResult: Sendable, Identifiable, Equatable, Hashable {

    // MARK: - Identity

    /// Unique identifier for this result (source-specific format)
    public let id: String

    /// Which source plugin produced this result
    public let sourceID: String

    // MARK: - Bibliographic Data

    public let title: String
    public let authors: [String]
    public let year: Int?
    public let venue: String?
    public let abstract: String?

    // MARK: - Identifiers

    public let doi: String?
    public let arxivID: String?
    public let pmid: String?
    public let bibcode: String?
    public let semanticScholarID: String?
    public let openAlexID: String?

    // MARK: - Categories (primarily for arXiv)

    /// Primary category (e.g., "cs.LG", "astro-ph.GA")
    public let primaryCategory: String?

    /// All categories including cross-listed (e.g., ["cs.LG", "stat.ML"])
    public let categories: [String]?

    // MARK: - URLs

    /// All available PDF links with type information
    public let pdfLinks: [PDFLink]
    public let webURL: URL?
    public let bibtexURL: URL?

    /// Convenience accessor for first PDF URL (backward compatibility)
    public var pdfURL: URL? {
        pdfLinks.first?.url
    }

    // MARK: - Initialization

    public init(
        id: String,
        sourceID: String,
        title: String,
        authors: [String] = [],
        year: Int? = nil,
        venue: String? = nil,
        abstract: String? = nil,
        doi: String? = nil,
        arxivID: String? = nil,
        pmid: String? = nil,
        bibcode: String? = nil,
        semanticScholarID: String? = nil,
        openAlexID: String? = nil,
        primaryCategory: String? = nil,
        categories: [String]? = nil,
        pdfLinks: [PDFLink] = [],
        webURL: URL? = nil,
        bibtexURL: URL? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.abstract = abstract
        self.doi = doi
        self.arxivID = arxivID
        self.pmid = pmid
        self.bibcode = bibcode
        self.semanticScholarID = semanticScholarID
        self.openAlexID = openAlexID
        self.primaryCategory = primaryCategory
        self.categories = categories
        self.pdfLinks = pdfLinks
        self.webURL = webURL
        self.bibtexURL = bibtexURL
    }

    /// Convenience initializer with single PDF URL (backward compatibility)
    public init(
        id: String,
        sourceID: String,
        title: String,
        authors: [String] = [],
        year: Int? = nil,
        venue: String? = nil,
        abstract: String? = nil,
        doi: String? = nil,
        arxivID: String? = nil,
        pmid: String? = nil,
        bibcode: String? = nil,
        semanticScholarID: String? = nil,
        openAlexID: String? = nil,
        primaryCategory: String? = nil,
        categories: [String]? = nil,
        pdfURL: URL?,
        webURL: URL? = nil,
        bibtexURL: URL? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.abstract = abstract
        self.doi = doi
        self.arxivID = arxivID
        self.pmid = pmid
        self.bibcode = bibcode
        self.semanticScholarID = semanticScholarID
        self.openAlexID = openAlexID
        self.primaryCategory = primaryCategory
        self.categories = categories
        // Convert single URL to pdfLinks array with default type
        if let url = pdfURL {
            self.pdfLinks = [PDFLink(url: url, type: .publisher)]
        } else {
            self.pdfLinks = []
        }
        self.webURL = webURL
        self.bibtexURL = bibtexURL
    }
}

// MARK: - Identifier Helpers

public extension SearchResult {

    /// Returns the primary identifier for this result (DOI preferred)
    var primaryIdentifier: String? {
        doi ?? arxivID ?? pmid ?? bibcode ?? semanticScholarID ?? openAlexID
    }

    /// Returns all available identifiers as a dictionary
    var allIdentifiers: [IdentifierType: String] {
        var result: [IdentifierType: String] = [:]
        if let doi = doi { result[.doi] = doi }
        if let arxivID = arxivID { result[.arxiv] = arxivID }
        if let pmid = pmid { result[.pmid] = pmid }
        if let bibcode = bibcode { result[.bibcode] = bibcode }
        if let semanticScholarID = semanticScholarID { result[.semanticScholar] = semanticScholarID }
        if let openAlexID = openAlexID { result[.openAlex] = openAlexID }
        return result
    }

    /// First author's last name (for display and cite key generation)
    var firstAuthorLastName: String? {
        guard let first = authors.first else { return nil }
        // Handle "Last, First" format
        if first.contains(",") {
            return first.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
        }
        // Handle "First Last" format
        return first.components(separatedBy: " ").last
    }
}

// MARK: - Identifier Type

/// Types of publication identifiers across different sources
public enum IdentifierType: String, Sendable, Codable, CaseIterable, Hashable {
    case doi
    case arxiv
    case pmid
    case pmcid
    case bibcode
    case semanticScholar
    case openAlex
    case dblp

    public var displayName: String {
        switch self {
        case .doi: return "DOI"
        case .arxiv: return "arXiv"
        case .pmid: return "PubMed"
        case .pmcid: return "PMC"
        case .bibcode: return "ADS Bibcode"
        case .semanticScholar: return "Semantic Scholar"
        case .openAlex: return "OpenAlex"
        case .dblp: return "DBLP"
        }
    }
}

// MARK: - Deduplicated Result

/// A search result that may have duplicates from multiple sources.
/// Used by the deduplication service to present unified results.
public struct DeduplicatedResult: Sendable, Identifiable, Equatable {

    /// The primary result (from highest priority source)
    public let primary: SearchResult

    /// Alternate results from other sources (same paper)
    public let alternates: [SearchResult]

    /// All known identifiers across all sources
    public let identifiers: [IdentifierType: String]

    public var id: String { primary.id }

    public init(
        primary: SearchResult,
        alternates: [SearchResult] = [],
        identifiers: [IdentifierType: String] = [:]
    ) {
        self.primary = primary
        self.alternates = alternates
        self.identifiers = identifiers.isEmpty ? primary.allIdentifiers : identifiers
    }

    /// All source IDs that found this paper
    public var sourceIDs: [String] {
        [primary.sourceID] + alternates.map(\.sourceID)
    }

    /// All PDF links across all sources, merged and deduplicated
    public var allPDFLinks: [PDFLink] {
        var links = primary.pdfLinks
        for alt in alternates {
            for link in alt.pdfLinks {
                // Add if we don't already have this type
                if !links.contains(where: { $0.type == link.type }) {
                    links.append(link)
                }
            }
        }
        return links
    }

    /// Best available PDF URL across all sources (preprint preferred)
    public var bestPDFURL: URL? {
        // Prefer preprint (free), then publisher, then others
        let priorityOrder: [PDFLinkType] = [.preprint, .publisher, .author, .adsScan]
        for type in priorityOrder {
            if let link = allPDFLinks.first(where: { $0.type == type }) {
                return link.url
            }
        }
        return allPDFLinks.first?.url
    }

    /// Best available BibTeX URL across all sources
    public var bestBibTeXURL: URL? {
        primary.bibtexURL ?? alternates.first(where: { $0.bibtexURL != nil })?.bibtexURL
    }

    /// Best available abstract across all sources
    /// Checks primary first, then alternates (abstracts often missing from Crossref but present in ADS)
    public var bestAbstract: String? {
        if let abstract = primary.abstract, !abstract.isEmpty {
            return abstract
        }
        return alternates.first(where: { $0.abstract != nil && !($0.abstract?.isEmpty ?? true) })?.abstract
    }
}
