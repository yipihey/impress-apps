//
//  LibraryViewModel.swift
//  PublicationManagerCore
//
//  View model for the main library view, backed by RustStoreAdapter.
//

import Foundation
import OSLog
import SwiftUI

// MARK: - Library View Model

/// View model for the main library view.
@MainActor
@Observable
public final class LibraryViewModel {

    // MARK: - Published State

    /// Publication row data for list display
    public private(set) var publicationRows: [PublicationRowData] = []

    /// Fast lookup by ID
    public private(set) var publicationsByID: [UUID: PublicationRowData] = [:]

    /// LocalPaper wrappers for unified view layer
    public private(set) var papers: [LocalPaper] = []

    public private(set) var isLoading = false
    public private(set) var error: Error?

    public var searchQuery = "" {
        didSet { performSearch() }
    }

    public var sortOrder: LibrarySortOrder = .dateAdded {
        didSet { Task { await loadPublications() } }
    }

    public var sortAscending = false {
        didSet { Task { await loadPublications() } }
    }

    public var selectedPublications: Set<UUID> = []

    // MARK: - Library Identity

    /// Unique identifier for this library
    public let libraryID: UUID

    // MARK: - Backward Compatibility

    /// Publications array — returns row data for iteration.
    /// Prefer `publicationRows` for new code.
    public var publications: [PublicationRowData] { publicationRows }

    // MARK: - Dependencies

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    // MARK: - Initialization

    public init(libraryID: UUID = UUID()) {
        self.libraryID = libraryID
    }

    /// Legacy initializer — ignores repository parameter.
    public convenience init(repository: Any, libraryID: UUID = UUID()) {
        self.init(libraryID: libraryID)
    }

    /// Default init for environment injection
    public convenience init() {
        self.init(libraryID: UUID())
    }

    // MARK: - Loading

    public func loadPublications() async {
        isLoading = true
        error = nil

        let sortKey = sortOrder.sortKey
        publicationRows = store.queryPublications(
            parentId: libraryID,
            sort: sortKey,
            ascending: sortAscending,
            limit: nil,
            offset: nil
        )

        publicationsByID = Dictionary(publicationRows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })

        // Build LocalPaper wrappers from row data
        papers = publicationRows.compactMap { row in
            guard let model = store.getPublicationDetail(id: row.id) else { return nil }
            return LocalPaper(from: model)
        }

        Logger.viewModels.infoCapture("Loaded \(self.publicationRows.count) publications", category: "library")

