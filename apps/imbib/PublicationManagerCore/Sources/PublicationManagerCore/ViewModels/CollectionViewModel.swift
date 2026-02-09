//
//  CollectionViewModel.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog
import SwiftUI

// MARK: - Collection View Model

/// View model for managing collections (both static and smart).
@MainActor
@Observable
public final class CollectionViewModel {

    // MARK: - Published State

    /// All collections
    public private(set) var collections: [CollectionModel] = []

    /// Smart collections only
    public var smartCollections: [CollectionModel] {
        collections.filter { $0.isSmart }
    }

    /// Static collections only
    public var staticCollections: [CollectionModel] {
        collections.filter { !$0.isSmart }
    }

    /// Currently selected collection
    public var selectedCollection: CollectionModel?

    /// Publications in the selected collection
    public private(set) var selectedCollectionPublications: [PublicationRowData] = []

    /// Loading state
    public private(set) var isLoading = false

    // MARK: - Dependencies

    private let store: RustStoreAdapter

    // MARK: - Initialization

    public init(store: RustStoreAdapter = .shared) {
        self.store = store
    }

    // MARK: - Loading

    public func loadCollections(libraryId: UUID? = nil) async {
        isLoading = true
        if let libraryId {
            collections = store.listCollections(libraryId: libraryId)
        } else {
            // Load all collections across libraries
            let libraries = store.listLibraries()
            var allCollections: [CollectionModel] = []
            for lib in libraries {
                allCollections.append(contentsOf: store.listCollections(libraryId: lib.id))
            }
            collections = allCollections
        }
        Logger.viewModels.infoCapture("Loaded \(collections.count) collections", category: "collections")
        isLoading = false
    }

    public func loadSmartCollections(libraryId: UUID? = nil) async {
        isLoading = true
        await loadCollections(libraryId: libraryId)
        // Filter to only smart collections is done via computed property
        isLoading = false
    }

    // MARK: - Selection

    public func selectCollection(_ collection: CollectionModel?) async {
        selectedCollection = collection

        guard let collection else {
            selectedCollectionPublications = []
            return
        }

        Logger.viewModels.infoCapture("Selected collection: \(collection.name)", category: "collections")

        // Load publications for this collection
        selectedCollectionPublications = store.listCollectionMembers(
            collectionId: collection.id,
            sort: "created",
            ascending: false
        )
        Logger.viewModels.infoCapture("Collection has \(selectedCollectionPublications.count) publications", category: "collections")
    }

    // MARK: - Create

    /// Create a new collection
    @discardableResult
    public func createCollection(name: String, libraryId: UUID, isSmart: Bool = false) async -> CollectionModel? {
        Logger.viewModels.infoCapture("Creating collection: \(name) (smart: \(isSmart))", category: "collections")
        let collection = store.createCollection(name: name, libraryId: libraryId)
        await loadCollections(libraryId: libraryId)
        return collection
    }

    // MARK: - Delete

    public func deleteCollection(_ collection: CollectionModel, libraryId: UUID? = nil) async {
        Logger.viewModels.infoCapture("Deleting collection: \(collection.name)", category: "collections")

        // Clear selection if deleting selected collection
        if selectedCollection?.id == collection.id {
            selectedCollection = nil
            selectedCollectionPublications = []
        }

        store.deleteItem(id: collection.id)
        await loadCollections(libraryId: libraryId)
    }

    // MARK: - Static Collection Management

    public func addToCollection(_ publicationIds: [UUID], collection: CollectionModel) async {
        guard !collection.isSmart else {
            Logger.viewModels.warning("Cannot add to smart collection")
            return
        }

        Logger.viewModels.infoCapture("Adding \(publicationIds.count) publications to: \(collection.name)", category: "collections")
        store.addToCollection(publicationIds: publicationIds, collectionId: collection.id)

        // Refresh if this is the selected collection
        if selectedCollection?.id == collection.id {
            await selectCollection(collection)
        }
    }

    public func removeFromCollection(_ publicationIds: [UUID], collection: CollectionModel) async {
        guard !collection.isSmart else {
            Logger.viewModels.warning("Cannot remove from smart collection")
            return
        }

        Logger.viewModels.infoCapture("Removing \(publicationIds.count) publications from: \(collection.name)", category: "collections")
        store.removeFromCollection(publicationIds: publicationIds, collectionId: collection.id)

        // Refresh if this is the selected collection
        if selectedCollection?.id == collection.id {
            await selectCollection(collection)
        }
    }
}

// MARK: - Collection Item

/// Wrapper for displaying collections in lists
public struct CollectionItem: Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let isSmart: Bool
    public let publicationCount: Int

    public init(collection: CollectionModel) {
        self.id = collection.id
        self.name = collection.name
        self.isSmart = collection.isSmart
        self.publicationCount = collection.publicationCount
    }

    public var icon: String {
        isSmart ? "gear" : "folder"
    }
}
