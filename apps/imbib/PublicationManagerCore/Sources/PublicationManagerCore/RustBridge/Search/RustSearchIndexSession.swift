//
//  RustSearchIndexSession.swift
//  PublicationManagerCore
//
//  Actor-based search index backed by the Rust imbib-core library (Tantivy).
//  Provides full-text search for publications with thread-safe access.
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

// MARK: - Search Index Error

/// Errors that can occur when using the search index
public enum SearchIndexError: Error, LocalizedError {
    case notInitialized
    case initializationFailed(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Search index not initialized"
        case .initializationFailed(let reason):
            return "Failed to initialize search index: \(reason)"
        case .operationFailed(let reason):
            return "Search index operation failed: \(reason)"
        }
    }
}

// MARK: - Rust Search Index Session (Actor-based)

/// Actor-based full-text search index backed by Rust/Tantivy.
/// Provides thread-safe access to the search index.
public actor RustSearchIndexSession {
    private var handleId: UInt64?

    /// Create a search index session (uninitialized)
    public init() {}

    /// Initialize with a path on disk
    /// - Parameter path: Directory path for the index
    /// - Throws: SearchIndexError if creation fails
    public func initialize(path: URL) async throws {
        do {
            self.handleId = try searchIndexCreate(path: path.path)
        } catch {
            throw SearchIndexError.initializationFailed("\(error)")
        }
    }

    /// Initialize with an in-memory index (for testing)
    /// - Throws: SearchIndexError if creation fails
    public func initializeInMemory() async throws {
        do {
            self.handleId = try searchIndexCreateInMemory()
        } catch {
            throw SearchIndexError.initializationFailed("\(error)")
        }
    }

    /// Add a publication to the index using SearchIndexInput
    /// - Parameters:
    ///   - input: The publication data to index
    ///   - fullText: Optional full text content (e.g., from PDF)
    /// - Throws: SearchIndexError if indexing fails
    public func add(_ input: SearchIndexInput, fullText: String? = nil) async throws {
        guard let id = handleId else {
            throw SearchIndexError.notInitialized
        }
        do {
            try searchIndexAdd(handleId: id, publication: input.toPublication(), fullText: fullText)
        } catch {
            throw SearchIndexError.operationFailed("\(error)")
        }
    }

    /// Add a publication to the index using the Rust Publication type
    /// - Parameters:
    ///   - publication: The publication to index
    ///   - fullText: Optional full text content (e.g., from PDF)
    /// - Throws: SearchIndexError if indexing fails
    public func add(_ publication: ImbibRustCore.Publication, fullText: String? = nil) async throws {
        guard let id = handleId else {
            throw SearchIndexError.notInitialized
        }
        do {
            try searchIndexAdd(handleId: id, publication: publication, fullText: fullText)
        } catch {
            throw SearchIndexError.operationFailed("\(error)")
        }
    }

    /// Delete a publication from the index
    /// - Parameter publicationId: The ID of the publication to remove
    /// - Throws: SearchIndexError if deletion fails
    public func delete(publicationId: String) async throws {
        guard let id = handleId else {
            throw SearchIndexError.notInitialized
        }
        do {
            try searchIndexDelete(handleId: id, publicationId: publicationId)
        } catch {
            throw SearchIndexError.operationFailed("\(error)")
        }
    }

    /// Commit pending changes to the index
    /// - Throws: SearchIndexError if commit fails
    public func commit() async throws {
        guard let id = handleId else {
            throw SearchIndexError.notInitialized
        }
        do {
            try searchIndexCommit(handleId: id)
        } catch {
            throw SearchIndexError.operationFailed("\(error)")
        }
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
    ) async throws -> [RustSearchHit] {
        guard let id = handleId else {
            throw SearchIndexError.notInitialized
        }
        do {
            let hits = try searchIndexSearch(
                handleId: id,
                query: query,
                limit: UInt32(limit),
                libraryId: libraryId
            )
            return hits.map { RustSearchHit(from: $0) }
        } catch {
            throw SearchIndexError.operationFailed("\(error)")
        }
    }

    /// Close the index and release resources
    public func close() async {
        guard let id = handleId else { return }
        do {
            try searchIndexClose(handleId: id)
        } catch {
            print("Warning: Failed to close search index: \(error)")
        }
        handleId = nil
    }

    /// Check if the index is initialized
    public var isInitialized: Bool {
        handleId != nil
    }

    deinit {
        if let id = handleId {
            do {
                try searchIndexClose(handleId: id)
            } catch {
                print("Warning: Failed to close search index in deinit: \(error)")
            }
        }
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

// MARK: - Legacy Type Alias

/// Type alias for backwards compatibility
@available(*, deprecated, renamed: "RustSearchIndexSession")
public typealias RustSearchIndex = RustSearchIndexSession
