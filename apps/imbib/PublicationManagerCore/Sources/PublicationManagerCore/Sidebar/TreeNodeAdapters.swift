//
//  TreeNodeAdapters.swift
//  PublicationManagerCore
//
//  Adapters that wrap domain models to conform to SidebarTreeNode protocol.
//

import Foundation
import ImpressSidebar

// MARK: - Collection Node Adapter

/// Adapter that wraps CollectionModel to conform to SidebarTreeNode.
///
/// This enables GenericTreeRow to render collections without modifying the
/// domain model. Different contexts can use different icon logic.
@MainActor
public struct CollectionNodeAdapter: SidebarTreeNode {
    public let collection: CollectionModel

    /// All collections in the tree (for sibling calculations)
    public let allCollections: [CollectionModel]

    /// Optional custom icon name (defaults to folder-based icon)
    public let customIconName: String?

    public init(
        collection: CollectionModel,
        allCollections: [CollectionModel] = [],
        customIconName: String? = nil
    ) {
        self.collection = collection
        self.allCollections = allCollections
        self.customIconName = customIconName
    }

    public var id: UUID { collection.id }

    public var displayName: String { collection.name }

    public var iconName: String {
        if let custom = customIconName {
            return custom
        }
        return collection.isSmart ? "folder.badge.gearshape" : "folder"
    }

    public var displayCount: Int? {
        let count = collection.publicationCount
        return count > 0 ? count : nil
    }

    public var treeDepth: Int {
        // Calculate depth from parent chain
        var depth = 0
        var current = collection.parentID
        while let parentID = current {
            depth += 1
            current = allCollections.first(where: { $0.id == parentID })?.parentID
        }
        return depth
    }

    public var hasTreeChildren: Bool {
        allCollections.contains { $0.parentID == collection.id }
    }

    public var parentID: UUID? { collection.parentID }

    public var childIDs: [UUID] {
        allCollections
            .filter { $0.parentID == collection.id }
            .sorted(by: { $0.sortOrder < $1.sortOrder })
            .map(\.id)
    }

    public var ancestorIDs: [UUID] {
        var ancestors: [UUID] = []
        var current = collection.parentID
        while let parentID = current {
            ancestors.append(parentID)
            current = allCollections.first(where: { $0.id == parentID })?.parentID
        }
        return ancestors
    }
}

// MARK: - Exploration Collection Adapter

/// Adapter for exploration collections with exploration-specific icons.
///
/// Exploration collections have type-specific icons based on their name prefix
/// (Refs:, Cites:, Similar:, Co-Reads:, Search:).
@MainActor
public struct ExplorationCollectionAdapter: SidebarTreeNode {
    public let collection: CollectionModel
    public let allCollections: [CollectionModel]

    public init(collection: CollectionModel, allCollections: [CollectionModel] = []) {
        self.collection = collection
        self.allCollections = allCollections
    }

    public var id: UUID { collection.id }

    public var displayName: String { collection.name }

    public var iconName: String {
        let name = collection.name
        if name.hasPrefix("Refs:") { return "arrow.down.doc" }
        if name.hasPrefix("Cites:") { return "arrow.up.doc" }
        if name.hasPrefix("Similar:") { return "doc.on.doc" }
        if name.hasPrefix("Co-Reads:") { return "person.2.fill" }
        if name.hasPrefix("Search:") { return "magnifyingglass" }
        return "doc.text.magnifyingglass"
    }

    public var displayCount: Int? {
        let count = collection.publicationCount
        return count > 0 ? count : nil
    }

    public var treeDepth: Int {
        var depth = 0
        var current = collection.parentID
        while let parentID = current {
            depth += 1
            current = allCollections.first(where: { $0.id == parentID })?.parentID
        }
        return depth
    }

    public var hasTreeChildren: Bool {
        allCollections.contains { $0.parentID == collection.id }
    }

    public var parentID: UUID? { collection.parentID }

