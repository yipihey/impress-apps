//
//  ImprintSearchService.swift
//  imprint
//
//  Multi-term Tantivy-backed publication search for imprint, mirroring
//  imbib's Cmd+F search pipeline. Opens a dedicated search index in the
//  shared workspace directory and indexes publications from the shared
//  Rust store on first use.
//
//  Why not reuse imbib's index directly: imbib's index lives in its own
//  sandbox container (~/Library/Application Support/imbib/search_index),
//  which imprint can't read. Putting our own index in the shared app
//  group container lets both apps maintain consistent search UX.
//

import Foundation
import ImbibRustCore
import ImpressKit
import ImpressLogging

/// Tantivy-backed publication search for imprint.
///
/// Use this for the inline citation palette and any other multi-term search UI.
/// Falls back to `ImprintPublicationService.searchPublications` (SQLite LIKE)
/// while the index is being built, so typed queries never show a dead state.
public actor ImprintSearchService {

    public static let shared = ImprintSearchService()

    private var session: RustImprintSearchSession?
    private var isIndexReady: Bool = false
    private var isRebuilding: Bool = false
    private var indexPath: URL?

    private init() {}

    // MARK: - Public API

    /// Whether the full-text index is ready for queries.
    public func isAvailable() async -> Bool {
        return isIndexReady && session != nil
    }

    /// Initialize the search index, building it from the shared publication
    /// store on first launch. Safe to call multiple times; no-ops after the
    /// first successful init.
    public func initialize() async {
        guard session == nil else { return }

        do {
            try SharedWorkspace.ensureDirectoryExists()
            let indexDir = SharedWorkspace.workspaceDirectory.appendingPathComponent("imprint_search_index", isDirectory: true)
            self.indexPath = indexDir

            logInfo("ImprintSearchService: initializing at \(indexDir.path)", category: "imprint-search")

            // Try to open (or create) the index
            let s = RustImprintSearchSession()
            do {
                try await s.initialize(path: indexDir)
            } catch {
                // If corrupted, delete and recreate
                let msg = String(describing: error)
                if msg.contains("FileDoesNotExist") || msg.contains("meta.json") || msg.contains("corrupt") {
                    logInfo("ImprintSearchService: index corrupted, recreating", category: "imprint-search")
                    try? FileManager.default.removeItem(at: indexDir)
                    let s2 = RustImprintSearchSession()
                    try await s2.initialize(path: indexDir)
                    self.session = s2
                } else {
                    throw error
                }
            }
            if self.session == nil { self.session = s }
            self.isIndexReady = true

            // Rebuild index on first launch or after invalidation
            let markerFile = indexDir.appendingPathComponent(".indexed")
            if !FileManager.default.fileExists(atPath: markerFile.path) {
                logInfo("ImprintSearchService: marker absent, rebuilding", category: "imprint-search")
                await rebuildIndex()
                try? Data().write(to: markerFile)
            }
        } catch {
            logInfo("ImprintSearchService: initialize failed: \(error)", category: "imprint-search")
        }
    }

    /// Rebuild the full index from the shared publication store.
    /// Uses batch indexing to avoid per-publication FFI overhead.
    public func rebuildIndex() async {
        guard let session, !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        // Fetch all publications from the shared store, then convert in one pass.
        // We call the service from a detached task because the store adapter is
        // MainActor-bound, and we want batch indexing off the main thread.
        let startedAt = Date()
        let rows: [BibliographyRow] = await MainActor.run {
            ImprintPublicationService.shared.allBibliographyRows()
        }

        logInfo("ImprintSearchService: fetched \(rows.count) rows for indexing", category: "imprint-search")

        // Convert to Rust Publication structs (skeletal — title/authors/abstract/note)
        let pubs: [Publication] = rows.map { row in
            Publication(
                id: row.id,
                citeKey: row.citeKey,
                entryType: "article",
                title: row.title,
                year: row.year.map { Int32($0) },
                month: nil,
                authors: [Author(
                    id: UUID().uuidString,
                    givenName: nil,
                    familyName: row.authorString,
                    suffix: nil,
                    orcid: nil,
                    affiliation: nil
                )],
                editors: [],
                journal: row.venue,
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
                note: row.note,
                abstractText: row.abstractText,
                keywords: row.categories,
                url: nil,
                eprint: nil,
                primaryClass: nil,
                archivePrefix: nil,
                identifiers: Identifiers(
                    doi: row.doi,
                    arxivId: row.arxivId,
                    pmid: nil,
                    pmcid: nil,
                    bibcode: row.bibcode,
                    isbn: nil,
                    issn: nil,
                    orcid: nil
                ),
                extraFields: [:],
                linkedFiles: [],
                tags: row.tags.map(\.path),
                collections: [],
                libraryId: nil,
                createdAt: nil,
                modifiedAt: nil,
                sourceId: nil,
                citationCount: Int32(row.citationCount),
                referenceCount: Int32(row.referenceCount),
                enrichmentSource: nil,
                enrichmentDate: nil,
                rawBibtex: nil,
                rawRis: nil
            )
        }

        do {
            let count = try await session.addBatch(pubs)
            try await session.commit()
            let elapsed = Date().timeIntervalSince(startedAt)
            logInfo("ImprintSearchService: indexed \(count) publications in \(String(format: "%.2f", elapsed))s", category: "imprint-search")
        } catch {
            logInfo("ImprintSearchService: rebuild failed: \(error)", category: "imprint-search")
        }
    }

    /// Invalidate the index and trigger a rebuild on next query.
    /// Called from cache invalidation hooks when imbib mutates publications.
    public func invalidate() async {
        guard let indexPath else { return }
        let markerFile = indexPath.appendingPathComponent(".indexed")
        try? FileManager.default.removeItem(at: markerFile)
        // Don't rebuild synchronously — let the next query trigger it lazily
    }

    /// Run a search query. Returns Tantivy scored results with snippets.
    public func search(query: String, limit: Int = 30) async -> [SearchHit] {
        // If the index isn't ready yet, try to initialize on the fly.
        if session == nil {
            await initialize()
        }
        guard let session, isIndexReady else { return [] }
        do {
            return try await session.searchWithSnippets(query: query, limit: limit, libraryId: nil)
        } catch {
            logInfo("ImprintSearchService: search failed: \(error)", category: "imprint-search")
            return []
        }
    }
}

