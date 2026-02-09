//
//  RustStoreAdapter.swift
//  PublicationManagerCore
//
//  Wraps ImbibStore (Rust UniFFI) for Swift consumption.
//  Single source of truth for all data operations — replaces
//  PublicationRepository + PersistenceController + all Core Data services.
//

import Foundation
import ImbibRustCore
import ImpressFTUI
import OSLog

// MARK: - Rust Store Adapter

/// Wraps the Rust ImbibStore (UniFFI) for Swift consumption.
///
/// All views and services read/write through this adapter.
/// Mutations bump `dataVersion` so `@Observable` views update automatically.
@MainActor
@Observable
public final class RustStoreAdapter {

    /// Shared singleton instance.
    public static let shared: RustStoreAdapter = {
        do {
            return try RustStoreAdapter()
        } catch {
            fatalError("Failed to initialize RustStoreAdapter: \(error)")
        }
    }()

    /// The underlying Rust store.
    private let store: ImbibStore

    /// Whether the Rust store is enabled (feature flag for gradual rollout).
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "useRustStore")
    }

    /// Bumped on every mutation. Views observe this to trigger updates.
    public private(set) var dataVersion: Int = 0

    // MARK: - Initialization

    private init() throws {
        let dbPath = Self.databasePath()
        self.store = try ImbibStore.open(path: dbPath)
        Logger.library.infoCapture("RustStoreAdapter initialized at \(dbPath)", category: "rust-store")
    }

    /// For testing with in-memory store.
    init(inMemory: Bool) throws {
        if inMemory {
            self.store = try ImbibStore.openInMemory()
        } else {
            let dbPath = Self.databasePath()
            self.store = try ImbibStore.open(path: dbPath)
        }
    }

    private static func databasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("com.impress.imbib", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("imbib.sqlite").path
    }

    private func didMutate() {
        dataVersion += 1
    }

    // MARK: - Publication Queries

    /// Query publications in a library, sorted and paginated.
    public func queryPublications(
        parentId: UUID,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        do {
            let rows = try store.queryPublications(
                parentId: parentId.uuidString,
                sortField: sort,
                ascending: ascending,
                limit: limit,
                offset: offset
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("queryPublications failed: \(error)")
            return []
        }
    }

    /// Query recent publications.
    public func queryRecent(limit: UInt32 = 50, parentId: UUID? = nil) -> [PublicationRowData] {
        do {
            let rows = try store.queryRecent(limit: limit, parentId: parentId?.uuidString)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("queryRecent failed: \(error)")
            return []
        }
    }

    /// Query starred publications.
    public func queryStarred(parentId: UUID? = nil) -> [PublicationRowData] {
        do {
            let rows = try store.queryStarred(parentId: parentId?.uuidString)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("queryStarred failed: \(error)")
            return []
        }
    }

    /// Query unread publications.
    public func queryUnread(parentId: UUID? = nil) -> [PublicationRowData] {
        do {
            let rows = try store.queryUnread(parentId: parentId?.uuidString)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("queryUnread failed: \(error)")
            return []
        }
    }

    /// Query publications by tag.
    public func queryByTag(tagPath: String, parentId: UUID? = nil) -> [PublicationRowData] {
        do {
            let rows = try store.queryByTag(tagPath: tagPath, parentId: parentId?.uuidString)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("queryByTag failed: \(error)")
            return []
        }
    }

    /// Search publications by text query (searches title, authors, abstract, note).
    public func searchPublications(query: String, parentId: UUID? = nil) -> [PublicationRowData] {
        do {
            let rows = try store.searchPublications(
                query: query,
                parentId: parentId?.uuidString
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("searchPublications failed: \(error)")
            return []
        }
    }

    /// Full-text search (FTS5 in SQLite).
    public func fullTextSearch(query: String, parentId: UUID? = nil, limit: UInt32? = nil) -> [PublicationRowData] {
        do {
            let rows = try store.fullTextSearch(query: query, parentId: parentId?.uuidString, limit: limit)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("fullTextSearch failed: \(error)")
            return []
        }
    }

    /// Get a single publication as row data.
    public func getPublication(id: UUID) -> PublicationRowData? {
        do {
            guard let row = try store.getPublication(id: id.uuidString) else { return nil }
            return PublicationRowData(from: row)
        } catch {
            Logger.library.error("getPublication failed: \(error)")
            return nil
        }
    }

    /// Get full publication detail for detail views.
    public func getPublicationDetail(id: UUID) -> PublicationModel? {
        do {
            guard let detail = try store.getPublicationDetail(id: id.uuidString) else { return nil }
            return PublicationModel(from: detail)
        } catch {
            Logger.library.error("getPublicationDetail failed: \(error)")
            return nil
        }
    }

    /// Get flagged publications.
    public func getFlaggedPublications(color: String? = nil) -> [PublicationRowData] {
        do {
            let rows = try store.getFlaggedPublications(color: color)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("getFlaggedPublications failed: \(error)")
            return []
        }
    }

    /// List collection members.
    public func listCollectionMembers(
        collectionId: UUID,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        do {
            let rows = try store.listCollectionMembers(
                collectionId: collectionId.uuidString,
                sortField: sort,
                ascending: ascending,
                limit: limit,
                offset: offset
            )
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("listCollectionMembers failed: \(error)")
            return []
        }
    }

    // MARK: - Deduplication Queries

    /// Find publications by DOI.
    public func findByDoi(doi: String) -> [PublicationRowData] {
        do {
            let rows = try store.findByDoi(doi: doi)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("findByDoi failed: \(error)")
            return []
        }
    }

    /// Find publications by arXiv ID.
    public func findByArxiv(arxivId: String) -> [PublicationRowData] {
        do {
            let rows = try store.findByArxiv(arxivId: arxivId)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("findByArxiv failed: \(error)")
            return []
        }
    }

    /// Find publications by bibcode.
    public func findByBibcode(bibcode: String) -> [PublicationRowData] {
        do {
            let rows = try store.findByBibcode(bibcode: bibcode)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("findByBibcode failed: \(error)")
            return []
        }
    }

    /// Find publications by any combination of identifiers.
    public func findByIdentifiers(doi: String? = nil, arxivId: String? = nil, bibcode: String? = nil, pmid: String? = nil) -> [PublicationRowData] {
        do {
            let rows = try store.findByIdentifiers(doi: doi, arxivId: arxivId, bibcode: bibcode, pmid: pmid)
            return rows.compactMap { PublicationRowData(from: $0) }
        } catch {
            Logger.library.error("findByIdentifiers failed: \(error)")
            return []
        }
    }

    /// Find publication by cite key.
    public func findByCiteKey(citeKey: String, libraryId: UUID? = nil) -> PublicationRowData? {
        do {
            guard let row = try store.findByCiteKey(citeKey: citeKey, libraryId: libraryId?.uuidString) else { return nil }
            return PublicationRowData(from: row)
        } catch {
            Logger.library.error("findByCiteKey failed: \(error)")
            return nil
        }
    }

    // MARK: - Publication Mutations

    /// Import BibTeX into a library.
    public func importBibTeX(_ bibtex: String, libraryId: UUID) -> [UUID] {
        do {
            let ids = try store.importBibtex(bibtex: bibtex, libraryId: libraryId.uuidString)
            didMutate()
            return ids.compactMap { UUID(uuidString: $0) }
        } catch {
            Logger.library.error("importBibTeX failed: \(error)")
            return []
        }
    }

    /// Import from a BibTeX file on disk.
    public func importFromBibTeXFile(path: String, libraryId: UUID) -> UInt32 {
        do {
            let count = try store.importFromBibtexFile(path: path, libraryId: libraryId.uuidString)
            didMutate()
            return count
        } catch {
            Logger.library.error("importFromBibTeXFile failed: \(error)")
            return 0
        }
    }

    /// Set read state for publications.
    public func setRead(ids: [UUID], read: Bool) {
        do {
            try store.setRead(ids: ids.map(\.uuidString), read: read)
            didMutate()
        } catch {
            Logger.library.error("setRead failed: \(error)")
        }
    }

    /// Set starred state for publications.
    public func setStarred(ids: [UUID], starred: Bool) {
        do {
            try store.setStarred(ids: ids.map(\.uuidString), starred: starred)
            didMutate()
        } catch {
            Logger.library.error("setStarred failed: \(error)")
        }
    }

    /// Set flag on publications.
    public func setFlag(ids: [UUID], color: String?, style: String? = nil, length: String? = nil) {
        do {
            try store.setFlag(ids: ids.map(\.uuidString), color: color, style: style, length: length)
            didMutate()
        } catch {
            Logger.library.error("setFlag failed: \(error)")
        }
    }

    /// Update a single string field on a publication.
    public func updateField(id: UUID, field: String, value: String?) {
        do {
            try store.updateField(id: id.uuidString, field: field, value: value)
            didMutate()
        } catch {
            Logger.library.error("updateField failed: \(error)")
        }
    }

    /// Update a boolean field on any item.
    public func updateBoolField(id: UUID, field: String, value: Bool) {
        do {
            try store.updateBoolField(id: id.uuidString, field: field, value: value)
            didMutate()
        } catch {
            Logger.library.error("updateBoolField failed: \(error)")
        }
    }

    /// Update an integer field on any item.
    public func updateIntField(id: UUID, field: String, value: Int64?) {
        do {
            try store.updateIntField(id: id.uuidString, field: field, value: value)
            didMutate()
        } catch {
            Logger.library.error("updateIntField failed: \(error)")
        }
    }

    /// Delete publications.
    public func deletePublications(ids: [UUID]) {
        do {
            try store.deletePublications(ids: ids.map(\.uuidString))
            didMutate()
        } catch {
            Logger.library.error("deletePublications failed: \(error)")
        }
    }

    /// Delete any item by ID.
    public func deleteItem(id: UUID) {
        do {
            try store.deleteItem(id: id.uuidString)
            didMutate()
        } catch {
            Logger.library.error("deleteItem failed: \(error)")
        }
    }

    /// Move publications between libraries.
    public func movePublications(ids: [UUID], toLibraryId: UUID) {
        do {
            try store.movePublications(ids: ids.map(\.uuidString), toLibraryId: toLibraryId.uuidString)
            didMutate()
        } catch {
            Logger.library.error("movePublications failed: \(error)")
        }
    }

    /// Duplicate publications to another library.
    public func duplicatePublications(ids: [UUID], toLibraryId: UUID) -> [UUID] {
        do {
            let newIds = try store.duplicatePublications(ids: ids.map(\.uuidString), toLibraryId: toLibraryId.uuidString)
            didMutate()
            return newIds.compactMap { UUID(uuidString: $0) }
        } catch {
            Logger.library.error("duplicatePublications failed: \(error)")
            return []
        }
    }

    // MARK: - Library Operations

    /// List all libraries.
    public func listLibraries() -> [LibraryModel] {
        do {
            return try store.listLibraries().map { LibraryModel(from: $0) }
        } catch {
            Logger.library.error("listLibraries failed: \(error)")
            return []
        }
    }

    /// Get a single library.
    public func getLibrary(id: UUID) -> LibraryModel? {
        do {
            guard let row = try store.getLibrary(id: id.uuidString) else { return nil }
            return LibraryModel(from: row)
        } catch {
            Logger.library.error("getLibrary failed: \(error)")
            return nil
        }
    }

    /// Get the default library.
    public func getDefaultLibrary() -> LibraryModel? {
        do {
            guard let row = try store.getDefaultLibrary() else { return nil }
            return LibraryModel(from: row)
        } catch {
            Logger.library.error("getDefaultLibrary failed: \(error)")
            return nil
        }
    }

    /// Get the inbox library.
    public func getInboxLibrary() -> LibraryModel? {
        do {
            guard let row = try store.getInboxLibrary() else { return nil }
            return LibraryModel(from: row)
        } catch {
            Logger.library.error("getInboxLibrary failed: \(error)")
            return nil
        }
    }

    /// Create a new library.
    public func createLibrary(name: String) -> LibraryModel? {
        do {
            let row = try store.createLibrary(name: name)
            didMutate()
            return LibraryModel(from: row)
        } catch {
            Logger.library.error("createLibrary failed: \(error)")
            return nil
        }
    }

    /// Create an inbox library.
    public func createInboxLibrary(name: String) -> LibraryModel? {
        do {
            let row = try store.createInboxLibrary(name: name)
            didMutate()
            return LibraryModel(from: row)
        } catch {
            Logger.library.error("createInboxLibrary failed: \(error)")
            return nil
        }
    }

    /// Set a library as the default.
    public func setLibraryDefault(id: UUID) {
        do {
            try store.setLibraryDefault(id: id.uuidString)
            didMutate()
        } catch {
            Logger.library.error("setLibraryDefault failed: \(error)")
        }
    }

    /// Delete a library.
    public func deleteLibrary(id: UUID) {
        do {
            try store.deleteLibrary(id: id.uuidString)
            didMutate()
        } catch {
            Logger.library.error("deleteLibrary failed: \(error)")
        }
    }

    // MARK: - Collection Operations

    /// List collections in a library.
    public func listCollections(libraryId: UUID) -> [CollectionModel] {
        do {
            return try store.listCollections(libraryId: libraryId.uuidString).map { CollectionModel(from: $0) }
        } catch {
            Logger.library.error("listCollections failed: \(error)")
            return []
        }
    }

    /// Create a collection.
    public func createCollection(name: String, libraryId: UUID, isSmart: Bool = false, query: String? = nil) -> CollectionModel? {
        do {
            let row = try store.createCollection(name: name, libraryId: libraryId.uuidString, isSmart: isSmart, query: query)
            didMutate()
            return CollectionModel(from: row)
        } catch {
            Logger.library.error("createCollection failed: \(error)")
            return nil
        }
    }

    /// Add publications to a collection.
    public func addToCollection(publicationIds: [UUID], collectionId: UUID) {
        do {
            try store.addToCollection(publicationIds: publicationIds.map(\.uuidString), collectionId: collectionId.uuidString)
            didMutate()
        } catch {
            Logger.library.error("addToCollection failed: \(error)")
        }
    }

    /// Remove publications from a collection.
    public func removeFromCollection(publicationIds: [UUID], collectionId: UUID) {
        do {
            try store.removeFromCollection(publicationIds: publicationIds.map(\.uuidString), collectionId: collectionId.uuidString)
            didMutate()
        } catch {
            Logger.library.error("removeFromCollection failed: \(error)")
        }
    }

    // MARK: - Tag Operations

    /// List all tag definitions (for display).
    public func listTags() -> [TagDisplayData] {
        do {
            return try store.listTags().map { tag in
                TagDisplayData(
                    id: UUID(),
                    path: tag.path,
                    leaf: tag.leafName,
                    colorLight: tag.colorLight,
                    colorDark: tag.colorDark
                )
            }
        } catch {
            Logger.library.error("listTags failed: \(error)")
            return []
        }
    }

    /// List tag definitions with publication counts (for settings/management).
    public func listTagsWithCounts() -> [TagDefinition] {
        do {
            return try store.listTagsWithCounts().map { TagDefinition(from: $0) }
        } catch {
            Logger.library.error("listTagsWithCounts failed: \(error)")
            return []
        }
    }

    /// Create a tag definition.
    public func createTag(path: String, colorLight: String? = nil, colorDark: String? = nil) {
        do {
            try store.createTag(path: path, colorLight: colorLight, colorDark: colorDark)
            didMutate()
        } catch {
            Logger.library.error("createTag failed: \(error)")
        }
    }

    /// Add a tag to publications.
    public func addTag(ids: [UUID], tagPath: String) {
        do {
            try store.addTag(ids: ids.map(\.uuidString), tagPath: tagPath)
            didMutate()
        } catch {
            Logger.library.error("addTag failed: \(error)")
        }
    }

    /// Remove a tag from publications.
    public func removeTag(ids: [UUID], tagPath: String) {
        do {
            try store.removeTag(ids: ids.map(\.uuidString), tagPath: tagPath)
            didMutate()
        } catch {
            Logger.library.error("removeTag failed: \(error)")
        }
    }

    /// Rename a tag definition and all assignments.
    public func renameTag(oldPath: String, newPath: String) {
        do {
            try store.renameTag(oldPath: oldPath, newPath: newPath)
            didMutate()
        } catch {
            Logger.library.error("renameTag failed: \(error)")
        }
    }

    /// Delete a tag definition and remove from all publications.
    public func deleteTag(path: String) {
        do {
            try store.deleteTag(path: path)
            didMutate()
        } catch {
            Logger.library.error("deleteTag failed: \(error)")
        }
    }

    /// Update tag definition colors.
    public func updateTag(path: String, colorLight: String?, colorDark: String?) {
        do {
            try store.updateTag(path: path, colorLight: colorLight, colorDark: colorDark)
            didMutate()
        } catch {
            Logger.library.error("updateTag failed: \(error)")
        }
    }

    // MARK: - Linked File Operations

    /// List linked files for a publication.
    public func listLinkedFiles(publicationId: UUID) -> [LinkedFileModel] {
        do {
            return try store.listLinkedFiles(publicationId: publicationId.uuidString).map { LinkedFileModel(from: $0) }
        } catch {
            Logger.library.error("listLinkedFiles failed: \(error)")
            return []
        }
    }

    /// Get a single linked file.
    public func getLinkedFile(id: UUID) -> LinkedFileModel? {
        do {
            guard let row = try store.getLinkedFile(id: id.uuidString) else { return nil }
            return LinkedFileModel(from: row)
        } catch {
            Logger.library.error("getLinkedFile failed: \(error)")
            return nil
        }
    }

    /// Add a linked file to a publication.
    public func addLinkedFile(
        publicationId: UUID,
        filename: String,
        relativePath: String? = nil,
        fileType: String? = nil,
        fileSize: Int64 = 0,
        sha256: String? = nil,
        isPdf: Bool = true
    ) -> LinkedFileModel? {
        do {
            let row = try store.addLinkedFile(
                publicationId: publicationId.uuidString,
                filename: filename,
                relativePath: relativePath,
                fileType: fileType,
                fileSize: fileSize,
                sha256: sha256,
                isPdf: isPdf
            )
            didMutate()
            return LinkedFileModel(from: row)
        } catch {
            Logger.library.error("addLinkedFile failed: \(error)")
            return nil
        }
    }

    /// Set locally materialized status on a linked file.
    public func setLocallyMaterialized(id: UUID, materialized: Bool) {
        do {
            try store.setLocallyMaterialized(id: id.uuidString, materialized: materialized)
            didMutate()
        } catch {
            Logger.library.error("setLocallyMaterialized failed: \(error)")
        }
    }

    /// Set PDF cloud availability on a linked file.
    public func setPdfCloudAvailable(id: UUID, available: Bool) {
        do {
            try store.setPdfCloudAvailable(id: id.uuidString, available: available)
            didMutate()
        } catch {
            Logger.library.error("setPdfCloudAvailable failed: \(error)")
        }
    }

    /// Count PDFs for a publication.
    public func countPdfs(publicationId: UUID) -> Int {
        do {
            return Int(try store.countPdfs(publicationId: publicationId.uuidString))
        } catch {
            Logger.library.error("countPdfs failed: \(error)")
            return 0
        }
    }

    // MARK: - Annotation Operations

    /// List annotations for a linked file.
    public func listAnnotations(linkedFileId: UUID, pageNumber: Int32? = nil) -> [AnnotationModel] {
        do {
            return try store.listAnnotations(linkedFileId: linkedFileId.uuidString, pageNumber: pageNumber).map { AnnotationModel(from: $0) }
        } catch {
            Logger.library.error("listAnnotations failed: \(error)")
            return []
        }
    }

    /// Create an annotation.
    public func createAnnotation(
        linkedFileId: UUID,
        annotationType: String,
        pageNumber: Int64,
        boundsJson: String? = nil,
        color: String? = nil,
        contents: String? = nil,
        selectedText: String? = nil
    ) -> AnnotationModel? {
        do {
            let row = try store.createAnnotation(
                linkedFileId: linkedFileId.uuidString,
                annotationType: annotationType,
                pageNumber: pageNumber,
                boundsJson: boundsJson,
                color: color,
                contents: contents,
                selectedText: selectedText
            )
            didMutate()
            return AnnotationModel(from: row)
        } catch {
            Logger.library.error("createAnnotation failed: \(error)")
            return nil
        }
    }

    /// Count annotations for a linked file.
    public func countAnnotations(linkedFileId: UUID) -> Int {
        do {
            return Int(try store.countAnnotations(linkedFileId: linkedFileId.uuidString))
        } catch {
            Logger.library.error("countAnnotations failed: \(error)")
            return 0
        }
    }

    // MARK: - Comment Operations

    /// List comments for a publication.
    public func listComments(publicationId: UUID) -> [Comment] {
        do {
            return try store.listComments(publicationId: publicationId.uuidString).map { Comment(from: $0) }
        } catch {
            Logger.library.error("listComments failed: \(error)")
            return []
        }
    }

    /// Create a comment.
    public func createComment(
        publicationId: UUID,
        text: String,
        authorIdentifier: String? = nil,
        authorDisplayName: String? = nil,
        parentCommentId: UUID? = nil
    ) -> Comment? {
        do {
            let row = try store.createComment(
                publicationId: publicationId.uuidString,
                text: text,
                authorIdentifier: authorIdentifier,
                authorDisplayName: authorDisplayName,
                parentCommentId: parentCommentId?.uuidString
            )
            didMutate()
            return Comment(from: row)
        } catch {
            Logger.library.error("createComment failed: \(error)")
            return nil
        }
    }

    /// Update a comment's text.
    public func updateComment(id: UUID, text: String) {
        do {
            try store.updateComment(id: id.uuidString, text: text)
            didMutate()
        } catch {
            Logger.library.error("updateComment failed: \(error)")
        }
    }

    // MARK: - Assignment Operations

    /// List assignments.
    public func listAssignments(publicationId: UUID? = nil) -> [Assignment] {
        do {
            return try store.listAssignments(publicationId: publicationId?.uuidString).map { Assignment(from: $0) }
        } catch {
            Logger.library.error("listAssignments failed: \(error)")
            return []
        }
    }

    /// Create an assignment.
    public func createAssignment(
        publicationId: UUID,
        assigneeName: String,
        assignedByName: String? = nil,
        note: String? = nil,
        dueDate: Int64? = nil
    ) -> Assignment? {
        do {
            let row = try store.createAssignment(
                publicationId: publicationId.uuidString,
                assigneeName: assigneeName,
                assignedByName: assignedByName,
                note: note,
                dueDate: dueDate
            )
            didMutate()
            return Assignment(from: row)
        } catch {
            Logger.library.error("createAssignment failed: \(error)")
            return nil
        }
    }

    // MARK: - Smart Search Operations

    /// List smart searches.
    public func listSmartSearches(libraryId: UUID? = nil) -> [SmartSearch] {
        do {
            return try store.listSmartSearches(libraryId: libraryId?.uuidString).map { SmartSearch(from: $0) }
        } catch {
            Logger.library.error("listSmartSearches failed: \(error)")
            return []
        }
    }

    /// Get a smart search.
    public func getSmartSearch(id: UUID) -> SmartSearch? {
        do {
            guard let row = try store.getSmartSearch(id: id.uuidString) else { return nil }
            return SmartSearch(from: row)
        } catch {
            Logger.library.error("getSmartSearch failed: \(error)")
            return nil
        }
    }

    /// Create a smart search.
    public func createSmartSearch(
        name: String,
        query: String,
        libraryId: UUID,
        sourceIdsJson: String? = nil,
        maxResults: Int64 = 100,
        feedsToInbox: Bool = false,
        autoRefreshEnabled: Bool = false,
        refreshIntervalSeconds: Int64 = 3600
    ) -> SmartSearch? {
        do {
            let row = try store.createSmartSearch(
                name: name,
                query: query,
                libraryId: libraryId.uuidString,
                sourceIdsJson: sourceIdsJson,
                maxResults: maxResults,
                feedsToInbox: feedsToInbox,
                autoRefreshEnabled: autoRefreshEnabled,
                refreshIntervalSeconds: refreshIntervalSeconds
            )
            didMutate()
            return SmartSearch(from: row)
        } catch {
            Logger.library.error("createSmartSearch failed: \(error)")
            return nil
        }
    }

    // MARK: - SciX Library Operations

    /// List SciX libraries.
    public func listScixLibraries() -> [SciXLibrary] {
        do {
            return try store.listScixLibraries().map { SciXLibrary(from: $0) }
        } catch {
            Logger.library.error("listScixLibraries failed: \(error)")
            return []
        }
    }

    /// Get a SciX library.
    public func getScixLibrary(id: UUID) -> SciXLibrary? {
        do {
            guard let row = try store.getScixLibrary(id: id.uuidString) else { return nil }
            return SciXLibrary(from: row)
        } catch {
            Logger.library.error("getScixLibrary failed: \(error)")
            return nil
        }
    }

    /// Create a SciX library.
    public func createScixLibrary(
        remoteId: String,
        name: String,
        description: String? = nil,
        isPublic: Bool = false,
        permissionLevel: String = "read",
        ownerEmail: String? = nil
    ) -> SciXLibrary? {
        do {
            let row = try store.createScixLibrary(
                remoteId: remoteId,
                name: name,
                description: description,
                isPublic: isPublic,
                permissionLevel: permissionLevel,
                ownerEmail: ownerEmail
            )
            didMutate()
            return SciXLibrary(from: row)
        } catch {
            Logger.library.error("createScixLibrary failed: \(error)")
            return nil
        }
    }

    /// Add publications to a SciX library.
    public func addToScixLibrary(publicationIds: [UUID], scixLibraryId: UUID) {
        do {
            try store.addToScixLibrary(publicationIds: publicationIds.map(\.uuidString), scixLibraryId: scixLibraryId.uuidString)
            didMutate()
        } catch {
            Logger.library.error("addToScixLibrary failed: \(error)")
        }
    }

    // MARK: - Inbox & Triage

    /// Create a muted item.
    public func createMutedItem(muteType: String, value: String) -> MutedItem? {
        do {
            let row = try store.createMutedItem(muteType: muteType, value: value)
            didMutate()
            return MutedItem(from: row)
        } catch {
            Logger.library.error("createMutedItem failed: \(error)")
            return nil
        }
    }

    /// List muted items.
    public func listMutedItems(muteType: String? = nil) -> [MutedItem] {
        do {
            return try store.listMutedItems(muteType: muteType).map { MutedItem(from: $0) }
        } catch {
            Logger.library.error("listMutedItems failed: \(error)")
            return []
        }
    }

    /// Dismiss a paper from inbox.
    public func dismissPaper(doi: String? = nil, arxivId: String? = nil, bibcode: String? = nil) -> DismissedPaper? {
        do {
            let row = try store.dismissPaper(doi: doi, arxivId: arxivId, bibcode: bibcode)
            didMutate()
            return DismissedPaper(from: row)
        } catch {
            Logger.library.error("dismissPaper failed: \(error)")
            return nil
        }
    }

    /// Check if a paper has been dismissed.
    public func isPaperDismissed(doi: String? = nil, arxivId: String? = nil, bibcode: String? = nil) -> Bool {
        do {
            return try store.isPaperDismissed(doi: doi, arxivId: arxivId, bibcode: bibcode)
        } catch {
            Logger.library.error("isPaperDismissed failed: \(error)")
            return false
        }
    }

    /// List dismissed papers.
    public func listDismissedPapers(limit: UInt32? = nil, offset: UInt32? = nil) -> [DismissedPaper] {
        do {
            return try store.listDismissedPapers(limit: limit, offset: offset).map { DismissedPaper(from: $0) }
        } catch {
            Logger.library.error("listDismissedPapers failed: \(error)")
            return []
        }
    }

    /// Count unread publications.
    public func countUnread(parentId: UUID? = nil) -> Int {
        do {
            return Int(try store.countUnread(parentId: parentId?.uuidString))
        } catch {
            Logger.library.error("countUnread failed: \(error)")
            return 0
        }
    }

    // MARK: - Activity Records

    /// List activity records for a library.
    public func listActivityRecords(libraryId: UUID, limit: UInt32? = nil, offset: UInt32? = nil) -> [ActivityRecord] {
        do {
            return try store.listActivityRecords(libraryId: libraryId.uuidString, limit: limit, offset: offset).map { ActivityRecord(from: $0) }
        } catch {
            Logger.library.error("listActivityRecords failed: \(error)")
            return []
        }
    }

    /// Create an activity record.
    public func createActivityRecord(
        libraryId: UUID,
        activityType: String,
        actorDisplayName: String? = nil,
        targetTitle: String? = nil,
        targetId: String? = nil,
        detail: String? = nil
    ) -> ActivityRecord? {
        do {
            let row = try store.createActivityRecord(
                libraryId: libraryId.uuidString,
                activityType: activityType,
                actorDisplayName: actorDisplayName,
                targetTitle: targetTitle,
                targetId: targetId,
                detail: detail
            )
            didMutate()
            return ActivityRecord(from: row)
        } catch {
            Logger.library.error("createActivityRecord failed: \(error)")
            return nil
        }
    }

    /// Clear all activity records for a library.
    public func clearActivityRecords(libraryId: UUID) {
        do {
            try store.clearActivityRecords(libraryId: libraryId.uuidString)
            didMutate()
        } catch {
            Logger.library.error("clearActivityRecords failed: \(error)")
        }
    }

    // MARK: - Recommendation Profiles

    /// Get recommendation profile JSON for a library.
    public func getRecommendationProfile(libraryId: UUID) -> String? {
        do {
            return try store.getRecommendationProfile(libraryId: libraryId.uuidString)
        } catch {
            Logger.library.error("getRecommendationProfile failed: \(error)")
            return nil
        }
    }

    /// Create or update a recommendation profile.
    public func createOrUpdateRecommendationProfile(
        libraryId: UUID,
        topicAffinitiesJson: String? = nil,
        authorAffinitiesJson: String? = nil,
        venueAffinitiesJson: String? = nil,
        trainingEventsJson: String? = nil
    ) {
        do {
            try store.createOrUpdateRecommendationProfile(
                libraryId: libraryId.uuidString,
                topicAffinitiesJson: topicAffinitiesJson,
                authorAffinitiesJson: authorAffinitiesJson,
                venueAffinitiesJson: venueAffinitiesJson,
                trainingEventsJson: trainingEventsJson
            )
            didMutate()
        } catch {
            Logger.library.error("createOrUpdateRecommendationProfile failed: \(error)")
        }
    }

    /// Delete a recommendation profile.
    public func deleteRecommendationProfile(libraryId: UUID) {
        do {
            try store.deleteRecommendationProfile(libraryId: libraryId.uuidString)
            didMutate()
        } catch {
            Logger.library.error("deleteRecommendationProfile failed: \(error)")
        }
    }

    // MARK: - Export

    /// Export publications as BibTeX.
    public func exportBibTeX(ids: [UUID]) -> String {
        do {
            return try store.exportBibtex(ids: ids.map(\.uuidString))
        } catch {
            Logger.library.error("exportBibTeX failed: \(error)")
            return ""
        }
    }

    /// Export all publications in a library as BibTeX.
    public func exportAllBibTeX(libraryId: UUID) -> String {
        do {
            return try store.exportAllBibtex(libraryId: libraryId.uuidString)
        } catch {
            Logger.library.error("exportAllBibTeX failed: \(error)")
            return ""
        }
    }

    // MARK: - Source Query Helper

    /// Query publications for a given source — central routing for all list views.
    public func queryPublications(for source: PublicationSource, sort: String = "created", ascending: Bool = false) -> [PublicationRowData] {
        switch source {
        case .library(let id):
            return queryPublications(parentId: id, sort: sort, ascending: ascending)
        case .collection(let id):
            return listCollectionMembers(collectionId: id, sort: sort, ascending: ascending)
        case .smartSearch:
            // Smart searches are executed via search, not direct query
            return []
        case .flagged(let color):
            return getFlaggedPublications(color: color)
        case .scixLibrary(let id):
            return queryPublications(parentId: id, sort: sort, ascending: ascending)
        case .unread:
            return queryUnread()
        case .starred:
            return queryStarred()
        case .tag(let path):
            return queryByTag(tagPath: path)
        case .inbox(let id):
            return queryPublications(parentId: id, sort: sort, ascending: ascending)
        case .dismissed:
            return []
        }
    }

    // MARK: - Convenience Methods (View Helpers)

    /// Get a smart search by ID. Alias for `getSmartSearch(id:)`.
    public func smartSearch(by id: UUID) -> SmartSearch? {
        getSmartSearch(id: id)
    }

    /// Update a smart search's name, query, and maxResults.
    ///
    /// Since the Rust store doesn't have an `updateSmartSearch` method,
    /// we use generic field updates for individual fields.
    public func updateSmartSearch(_ id: UUID, name: String, query: String, maxResults: Int16) {
        updateField(id: id, field: "name", value: name)
        updateField(id: id, field: "query", value: query)
        updateIntField(id: id, field: "max_results", value: Int64(maxResults))
    }

    /// Update a smart search with optional source IDs and max results.
    public func updateSmartSearch(
        id: UUID,
        name: String,
        query: String,
        sourceIdsJson: String?,
        maxResults: Int64
    ) {
        updateField(id: id, field: "name", value: name)
        updateField(id: id, field: "query", value: query)
        if let sourceIdsJson {
            updateField(id: id, field: "source_ids_json", value: sourceIdsJson)
        }
        updateIntField(id: id, field: "max_results", value: maxResults)
    }

    /// Create an inbox feed smart search.
    public func createInboxFeed(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int16? = nil,
        refreshIntervalSeconds: Int64 = 3600
    ) -> SmartSearch? {
        // Get or create inbox library
        guard let inboxLib = getInboxLibrary() else {
            Logger.library.error("createInboxFeed: no inbox library")
            return nil
        }
        let sourceIdsJson = sourceIDs.isEmpty ? nil : {
            if let data = try? JSONEncoder().encode(sourceIDs) {
                return String(data: data, encoding: .utf8)
            }
            return nil as String?
        }()
        return createSmartSearch(
            name: name,
            query: query,
            libraryId: inboxLib.id,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(maxResults ?? 500),
            feedsToInbox: true,
            autoRefreshEnabled: true,
            refreshIntervalSeconds: refreshIntervalSeconds
        )
    }

    /// Create a library smart search.
    public func createLibrarySmartSearch(
        name: String,
        query: String,
        sourceIDs: [String],
        libraryID: UUID,
        maxResults: Int16? = nil
    ) -> SmartSearch? {
        let sourceIdsJson = sourceIDs.isEmpty ? nil : {
            if let data = try? JSONEncoder().encode(sourceIDs) {
                return String(data: data, encoding: .utf8)
            }
            return nil as String?
        }()
        return createSmartSearch(
            name: name,
            query: query,
            libraryId: libraryID,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(maxResults ?? 100),
            autoRefreshEnabled: false,
            refreshIntervalSeconds: 86400
        )
    }

    /// Create an exploration search.
    public func createExplorationSearch(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int16? = nil
    ) -> SmartSearch? {
        // Use a designated exploration library — just use the default library for now
        guard let defaultLib = getDefaultLibrary() else {
            Logger.library.error("createExplorationSearch: no default library")
            return nil
        }
        let sourceIdsJson = sourceIDs.isEmpty ? nil : {
            if let data = try? JSONEncoder().encode(sourceIDs) {
                return String(data: data, encoding: .utf8)
            }
            return nil as String?
        }()
        return createSmartSearch(
            name: name,
            query: query,
            libraryId: defaultLib.id,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(maxResults ?? 100),
            autoRefreshEnabled: false,
            refreshIntervalSeconds: 86400
        )
    }

    /// List recent activity for a library.
    public func recentActivity(libraryID: UUID, limit: Int) -> [ActivityRecord] {
        listActivityRecords(libraryId: libraryID, limit: UInt32(limit))
    }

    /// List comments for a publication.
    public func comments(for publicationID: UUID) -> [Comment] {
        listComments(publicationId: publicationID)
    }

    /// Add a comment to a publication.
    public func addComment(text: String, to publicationID: UUID, parentCommentID: UUID? = nil) {
        #if os(macOS)
        let authorName = Host.current().localizedName
        #else
        let authorName: String? = UIDevice.current.name
        #endif
        _ = createComment(
            publicationId: publicationID,
            text: text,
            authorDisplayName: authorName,
            parentCommentId: parentCommentID
        )
    }

    /// Edit a comment's text.
    public func editComment(_ id: UUID, newText: String) {
        updateComment(id: id, text: newText)
    }

    /// Delete a comment.
    public func deleteComment(_ id: UUID) {
        deleteItem(id: id)
    }

    /// List all assignments for a library.
    public func assignments(libraryID: UUID) -> [Assignment] {
        listAssignments()
    }

    /// List assignments for the current user.
    public func myAssignments(libraryID: UUID) -> [Assignment] {
        #if os(macOS)
        let currentName = Host.current().localizedName ?? ""
        #else
        let currentName = UIDevice.current.name
        #endif
        return listAssignments().filter { $0.assigneeName == currentName }
    }

    /// Remove an assignment.
    public func removeAssignment(_ id: UUID) {
        deleteItem(id: id)
    }

    /// Get participant names for a library.
    public func participantNames(libraryID: UUID) -> [String] {
        // Derive participant names from activity records
        let records = listActivityRecords(libraryId: libraryID, limit: 500)
        let names = Set(records.compactMap { $0.actorDisplayName })
        return Array(names).sorted()
    }

    /// Suggest a publication to a participant.
    public func suggestPublication(
        publicationID: UUID,
        to assigneeName: String,
        libraryID: UUID,
        note: String? = nil,
        dueDate: Date? = nil
    ) throws {
        #if os(macOS)
        let assignedBy = Host.current().localizedName
        #else
        let assignedBy: String? = UIDevice.current.name
        #endif
        let dueDateTimestamp: Int64? = dueDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        _ = createAssignment(
            publicationId: publicationID,
            assigneeName: assigneeName,
            assignedByName: assignedBy,
            note: note,
            dueDate: dueDateTimestamp
        )
    }
}

// MARK: - PublicationRowData Extension

extension PublicationRowData {

    /// Initialize from Rust-shaped BibliographyRow — direct field mapping, no Core Data.
    public init?(from row: BibliographyRow) {
        guard let id = UUID(uuidString: row.id) else {
            return nil
        }

        self.id = id
        self.citeKey = row.citeKey
        self.title = row.title.isEmpty ? "Untitled" : row.title
        self.authorString = row.authorString.isEmpty ? "Unknown Author" : row.authorString
        self.year = row.year.map { Int($0) }
        self.abstract = row.abstractText
        self.isRead = row.isRead
        self.isStarred = row.isStarred

        // Map flag from Rust strings to PublicationFlag
        if let colorName = row.flagColor,
           let flagColor = FlagColor(rawValue: colorName) {
            let flagStyle = row.flagStyle.flatMap { FlagStyle(rawValue: $0) } ?? .solid
            let flagLength = row.flagLength.flatMap { FlagLength(rawValue: $0) } ?? .full
            self.flag = PublicationFlag(color: flagColor, style: flagStyle, length: flagLength)
        } else {
            self.flag = nil
        }

        self.hasDownloadedPDF = row.hasDownloadedPdf
        self.hasOtherAttachments = row.hasOtherAttachments
        self.citationCount = Int(row.citationCount)
        self.referenceCount = Int(row.referenceCount)
        self.doi = row.doi
        self.arxivID = row.arxivId
        self.bibcode = row.bibcode
        self.venue = row.venue
        self.note = row.note
        self.dateAdded = Date(timeIntervalSince1970: TimeInterval(row.dateAdded) / 1000.0)
        self.dateModified = Date(timeIntervalSince1970: TimeInterval(row.dateModified) / 1000.0)
        self.primaryCategory = row.primaryCategory
        self.categories = row.categories

        // Map tags from Rust TagDisplayRow to Swift TagDisplayData
        self.tagDisplays = row.tags.map { tag in
            TagDisplayData(
                id: UUID(),
                path: tag.path,
                leaf: tag.leafName,
                colorLight: tag.colorLight,
                colorDark: tag.colorDark
            )
        }

        self.libraryName = row.libraryName
    }
}