    public var childIDs: [UUID] {
        allCollections
            .filter { $0.parentID == collection.id }
            .sorted(by: { $0.sortOrder < $1.sortOrder })
            .map(\.id)
    }

    public var ancestorIDs: [UUID] {
        var ancestors: [UUID] = []
        var current = collection.parentID
        while let parentID = current {
            ancestors.append(parentID)
            current = allCollections.first(where: { $0.id == parentID })?.parentID
        }
        return ancestors
    }
}

// MARK: - Smart Search Adapter

/// Adapter for SmartSearch (inbox feeds, saved searches).
@MainActor
public struct SmartSearchNodeAdapter: SidebarTreeNode {
    public let smartSearch: SmartSearch

    public init(smartSearch: SmartSearch) {
        self.smartSearch = smartSearch
    }

    public var id: UUID { smartSearch.id }

    public var displayName: String { smartSearch.name }

    public var iconName: String {
        // Use type-specific icons based on search characteristics
        if smartSearch.feedsToInbox {
            return "antenna.radiowaves.left.and.right"
        }
        return "magnifyingglass"
    }

    public var displayCount: Int? {
        // Smart searches show lastFetchCount if non-zero
        let count = smartSearch.lastFetchCount
        return count > 0 ? count : nil
    }

    public var treeDepth: Int { 0 }

    public var hasTreeChildren: Bool { false }

    public var parentID: UUID? { nil }

    public var childIDs: [UUID] { [] }

    public var ancestorIDs: [UUID] { [] }
}

// MARK: - Library Node Adapter

/// Adapter for LibraryModel (library headers in sidebar).
@MainActor
public struct LibraryNodeAdapter: SidebarTreeNode {
    public let library: LibraryModel

    /// Whether this library header has child content (collections, smart searches)
    public let hasChildren: Bool

    public init(library: LibraryModel, hasChildren: Bool = false) {
        self.library = library
        self.hasChildren = hasChildren
    }

    public var id: UUID { library.id }

    public var displayName: String { library.name }

    public var iconName: String {
        if library.isInbox { return "tray" }
        if library.isDefault { return "book.closed" }
        return "books.vertical"
    }

    public var displayCount: Int? {
        let count = library.publicationCount
        return count > 0 ? count : nil
    }

    public var treeDepth: Int { 0 }

    public var hasTreeChildren: Bool { hasChildren }

    public var parentID: UUID? { nil }

    public var childIDs: [UUID] { [] }

    public var ancestorIDs: [UUID] { [] }
}

// MARK: - SciX Library Adapter

/// Adapter for SciXLibrary (NASA ADS/SciX online libraries).
@MainActor
public struct SciXLibraryNodeAdapter: SidebarTreeNode {
    public let scixLibrary: SciXLibrary

    public init(scixLibrary: SciXLibrary) {
        self.scixLibrary = scixLibrary
    }

    public var id: UUID { scixLibrary.id }

    public var displayName: String { scixLibrary.name }

    public var iconName: String { "cloud" }

    public var displayCount: Int? {
        let count = scixLibrary.publicationCount
        return count > 0 ? count : nil
    }

    public var treeDepth: Int { 0 }

    public var hasTreeChildren: Bool { false }

    public var parentID: UUID? { nil }

    public var childIDs: [UUID] { [] }

    public var ancestorIDs: [UUID] { [] }
}

// MARK: - Tree Building Helpers

/// Extension providing helper methods for building adapter arrays from domain models.
public extension Array where Element == CollectionModel {
    /// Convert to CollectionNodeAdapters for library collections.
    @MainActor
    func asCollectionAdapters() -> [CollectionNodeAdapter] {
        map { CollectionNodeAdapter(collection: $0, allCollections: self) }
    }

    /// Convert to ExplorationCollectionAdapters for exploration collections.
    @MainActor
    func asExplorationAdapters() -> [ExplorationCollectionAdapter] {
        map { ExplorationCollectionAdapter(collection: $0, allCollections: self) }
    }
}
