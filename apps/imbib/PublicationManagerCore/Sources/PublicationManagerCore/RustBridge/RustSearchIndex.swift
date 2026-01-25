//
//  RustSearchIndex.swift
//  PublicationManagerCore
//
//  Search index backed by the Rust imbib-core library (Tantivy).
//  Provides full-text search for publications.
//

import Foundation
import ImbibRustCore

// MARK: - Input Type (shared API)

/// Input for indexing a publication
public struct SearchIndexInput: Sendable {
    public let id: String
    public let citeKey: String
    public let title: String
    public let authors: String?
    public let abstractText: String?

    public init(
        id: String,
        citeKey: String,
        title: String,
        authors: String? = nil,
        abstractText: String? = nil
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.abstractText = abstractText
    }

    /// Convert to Rust Publication type
    func toPublication() -> ImbibRustCore.Publication {
        var authors: [ImbibRustCore.Author] = []
        if let authorString = self.authors {
            // Simple author parsing - create a single author with the string
            authors = [ImbibRustCore.Author(
                id: UUID().uuidString,
                givenName: nil,
                familyName: authorString,
                suffix: nil,
                orcid: nil,
                affiliation: nil
            )]
        }

        return ImbibRustCore.Publication(
            id: id,
            citeKey: citeKey,
            entryType: "article",
            title: title,
            year: nil,
            month: nil,
            authors: authors,
            editors: [],
            journal: nil,
            booktitle: nil,
            publisher: nil,
            volume: nil,
            number: nil,
            pages: nil,
            edition: nil,
            series: nil,
            address: nil,
            chapter: nil,
            howpublished: nil,
            institution: nil,
            organization: nil,
            school: nil,
            note: nil,
            abstractText: abstractText,
            keywords: [],
            url: nil,
            eprint: nil,
            primaryClass: nil,
            archivePrefix: nil,
            identifiers: ImbibRustCore.Identifiers(
                doi: nil,
                arxivId: nil,
                pmid: nil,
                pmcid: nil,
                bibcode: nil,
                isbn: nil,
                issn: nil,
                orcid: nil
            ),
            extraFields: [:],
            linkedFiles: [],
            tags: [],
            collections: [],
            libraryId: nil,
            createdAt: nil,
            modifiedAt: nil,
            sourceId: nil,
            citationCount: nil,
            referenceCount: nil,
            enrichmentSource: nil,
            enrichmentDate: nil,
            rawBibtex: nil,
            rawRis: nil
        )
    }
}

// MARK: - Rust Search Index

/// Full-text search index backed by Rust/Tantivy
public final class RustSearchIndex: @unchecked Sendable {
    private let handleId: UInt64

    /// Create a search index at the given path
    /// - Parameter path: Directory path for the index
    /// - Throws: SearchIndexError if creation fails
    public init(path: URL) throws {
        self.handleId = try searchIndexCreate(path: path.path)
    }

    /// Create an in-memory search index (for testing)
    /// - Throws: SearchIndexError if creation fails
    public init(inMemory: Bool = true) throws {
        self.handleId = try searchIndexCreateInMemory()
    }

    deinit {
        do {
            try searchIndexClose(handleId: handleId)
        } catch {
            // Log but don't throw in deinit
            print("Warning: Failed to close search index: \(error)")
        }
    }

    /// Add a publication to the index using SearchIndexInput
    /// - Parameters:
    ///   - input: The publication data to index
    ///   - fullText: Optional full text content (e.g., from PDF)
    /// - Throws: SearchIndexError if indexing fails
    public func add(_ input: SearchIndexInput, fullText: String? = nil) throws {
        try searchIndexAdd(handleId: handleId, publication: input.toPublication(), fullText: fullText)
    }

    /// Add a publication to the index using the Rust Publication type
    /// - Parameters:
    ///   - publication: The publication to index
    ///   - fullText: Optional full text content (e.g., from PDF)
    /// - Throws: SearchIndexError if indexing fails
    public func add(_ publication: ImbibRustCore.Publication, fullText: String? = nil) throws {
        try searchIndexAdd(handleId: handleId, publication: publication, fullText: fullText)
    }

    /// Delete a publication from the index
    /// - Parameter publicationId: The ID of the publication to remove
    /// - Throws: SearchIndexError if deletion fails
    public func delete(publicationId: String) throws {
        try searchIndexDelete(handleId: handleId, publicationId: publicationId)
    }

    /// Commit pending changes to the index
    /// - Throws: SearchIndexError if commit fails
    public func commit() throws {
        try searchIndexCommit(handleId: handleId)
    }

    /// Search the index
    /// - Parameters:
    ///   - query: The search query
    ///   - limit: Maximum number of results
    ///   - libraryId: Optional library ID to filter results
    /// - Returns: Array of search hits
    /// - Throws: SearchIndexError if search fails
    public func search(
        query: String,
        limit: Int = 20,
        libraryId: String? = nil
    ) throws -> [RustSearchHit] {
        let hits = try searchIndexSearch(
            handleId: handleId,
            query: query,
            limit: UInt32(limit),
            libraryId: libraryId
        )
        return hits.map { RustSearchHit(from: $0) }
    }

    /// Get the number of active index handles (for debugging)
    public static var activeHandleCount: Int {
        Int(searchIndexHandleCount())
    }
}

/// A search result hit
public struct RustSearchHit: Sendable {
    /// Publication ID
    public let id: String
    /// Citation key
    public let citeKey: String
    /// Publication title
    public let title: String
    /// Relevance score
    public let score: Float
    /// Optional text snippet with matches highlighted
    public let snippet: String?

    init(from hit: ImbibRustCore.SearchHit) {
        self.id = hit.id
        self.citeKey = hit.citeKey
        self.title = hit.title
        self.score = hit.score
        self.snippet = hit.snippet
    }

    public init(
        id: String,
        citeKey: String,
        title: String,
        score: Float,
        snippet: String?
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.score = score
        self.snippet = snippet
    }
}

/// Information about Rust search index availability
public enum RustSearchIndexInfo {
    public static var isAvailable: Bool { true }
}
