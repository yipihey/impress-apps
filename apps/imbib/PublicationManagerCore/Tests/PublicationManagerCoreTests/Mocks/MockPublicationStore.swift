//
//  MockPublicationStore.swift
//  PublicationManagerCoreTests
//
//  In-memory mock of PublicationStoreProtocol for unit testing.
//

import Foundation
@testable import PublicationManagerCore

@MainActor
final class MockPublicationStore: PublicationStoreProtocol {

    // MARK: - Observable State

    var dataVersion: Int = 0

    // MARK: - In-Memory Storage

    var libraries: [UUID: LibraryModel] = [:]
    var publications: [UUID: PublicationRowData] = [:]
    /// Maps library ID → set of publication IDs
    var libraryPublications: [UUID: Set<UUID>] = [:]
    var collections: [UUID: CollectionModel] = [:]
    /// Maps collection ID → set of publication IDs
    var collectionMembers: [UUID: Set<UUID>] = [:]
    var smartSearches: [UUID: SmartSearch] = [:]
    var defaultLibraryID: UUID?
    var inboxLibraryID: UUID?

    // MARK: - Call Tracking

    var importBibTeXCallCount = 0
    var deletePublicationsCallCount = 0
    var movePublicationsCallCount = 0
    var setReadCallCount = 0
    var setStarredCallCount = 0
    var lastImportedBibTeX: String?

    // MARK: - Helpers

    /// Seed a library and optionally make it default.
    @discardableResult
    func seedLibrary(name: String, isDefault: Bool = false, isInbox: Bool = false) -> LibraryModel {
        let lib = LibraryModel(id: UUID(), name: name, isDefault: isDefault, isInbox: isInbox)
        libraries[lib.id] = lib
        libraryPublications[lib.id] = []
        if isDefault { defaultLibraryID = lib.id }
        if isInbox { inboxLibraryID = lib.id }
        dataVersion += 1
        return lib
    }

    /// Seed a publication into a library.
    @discardableResult
    func seedPublication(
        in libraryID: UUID,
        title: String = "Test Paper",
        author: String = "Test Author",
        year: Int? = 2024,
        isRead: Bool = false,
        isStarred: Bool = false
    ) -> PublicationRowData {
        let pub = PublicationRowData(
            id: UUID(),
            citeKey: title.lowercased().replacingOccurrences(of: " ", with: "_"),
            title: title,
            authorString: author,
            year: year,
            isRead: isRead,
            isStarred: isStarred
        )
        publications[pub.id] = pub
        libraryPublications[libraryID, default: []].insert(pub.id)
        dataVersion += 1
        return pub
    }

    private func didMutate() {
        dataVersion += 1
    }

    // MARK: - Publication Queries

    func queryPublications(
        parentId: UUID,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData] {
        let ids = libraryPublications[parentId] ?? []
        var results = ids.compactMap { publications[$0] }
        results.sort { a, b in
            switch sort {
            case "title": return ascending ? a.title < b.title : a.title > b.title
            case "year":
                let ay = a.year ?? 0, by = b.year ?? 0
                return ascending ? ay < by : ay > by
            default: // "created"
                return ascending ? a.dateAdded < b.dateAdded : a.dateAdded > b.dateAdded
            }
        }
        if let offset = offset { results = Array(results.dropFirst(Int(offset))) }
        if let limit = limit { results = Array(results.prefix(Int(limit))) }
        return results
    }

