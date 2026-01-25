//
//  AutomationOperations.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//
//  Protocol defining all automation operations (ADR-018).
//  This protocol returns rich data types, unlike URLSchemeHandler which posts notifications.
//

import Foundation

// MARK: - Automation Operations Protocol

/// Protocol defining all automation operations for AI assistants and external tools.
///
/// This protocol provides rich data return types suitable for:
/// - MCP server (Claude Desktop, Cursor, Zed)
/// - Enhanced AppIntents with EntityQuery
/// - REST API
/// - CLI tools
///
/// Unlike URLSchemeHandler which posts notifications for UI updates,
/// implementations of this protocol return actual data for programmatic consumption.
public protocol AutomationOperations: Actor {

    // MARK: - Library Search

    /// Search the local library for papers matching a query.
    ///
    /// - Parameters:
    ///   - query: Search query (searches title, authors, abstract, cite key)
    ///   - filters: Optional filters to narrow results
    /// - Returns: Array of matching papers
    func searchLibrary(query: String, filters: SearchFilters?) async throws -> [PaperResult]

    /// Search external sources (ADS, arXiv, etc.) for papers.
    ///
    /// - Parameters:
    ///   - sources: Source IDs to search (nil = all available)
    ///   - query: Search query
    ///   - maxResults: Maximum results per source
    /// - Returns: Search operation result with papers and metadata
    func searchExternal(sources: [String]?, query: String, maxResults: Int?) async throws -> SearchOperationResult

    // MARK: - Paper Operations

    /// Get a single paper by identifier.
    ///
    /// - Parameter identifier: Paper identifier (cite key, DOI, arXiv, etc.)
    /// - Returns: Paper details or nil if not found
    func getPaper(identifier: PaperIdentifier) async throws -> PaperResult?

    /// Get multiple papers by identifiers.
    ///
    /// - Parameter identifiers: Paper identifiers to look up
    /// - Returns: Array of found papers (missing papers are omitted)
    func getPapers(identifiers: [PaperIdentifier]) async throws -> [PaperResult]

    /// Add papers to the library from external identifiers.
    ///
    /// This fetches metadata from external sources and imports papers.
    ///
    /// - Parameters:
    ///   - identifiers: Paper identifiers (DOI, arXiv, bibcode, etc.)
    ///   - collection: Optional collection to add papers to
    ///   - library: Optional library to add papers to
    ///   - downloadPDFs: Whether to download PDFs automatically
    /// - Returns: Result with added papers, duplicates, and failures
    func addPapers(
        identifiers: [PaperIdentifier],
        collection: UUID?,
        library: UUID?,
        downloadPDFs: Bool
    ) async throws -> AddPapersResult

    /// Delete papers from the library.
    ///
    /// - Parameter identifiers: Paper identifiers to delete
    /// - Returns: Number of papers actually deleted
    func deletePapers(identifiers: [PaperIdentifier]) async throws -> Int

    /// Mark papers as read.
    ///
    /// - Parameter identifiers: Paper identifiers to mark
    /// - Returns: Number of papers updated
    func markAsRead(identifiers: [PaperIdentifier]) async throws -> Int

    /// Mark papers as unread.
    ///
    /// - Parameter identifiers: Paper identifiers to mark
    /// - Returns: Number of papers updated
    func markAsUnread(identifiers: [PaperIdentifier]) async throws -> Int

    /// Toggle read status for papers.
    ///
    /// - Parameter identifiers: Paper identifiers to toggle
    /// - Returns: Number of papers updated
    func toggleReadStatus(identifiers: [PaperIdentifier]) async throws -> Int

    /// Toggle star status for papers.
    ///
    /// - Parameter identifiers: Paper identifiers to toggle
    /// - Returns: Number of papers updated
    func toggleStar(identifiers: [PaperIdentifier]) async throws -> Int

    // MARK: - Collection Operations

    /// List all collections, optionally filtered by library.
    ///
    /// - Parameter libraryID: Optional library to filter by
    /// - Returns: Array of collections
    func listCollections(libraryID: UUID?) async throws -> [CollectionResult]