        isLoading = false
    }

    // MARK: - Lookup

    /// Fast O(1) lookup of publication row by ID.
    public func publication(for id: UUID) -> PublicationRowData? {
        if let row = publicationsByID[id] {
            return row
        }
        return store.getPublication(id: id)
    }

    /// Get full publication detail by ID.
    public func publicationDetail(for id: UUID) -> PublicationModel? {
        store.getPublicationDetail(id: id)
    }

    // MARK: - Search

    private func performSearch() {
        Task {
            if searchQuery.isEmpty {
                await loadPublications()
            } else {
                isLoading = true
                publicationRows = store.searchPublications(query: searchQuery, parentId: libraryID)
                publicationsByID = Dictionary(publicationRows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                isLoading = false
            }
        }
    }

    // MARK: - Import

    /// Import a bibliography file (BibTeX or RIS) based on file extension.
    public func importFile(from url: URL) async throws -> Int {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "bib", "bibtex":
            return try await importBibTeX(from: url)
        case "ris":
            return try await importRIS(from: url)
        default:
            throw ImportError.unsupportedFormat(ext)
        }
    }

    public func importBibTeX(from url: URL) async throws -> Int {
        Logger.viewModels.infoCapture("Importing BibTeX from \(url.lastPathComponent)", category: "import")

        let content = try String(contentsOf: url, encoding: .utf8)
        let ids = store.importBibTeX(content, libraryId: libraryID)
        await loadPublications()

        // Queue newly imported for enrichment
        await queueNewlyImportedForEnrichment(ids: ids)

        Logger.viewModels.infoCapture("Successfully imported \(ids.count) entries", category: "import")
        return ids.count
    }

    public func importRIS(from url: URL) async throws -> Int {
        Logger.viewModels.infoCapture("Importing RIS from \(url.lastPathComponent)", category: "import")

        let content = try String(contentsOf: url, encoding: .utf8)
        let parser = RISParserFactory.createParser()
        let entries = try parser.parse(content)

        var importedCount = 0
        for risEntry in entries {
            let bibEntry = risEntry.toBibTeX()
            let bibtex = bibEntry.rawBibTeX ?? bibEntry.synthesizeBibTeX()
            let ids = store.importBibTeX(bibtex, libraryId: libraryID)
            importedCount += ids.count
        }

        await loadPublications()

        Logger.viewModels.infoCapture("Successfully imported \(importedCount) RIS entries", category: "import")
        return importedCount
    }

    public func importEntry(_ entry: BibTeXEntry) async {
        Logger.viewModels.infoCapture("Importing entry: \(entry.citeKey)", category: "import")

        let bibtex = entry.rawBibTeX ?? entry.synthesizeBibTeX()
        _ = store.importBibTeX(bibtex, libraryId: libraryID)
        await loadPublications()
    }

    /// Import a BibTeX entry directly. Returns the UUID of the imported publication.
    @discardableResult
    public func importBibTeXEntry(_ entry: BibTeXEntry) async -> UUID? {
        Logger.viewModels.infoCapture("Importing BibTeX entry: \(entry.citeKey)", category: "import")

        let bibtex = entry.rawBibTeX ?? entry.synthesizeBibTeX()
        let ids = store.importBibTeX(bibtex, libraryId: libraryID)
        await loadPublications()
        await DefaultLibraryLookupService.shared.invalidateCache()

        return ids.first
    }

    /// Import a paper from the citation explorer.
    @discardableResult
    public func importFromPaperStub(_ stub: PaperStub, toLibraryId: UUID) async throws -> UUID? {
        Logger.viewModels.infoCapture("Importing paper stub: \(stub.title)", category: "import")

        let bibcode = stub.id
        let adsSource = ADSSource()
        let entry = try await adsSource.fetchBibTeX(bibcode: bibcode)

        let bibtex = entry.rawBibTeX ?? entry.synthesizeBibTeX()
        let ids = store.importBibTeX(bibtex, libraryId: toLibraryId)
        await loadPublications()
        await DefaultLibraryLookupService.shared.invalidateCache()

        if let id = ids.first {
            Logger.viewModels.info("Imported: \(entry.citeKey)")
            return id
        }
        return nil
    }

    // MARK: - Delete

    public func deleteSelected() async {
        let toDelete = Array(selectedPublications)
        guard !toDelete.isEmpty else { return }

        Logger.viewModels.infoCapture("Deleting \(toDelete.count) publications", category: "library")
        store.deletePublications(ids: toDelete)
        selectedPublications.removeAll()
        await loadPublications()
    }

    public func delete(id: UUID) async {
        Logger.viewModels.infoCapture("Deleting: \(id)", category: "library")
        store.deletePublications(ids: [id])
        selectedPublications.remove(id)
        await loadPublications()
    }

    public func delete(ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        Logger.viewModels.infoCapture("Deleting \(ids.count) publications by ID", category: "library")

        for id in ids {
            selectedPublications.remove(id)
        }

        publicationRows.removeAll { ids.contains($0.id) }

        // Brief delay to let SwiftUI process state change
        try? await Task.sleep(for: .milliseconds(50))

        store.deletePublications(ids: Array(ids))
        await loadPublications()
    }

    // MARK: - Update

    public func updateField(id: UUID, field: String, value: String?) async {
        store.updateField(id: id, field: field, value: value)
    }

    /// Update a publication from an edited BibTeX entry.
    public func updateFromBibTeX(id: UUID, entry: BibTeXEntry) async {
        Logger.viewModels.infoCapture("Updating publication from BibTeX: \(entry.citeKey)", category: "update")

        // Re-import the entry (Rust store handles upsert by cite key)
        let bibtex = entry.rawBibTeX ?? entry.synthesizeBibTeX()
        _ = store.importBibTeX(bibtex, libraryId: libraryID)
        await loadPublications()
    }

    // MARK: - Export

    public func exportAll() -> String {
        store.exportAllBibTeX(libraryId: libraryID)
    }

    public func exportSelected() -> String {
        let ids = Array(selectedPublications)
        guard !ids.isEmpty else { return "" }
        return store.exportBibTeX(ids: ids)
    }

    // MARK: - Selection

    public func selectAll() {
        selectedPublications = Set(publicationRows.map(\.id))
    }

    public func clearSelection() {
        selectedPublications.removeAll()
    }

    public func toggleSelection(id: UUID) {
        if selectedPublications.contains(id) {
            selectedPublications.remove(id)
        } else {
            selectedPublications.insert(id)
        }
    }

    // MARK: - Read Status

    public func markAsRead(id: UUID) async {
        store.setRead(ids: [id], read: true)
        NotificationCenter.default.post(name: Notification.Name("readStatusDidChange"), object: id)
        // Phase 8: SignalCollector still uses CDPublication — will be migrated
        // Task { await SignalCollector.shared.recordRead(publicationId: id) }
    }

    /// Convenience for callers that have PublicationRowData
    public func markAsRead(_ row: PublicationRowData) async {
        await markAsRead(id: row.id)
    }

    public func markAsUnread(id: UUID) async {
        store.setRead(ids: [id], read: false)
        NotificationCenter.default.post(name: Notification.Name("readStatusDidChange"), object: id)
    }

    public func toggleReadStatus(id: UUID) async {
        let row = store.getPublication(id: id)
        let isCurrentlyRead = row?.isRead ?? false
        store.setRead(ids: [id], read: !isCurrentlyRead)
        NotificationCenter.default.post(name: Notification.Name("readStatusDidChange"), object: id)
    }

    public func markSelectedAsRead() async {
        let ids = Array(selectedPublications)
        store.setRead(ids: ids, read: true)
        await loadPublications()
    }

    /// Smart toggle for multiple publications.
    public func smartToggleReadStatus(_ publicationIDs: Set<UUID>) async {
        let selected = publicationRows.filter { publicationIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        let allRead = selected.allSatisfy { $0.isRead }

        if allRead {
            store.setRead(ids: selected.map(\.id), read: false)
        } else {
            store.setRead(ids: selected.map(\.id), read: true)
        }

        for row in selected {
            NotificationCenter.default.post(name: Notification.Name("readStatusDidChange"), object: row.id)
        }
    }

    public func unreadCount() -> Int {
        store.countUnread(parentId: libraryID)
    }

    // MARK: - Clipboard

    public func copySelectedToClipboard() {
        let ids = Array(selectedPublications)
        guard !ids.isEmpty else { return }

        let bibtex = store.exportBibTeX(ids: ids)
        Clipboard.shared.setString(bibtex)
        Logger.viewModels.infoCapture("Copied \(ids.count) publications to clipboard", category: "clipboard")
    }

    public func copyToClipboard(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let bibtex = store.exportBibTeX(ids: Array(ids))
        Clipboard.shared.setString(bibtex)
        Logger.viewModels.infoCapture("Copied \(ids.count) publications to clipboard", category: "clipboard")
    }

    public func cutSelectedToClipboard() async {
        copySelectedToClipboard()
        await deleteSelected()
        Logger.viewModels.infoCapture("Cut publications to clipboard", category: "clipboard")
    }

    public func cutToClipboard(_ ids: Set<UUID>) async {
        copyToClipboard(ids)
        await delete(ids: ids)
        Logger.viewModels.infoCapture("Cut publications to clipboard", category: "clipboard")
    }

    @discardableResult
    public func pasteFromClipboard() async throws -> Int {
        guard let bibtex = Clipboard.shared.getString() else {
            throw ImportError.noBibTeXEntry
        }

        let parser = BibTeXParserFactory.createParser()
        let entries = try parser.parseEntries(bibtex)
        guard !entries.isEmpty else {
            throw ImportError.noBibTeXEntry
        }

        var totalImported = 0
        for entry in entries {
            let bibtexStr = entry.rawBibTeX ?? entry.synthesizeBibTeX()
            let ids = store.importBibTeX(bibtexStr, libraryId: libraryID)
            totalImported += ids.count
        }

        await loadPublications()
        Logger.viewModels.infoCapture("Pasted \(totalImported) publications from clipboard", category: "clipboard")
        return totalImported
    }

    // MARK: - Library and Collection Operations

    public func addToLibrary(_ ids: Set<UUID>, libraryId: UUID) {
        guard !ids.isEmpty else { return }
        store.movePublications(ids: Array(ids), toLibraryId: libraryId)
        Logger.viewModels.infoCapture("Added \(ids.count) publications to library", category: "library")
        NotificationCenter.default.post(name: .libraryContentDidChange, object: libraryId)
    }

    public func addToCollection(_ ids: Set<UUID>, collectionId: UUID) {
        guard !ids.isEmpty else { return }
        store.addToCollection(publicationIds: Array(ids), collectionId: collectionId)
        Logger.viewModels.infoCapture("Added \(ids.count) publications to collection", category: "library")
        NotificationCenter.default.post(name: .libraryContentDidChange, object: collectionId)
    }

    public func removeFromCollection(_ ids: Set<UUID>, collectionId: UUID) {
        guard !ids.isEmpty else { return }
        store.removeFromCollection(publicationIds: Array(ids), collectionId: collectionId)
        Logger.viewModels.infoCapture("Removed \(ids.count) publications from collection", category: "library")
    }

    // MARK: - Enrichment

    private func queueNewlyImportedForEnrichment(ids: [UUID] = []) async {
        let idsToEnrich: [UUID]
        if ids.isEmpty {
            idsToEnrich = publicationRows.compactMap { row in
                // Check if the publication needs enrichment
                guard let detail = store.getPublicationDetail(id: row.id) else { return nil }
                let hasIdentifiers = detail.doi != nil || detail.arxivID != nil
                let needsEnrichment = detail.citationCount == nil
                return (hasIdentifiers && needsEnrichment) ? row.id : nil
            }
        } else {
            idsToEnrich = ids
        }

        guard !idsToEnrich.isEmpty else { return }

        Logger.viewModels.infoCapture("Queueing \(idsToEnrich.count) papers for enrichment", category: "enrichment")
        // Phase 8: EnrichmentCoordinator still uses CDPublication — will be migrated
        // await EnrichmentCoordinator.shared.queueForEnrichment(ids: idsToEnrich, priority: .libraryPaper)
    }
}

