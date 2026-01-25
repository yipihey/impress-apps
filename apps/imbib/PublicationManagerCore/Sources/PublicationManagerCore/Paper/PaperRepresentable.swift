//
//  PaperRepresentable.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - Paper Source Type

/// Identifies the origin of a paper
public enum PaperSourceType: Sendable, Equatable {
    /// Paper from a local library (.bib file)
    case local(libraryID: UUID)

    /// Paper from a saved smart search
    case smartSearch(searchID: UUID)

    /// Paper from an ad-hoc online search (session-only)
    case adHocSearch(sourceID: String)

    /// Whether this paper is from persistent storage
    public var isPersistent: Bool {
        switch self {
        case .local: return true
        case .smartSearch, .adHocSearch: return false
        }
    }
}

// MARK: - Paper Representable Protocol

/// Common interface for papers from any source.
///
/// This protocol unifies local library papers (Core Data backed) and
/// online search results (transient) under a single abstraction,
/// enabling a unified UI across all paper sources.
public protocol PaperRepresentable: Identifiable, Sendable {

    // MARK: - Identity

    /// Unique identifier for this paper
    var id: String { get }

    // MARK: - Bibliographic Data

    var title: String { get }
    var authors: [String] { get }
    var year: Int? { get }
    var venue: String? { get }
    var abstract: String? { get }

    // MARK: - Identifiers

    var doi: String? { get }
    var arxivID: String? { get }
    var pmid: String? { get }
    var bibcode: String? { get }

    // MARK: - Source Info

    /// Where this paper came from
    var sourceType: PaperSourceType { get }

    // MARK: - File Access

    /// Available PDF links with type information (publisher, preprint, etc.)
    var pdfLinks: [PDFLink] { get }

    /// URL to the PDF, if available.
    /// For online papers, this may trigger a download to temp storage.
    func pdfURL() async -> URL?

    /// BibTeX representation of this paper.
    /// For local papers, returns stored BibTeX.
    /// For online papers, fetches from source.
    func bibtex() async throws -> String
}

// MARK: - Default Implementations

public extension PaperRepresentable {

    /// First author's last name for display and cite key generation
    var firstAuthorLastName: String? {
        guard let first = authors.first else { return nil }
        // Handle "Last, First" format
        if first.contains(",") {
            return first.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
        }
        // Handle "First Last" format
        return first.components(separatedBy: " ").last
    }

    /// Short author string for display (e.g., "Einstein et al.")
    var authorDisplayString: String {
        switch authors.count {
        case 0: return "Unknown"
        case 1: return authors[0]
        case 2: return "\(firstAuthorLastName ?? authors[0]) & \(authors[1].components(separatedBy: " ").last ?? authors[1])"
        default: return "\(firstAuthorLastName ?? authors[0]) et al."
        }
    }

    /// All available identifiers
    var allIdentifiers: [IdentifierType: String] {
        var result: [IdentifierType: String] = [:]
        if let doi = doi { result[.doi] = doi }
        if let arxivID = arxivID { result[.arxiv] = arxivID }
        if let pmid = pmid { result[.pmid] = pmid }
        if let bibcode = bibcode { result[.bibcode] = bibcode }
        return result
    }

    /// Primary identifier (DOI preferred)
    var primaryIdentifier: String? {
        doi ?? arxivID ?? pmid ?? bibcode
    }

    /// Whether this paper has a PDF available (local file or remote URL)
    var hasPDF: Bool {
        false  // Default - types override as needed
    }

    /// Default empty PDF links - types override as needed
    var pdfLinks: [PDFLink] {
        []
    }
}

// MARK: - Library Lookup Service

/// Service for checking whether papers exist in the active library.
/// This is injected into paper types to enable the `isInLibrary` check.
public protocol LibraryLookupService: Sendable {
    /// Check if a paper with any of the given identifiers exists in the library
    func contains(identifiers: [IdentifierType: String]) async -> Bool

    /// Check if a paper with the given DOI exists
    func contains(doi: String) async -> Bool

    /// Check if a paper with the given arXiv ID exists
    func contains(arxivID: String) async -> Bool

    /// Check if a paper with the given bibcode exists
    func contains(bibcode: String) async -> Bool
}

// MARK: - Type-Erased Paper

/// Type-erased wrapper for any PaperRepresentable.
/// Useful for collections containing mixed paper types.
public struct AnyPaper: PaperRepresentable {
    private let _id: String
    private let _title: String
    private let _authors: [String]
    private let _year: Int?
    private let _venue: String?
    private let _abstract: String?
    private let _doi: String?
    private let _arxivID: String?
    private let _pmid: String?
    private let _bibcode: String?
    private let _sourceType: PaperSourceType
    private let _hasPDF: Bool
    private let _pdfLinks: [PDFLink]
    private let _pdfURL: @Sendable () async -> URL?
    private let _bibtex: @Sendable () async throws -> String

    public init<P: PaperRepresentable>(_ paper: P) {
        self._id = paper.id
        self._title = paper.title
        self._authors = paper.authors
        self._year = paper.year
        self._venue = paper.venue
        self._abstract = paper.abstract
        self._doi = paper.doi
        self._arxivID = paper.arxivID
        self._pmid = paper.pmid
        self._bibcode = paper.bibcode
        self._sourceType = paper.sourceType
        self._hasPDF = paper.hasPDF
        self._pdfLinks = paper.pdfLinks
        self._pdfURL = { await paper.pdfURL() }
        self._bibtex = { try await paper.bibtex() }
    }

    public var id: String { _id }
    public var title: String { _title }
    public var authors: [String] { _authors }
    public var year: Int? { _year }
    public var venue: String? { _venue }
    public var abstract: String? { _abstract }
    public var doi: String? { _doi }
    public var arxivID: String? { _arxivID }
    public var pmid: String? { _pmid }
    public var bibcode: String? { _bibcode }
    public var sourceType: PaperSourceType { _sourceType }
    public var hasPDF: Bool { _hasPDF }
    public var pdfLinks: [PDFLink] { _pdfLinks }

    public func pdfURL() async -> URL? {
        await _pdfURL()
    }

    public func bibtex() async throws -> String {
        try await _bibtex()
    }
}