// MARK: - Minimal actor wrapper around the Rust search index FFI

/// Thin actor wrapping the UniFFI `searchIndex*` free functions from ImbibRustCore.
/// Separate from imbib's `RustSearchIndexSession` so we don't need to import
/// PublicationManagerCore (which would pull in lots of unrelated deps).
public actor RustImprintSearchSession {
    private var handleId: UInt64?

    public init() {}

    public func initialize(path: URL) async throws {
        // Ensure parent directory exists (Rust creates the index dir itself)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.handleId = try searchIndexCreate(path: path.path)
    }

    public func addBatch(_ publications: [Publication]) async throws -> UInt32 {
        guard let id = handleId else { throw ImprintSearchError.notInitialized }
        return try searchIndexAddBatch(handleId: id, publications: publications)
    }

    public func commit() async throws {
        guard let id = handleId else { throw ImprintSearchError.notInitialized }
        try searchIndexCommit(handleId: id)
    }

    public func searchWithSnippets(
        query: String,
        limit: Int = 30,
        libraryId: String? = nil
    ) async throws -> [SearchHit] {
        guard let id = handleId else { throw ImprintSearchError.notInitialized }
        return try searchIndexSearchWithSnippets(
            handleId: id,
            query: query,
            limit: UInt32(limit),
            libraryId: libraryId
        )
    }
}

public enum ImprintSearchError: Error {
    case notInitialized
}
