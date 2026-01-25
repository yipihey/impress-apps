//
//  RustSourceBridge.swift
//  PublicationManagerCore
//
//  Bridge between Rust imbib_core source types and Swift types.
//

import Foundation
@_exported import ImbibRustCore

// MARK: - Type Aliases for Disambiguation

/// Rust SearchResult from imbib_core
public typealias RustSearchResult = ImbibRustCore.SearchResult

/// Rust PaperStub from imbib_core
public typealias RustPaperStub = ImbibRustCore.PaperStub

/// Rust Author from imbib_core
public typealias RustAuthor = ImbibRustCore.Author

/// Rust Source enum from imbib_core
public typealias RustSource = ImbibRustCore.Source

/// Rust PdfLink from imbib_core
public typealias RustPdfLink = ImbibRustCore.PdfLink

/// Rust PdfLinkType from imbib_core
public typealias RustPdfLinkType = ImbibRustCore.PdfLinkType

// MARK: - SearchResult Conversion

extension RustSearchResult {

    /// Convert Rust SearchResult to Swift SearchResult
    public func toSwiftSearchResult() -> SearchResult {
        // Convert authors from Rust Author structs to Swift author strings
        let authorStrings = authors.map { author -> String in
            if let given = author.givenName {
                return "\(author.familyName), \(given)"
            } else {
                return author.familyName
            }
        }

        // Convert PDF links (filter out invalid URLs)
        let swiftPdfLinks = pdfLinks.compactMap { link -> PDFLink? in
            guard let url = URL(string: link.url) else { return nil }
            return PDFLink(
                url: url,
                type: link.linkType.toSwiftPDFLinkType(),
                sourceID: source.toSourceID()
            )
        }

        // Build web URL if available
        let webURL: URL? = self.url.flatMap { URL(string: $0) }

        return SearchResult(
            id: sourceId,
            sourceID: source.toSourceID(),
            title: title,
            authors: authorStrings,
            year: year.map { Int($0) },
            venue: journal,
            abstract: abstractText,
            doi: identifiers.doi,
            arxivID: identifiers.arxivId,
            pmid: identifiers.pmid,
            bibcode: identifiers.bibcode,
            pdfLinks: swiftPdfLinks,
            webURL: webURL
        )
    }
}

// MARK: - PaperStub Conversion

extension RustPaperStub {

    /// Convert Rust PaperStub to Swift PaperStub
    public func toSwiftPaperStub() -> PaperStub {
        PaperStub(
            id: id,
            title: title,
            authors: authors,
            year: year.map { Int($0) },
            venue: venue,
            doi: doi,
            arxivID: arxivId,
            citationCount: citationCount.map { Int($0) },
            referenceCount: referenceCount.map { Int($0) },
            isOpenAccess: isOpenAccess,
            abstract: abstractText
        )
    }
}

// MARK: - Source Conversion

extension RustSource {

    /// Convert Rust Source enum to Swift source ID string
    public func toSourceID() -> String {
        switch self {
        case .arXiv: return "arxiv"
        case .ads: return "ads"
        case .crossref: return "crossref"
        case .pubMed: return "pubmed"
        case .semanticScholar: return "semantic_scholar"
        case .openAlex: return "openalex"
        case .dblp: return "dblp"
        case .sciX: return "scix"
        case .local: return "local"
        case .manual: return "manual"
        }
    }
}

// MARK: - PDFLinkType Conversion

extension RustPdfLinkType {

    /// Convert Rust PdfLinkType to Swift PDFLinkType
    public func toSwiftPDFLinkType() -> PDFLinkType {
        switch self {
        case .direct: return .publisher
        case .arXiv: return .preprint
        case .publisher: return .publisher
        case .landing: return .publisher
        case .openAccess: return .preprint
        }
    }
}

// MARK: - Array Extensions

extension Array where Element == RustSearchResult {

    /// Convert array of Rust SearchResults to Swift SearchResults
    public func toSwiftSearchResults() -> [SearchResult] {
        map { $0.toSwiftSearchResult() }
    }
}

extension Array where Element == RustPaperStub {

    /// Convert array of Rust PaperStubs to Swift PaperStubs
    public func toSwiftPaperStubs() -> [PaperStub] {
        map { $0.toSwiftPaperStub() }
    }
}