    /// Create a new collection.
    ///
    /// - Parameters:
    ///   - name: Collection name
    ///   - libraryID: Library to create collection in (nil = default library)
    ///   - isSmartCollection: Whether this is a smart collection
    ///   - predicate: Predicate string for smart collections
    /// - Returns: The created collection
    func createCollection(
        name: String,
        libraryID: UUID?,
        isSmartCollection: Bool,
        predicate: String?
    ) async throws -> CollectionResult

    /// Delete a collection.
    ///
    /// - Parameter collectionID: Collection to delete
    /// - Returns: True if deleted, false if not found
    func deleteCollection(collectionID: UUID) async throws -> Bool

    /// Add papers to a collection.
    ///
    /// - Parameters:
    ///   - papers: Paper identifiers to add
    ///   - collectionID: Collection to add to
    /// - Returns: Number of papers added
    func addToCollection(papers: [PaperIdentifier], collectionID: UUID) async throws -> Int

    /// Remove papers from a collection.
    ///
    /// - Parameters:
    ///   - papers: Paper identifiers to remove
    ///   - collectionID: Collection to remove from
    /// - Returns: Number of papers removed
    func removeFromCollection(papers: [PaperIdentifier], collectionID: UUID) async throws -> Int

    // MARK: - Library Operations

    /// List all libraries.
    ///
    /// - Returns: Array of libraries
    func listLibraries() async throws -> [LibraryResult]

    /// Get the default library.
    ///
    /// - Returns: Default library or nil if none set
    func getDefaultLibrary() async throws -> LibraryResult?

    /// Get the Inbox library.
    ///
    /// - Returns: Inbox library or nil if none exists
    func getInboxLibrary() async throws -> LibraryResult?

    // MARK: - Export Operations

    /// Export papers to BibTeX format.
    ///
    /// - Parameter identifiers: Paper identifiers to export (nil = all papers)
    /// - Returns: Export result with BibTeX content
    func exportBibTeX(identifiers: [PaperIdentifier]?) async throws -> ExportResult

    /// Export papers to RIS format.
    ///
    /// - Parameter identifiers: Paper identifiers to export (nil = all papers)
    /// - Returns: Export result with RIS content
    func exportRIS(identifiers: [PaperIdentifier]?) async throws -> ExportResult

    // MARK: - PDF Operations

    /// Download PDFs for papers.
    ///
    /// - Parameter identifiers: Paper identifiers to download PDFs for
    /// - Returns: Download result with success/failure details
    func downloadPDFs(identifiers: [PaperIdentifier]) async throws -> DownloadResult

    /// Check which papers have PDFs available.
    ///
    /// - Parameter identifiers: Paper identifiers to check
    /// - Returns: Dictionary mapping identifier to has-PDF status
    func checkPDFStatus(identifiers: [PaperIdentifier]) async throws -> [String: Bool]

    // MARK: - Source Operations

    /// List available external sources.
    ///
    /// - Returns: Array of source IDs and names
    func listSources() async throws -> [(id: String, name: String, hasCredentials: Bool)]
}

// MARK: - Default Implementations

public extension AutomationOperations {

    /// Search with default filters.
    func searchLibrary(query: String) async throws -> [PaperResult] {
        try await searchLibrary(query: query, filters: nil)
    }

    /// Search all external sources.
    func searchExternal(query: String, maxResults: Int = 50) async throws -> SearchOperationResult {
        try await searchExternal(sources: nil, query: query, maxResults: maxResults)
    }

    /// Add papers without specifying collection or library.
    func addPapers(identifiers: [PaperIdentifier], downloadPDFs: Bool = true) async throws -> AddPapersResult {
        try await addPapers(identifiers: identifiers, collection: nil, library: nil, downloadPDFs: downloadPDFs)
    }

    /// Create a static collection in the default library.
    func createCollection(name: String) async throws -> CollectionResult {
        try await createCollection(name: name, libraryID: nil, isSmartCollection: false, predicate: nil)
    }

    /// Export all papers to BibTeX.
    func exportBibTeX() async throws -> ExportResult {
        try await exportBibTeX(identifiers: nil)
    }

    /// Export all papers to RIS.
    func exportRIS() async throws -> ExportResult {
        try await exportRIS(identifiers: nil)
    }
}
