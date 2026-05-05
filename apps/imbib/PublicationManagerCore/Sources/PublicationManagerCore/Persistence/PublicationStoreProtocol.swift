//
//  PublicationStoreProtocol.swift
//  PublicationManagerCore
//
//  Protocol abstraction for the publication store, enabling dependency injection
//  and mock-based unit testing of view models.
//

import Foundation

/// Protocol abstracting the core data operations of the publication store.
///
/// View models depend on this protocol instead of `RustStoreAdapter` directly,
/// allowing injection of mock stores for unit testing.
@MainActor
public protocol PublicationStoreProtocol {

    // MARK: - Observable State

    /// Bumped on every mutation. Views observe this to trigger updates.
    var dataVersion: Int { get }

    // MARK: - Publication Queries

    func queryPublications(
        parentId: UUID,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData]

    func queryPublications(
        for source: PublicationSource,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData]

    func getPublication(id: UUID) -> PublicationRowData?
    func getPublicationDetail(id: UUID) -> PublicationModel?

    func searchPublications(
        query: String,
        parentId: UUID?,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData]

    func getFlaggedPublications(
        color: String?,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData]

    func listCollectionMembers(
        collectionId: UUID,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData]

    // MARK: - Counts

    func countPublications(parentId: UUID?) -> Int
    func countPublications(for source: PublicationSource) -> Int
    func countUnread(parentId: UUID?) -> Int
    func countUnreadInCollection(collectionId: UUID) -> Int
    func countStarred(parentId: UUID?) -> Int
    func countArtifacts(type: ArtifactType?) -> Int

    // MARK: - Publication Mutations

    @discardableResult
    func importBibTeX(_ bibtex: String, libraryId: UUID) -> [UUID]

    func deletePublications(ids: [UUID])
    func deleteItem(id: UUID)
    func movePublications(ids: [UUID], toLibraryId: UUID)
    func duplicatePublications(ids: [UUID], toLibraryId: UUID) -> [UUID]

    func updateField(id: UUID, field: String, value: String?)
    func updateBoolField(id: UUID, field: String, value: Bool)
    func updateIntField(id: UUID, field: String, value: Int64?)

    func setRead(ids: [UUID], read: Bool)
    func setStarred(ids: [UUID], starred: Bool)
    func setFlag(ids: [UUID], color: String?, style: String?, length: String?)

    // MARK: - Library Management

    func listLibraries() -> [LibraryModel]
    func getLibrary(id: UUID) -> LibraryModel?
    func getDefaultLibrary() -> LibraryModel?
    func getInboxLibrary() -> LibraryModel?

    @discardableResult
    func createLibrary(name: String) -> LibraryModel?

    @discardableResult
    func createInboxLibrary(name: String) -> LibraryModel?

    func setLibraryDefault(id: UUID)
    func deleteLibrary(id: UUID)

    // MARK: - Collection Management

    func listCollections(libraryId: UUID) -> [CollectionModel]

    @discardableResult
    func createCollection(name: String, libraryId: UUID, isSmart: Bool, query: String?) -> CollectionModel?

    func addToCollection(publicationIds: [UUID], collectionId: UUID)
    func removeFromCollection(publicationIds: [UUID], collectionId: UUID)

    // MARK: - Smart Search

    func listSmartSearches(libraryId: UUID?) -> [SmartSearch]
    func getSmartSearch(id: UUID) -> SmartSearch?

    @discardableResult
    func createInboxFeed(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int16?,
        refreshIntervalSeconds: Int64
    ) -> SmartSearch?

    // MARK: - SciX Libraries

    func addToScixLibrary(publicationIds: [UUID], scixLibraryId: UUID)

    // MARK: - Export

    func exportBibTeX(ids: [UUID]) -> String
    func exportAllBibTeX(libraryId: UUID) -> String

    // MARK: - Structural Operations

    func reparentItem(id: UUID, newParentId: UUID)

    // MARK: - Batch Mutations

    func beginBatchMutation()
    func endBatchMutation()
}

// MARK: - Default Parameter Values

public extension PublicationStoreProtocol {
    func queryPublications(
        parentId: UUID,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        queryPublications(parentId: parentId, sort: sort, ascending: ascending, limit: limit, offset: offset)
    }

    func queryPublications(
        for source: PublicationSource,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        queryPublications(for: source, sort: sort, ascending: ascending, limit: limit, offset: offset)
    }

    func searchPublications(
        query: String,
        parentId: UUID? = nil,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        searchPublications(query: query, parentId: parentId, sort: sort, ascending: ascending, limit: limit, offset: offset)
    }

    func getFlaggedPublications(
        color: String? = nil,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        getFlaggedPublications(color: color, sort: sort, ascending: ascending, limit: limit, offset: offset)
    }

    func listCollectionMembers(
        collectionId: UUID,
        sort: String = "created",
        ascending: Bool = false,
        limit: UInt32? = nil,
        offset: UInt32? = nil
    ) -> [PublicationRowData] {
        listCollectionMembers(collectionId: collectionId, sort: sort, ascending: ascending, limit: limit, offset: offset)
    }

    func countPublications(parentId: UUID? = nil) -> Int {
        countPublications(parentId: parentId)
    }

    func countUnread(parentId: UUID? = nil) -> Int {
        countUnread(parentId: parentId)
    }

    func countStarred(parentId: UUID? = nil) -> Int {
        countStarred(parentId: parentId)
    }

    func countArtifacts(type: ArtifactType? = nil) -> Int {
        countArtifacts(type: type)
    }

    func createCollection(name: String, libraryId: UUID, isSmart: Bool = false, query: String? = nil) -> CollectionModel? {
        createCollection(name: name, libraryId: libraryId, isSmart: isSmart, query: query)
    }

    func listSmartSearches(libraryId: UUID? = nil) -> [SmartSearch] {
        listSmartSearches(libraryId: libraryId)
    }

    func setFlag(ids: [UUID], color: String?, style: String? = nil, length: String? = nil) {
        setFlag(ids: ids, color: color, style: style, length: length)
    }

    func createInboxFeed(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int16? = nil,
        refreshIntervalSeconds: Int64 = 3600
    ) -> SmartSearch? {
        createInboxFeed(name: name, query: query, sourceIDs: sourceIDs, maxResults: maxResults, refreshIntervalSeconds: refreshIntervalSeconds)
    }
}