// MARK: - Library Sort Order

public enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case dateAdded
    case dateModified
    case title
    case year
    case citeKey
    case citationCount
    case starred
    case recommended

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .title: return "Title"
        case .year: return "Year"
        case .citeKey: return "Cite Key"
        case .citationCount: return "Citation Count"
        case .starred: return "Starred First"
        case .recommended: return "Recommended"
        }
    }

    var sortKey: String {
        switch self {
        case .dateAdded: return "created"
        case .dateModified: return "modified"
        case .title: return "title"
        case .year: return "year"
        case .citeKey: return "cite_key"
        case .citationCount: return "citation_count"
        case .starred: return "starred"
        case .recommended: return "created"
        }
    }

    public var defaultAscending: Bool {
        switch self {
        case .dateAdded, .dateModified, .year, .citationCount, .starred, .recommended:
            return false
        case .title, .citeKey:
            return true
        }
    }

    public var usesRecommendation: Bool {
        self == .recommended
    }
}

// MARK: - Import Error

public enum ImportError: LocalizedError, Sendable {
    case noBibTeXEntry
    case fileNotFound(URL)
    case invalidBibTeX(String)
    case unsupportedFormat(String)
    case parseError(String)
    case cancelled
    case noLibrarySelected

    public var errorDescription: String? {
        switch self {
        case .noBibTeXEntry:
            return "No BibTeX entry found in the fetched data"
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .invalidBibTeX(let reason):
            return "Invalid BibTeX: \(reason)"
        case .unsupportedFormat(let ext):
            return "Unsupported file format: .\(ext)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .cancelled:
            return "Import cancelled"
        case .noLibrarySelected:
            return "No library selected for import"
        }
    }
}
