//
//  SmartSearchTypes.swift
//  ImpressSmartSearch
//
//  Library-local value types. Mirror the shapes of imbib's PaperIdentifier
//  and CitationInput so callers can adapt one→one, but keep this package
//  independent of imbib internals.
//

import Foundation

// MARK: - PaperIdentifierLite

/// A bare paper identifier the classifier can recognize without database
/// access. Only includes types we can detect from a string with confidence.
public enum PaperIdentifierLite: Sendable, Equatable, Hashable {
    case doi(String)
    case arxiv(String)
    case bibcode(String)
    case pmid(String)

    public var value: String {
        switch self {
        case .doi(let v), .arxiv(let v), .bibcode(let v), .pmid(let v):
            return v
        }
    }

    public var typeName: String {
        switch self {
        case .doi: return "doi"
        case .arxiv: return "arxiv"
        case .bibcode: return "bibcode"
        case .pmid: return "pmid"
        }
    }
}

// MARK: - CitationInputLite

/// Structured citation fields, mirroring imbib's `CitationInput`. Used by
/// `ReferenceParser` to return parsed results that the caller (imbib) can
/// trivially adapt to its own type at the call site.
public struct CitationInputLite: Sendable, Equatable, Hashable {
    public var authors: [String]
    public var title: String?
    public var year: Int?
    public var journal: String?
    public var volume: String?
    public var pages: String?
    public var doi: String?
    public var arxiv: String?
    public var bibcode: String?
    /// The original raw reference string the user pasted, kept so the resolver
    /// can fall back to all-sources search if structured ADS finds nothing.
    public var freeText: String?

    public init(
        authors: [String] = [],
        title: String? = nil,
        year: Int? = nil,
        journal: String? = nil,
        volume: String? = nil,
        pages: String? = nil,
        doi: String? = nil,
        arxiv: String? = nil,
        bibcode: String? = nil,
        freeText: String? = nil
    ) {
        self.authors = authors
        self.title = title
        self.year = year
        self.journal = journal
        self.volume = volume
        self.pages = pages
        self.doi = doi
        self.arxiv = arxiv
        self.bibcode = bibcode
        self.freeText = freeText
    }

    public var hasIdentifier: Bool {
        !(doi ?? "").isEmpty || !(arxiv ?? "").isEmpty || !(bibcode ?? "").isEmpty
    }
}

// MARK: - ParsedReference

/// Provider-agnostic intermediate shape — both the on-device `@Generable`
/// path and the cloud JSON path produce this before validation.
public struct ParsedReference: Sendable, Equatable, Hashable {
    public let authors: [String]
    public let title: String
    public let year: Int
    public let journal: String
    public let volume: String
    public let pages: String
    public let doi: String
    public let arxiv: String
    public let bibcode: String
    public let confidence: Double

    public init(
        authors: [String],
        title: String,
        year: Int,
        journal: String,
        volume: String,
        pages: String,
        doi: String,
        arxiv: String,
        bibcode: String,
        confidence: Double
    ) {
        self.authors = authors
        self.title = title
        self.year = year
        self.journal = journal
        self.volume = volume
        self.pages = pages
        self.doi = doi
        self.arxiv = arxiv
        self.bibcode = bibcode
        self.confidence = confidence
    }
}

// MARK: - QueryRewriteResult

public struct QueryRewriteResult: Sendable, Equatable, Hashable {
    public let query: String
    public let interpretation: String
    public let confidence: Double
    public let source: Source

    public enum Source: String, Sendable, Equatable, Hashable {
        case appleIntelligence
        case cloud
        case degenerate
    }

    public init(query: String, interpretation: String, confidence: Double, source: Source) {
        self.query = query
        self.interpretation = interpretation
        self.confidence = confidence
        self.source = source
    }
}

// MARK: - SearchIntent

public enum SearchIntent: Sendable, Equatable, Hashable {
    case identifier(PaperIdentifierLite)
    case fielded(query: String)
    case reference(blocks: [String])
    case freeText(query: String)
    case url(URL)

    public var label: String {
        switch self {
        case .identifier(let id):
            switch id {
            case .doi: return "DOI"
            case .arxiv: return "arXiv"
            case .bibcode: return "Bibcode"
            case .pmid: return "PMID"
            }
        case .fielded: return "Fielded query"
        case .reference(let blocks):
            return blocks.count == 1 ? "Reference" : "References (\(blocks.count))"
        case .freeText: return "Free-text search"
        case .url(let u): return "URL · \(u.host ?? "page")"
        }
    }

    public var kindRawValue: String {
        switch self {
        case .identifier: return "identifier"
        case .fielded: return "fielded"
        case .reference: return "reference"
        case .freeText: return "freeText"
        case .url: return "url"
        }
    }
}

// MARK: - ResolveOutcome

/// Result of `SmartSearchEngine.resolve(_:)`. The caller composes downstream
/// behavior (local lookup, source fan-out, library import) on top of this.
public enum ResolveOutcome: Sendable, Equatable, Hashable {
    case identifier(PaperIdentifierLite)
    case fielded(query: String)
    case citation(ParsedReference)
    case citations([ParsedReference?])     // multi-block; nil = parse-failed
    case freeTextQuery(QueryRewriteResult)
    case urlExtraction(URLExtractionResult)
}

// MARK: - URLExtractionResult

/// Result of `URLContentExtractor.extract(from:)`. Carries the identifiers
/// scraped from the page so the caller can resolve each one through its
/// existing identifier-resolution pipeline.
public struct URLExtractionResult: Sendable, Equatable, Hashable {
    public let url: URL
    public let pageTitle: String?
    /// Identifiers found on the page, deduped by (typeName, value).
    public let identifiers: [PaperIdentifierLite]
    /// Friendly summary for telemetry / UI when no identifiers are found.
    public let reason: String?

    public init(url: URL, pageTitle: String?, identifiers: [PaperIdentifierLite], reason: String? = nil) {
        self.url = url
        self.pageTitle = pageTitle
        self.identifiers = identifiers
        self.reason = reason
    }
}
