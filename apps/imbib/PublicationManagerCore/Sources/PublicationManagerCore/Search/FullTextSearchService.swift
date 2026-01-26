//
//  FullTextSearchService.swift
//  PublicationManagerCore
//
//  Full-text search service using Rust/Tantivy index.
//  Provides fast search across title, authors, abstract, and notes.
//

import Foundation
import CoreData
import OSLog

// MARK: - Full-Text Search Service

/// Actor that manages full-text search using the Rust Tantivy index.
///
/// This service:
/// - Maintains a persistent search index on disk
/// - Indexes publication metadata including abstracts
/// - Provides fast full-text search with relevance ranking
/// - Syncs with Core Data changes
///
/// ## Usage
/// ```swift
/// // Search for publications
/// let results = await FullTextSearchService.shared.search(query: "quantum entanglement")
///
/// // Rebuild the index
/// await FullTextSearchService.shared.rebuildIndex()
/// ```
public actor FullTextSearchService {

    // MARK: - Singleton

    public static let shared = FullTextSearchService()

    // MARK: - Properties

    private var searchIndex: RustSearchIndex?
    private var isIndexReady = false
    private var indexPath: URL?
    private let persistenceController: PersistenceController

    // MARK: - Initialization

    private init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController

        // Set up index path in Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let indexDir = appSupport.appendingPathComponent("imbib/search_index", isDirectory: true)
            self.indexPath = indexDir
        }
    }

    // MARK: - Public API

    /// Check if the search index is available and ready.
    public var isAvailable: Bool {
        let rustAvailable = RustSearchIndexInfo.isAvailable
        let ready = isIndexReady
        if !rustAvailable || !ready {
            Logger.search.debug("FTS availability: rustAvailable=\(rustAvailable), isIndexReady=\(ready)")
        }
        return rustAvailable && ready
    }

    /// Get the number of indexed publications.
    public var indexedCount: Int {
        // This would require adding a count method to the index
        // For now, return -1 to indicate unknown
        -1
    }

    /// Initialize the search index.
    ///
    /// Call this at app launch to set up the search index.
    public func initialize() async {
        Logger.search.infoCapture("Initializing fulltext search index...", category: "search")

        guard RustSearchIndexInfo.isAvailable else {
            Logger.search.warning("Rust search index not available")
            return
        }

        guard let path = indexPath else {
            Logger.search.error("No index path configured")
            return
        }

        Logger.search.debug("Index path: \(path.path)")

        do {
            // Try to create or open the index
            do {
                // Create parent directory if needed (Rust will create the index dir)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                let index = RustSearchIndex()
                try await index.initialize(path: path)
                searchIndex = index
            } catch {
                // If opening fails (e.g., corrupted/empty directory), delete and retry
                let errorDesc = String(describing: error)
                if errorDesc.contains("FileDoesNotExist") || errorDesc.contains("meta.json") {
                    Logger.search.warningCapture("Index directory corrupted, deleting and recreating...", category: "search")

                    // Delete the entire index directory so Rust creates a fresh one
                    try? FileManager.default.removeItem(at: path)

                    // Let Rust create the directory and index from scratch
                    let index = RustSearchIndex()
                    try await index.initialize(path: path)
                    searchIndex = index
                    Logger.search.infoCapture("Fresh index created after deleting corrupted directory", category: "search")
                } else {
                    throw error
                }
            }

            isIndexReady = true
            Logger.search.infoCapture("Fulltext search index ready", category: "search")

            // Check if index needs rebuilding (e.g., first launch or version upgrade)
            let markerFile = path.appendingPathComponent(".indexed")
            if !FileManager.default.fileExists(atPath: markerFile.path) {
                Logger.search.infoCapture("Index marker not found, rebuilding index...", category: "search")
                await rebuildIndex()
                FileManager.default.createFile(atPath: markerFile.path, contents: nil)
                Logger.search.infoCapture("Index rebuilt successfully", category: "search")
            }
        } catch {
            Logger.search.error("Failed to initialize fulltext search: \(error.localizedDescription)")
        }
    }

    /// Search for publications matching the query.
    ///
    /// - Parameters:
    ///   - query: The search query (supports full-text search syntax)
    ///   - limit: Maximum number of results to return
    ///   - libraryId: Optional library ID to filter results
    /// - Returns: Array of publication IDs with relevance scores, or nil if index unavailable
    public func search(
        query: String,
        limit: Int = 50,
        libraryId: UUID? = nil
    ) async -> [FullTextSearchResult]? {
        guard let index = searchIndex, isIndexReady else {
            return nil
        }

        do {
            let hits = try await index.search(
                query: query,
                limit: limit,
                libraryId: libraryId?.uuidString
            )

            return hits.map { hit in
                FullTextSearchResult(
                    publicationId: UUID(uuidString: hit.id) ?? UUID(),
                    citeKey: hit.citeKey,
                    title: hit.title,
                    score: hit.score,
                    snippet: hit.snippet
                )
            }
        } catch {
            Logger.search.error("Search failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Rebuild the entire search index from Core Data.
    ///
    /// This is useful for:
    /// - Initial setup
    /// - Recovery from corruption
    /// - After bulk imports
    public func rebuildIndex() async {
        guard let index = searchIndex else {
            Logger.search.warning("Cannot rebuild: index not initialized")
            return
        }

        Logger.search.infoCapture("Rebuilding search index...", category: "search")

        let context = persistenceController.viewContext
        let publications = await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            return (try? context.fetch(request)) ?? []
        }

        var indexedCount = 0
        for publication in publications {
            await indexPublication(publication, using: index, fullText: nil)
            indexedCount += 1
        }

        do {
            try await index.commit()
            Logger.search.infoCapture("Search index rebuilt with \(indexedCount) publications", category: "search")
        } catch {
            Logger.search.error("Failed to commit index: \(error.localizedDescription)")
        }
    }

    /// Index a single publication.
    ///
    /// Call this when a publication is created or updated.
    public func indexPublication(_ publication: CDPublication) async {
        guard let index = searchIndex else { return }

        await indexPublication(publication, using: index)

        do {
            try await index.commit()
        } catch {
            Logger.search.error("Failed to commit after indexing: \(error.localizedDescription)")
        }
    }

    /// Remove a publication from the index.
    ///
    /// Call this when a publication is deleted.
    public func removePublication(id: UUID) async {
        guard let index = searchIndex else { return }

        do {
            try await index.delete(publicationId: id.uuidString)
            try await index.commit()
        } catch {
            Logger.search.error("Failed to remove from index: \(error.localizedDescription)")
        }
    }

    /// Index multiple publications in batch.
    ///
    /// More efficient than indexing one at a time.
    public func indexPublications(_ publications: [CDPublication]) async {
        guard let index = searchIndex else { return }

        for publication in publications {
            await indexPublication(publication, using: index)
        }

        do {
            try await index.commit()
            Logger.search.debug("Batch indexed \(publications.count) publications")
        } catch {
            Logger.search.error("Failed to commit batch index: \(error.localizedDescription)")
        }
    }

    // MARK: - PDF Text Indexing

    /// Index a publication with its PDF content.
    ///
    /// Call this after importing a PDF to include full-text search.
    ///
    /// - Parameters:
    ///   - publication: The publication with the PDF
    ///   - pdfData: Raw PDF file data
    public func indexPublicationWithPDF(
        _ publication: CDPublication,
        pdfData: Data
    ) async {
        guard let index = searchIndex else { return }

        // Extract PDF text using Rust/pdfium
        let pdfText: String?
        if RustPDFService.isAvailable {
            do {
                let result = try RustPDFService.extractText(from: pdfData)
                pdfText = result.fullText
                Logger.search.info("Extracted \(result.pageCount) pages of text for indexing")
            } catch {
                Logger.search.warning("Failed to extract PDF text: \(error.localizedDescription)")
                pdfText = nil
            }
        } else {
            pdfText = nil
        }

        await indexPublication(publication, using: index, fullText: pdfText)

        do {
            try await index.commit()
        } catch {
            Logger.search.error("Failed to commit after indexing with PDF: \(error.localizedDescription)")
        }
    }

    /// Index a publication with PDF from its linked file.
    ///
    /// Convenience method that resolves the PDF file and extracts text.
    ///
    /// - Parameters:
    ///   - publication: The publication with linked PDF
    ///   - library: The library containing the publication
    public func indexPublicationWithLinkedPDF(
        _ publication: CDPublication,
        in library: CDLibrary?
    ) async {
        guard RustPDFService.isAvailable else { return }

        // Get linked PDF file and resolve URL on main actor (Core Data thread safety)
        let (pdfURL, citeKey): (URL?, String) = await MainActor.run {
            guard let linkedFiles = publication.linkedFiles,
                  let pdfFile = linkedFiles.first(where: { $0.fileType?.lowercased() == "pdf" }) else {
                return (nil, publication.citeKey)
            }
            let url = AttachmentManager.shared.resolveURL(for: pdfFile, in: library)
            return (url, publication.citeKey)
        }

        guard let url = pdfURL else { return }

        // Read PDF data (can be done off main actor)
        let pdfData: Data?
        do {
            pdfData = try Data(contentsOf: url)
        } catch {
            Logger.search.warning("Could not read PDF for indexing: \(citeKey)")
            return
        }

        guard let data = pdfData else {
            return
        }

        await indexPublicationWithPDF(publication, pdfData: data)
    }

    // MARK: - Private Methods

    private func indexPublication(_ publication: CDPublication, using index: RustSearchIndex, fullText: String? = nil) async {
        // Extract data on main actor since CDPublication isn't thread-safe
        let input = await MainActor.run {
            SearchIndexInput(
                id: publication.id.uuidString,
                citeKey: publication.citeKey,
                title: publication.title ?? "",
                authors: publication.authorString,
                abstractText: publication.fields["abstract"]
            )
        }

        do {
            try await index.add(input, fullText: fullText)
        } catch {
            Logger.search.error("Failed to index publication \(input.citeKey): \(error.localizedDescription)")
        }
    }
}

// MARK: - Search Result

/// A full-text search result with relevance score.
public struct FullTextSearchResult: Sendable, Identifiable {
    public let id: UUID
    public let publicationId: UUID
    public let citeKey: String
    public let title: String
    public let score: Float
    public let snippet: String?

    public init(
        publicationId: UUID,
        citeKey: String,
        title: String,
        score: Float,
        snippet: String?
    ) {
        self.id = publicationId
        self.publicationId = publicationId
        self.citeKey = citeKey
        self.title = title
        self.score = score
        self.snippet = snippet
    }
}

