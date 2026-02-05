//
//  TreeNodeAdapters.swift
//  PublicationManagerCore
//
//  Adapters that wrap Core Data models to conform to SidebarTreeNode protocol.
//

import Foundation
import ImpressSidebar

// MARK: - Collection Node Adapter

/// Adapter that wraps CDCollection to conform to SidebarTreeNode.
///
/// This enables GenericTreeRow to render collections without modifying the
/// Core Data model. Different contexts can use different icon logic.
@MainActor
public struct CollectionNodeAdapter: SidebarTreeNode {
    public let collection: CDCollection

    /// All collections in the tree (for sibling calculations)
    public let allCollections: [CDCollection]

    /// Optional custom icon name (defaults to folder-based icon)
    public let customIconName: String?

    public init(
        collection: CDCollection,
        allCollections: [CDCollection] = [],
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
        return collection.isSmartCollection ? "folder.badge.gearshape" : "folder"
    }

    public var displayCount: Int? {
        let count = collection.matchingPublicationCount
        return count > 0 ? count : nil
    }

    public var treeDepth: Int { collection.depth }

    public var hasTreeChildren: Bool { collection.hasChildren }

    public var parentID: UUID? { collection.parentCollection?.id }

    public var childIDs: [UUID] {
        collection.sortedChildren.map { $0.id }
    }

    public var ancestorIDs: [UUID] {
        collection.ancestors.map { $0.id }
    }
}

// MARK: - Exploration Collection Adapter

/// Adapter for exploration collections with exploration-specific icons.
///
/// Exploration collections have type-specific icons based on their name prefix
/// (Refs:, Cites:, Similar:, Co-Reads:, Search:).
@MainActor
public struct ExplorationCollectionAdapter: SidebarTreeNode {
    public let collection: CDCollection
    public let allCollections: [CDCollection]

    public init(collection: CDCollection, allCollections: [CDCollection] = []) {
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
        let count = collection.matchingPublicationCount
        return count > 0 ? count : nil
    }

    public var treeDepth: Int { collection.depth }

    public var hasTreeChildren: Bool { collection.hasChildren }

    public var parentID: UUID? { collection.parentCollection?.id }

    public var childIDs: [UUID] {
        collection.sortedChildren.map { $0.id }
    }

    public var ancestorIDs: [UUID] {
        collection.ancestors.map { $0.id }
    }
}

// MARK: - Smart Search Adapter

/// Adapter for CDSmartSearch (inbox feeds, saved searches).
@MainActor
public struct SmartSearchNodeAdapter: SidebarTreeNode {
    public let smartSearch: CDSmartSearch

    public init(smartSearch: CDSmartSearch) {
        self.smartSearch = smartSearch
    }

    public var id: UUID { smartSearch.id }

    public var displayName: String { smartSearch.name }

    public var iconName: String {
        // Use type-specific icons based on search characteristics
        if smartSearch.isGroupFeed {
            return "person.3.fill"
        }
        if smartSearch.feedsToInbox {
            return "antenna.radiowaves.left.and.right"
        }
        return "magnifyingglass"
    }

    public var displayCount: Int? {
        // Smart searches show lastFetchCount if non-zero
        let count = Int(smartSearch.lastFetchCount)
        return count > 0 ? count : nil
    }

    public var treeDepth: Int { 0 }

    public var hasTreeChildren: Bool { false }

    public var parentID: UUID? { nil }

    public var childIDs: [UUID] { [] }

    public var ancestorIDs: [UUID] { [] }
}

// MARK: - Library Node Adapter

/// Adapter for CDLibrary (library headers in sidebar).
@MainActor
public struct LibraryNodeAdapter: SidebarTreeNode {
    public let library: CDLibrary

    /// Whether this library header has child content (collections, smart searches)
    public let hasChildren: Bool

    public init(library: CDLibrary, hasChildren: Bool = false) {
        self.library = library
        self.hasChildren = hasChildren
    }

    public var id: UUID { library.id }

    public var displayName: String { library.displayName }

    public var iconName: String {
        if library.isInbox { return "tray" }
        if library.isSystemLibrary { return "book.closed" }
        if library.isDismissedLibrary { return "archivebox" }
        return "books.vertical"
    }

    public var displayCount: Int? {
        let count = library.publications?.count ?? 0
        return count > 0 ? count : nil
    }

    public var treeDepth: Int { 0 }

    public var hasTreeChildren: Bool { hasChildren }

    public var parentID: UUID? { nil }

    public var childIDs: [UUID] { [] }

    public var ancestorIDs: [UUID] { [] }
}

// MARK: - SciX Library Adapter

/// Adapter for CDSciXLibrary (NASA ADS/SciX online libraries).
@MainActor
public struct SciXLibraryNodeAdapter: SidebarTreeNode {
    public let scixLibrary: CDSciXLibrary

    public init(scixLibrary: CDSciXLibrary) {
        self.scixLibrary = scixLibrary
    }

    public var id: UUID { scixLibrary.id }

    public var displayName: String { scixLibrary.name ?? "SciX Library" }

    public var iconName: String { "cloud" }

    public var displayCount: Int? {
        let count = scixLibrary.publications?.count ?? 0
        return count > 0 ? count : nil
    }

    public var treeDepth: Int { 0 }

    public var hasTreeChildren: Bool { false }

    public var parentID: UUID? { nil }

    public var childIDs: [UUID] { [] }

    public var ancestorIDs: [UUID] { [] }
}

// MARK: - Tree Building Helpers

/// Extension providing helper methods for building adapter arrays from Core Data.
public extension Array where Element == CDCollection {
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
