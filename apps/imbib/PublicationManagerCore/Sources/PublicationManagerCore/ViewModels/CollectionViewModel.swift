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
    public private(set) var collections: [CDCollection] = []

    /// Smart collections only
    public var smartCollections: [CDCollection] {
        collections.filter { $0.isSmartCollection }
    }

    /// Static collections only
    public var staticCollections: [CDCollection] {
        collections.filter { !$0.isSmartCollection }
    }

    /// Currently selected collection
    public var selectedCollection: CDCollection?

    /// Publications in the selected collection
    public private(set) var selectedCollectionPublications: [CDPublication] = []

    /// Loading state
    public private(set) var isLoading = false

    // MARK: - Dependencies

    private let repository: CollectionRepository

    // MARK: - Initialization

    public init(repository: CollectionRepository = CollectionRepository()) {
        self.repository = repository
    }

    // MARK: - Loading

    public func loadCollections() async {
        isLoading = true
        collections = await repository.fetchAll()
        Logger.viewModels.infoCapture("Loaded \(collections.count) collections", category: "collections")
        isLoading = false
    }

    public func loadSmartCollections() async {
        isLoading = true
        let smart = await repository.fetchSmartCollections()
        // Merge with existing - update smart collections only
        collections = collections.filter { !$0.isSmartCollection } + smart
        isLoading = false
    }

    // MARK: - Selection

    public func selectCollection(_ collection: CDCollection?) async {
        selectedCollection = collection

        guard let collection else {
            selectedCollectionPublications = []
            return
        }

        Logger.viewModels.infoCapture("Selected collection: \(collection.name)", category: "collections")

        // Execute the collection query
        selectedCollectionPublications = await repository.executeSmartCollection(collection)
        Logger.viewModels.infoCapture("Collection has \(selectedCollectionPublications.count) publications", category: "collections")
    }

    // MARK: - Create

    /// Create a new smart collection
    @discardableResult
    public func createSmartCollection(name: String, predicate: String) async -> CDCollection {
        Logger.viewModels.infoCapture("Creating smart collection: \(name)", category: "collections")
        let collection = await repository.create(name: name, isSmartCollection: true, predicate: predicate)
        await loadCollections()
        return collection
    }

    /// Create a new static collection
    @discardableResult
    public func createStaticCollection(name: String) async -> CDCollection {
        Logger.viewModels.infoCapture("Creating static collection: \(name)", category: "collections")
        let collection = await repository.create(name: name, isSmartCollection: false)
        await loadCollections()
        return collection
    }

    // MARK: - Update

    public func updateCollection(_ collection: CDCollection, name: String? = nil, predicate: String? = nil) async {
        Logger.viewModels.infoCapture("Updating collection: \(collection.name)", category: "collections")
        await repository.update(collection, name: name, predicate: predicate)
        await loadCollections()

        // Refresh selected collection if it was updated
        if selectedCollection?.id == collection.id {
            await selectCollection(collection)
        }
    }

    // MARK: - Delete

    public func deleteCollection(_ collection: CDCollection) async {
        Logger.viewModels.infoCapture("Deleting collection: \(collection.name)", category: "collections")

        // Clear selection if deleting selected collection
        if selectedCollection?.id == collection.id {
            selectedCollection = nil
            selectedCollectionPublications = []
        }

        await repository.delete(collection)
        await loadCollections()
    }

    // MARK: - Static Collection Management

    public func addToCollection(_ publications: [CDPublication], collection: CDCollection) async {
        guard !collection.isSmartCollection else {
            Logger.viewModels.warning("Cannot add to smart collection")
            return
        }

        Logger.viewModels.infoCapture("Adding \(publications.count) publications to: \(collection.name)", category: "collections")
        await repository.addPublications(publications, to: collection)

        // Refresh if this is the selected collection
        if selectedCollection?.id == collection.id {
            await selectCollection(collection)
        }
    }

    public func removeFromCollection(_ publications: [CDPublication], collection: CDCollection) async {
        guard !collection.isSmartCollection else {
            Logger.viewModels.warning("Cannot remove from smart collection")
            return
        }

        Logger.viewModels.infoCapture("Removing \(publications.count) publications from: \(collection.name)", category: "collections")
        await repository.removePublications(publications, from: collection)

        // Refresh if this is the selected collection
        if selectedCollection?.id == collection.id {
            await selectCollection(collection)
        }
    }

    // MARK: - Predefined Smart Collections

    /// Create common predefined smart collections
    public func createDefaultSmartCollections() async {
        // Recent additions (last 30 days)
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let recentPredicate = "dateAdded >= CAST(\(thirtyDaysAgo.timeIntervalSinceReferenceDate), 'NSDate')"
        await repository.create(name: "Recent Additions", isSmartCollection: true, predicate: recentPredicate)

        // Unread (no linked PDF opened yet) - would need a read flag
        // For now, just create "Missing PDF"
        // Note: This would need linkedFiles relationship to work
        // await repository.create(name: "Missing PDF", isSmartCollection: true, predicate: "linkedFiles.@count == 0")

        // This year
        let currentYear = Calendar.current.component(.year, from: Date())
        await repository.create(name: "This Year", isSmartCollection: true, predicate: "year == \(currentYear)")

        await loadCollections()
    }
}

// MARK: - Collection Item

/// Wrapper for displaying collections in lists
public struct CollectionItem: Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let isSmartCollection: Bool
    public let publicationCount: Int
    public let collection: CDCollection

    public init(collection: CDCollection, publicationCount: Int = 0) {
        self.id = collection.id
        self.name = collection.name
        self.isSmartCollection = collection.isSmartCollection
        self.publicationCount = publicationCount
        self.collection = collection
    }

    public static func == (lhs: CollectionItem, rhs: CollectionItem) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public var icon: String {
        isSmartCollection ? "gear" : "folder"
    }
}