    func queryPublications(
        for source: PublicationSource,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData] {
        switch source {
        case .library(let id), .inbox(let id):
            return queryPublications(parentId: id, sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .collection(let id):
            return listCollectionMembers(collectionId: id, sort: sort, ascending: ascending, limit: limit, offset: offset)
        case .starred:
            return publications.values.filter { $0.isStarred }.sorted { $0.dateAdded > $1.dateAdded }
        case .unread:
            return publications.values.filter { !$0.isRead }.sorted { $0.dateAdded > $1.dateAdded }
        default:
            return []
        }
    }

    func getPublication(id: UUID) -> PublicationRowData? {
        publications[id]
    }

    func getPublicationDetail(id: UUID) -> PublicationModel? {
        // Mock returns nil — detail views need more fields
        nil
    }

    func searchPublications(
        query: String,
        parentId: UUID?,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData] {
        let lowered = query.lowercased()
        var pool: [PublicationRowData]
        if let parentId = parentId {
            let ids = libraryPublications[parentId] ?? []
            pool = ids.compactMap { publications[$0] }
        } else {
            pool = Array(publications.values)
        }
        return pool.filter {
            $0.title.lowercased().contains(lowered) ||
            $0.authorString.lowercased().contains(lowered)
        }
    }

    func getFlaggedPublications(
        color: String?,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData] {
        publications.values.filter { $0.flag != nil }.sorted { $0.dateAdded > $1.dateAdded }
    }

    func listCollectionMembers(
        collectionId: UUID,
        sort: String,
        ascending: Bool,
        limit: UInt32?,
        offset: UInt32?
    ) -> [PublicationRowData] {
        let ids = collectionMembers[collectionId] ?? []
        return ids.compactMap { publications[$0] }
    }

    // MARK: - Counts

    func countPublications(parentId: UUID?) -> Int {
        if let parentId = parentId {
            return libraryPublications[parentId]?.count ?? 0
        }
        return publications.count
    }

    func countPublications(for source: PublicationSource) -> Int {
        queryPublications(for: source, sort: "created", ascending: false, limit: nil, offset: nil).count
    }

    func countUnread(parentId: UUID?) -> Int {
        if let parentId = parentId {
            let ids = libraryPublications[parentId] ?? []
            return ids.compactMap { publications[$0] }.filter { !$0.isRead }.count
        }
        return publications.values.filter { !$0.isRead }.count
    }

    func countStarred(parentId: UUID?) -> Int {
        if let parentId = parentId {
            let ids = libraryPublications[parentId] ?? []
            return ids.compactMap { publications[$0] }.filter { $0.isStarred }.count
        }
        return publications.values.filter { $0.isStarred }.count
    }

    func countArtifacts(type: ArtifactType?) -> Int {
        0 // Artifacts not tracked in mock
    }

    // MARK: - Publication Mutations

    @discardableResult
    func importBibTeX(_ bibtex: String, libraryId: UUID) -> [UUID] {
        importBibTeXCallCount += 1
        lastImportedBibTeX = bibtex

        // Simple mock: create one publication per @article/@book/@inproceedings found
        let pattern = try! NSRegularExpression(pattern: "@\\w+\\{([^,]+),", options: [])
        let nsString = bibtex as NSString
        let matches = pattern.matches(in: bibtex, range: NSRange(location: 0, length: nsString.length))

        var ids: [UUID] = []
        for match in matches {
            let citeKey = nsString.substring(with: match.range(at: 1))
            let pub = PublicationRowData(
                id: UUID(),
                citeKey: citeKey,
                title: "Imported: \(citeKey)"
            )
            publications[pub.id] = pub
            libraryPublications[libraryId, default: []].insert(pub.id)
            ids.append(pub.id)
        }
        didMutate()
        return ids
    }

    func deletePublications(ids: [UUID]) {
        deletePublicationsCallCount += 1
        for id in ids {
            publications.removeValue(forKey: id)
            for libID in libraryPublications.keys {
                libraryPublications[libID]?.remove(id)
            }
            for colID in collectionMembers.keys {
                collectionMembers[colID]?.remove(id)
            }
        }
        didMutate()
    }

    func deleteItem(id: UUID) {
        collections.removeValue(forKey: id)
        collectionMembers.removeValue(forKey: id)
        smartSearches.removeValue(forKey: id)
        didMutate()
    }

    func movePublications(ids: [UUID], toLibraryId: UUID) {
        movePublicationsCallCount += 1
        for id in ids {
            for libID in libraryPublications.keys {
                libraryPublications[libID]?.remove(id)
            }
            libraryPublications[toLibraryId, default: []].insert(id)
        }
        didMutate()
    }

    func duplicatePublications(ids: [UUID], toLibraryId: UUID) -> [UUID] {
        var newIDs: [UUID] = []
        for id in ids {
            guard let original = publications[id] else { continue }
            let newID = UUID()
            let dup = PublicationRowData(
                id: newID,
                citeKey: original.citeKey,
                title: original.title,
                authorString: original.authorString,
                year: original.year
            )
            publications[newID] = dup
            libraryPublications[toLibraryId, default: []].insert(newID)
            newIDs.append(newID)
        }
        didMutate()
        return newIDs
    }

    func updateField(id: UUID, field: String, value: String?) {
        // Simplified: only track title updates
        if field == "title", let value = value, var pub = publications[id] {
            publications[id] = PublicationRowData(
                id: pub.id,
                citeKey: pub.citeKey,
                title: value,
                authorString: pub.authorString,
                year: pub.year
            )
        }
        didMutate()
    }

    func updateBoolField(id: UUID, field: String, value: Bool) {
        didMutate()
    }

    func updateIntField(id: UUID, field: String, value: Int64?) {
        didMutate()
    }

    func setRead(ids: [UUID], read: Bool) {
        setReadCallCount += 1
        for id in ids {
            guard let pub = publications[id] else { continue }
            publications[id] = PublicationRowData(
                id: pub.id,
                citeKey: pub.citeKey,
                title: pub.title,
                authorString: pub.authorString,
                year: pub.year,
                isRead: read,
                isStarred: pub.isStarred,
                flag: pub.flag
            )
        }
        didMutate()
    }

    func setStarred(ids: [UUID], starred: Bool) {
        setStarredCallCount += 1
        for id in ids {
            guard let pub = publications[id] else { continue }
            publications[id] = PublicationRowData(
                id: pub.id,
                citeKey: pub.citeKey,
                title: pub.title,
                authorString: pub.authorString,
                year: pub.year,
                isRead: pub.isRead,
                isStarred: starred,
                flag: pub.flag
            )
        }
        didMutate()
    }

    func setFlag(ids: [UUID], color: String?, style: String?, length: String?) {
        didMutate()
    }

    // MARK: - Library Management

    func listLibraries() -> [LibraryModel] {
        Array(libraries.values).sorted { $0.name < $1.name }
    }

    func getLibrary(id: UUID) -> LibraryModel? {
        libraries[id]
    }

    func getDefaultLibrary() -> LibraryModel? {
        libraries.values.first { $0.isDefault }
    }

    func getInboxLibrary() -> LibraryModel? {
        libraries.values.first { $0.isInbox }
    }

    @discardableResult
    func createLibrary(name: String) -> LibraryModel? {
        let lib = LibraryModel(id: UUID(), name: name)
        libraries[lib.id] = lib
        libraryPublications[lib.id] = []
        didMutate()
        return lib
    }

    @discardableResult
    func createInboxLibrary(name: String) -> LibraryModel? {
        let lib = LibraryModel(id: UUID(), name: name, isInbox: true)
        libraries[lib.id] = lib
        libraryPublications[lib.id] = []
        inboxLibraryID = lib.id
        didMutate()
        return lib
    }

    func setLibraryDefault(id: UUID) {
        // Clear existing default
        for (key, lib) in libraries {
            if lib.isDefault {
                libraries[key] = LibraryModel(id: lib.id, name: lib.name, isDefault: false, isInbox: lib.isInbox, publicationCount: lib.publicationCount)
            }
        }
        if let lib = libraries[id] {
            libraries[id] = LibraryModel(id: lib.id, name: lib.name, isDefault: true, isInbox: lib.isInbox, publicationCount: lib.publicationCount)
            defaultLibraryID = id
        }
        didMutate()
    }

    func deleteLibrary(id: UUID) {
        libraries.removeValue(forKey: id)
        let pubIDs = libraryPublications.removeValue(forKey: id) ?? []
        for pubID in pubIDs {
            publications.removeValue(forKey: pubID)
        }
        didMutate()
    }

    // MARK: - Collection Management

    func listCollections(libraryId: UUID) -> [CollectionModel] {
        collections.values.filter { col in
            // Associate collections with libraries by convention (stored in collectionMembers)
            true // simplified — return all collections
        }.sorted { $0.sortOrder < $1.sortOrder }
    }

    @discardableResult
    func createCollection(name: String, libraryId: UUID, isSmart: Bool, query: String?) -> CollectionModel? {
        let col = CollectionModel(
            id: UUID(),
            name: name,
            isSmart: isSmart,
            sortOrder: collections.count
        )
        collections[col.id] = col
        collectionMembers[col.id] = []
        didMutate()
        return col
    }

    func addToCollection(publicationIds: [UUID], collectionId: UUID) {
        for id in publicationIds {
            collectionMembers[collectionId, default: []].insert(id)
        }
        didMutate()
    }

    func removeFromCollection(publicationIds: [UUID], collectionId: UUID) {
        for id in publicationIds {
            collectionMembers[collectionId]?.remove(id)
        }
        didMutate()
    }

    // MARK: - Smart Search

    func listSmartSearches(libraryId: UUID?) -> [SmartSearch] {
        // Mock returns empty
        []
    }

    func getSmartSearch(id: UUID) -> SmartSearch? {
        smartSearches[id]
    }

    @discardableResult
    func createInboxFeed(
        name: String,
        query: String,
        sourceIDs: [String],
        maxResults: Int16?,
        refreshIntervalSeconds: Int64
    ) -> SmartSearch? {
        nil // Simplified
    }

    // MARK: - SciX Libraries

    func addToScixLibrary(publicationIds: [UUID], scixLibraryId: UUID) {
        didMutate()
    }

    // MARK: - Export

    func exportBibTeX(ids: [UUID]) -> String {
        ids.compactMap { publications[$0] }.map { pub in
            "@article{\(pub.citeKey),\n  title = {\(pub.title)},\n  author = {\(pub.authorString)}\n}"
        }.joined(separator: "\n\n")
    }

    func exportAllBibTeX(libraryId: UUID) -> String {
        let ids = Array(libraryPublications[libraryId] ?? [])
        return exportBibTeX(ids: ids)
    }

    // MARK: - Structural Operations

    func reparentItem(id: UUID, newParentId: UUID) {
        didMutate()
    }

    // MARK: - Batch Mutations

    func beginBatchMutation() {
        // No-op in mock
    }

    func endBatchMutation() {
        // No-op in mock
    }
}

