//
//  ImbibSidebarViewModel.swift
//  imbib
//
//  View model for the NSOutlineView-based sidebar. Absorbs all sidebar state
//  from TabContentView and provides SidebarOutlineConfiguration.
//

#if os(macOS)
import AppKit
import SwiftUI
import PublicationManagerCore
import ImpressSidebar
import ImpressFTUI
import UniformTypeIdentifiers
import OSLog

/// View model that owns all sidebar state and provides the configuration
/// for `SidebarOutlineView<ImbibSidebarNode>`.
@MainActor
@Observable
final class ImbibSidebarViewModel {

    // MARK: - Dependencies (set via configure())

    private(set) var libraryManager: LibraryManager?
    private(set) var libraryViewModel: LibraryViewModel?
    private(set) var searchViewModel: SearchViewModel?

    // MARK: - Selection

    var selectedNodeID: UUID? {
        didSet { resolveSelectedTab() }
    }
    var selectedTab: ImbibTab? = .inbox

    // MARK: - Expansion & Editing

    var expansionState = TreeExpansionState()
    var editingNodeID: UUID?
    var dataVersion: Int = 0

    // MARK: - Section State

    var sectionOrder: [SidebarSectionType] = SidebarSectionOrderStore.loadOrderSync()
    private var collapsedSections: Set<SidebarSectionType> = SidebarCollapsedStateStore.loadCollapsedSync()

    // MARK: - Orderable Items

    var searchForms: [SearchFormType] = SearchFormStore.loadVisibleFormsSync()
    var hiddenSearchForms: Set<SearchFormType> = SearchFormStore.loadHiddenSync()
    var flagColors: [FlagColor] = FlagColorOrderStore.loadOrderSync()

    // MARK: - Counts & Status

    var flagCounts = FlagCounts.empty
    var hasSciXAPIKey = false
    var scixSyncing = false
    var scixSyncError: String?

    // MARK: - Library Management

    var libraryToDelete: (id: UUID, name: String)?
    var showDeleteConfirmation = false

    // MARK: - Sharing

    var itemToShareViaICloud: ShareableItem?

    // MARK: - Exploration

    var explorationRefreshTrigger = UUID()

    // MARK: - Private

    private let scixRepository = SciXLibraryRepository.shared
    private let dragDropCoordinator = DragDropCoordinator.shared
    private var store: RustStoreAdapter { RustStoreAdapter.shared }
    private static let logger = Logger(subsystem: "com.imbib.app", category: "sidebar")

    // Node lookup for tab → nodeID reverse mapping
    private var tabToNodeID: [ImbibTab: UUID] = [:]

    // MARK: - Configure

    func configure(
        libraryManager: LibraryManager,
        libraryViewModel: LibraryViewModel,
        searchViewModel: SearchViewModel
    ) {
        self.libraryManager = libraryManager
        self.libraryViewModel = libraryViewModel
        self.searchViewModel = searchViewModel

        // Seed expansion state from collapsed sections
        initializeExpansionState()

        // Select allInbox by default
        let inboxNodeID = ImbibSidebarNodeID.allInbox
        selectedNodeID = inboxNodeID

        bumpDataVersion()
    }

    // MARK: - Data Version

    func bumpDataVersion() {
        dataVersion += 1
        rebuildTabMap()
    }

    // MARK: - Outline Configuration

    var outlineConfiguration: SidebarOutlineConfiguration<ImbibSidebarNode> {
        .init(
            rootNodes: buildSectionNodes(),
            childrenOf: { [weak self] node in
                self?.children(of: node) ?? []
            },
            capabilitiesOf: { [weak self] node in
                self?.capabilities(of: node) ?? .readOnly
            },
            pasteboardType: .init(rawValue: UTType.sidebarSectionID.identifier),
            additionalDragTypes: [.init(rawValue: UTType.publicationID.identifier)],
            onReorder: { [weak self] siblings, parent in
                self?.handleReorder(siblings, parent: parent)
            },
            onReparent: { [weak self] node, newParent in
                self?.handleReparent(node, newParent: newParent)
            },
            onExternalDrop: { [weak self] pasteboard, target in
                self?.handleExternalDrop(pasteboard, target: target) ?? false
            },
            onRename: { [weak self] node, newName in
                self?.handleRename(node, newName: newName)
            },
            contextMenu: { [weak self] node in
                self?.buildContextMenu(for: node)
            },
            canAcceptDrop: { [weak self] dragged, target in
                self?.canAcceptDrop(dragged, target: target) ?? false
            },
            isGroupItem: { $0.isGroup }
        )
    }

    // MARK: - Expansion State Initialization

    private func initializeExpansionState() {
        // Sections that are NOT collapsed should be expanded
        for section in sectionOrder {
            let sectionNodeID = ImbibSidebarNodeID.section(section)
            if !collapsedSections.contains(section) {
                expansionState.expand(sectionNodeID)
            }
        }
    }

    // MARK: - Tab ↔ Node ID Mapping

    private func rebuildTabMap() {
        tabToNodeID.removeAll()
        func registerNode(_ node: ImbibSidebarNode) {
            if let tab = node.imbibTab {
                tabToNodeID[tab] = node.id
            }
            for child in children(of: node) {
                registerNode(child)
            }
        }
        for section in buildSectionNodes() {
            registerNode(section)
        }
    }

    /// Navigate to a specific tab, updating selection.
    /// Sets `selectedNodeID` which triggers `didSet` → `resolveSelectedTab()`.
    func navigateToTab(_ tab: ImbibTab) {
        if let nodeID = tabToNodeID[tab] {
            selectedNodeID = nodeID
        } else {
            // Fallback: set tab directly when no node mapping exists
            selectedTab = tab
        }
    }

    // MARK: - Tree Building

    private func buildSectionNodes() -> [ImbibSidebarNode] {
        var nodes: [ImbibSidebarNode] = []
        for section in sectionOrder {
            guard shouldShowSection(section) else { continue }
            nodes.append(makeSectionNode(section))
        }
        return nodes
    }

    private func shouldShowSection(_ section: SidebarSectionType) -> Bool {
        switch section {
        case .inbox, .libraries, .search, .flagged:
            return true
        case .sharedWithMe:
            // TODO: sharedWithMeLibraries not yet implemented in LibraryManager
            return false
        case .scixLibraries:
            return hasSciXAPIKey
        case .exploration:
            guard let lib = libraryManager?.explorationLibrary else { return false }
            return explorationHasContent(libraryID: lib.id)
        case .artifacts:
            return true
        case .dismissed:
            guard let lib = libraryManager?.dismissedLibrary else { return false }
            return lib.publicationCount > 0
        }
    }

    private func makeSectionNode(_ section: SidebarSectionType) -> ImbibSidebarNode {
        ImbibSidebarNode(
            id: ImbibSidebarNodeID.section(section),
            nodeType: .section(section),
            displayName: section.displayName,
            iconName: section.icon,
            isGroup: true
        )
    }

    func children(of node: ImbibSidebarNode) -> [ImbibSidebarNode] {
        switch node.nodeType {
        case .section(let sectionType):
            return sectionChildren(sectionType)
        case .library(let libraryID):
            return libraryCollectionChildren(libraryID: libraryID)
        case .libraryCollection(let collectionID, let libraryID):
            return collectionSubchildren(collectionID: collectionID, libraryID: libraryID)
        case .inboxCollection(let collectionID):
            return inboxCollectionSubchildren(collectionID: collectionID)
        case .explorationCollection(let collectionID):
            return explorationCollectionSubchildren(collectionID: collectionID)
        default:
            return []
        }
    }

    // MARK: - Section Children

    private func sectionChildren(_ section: SidebarSectionType) -> [ImbibSidebarNode] {
        switch section {
        case .inbox:
            return inboxChildren()
        case .libraries:
            return librariesChildren()
        case .sharedWithMe:
            return sharedWithMeChildren()
        case .scixLibraries:
            return scixChildren()
        case .search:
            return searchChildren()
        case .exploration:
            return explorationChildren()
        case .flagged:
            return flaggedChildren()
        case .artifacts:
            return artifactsChildren()
        case .dismissed:
            return dismissedChildren()
        }
    }

    // MARK: Inbox

    private func inboxChildren() -> [ImbibSidebarNode] {
        var nodes: [ImbibSidebarNode] = []

        // All Inbox row
        let unread = InboxManager.shared.unreadCount
        nodes.append(ImbibSidebarNode(
            id: ImbibSidebarNodeID.allInbox,
            nodeType: .allInbox,
            displayName: "All Inbox",
            iconName: "tray",
            displayCount: unread > 0 ? unread : nil
        ))

        // Top-level feeds (no parent collection — feeds don't have parent collection in domain model)
        let feeds = fetchInboxFeeds()
        for feed in feeds {
            nodes.append(makeInboxFeedNode(feed))
        }

        // Inbox collections
        if let inboxLib = InboxManager.shared.inboxLibrary {
            let collections = store.listCollections(libraryId: inboxLib.id)
            let rootCollections = collections
                .filter { $0.parentID == nil && !$0.isSmart }
                .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
            for collection in rootCollections {
                let hasChildren = collections.contains { $0.parentID == collection.id }
                nodes.append(makeInboxCollectionNode(collection, depth: 0, hasChildren: hasChildren, allCollections: collections))
            }
        }

        return nodes
    }

    private func makeInboxFeedNode(_ feed: SmartSearch) -> ImbibSidebarNode {
        let unread = unreadCountForFeed(feed)
        return ImbibSidebarNode(
            id: feed.id,
            nodeType: .inboxFeed(feedID: feed.id),
            displayName: feed.name,
            iconName: feed.isGroupFeed ? "person.3.fill" : "antenna.radiowaves.left.and.right",
            displayCount: unread > 0 ? unread : nil
        )
    }

    private func makeInboxCollectionNode(_ collection: CollectionModel, depth: Int, hasChildren: Bool, allCollections: [CollectionModel]) -> ImbibSidebarNode {
        let count = collection.publicationCount
        return ImbibSidebarNode(
            id: collection.id,
            nodeType: .inboxCollection(collectionID: collection.id),
            displayName: collection.name,
            iconName: "folder",
            displayCount: count > 0 ? count : nil,
            treeDepth: depth,
            hasTreeChildren: hasChildren
        )
    }

    private func inboxCollectionSubchildren(collectionID: UUID) -> [ImbibSidebarNode] {
        guard let inboxLib = InboxManager.shared.inboxLibrary else { return [] }
        let allCollections = store.listCollections(libraryId: inboxLib.id)
        guard allCollections.contains(where: { $0.id == collectionID }) else { return [] }

        var nodes: [ImbibSidebarNode] = []

        // Child collections
        let children = allCollections
            .filter { $0.parentID == collectionID && !$0.isSmart }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
        for child in children {
            let hasGrandchildren = allCollections.contains { $0.parentID == child.id }
            nodes.append(makeInboxCollectionNode(child, depth: 1, hasChildren: hasGrandchildren, allCollections: allCollections))
        }

        return nodes
    }

    // MARK: Libraries

    private func librariesChildren() -> [ImbibSidebarNode] {
        guard let manager = libraryManager else { return [] }
        let explorationID = manager.explorationLibrary?.id
        let dismissedID = manager.dismissedLibrary?.id
        return manager.libraries
            .filter { !$0.isInbox && $0.id != explorationID && $0.id != dismissedID }
            .map { library in
                // Check via Rust store for collections
                let collections = store.listCollections(libraryId: library.id)
                let hasCollections = !collections.isEmpty
                let count = library.publicationCount
                return ImbibSidebarNode(
                    id: library.id,
                    nodeType: .library(libraryID: library.id),
                    displayName: library.name,
                    iconName: "book.closed",
                    displayCount: count > 0 ? count : nil,
                    hasTreeChildren: hasCollections
                )
            }
    }

    private func libraryCollectionChildren(libraryID: UUID) -> [ImbibSidebarNode] {
        let collections = store.listCollections(libraryId: libraryID)
        return collections
            .filter { $0.parentID == nil }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
            .map { makeLibraryCollectionNode($0, libraryID: libraryID, allCollections: collections, depth: 1) }
    }

    private func collectionSubchildren(collectionID: UUID, libraryID: UUID) -> [ImbibSidebarNode] {
        let collections = store.listCollections(libraryId: libraryID)
        return collections
            .filter { $0.parentID == collectionID }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
            .map { makeLibraryCollectionNode($0, libraryID: libraryID, allCollections: collections, depth: depthOf(collectionID, in: collections) + 2) }
    }

    private func makeLibraryCollectionNode(_ collection: CollectionModel, libraryID: UUID, allCollections: [CollectionModel], depth: Int) -> ImbibSidebarNode {
        let count = collection.publicationCount
        let hasChildren = allCollections.contains { $0.parentID == collection.id }
        return ImbibSidebarNode(
            id: collection.id,
            nodeType: .libraryCollection(collectionID: collection.id, libraryID: libraryID),
            displayName: collection.name,
            iconName: collection.isSmart ? "folder.badge.gearshape" : "folder",
            displayCount: count > 0 ? count : nil,
            treeDepth: depth,
            hasTreeChildren: hasChildren
        )
    }

    /// Compute depth of a collection by walking the parentID chain.
    private func depthOf(_ collectionID: UUID, in collections: [CollectionModel]) -> Int {
        var depth = 0
        var currentID: UUID? = collectionID
        while let cid = currentID, let col = collections.first(where: { $0.id == cid }), let pid = col.parentID {
            depth += 1
            currentID = pid
        }
        return depth
    }

    // MARK: Shared With Me

    private func sharedWithMeChildren() -> [ImbibSidebarNode] {
        // TODO: sharedWithMeLibraries not yet implemented in LibraryManager
        return []
    }

    // MARK: SciX

    private func scixChildren() -> [ImbibSidebarNode] {
        return scixRepository.libraries.map { library in
            let count = library.documentCount > 0 ? Int(library.documentCount) : nil
            return ImbibSidebarNode(
                id: library.id,
                nodeType: .scixLibrary(libraryID: library.id),
                displayName: library.name,
                iconName: "sparkles",
                displayCount: count
            )
        }
    }

    // MARK: Search

    private func searchChildren() -> [ImbibSidebarNode] {
        searchForms.map { formType in
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.searchForm(formType),
                nodeType: .searchForm(formType),
                displayName: formType.displayName,
                iconName: formType.icon
            )
        }
    }

    // MARK: Exploration

    private func explorationChildren() -> [ImbibSidebarNode] {
        guard let lib = libraryManager?.explorationLibrary else { return [] }
        var items: [(order: Int, node: ImbibSidebarNode)] = []

        // Smart searches
        let searches = store.listSmartSearches(libraryId: lib.id)
        for search in searches {
            items.append((search.sortOrder, ImbibSidebarNode(
                id: search.id,
                nodeType: .explorationSearch(searchID: search.id),
                displayName: search.name,
                iconName: "lightbulb"
            )))
        }

        // Collections
        let collections = store.listCollections(libraryId: lib.id)
        let rootCollections = collections
            .filter { $0.parentID == nil && !$0.isSmart }
        for collection in rootCollections {
            let hasChildren = collections.contains { $0.parentID == collection.id }
            items.append((collection.sortOrder, makeExplorationCollectionNode(collection, allCollections: collections, depth: 0, hasChildren: hasChildren)))
        }

        items.sort { $0.order != $1.order ? $0.order < $1.order : $0.node.displayName < $1.node.displayName }
        return items.map(\.node)
    }

    private func makeExplorationCollectionNode(_ collection: CollectionModel, allCollections: [CollectionModel], depth: Int, hasChildren: Bool) -> ImbibSidebarNode {
        let count = collection.publicationCount
        let name = collection.name
        let icon: String
        if name.hasPrefix("Refs:") { icon = "arrow.down.doc" }
        else if name.hasPrefix("Cites:") { icon = "arrow.up.doc" }
        else if name.hasPrefix("Similar:") { icon = "doc.on.doc" }
        else if name.hasPrefix("Co-Reads:") { icon = "person.2.fill" }
        else if name.hasPrefix("Search:") { icon = "magnifyingglass" }
        else { icon = "doc.text.magnifyingglass" }

        return ImbibSidebarNode(
            id: collection.id,
            nodeType: .explorationCollection(collectionID: collection.id),
            displayName: name,
            iconName: icon,
            displayCount: count > 0 ? count : nil,
            treeDepth: depth,
            hasTreeChildren: hasChildren
        )
    }

    private func explorationCollectionSubchildren(collectionID: UUID) -> [ImbibSidebarNode] {
        guard let lib = libraryManager?.explorationLibrary else { return [] }
        let collections = store.listCollections(libraryId: lib.id)
        return collections
            .filter { $0.parentID == collectionID && !$0.isSmart }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
            .map { child in
                let hasGrandchildren = collections.contains { $0.parentID == child.id }
                return makeExplorationCollectionNode(child, allCollections: collections, depth: depthOf(collectionID, in: collections) + 1, hasChildren: hasGrandchildren)
            }
    }

    // MARK: Flagged

    private func flaggedChildren() -> [ImbibSidebarNode] {
        var nodes: [ImbibSidebarNode] = []

        // Any Flag
        nodes.append(ImbibSidebarNode(
            id: ImbibSidebarNodeID.anyFlag,
            nodeType: .anyFlag,
            displayName: "Any Flag",
            iconName: "flag.fill",
            displayCount: flagCounts.total > 0 ? flagCounts.total : nil
        ))

        // Individual flag colors
        for color in flagColors {
            let count = flagCounts.byColor[color.rawValue] ?? 0
            nodes.append(ImbibSidebarNode(
                id: ImbibSidebarNodeID.flagColor(color),
                nodeType: .flagColor(color),
                displayName: color.displayName,
                iconName: "flag.fill",
                displayCount: count > 0 ? count : nil,
                iconColor: color.defaultLightColor
            ))
        }

        return nodes
    }

    // MARK: Artifacts

    private func artifactsChildren() -> [ImbibSidebarNode] {
        var nodes: [ImbibSidebarNode] = []

        // All Artifacts row
        let totalCount = store.countArtifacts(type: nil)
        nodes.append(ImbibSidebarNode(
            id: ImbibSidebarNodeID.allArtifacts,
            nodeType: .allArtifacts,
            displayName: "All Artifacts",
            iconName: "archivebox",
            displayCount: totalCount > 0 ? totalCount : nil
        ))

        // Per-type rows
        for artifactType in ArtifactType.allCases {
            let count = store.countArtifacts(type: artifactType)
            guard count > 0 else { continue }
            nodes.append(ImbibSidebarNode(
                id: ImbibSidebarNodeID.artifactType(artifactType.rawValue),
                nodeType: .artifactType(artifactType.rawValue),
                displayName: artifactType.pluralDisplayName,
                iconName: artifactType.iconName,
                displayCount: count
            ))
        }

        return nodes
    }

    // MARK: Dismissed

    private func dismissedChildren() -> [ImbibSidebarNode] {
        guard let lib = libraryManager?.dismissedLibrary else { return [] }
        let count = lib.publicationCount
        guard count > 0 else { return [] }
        return [ImbibSidebarNode(
            id: ImbibSidebarNodeID.dismissed,
            nodeType: .dismissed,
            displayName: "Dismissed",
            iconName: "xmark.circle",
            displayCount: count
        )]
    }

    // MARK: - Capabilities

    private func capabilities(of node: ImbibSidebarNode) -> TreeNodeCapabilities {
        switch node.nodeType {
        case .section:
            return .draggable
        case .library:
            return [.draggable, .droppable, .renamable, .deletable]
        case .libraryCollection:
            return [.draggable, .droppable, .renamable, .deletable]
        case .inboxCollection:
            return [.renamable, .deletable]
        case .searchForm:
            return .draggable
        case .flagColor:
            return .draggable
        case .scixLibrary:
            return .draggable
        case .explorationSearch:
            return .draggable
        case .explorationCollection:
            return [.draggable, .deletable]
        default:
            return .readOnly
        }
    }

    // MARK: - Drag-Drop

    private func canAcceptDrop(_ dragged: ImbibSidebarNode, target: ImbibSidebarNode?) -> Bool {
        guard let target = target else {
            // Root level: only sections can be dropped here
            return dragged.nodeType.isSection
        }

        switch (dragged.nodeType, target.nodeType) {
        case (.section, _):
            return false // sections only reorder at root
        case (.library, .section(.libraries)):
            return true
        case (.libraryCollection(_, let dragLibID), .library(let targetLibID)):
            return true // reparent to root of library
        case (.libraryCollection(let dragColID, let dragLibID), .libraryCollection(let targetColID, let targetLibID)):
            // Same library, not self, not descendant
            return dragLibID == targetLibID && dragColID != targetColID
        case (.scixLibrary, .section(.scixLibraries)):
            return true
        case (.searchForm, .section(.search)):
            return true
        case (.flagColor, .section(.flagged)):
            return true
        case (.explorationSearch, .section(.exploration)):
            return true
        case (.explorationCollection, .section(.exploration)):
            return true
        default:
            return false
        }
    }

    private func handleReorder(_ siblings: [ImbibSidebarNode], parent: ImbibSidebarNode?) {
        guard let parentType = parent?.nodeType else {
            // Root level: section reorder
            let newOrder = siblings.compactMap { node -> SidebarSectionType? in
                if case .section(let type) = node.nodeType { return type }
                return nil
            }
            sectionOrder = newOrder
            Task { await SidebarSectionOrderStore.shared.save(newOrder) }
            bumpDataVersion()
            return
        }

        switch parentType {
        case .section(.libraries):
            guard let manager = libraryManager else { return }
            let libraryIDs = siblings.compactMap { node -> UUID? in
                if case .library(let id) = node.nodeType { return id }
                return nil
            }
            // Reorder libraries — now done via LibraryManager
            for (index, id) in libraryIDs.enumerated() {
                store.updateIntField(id: id, field: "sort_order", value: Int64(index))
            }
            manager.loadLibraries()
            bumpDataVersion()

        case .library(let libraryID):
            // Root collection reorder in library
            let collectionIDs = siblings.compactMap { node -> UUID? in
                if case .libraryCollection(let colID, _) = node.nodeType { return colID }
                return nil
            }
            reorderCollections(collectionIDs)

        case .libraryCollection(let parentColID, _):
            // Subcollection reorder
            let collectionIDs = siblings.compactMap { node -> UUID? in
                if case .libraryCollection(let colID, _) = node.nodeType { return colID }
                return nil
            }
            reorderCollections(collectionIDs)

        case .section(.search):
            let newOrder = siblings.compactMap { node -> SearchFormType? in
                if case .searchForm(let type) = node.nodeType { return type }
                return nil
            }
            searchForms = newOrder
            Task { await SearchFormStore.shared.save(newOrder) }
            bumpDataVersion()

        case .section(.flagged):
            let newOrder = siblings.compactMap { node -> FlagColor? in
                if case .flagColor(let color) = node.nodeType { return color }
                return nil
            }
            flagColors = newOrder
            Task { await FlagColorOrderStore.shared.save(newOrder) }
            bumpDataVersion()

        case .section(.scixLibraries):
            let reordered = siblings.compactMap { node -> SciXLibrary? in
                if case .scixLibrary(let id) = node.nodeType {
                    return scixRepository.libraries.first { $0.id == id }
                }
                return nil
            }
            scixRepository.updateSortOrder(reordered)
            bumpDataVersion()

        case .section(.exploration):
            reorderExplorationChildren(siblings)

        default:
            break
        }
    }

    private func reorderCollections(_ collectionIDs: [UUID]) {
        for (index, id) in collectionIDs.enumerated() {
            store.updateIntField(id: id, field: "sort_order", value: Int64(index))
        }
        bumpDataVersion()
    }

    private func reorderExplorationChildren(_ siblings: [ImbibSidebarNode]) {
        for (index, node) in siblings.enumerated() {
            switch node.nodeType {
            case .explorationSearch(let searchID):
                store.updateIntField(id: searchID, field: "sort_order", value: Int64(index))
            case .explorationCollection(let colID):
                store.updateIntField(id: colID, field: "sort_order", value: Int64(index))
            default:
                break
            }
        }
        bumpDataVersion()
    }

    private func handleReparent(_ node: ImbibSidebarNode, newParent: ImbibSidebarNode?) {
        guard case .libraryCollection(let collectionID, let sourceLibraryID) = node.nodeType else { return }

        if let newParent = newParent {
            switch newParent.nodeType {
            case .library(let libraryID):
                // Move to root of library — clear parent, update library association
                store.updateField(id: collectionID, field: "parent_id", value: nil)
                if sourceLibraryID != libraryID {
                    store.reparentItem(id: collectionID, newParentId: libraryID)
                }
                libraryManager?.loadLibraries()
                bumpDataVersion()

            case .libraryCollection(let targetColID, let targetLibID):
                // Check for circular reference by walking ancestor chain
                if targetColID == collectionID { return }
                let collections = store.listCollections(libraryId: targetLibID)
                if isAncestor(collectionID, of: targetColID, in: collections) { return }

                // Update parent collection
                store.updateField(id: collectionID, field: "parent_id", value: targetColID.uuidString)
                if sourceLibraryID != targetLibID {
                    store.reparentItem(id: collectionID, newParentId: targetLibID)
                }
                libraryManager?.loadLibraries()
                bumpDataVersion()

            default:
                break
            }
        }
    }

    /// Check if `ancestorID` is an ancestor of `descendantID` in the collection tree.
    private func isAncestor(_ ancestorID: UUID, of descendantID: UUID, in collections: [CollectionModel]) -> Bool {
        var currentID: UUID? = descendantID
        while let cid = currentID {
            guard let col = collections.first(where: { $0.id == cid }) else { return false }
            guard let parentID = col.parentID else { return false }
            if parentID == ancestorID { return true }
            currentID = parentID
        }
        return false
    }

    private func handleExternalDrop(_ pasteboard: NSPasteboard, target: ImbibSidebarNode?) -> Bool {
        // Handle publication ID drops
        if let data = pasteboard.data(forType: .init(rawValue: UTType.publicationID.identifier)),
           let target = target {
            let uuids = decodePublicationUUIDs(from: data)
            if !uuids.isEmpty {
                Task { await handlePublicationDrop(uuids, onto: target) }
                return true
            }
        }

        // Handle file URL drops
        if pasteboard.types?.contains(.fileURL) == true, let target = target {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
                return false
            }

            let bibExtensions = ["bib", "bibtex", "ris"]
            let hasBibFiles = urls.contains { bibExtensions.contains($0.pathExtension.lowercased()) }

            if hasBibFiles {
                // Route to BibTeX import
                if let url = urls.first {
                    handleBibTeXFileDrop(url, target: target)
                }
                return true
            }

            // Route to general file drop handler
            let targetDropTarget = dropTarget(for: target)
            if let dropTarget = targetDropTarget {
                let info = DragDropInfo(providers: urls.map { NSItemProvider(contentsOf: $0)! })
                Task {
                    _ = await dragDropCoordinator.performDrop(info, target: dropTarget)
                }
                return true
            }
        }

        return false
    }

    private func dropTarget(for node: ImbibSidebarNode) -> DropTarget? {
        switch node.nodeType {
        case .library(let id):
            return .library(libraryID: id)
        case .libraryCollection(let colID, let libID):
            return .collection(collectionID: colID, libraryID: libID)
        case .allInbox:
            return .inbox
        default:
            return nil
        }
    }

    private func handleBibTeXFileDrop(_ url: URL, target: ImbibSidebarNode) {
        var userInfo: [String: Any] = ["fileURL": url]

        switch target.nodeType {
        case .library(let id):
            userInfo["libraryID"] = id
        case .libraryCollection(let colID, let libID):
            userInfo["libraryID"] = libID
            userInfo["collectionID"] = colID
        default:
            break
        }

        NotificationCenter.default.post(
            name: .importBibTeXToLibrary,
            object: nil,
            userInfo: userInfo
        )
    }

    private func decodePublicationUUIDs(from data: Data) -> [UUID] {
        if let uuidStrings = try? JSONDecoder().decode([String].self, from: data) {
            return uuidStrings.compactMap { UUID(uuidString: $0) }
        }
        if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
            return [uuid]
        }
        return []
    }

    private func handlePublicationDrop(_ uuids: [UUID], onto target: ImbibSidebarNode) async {
        switch target.nodeType {
        case .library(let libraryID):
            // Move publications to the target library
            store.movePublications(ids: uuids, toLibraryId: libraryID)
            bumpDataVersion()

        case .libraryCollection(let collectionID, let libraryID):
            // Check if collection is not smart
            let collections = store.listCollections(libraryId: libraryID)
            guard let collection = collections.first(where: { $0.id == collectionID }),
                  !collection.isSmart else { return }
            // Add publications to collection (also ensures they're in the library)
            store.addToCollection(publicationIds: uuids, collectionId: collectionID)
            bumpDataVersion()

        default:
            break
        }
    }

    // MARK: - Selection

    /// Resolves `selectedTab` from `selectedNodeID`. Called automatically via `didSet`.
    private func resolveSelectedTab() {
        guard let id = selectedNodeID else {
            selectedTab = nil
            ExplorationService.shared.currentExplorationCollectionID = nil
            return
        }

        guard let node = findNode(id), let tab = node.imbibTab else {
            return
        }
        selectedTab = tab

        // Set exploration context
        if case .explorationCollection(let colID) = node.nodeType {
            ExplorationService.shared.currentExplorationCollectionID = colID
        } else {
            ExplorationService.shared.currentExplorationCollectionID = nil
        }
    }

    // MARK: - Rename

    private func handleRename(_ node: ImbibSidebarNode, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch node.nodeType {
        case .library(let id):
            libraryManager?.rename(id: id, to: trimmed)
            bumpDataVersion()

        case .libraryCollection(let colID, _), .inboxCollection(collectionID: let colID):
            store.updateField(id: colID, field: "name", value: trimmed)
            bumpDataVersion()

        default:
            break
        }
    }

    // MARK: - Context Menus

    private func buildContextMenu(for node: ImbibSidebarNode) -> NSMenu? {
        let menu = NSMenu()

        switch node.nodeType {
        case .section(let sectionType):
            buildSectionContextMenu(menu, section: sectionType)

        case .library(let id):
            buildLibraryContextMenu(menu, libraryID: id)

        case .libraryCollection(let colID, let libID):
            buildCollectionContextMenu(menu, collectionID: colID, libraryID: libID)

        case .inboxCollection(let colID):
            buildInboxCollectionContextMenu(menu, collectionID: colID)

        case .searchForm(let formType):
            buildSearchFormContextMenu(menu, formType: formType)

        case .explorationCollection(let colID):
            let deleteItem = NSMenuItem(title: "Delete", action: #selector(ContextMenuActions.deleteExplorationCollection(_:)), keyEquivalent: "")
            deleteItem.target = ContextMenuActions.shared
            deleteItem.representedObject = colID
            menu.addItem(deleteItem)

        default:
            // Add section reorder items for items that have them
            if let sectionType = sectionTypeForNode(node) {
                addSectionReorderItems(to: menu, section: sectionType)
            }
            return menu.items.isEmpty ? nil : menu
        }

        return menu.items.isEmpty ? nil : menu
    }

    private func buildSectionContextMenu(_ menu: NSMenu, section: SidebarSectionType) {
        switch section {
        case .libraries:
            let newLibItem = NSMenuItem(title: "New Library", action: #selector(ContextMenuActions.createLibrary(_:)), keyEquivalent: "")
            newLibItem.target = ContextMenuActions.shared
            menu.addItem(newLibItem)
            menu.addItem(.separator())

        case .search:
            if !hiddenSearchForms.isEmpty {
                let showHiddenMenu = NSMenu()
                for formType in Array(hiddenSearchForms).sorted(by: { $0.rawValue < $1.rawValue }) {
                    let item = NSMenuItem(title: "Show \(formType.displayName)", action: #selector(ContextMenuActions.showSearchForm(_:)), keyEquivalent: "")
                    item.target = ContextMenuActions.shared
                    item.representedObject = formType.rawValue
                    showHiddenMenu.addItem(item)
                }
                showHiddenMenu.addItem(.separator())
                let showAllItem = NSMenuItem(title: "Show All", action: #selector(ContextMenuActions.showAllSearchForms(_:)), keyEquivalent: "")
                showAllItem.target = ContextMenuActions.shared
                showHiddenMenu.addItem(showAllItem)

                let submenuItem = NSMenuItem(title: "Show Hidden Forms", action: nil, keyEquivalent: "")
                submenuItem.submenu = showHiddenMenu
                menu.addItem(submenuItem)
                menu.addItem(.separator())
            }

        default:
            break
        }

        addSectionReorderItems(to: menu, section: section)
    }

    private func buildLibraryContextMenu(_ menu: NSMenu, libraryID: UUID) {
        let renameItem = NSMenuItem(title: "Rename", action: #selector(ContextMenuActions.renameItem(_:)), keyEquivalent: "")
        renameItem.target = ContextMenuActions.shared
        renameItem.representedObject = libraryID
        menu.addItem(renameItem)

        let newColItem = NSMenuItem(title: "New Collection", action: #selector(ContextMenuActions.createCollection(_:)), keyEquivalent: "")
        newColItem.target = ContextMenuActions.shared
        newColItem.representedObject = libraryID
        menu.addItem(newColItem)

        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: "Export...", action: #selector(ContextMenuActions.exportLibrary(_:)), keyEquivalent: "")
        exportItem.target = ContextMenuActions.shared
        exportItem.representedObject = libraryID
        menu.addItem(exportItem)

        let importItem = NSMenuItem(title: "Import...", action: #selector(ContextMenuActions.importToLibrary(_:)), keyEquivalent: "")
        importItem.target = ContextMenuActions.shared
        importItem.representedObject = libraryID
        menu.addItem(importItem)

        let shareItem = NSMenuItem(title: "Share...", action: #selector(ContextMenuActions.shareLibrary(_:)), keyEquivalent: "")
        shareItem.target = ContextMenuActions.shared
        shareItem.representedObject = libraryID
        menu.addItem(shareItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete Library", action: #selector(ContextMenuActions.deleteLibrary(_:)), keyEquivalent: "")
        deleteItem.target = ContextMenuActions.shared
        deleteItem.representedObject = libraryID
        menu.addItem(deleteItem)

        menu.addItem(.separator())
        addSectionReorderItems(to: menu, section: .libraries)
    }

    private func buildCollectionContextMenu(_ menu: NSMenu, collectionID: UUID, libraryID: UUID) {
        let collections = store.listCollections(libraryId: libraryID)
        guard let collection = collections.first(where: { $0.id == collectionID }) else { return }

        if !collection.isSmart {
            let renameItem = NSMenuItem(title: "Rename", action: #selector(ContextMenuActions.renameItem(_:)), keyEquivalent: "")
            renameItem.target = ContextMenuActions.shared
            renameItem.representedObject = collectionID
            menu.addItem(renameItem)

            let newSubItem = NSMenuItem(title: "New Subcollection", action: #selector(ContextMenuActions.createSubcollection(_:)), keyEquivalent: "")
            newSubItem.target = ContextMenuActions.shared
            newSubItem.representedObject = ["collectionID": collectionID, "libraryID": libraryID] as [String: UUID]
            menu.addItem(newSubItem)

            let shareItem = NSMenuItem(title: "Share...", action: #selector(ContextMenuActions.shareCollection(_:)), keyEquivalent: "")
            shareItem.target = ContextMenuActions.shared
            shareItem.representedObject = collectionID
            menu.addItem(shareItem)

            menu.addItem(.separator())
        }

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(ContextMenuActions.deleteCollection(_:)), keyEquivalent: "")
        deleteItem.target = ContextMenuActions.shared
        deleteItem.representedObject = collectionID
        menu.addItem(deleteItem)
    }

    private func buildInboxCollectionContextMenu(_ menu: NSMenu, collectionID: UUID) {
        let renameItem = NSMenuItem(title: "Rename", action: #selector(ContextMenuActions.renameItem(_:)), keyEquivalent: "")
        renameItem.target = ContextMenuActions.shared
        renameItem.representedObject = collectionID
        menu.addItem(renameItem)

        let newSubItem = NSMenuItem(title: "New Subcollection", action: #selector(ContextMenuActions.createInboxSubcollection(_:)), keyEquivalent: "")
        newSubItem.target = ContextMenuActions.shared
        newSubItem.representedObject = collectionID
        menu.addItem(newSubItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(ContextMenuActions.deleteCollection(_:)), keyEquivalent: "")
        deleteItem.target = ContextMenuActions.shared
        deleteItem.representedObject = collectionID
        menu.addItem(deleteItem)
    }

    private func buildSearchFormContextMenu(_ menu: NSMenu, formType: SearchFormType) {
        let hideItem = NSMenuItem(title: "Hide", action: #selector(ContextMenuActions.hideSearchForm(_:)), keyEquivalent: "")
        hideItem.target = ContextMenuActions.shared
        hideItem.representedObject = formType.rawValue
        menu.addItem(hideItem)

        menu.addItem(.separator())
        addSectionReorderItems(to: menu, section: .search)
    }

    private func addSectionReorderItems(to menu: NSMenu, section: SidebarSectionType) {
        guard let index = sectionOrder.firstIndex(of: section) else { return }

        if index > 0 {
            let moveUpItem = NSMenuItem(title: "Move Section Up", action: #selector(ContextMenuActions.moveSectionUp(_:)), keyEquivalent: "")
            moveUpItem.target = ContextMenuActions.shared
            moveUpItem.representedObject = section.rawValue
            menu.addItem(moveUpItem)
        }

        if index < sectionOrder.count - 1 {
            let moveDownItem = NSMenuItem(title: "Move Section Down", action: #selector(ContextMenuActions.moveSectionDown(_:)), keyEquivalent: "")
            moveDownItem.target = ContextMenuActions.shared
            moveDownItem.representedObject = section.rawValue
            menu.addItem(moveDownItem)
        }
    }

    private func sectionTypeForNode(_ node: ImbibSidebarNode) -> SidebarSectionType? {
        switch node.nodeType {
        case .allInbox, .inboxFeed, .inboxCollection: return .inbox
        case .sharedLibrary: return .sharedWithMe
        case .scixLibrary: return .scixLibraries
        case .anyFlag, .flagColor: return .flagged
        case .allArtifacts, .artifactType: return .artifacts
        case .dismissed: return .dismissed
        case .explorationSearch, .explorationCollection: return .exploration
        default: return nil
        }
    }

    // MARK: - Expansion Persistence

    func handleExpansionChange(nodeID: UUID, expanded: Bool) {
        // Check if this is a section node
        for section in sectionOrder {
            if ImbibSidebarNodeID.section(section) == nodeID {
                if expanded {
                    collapsedSections.remove(section)
                } else {
                    collapsedSections.insert(section)
                }
                Task { await SidebarCollapsedStateStore.shared.save(collapsedSections) }
                return
            }
        }
    }

    // MARK: - Flag Counts

    func refreshFlagCounts() {
        guard let manager = libraryManager else { return }
        var total = 0
        var byColor: [String: Int] = [:]
        for library in manager.libraries {
            // Query publications via Rust store
            let pubs = store.queryPublications(parentId: library.id, sort: "created", ascending: false, limit: nil, offset: nil)
            for pubRow in pubs {
                if let color = pubRow.flag?.color {
                    total += 1
                    byColor[color.rawValue, default: 0] += 1
                }
            }
        }
        flagCounts = FlagCounts(total: total, byColor: byColor)
    }

    // MARK: - Lookup Helpers

    private func findNode(_ id: UUID) -> ImbibSidebarNode? {
        func search(in nodes: [ImbibSidebarNode]) -> ImbibSidebarNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = search(in: children(of: node)) { return found }
            }
            return nil
        }
        return search(in: buildSectionNodes())
    }

    /// Find a collection by ID across all libraries.
    private func findCollectionModel(_ id: UUID) -> CollectionModel? {
        guard let manager = libraryManager else { return nil }
        // Search all libraries
        for library in manager.libraries {
            let collections = store.listCollections(libraryId: library.id)
            if let found = collections.first(where: { $0.id == id }) {
                return found
            }
        }
        // Check inbox library
        if let inboxLib = InboxManager.shared.inboxLibrary {
            let collections = store.listCollections(libraryId: inboxLib.id)
            if let found = collections.first(where: { $0.id == id }) {
                return found
            }
        }
        // Check exploration library
        if let explorationLib = manager.explorationLibrary {
            let collections = store.listCollections(libraryId: explorationLib.id)
            if let found = collections.first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }

    /// Find the library ID that contains a given collection.
    private func findLibraryIDForCollection(_ collectionID: UUID) -> UUID? {
        guard let manager = libraryManager else { return nil }
        for library in manager.libraries {
            let collections = store.listCollections(libraryId: library.id)
            if collections.contains(where: { $0.id == collectionID }) {
                return library.id
            }
        }
        if let inboxLib = InboxManager.shared.inboxLibrary {
            let collections = store.listCollections(libraryId: inboxLib.id)
            if collections.contains(where: { $0.id == collectionID }) {
                return inboxLib.id
            }
        }
        if let explorationLib = manager.explorationLibrary {
            let collections = store.listCollections(libraryId: explorationLib.id)
            if collections.contains(where: { $0.id == collectionID }) {
                return explorationLib.id
            }
        }
        return nil
    }

    private func explorationHasContent(libraryID: UUID) -> Bool {
        let searches = store.listSmartSearches(libraryId: libraryID)
        let hasSearches = !searches.isEmpty
        let collections = store.listCollections(libraryId: libraryID)
        let hasCollections = collections.contains { !$0.isSmart }
        return hasSearches || hasCollections
    }

    private func fetchInboxFeeds() -> [SmartSearch] {
        // Fetch all smart searches that feed to inbox
        let allSearches = store.listSmartSearches()
        return allSearches
            .filter { $0.feedsToInbox }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
    }

    private func unreadCountForFeed(_ feed: SmartSearch) -> Int {
        // Count unread publications in the feed's library scope
        // Smart searches that feed to inbox store results as collection members
        // Use the feed's library ID to count unread
        guard let libraryID = feed.libraryID else { return 0 }
        return store.countUnread(parentId: libraryID)
    }

    // MARK: - Creation Helpers

    func createLibrary() {
        guard let manager = libraryManager else { return }
        guard let library = manager.createLibrary(name: "New Library") else { return }
        bumpDataVersion()
        // Trigger inline rename
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.editingNodeID = library.id
        }
    }

    func createCollection(in libraryID: UUID, parentID: UUID? = nil) {
        let name = parentID != nil ? "New Subcollection" : "New Collection"
        guard let collection = store.createCollection(name: name, libraryId: libraryID) else { return }

        // If there's a parent, update the parent_id field
        if let parentID = parentID {
            store.updateField(id: collection.id, field: "parent_id", value: parentID.uuidString)
            expansionState.expand(parentID)
        }
        expansionState.expand(libraryID)

        libraryManager?.loadLibraries()
        bumpDataVersion()

        // Trigger inline rename
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.editingNodeID = collection.id
        }
    }

    func createInboxCollection(parentID: UUID? = nil) {
        guard let inboxLib = InboxManager.shared.inboxLibrary else { return }
        let name = parentID != nil ? "New Subcollection" : "New Collection"
        guard let collection = store.createCollection(name: name, libraryId: inboxLib.id) else { return }

        if let parentID = parentID {
            store.updateField(id: collection.id, field: "parent_id", value: parentID.uuidString)
            expansionState.expand(parentID)
        }

        bumpDataVersion()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.editingNodeID = collection.id
        }
    }

    func deleteCollection(_ collectionID: UUID) {
        // Clear selection if this collection is selected (didSet resolves selectedTab)
        switch selectedTab {
        case .collection(let id) where id == collectionID,
             .inboxCollection(let id) where id == collectionID,
             .explorationCollection(let id) where id == collectionID:
            selectedNodeID = nil
        default:
            break
        }

        store.deleteItem(id: collectionID)
        libraryManager?.loadLibraries()
        bumpDataVersion()
    }

    func deleteExplorationCollection(_ collectionID: UUID) {
        if case .explorationCollection(let id) = selectedTab, id == collectionID {
            selectedNodeID = nil
        }
        libraryManager?.deleteExplorationCollection(id: collectionID)
        explorationRefreshTrigger = UUID()
        bumpDataVersion()
    }

    func deleteLibrary(_ libraryID: UUID) {
        guard let library = libraryManager?.libraries.first(where: { $0.id == libraryID }) else { return }
        libraryToDelete = (id: library.id, name: library.name)
        showDeleteConfirmation = true
    }

    func hideSearchForm(_ rawValue: String) {
        guard let formType = SearchFormType(rawValue: rawValue) else { return }
        searchForms.removeAll { $0 == formType }
        hiddenSearchForms.insert(formType)
        Task { await SearchFormStore.shared.hide(formType) }
        bumpDataVersion()
    }

    func showSearchForm(_ rawValue: String) {
        guard let formType = SearchFormType(rawValue: rawValue) else { return }
        hiddenSearchForms.remove(formType)
        searchForms = SearchFormStore.loadVisibleFormsSync()
        Task { await SearchFormStore.shared.show(formType) }
        bumpDataVersion()
    }

    func showAllSearchForms() {
        hiddenSearchForms.removeAll()
        searchForms = SearchFormStore.loadVisibleFormsSync()
        Task { await SearchFormStore.shared.setHidden([]) }
        bumpDataVersion()
    }

    func moveSectionUp(_ rawValue: String) {
        guard let section = SidebarSectionType(rawValue: rawValue),
              let index = sectionOrder.firstIndex(of: section), index > 0 else { return }
        sectionOrder.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
        Task { await SidebarSectionOrderStore.shared.save(sectionOrder) }
        bumpDataVersion()
    }

    func moveSectionDown(_ rawValue: String) {
        guard let section = SidebarSectionType(rawValue: rawValue),
              let index = sectionOrder.firstIndex(of: section), index < sectionOrder.count - 1 else { return }
        sectionOrder.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
        Task { await SidebarSectionOrderStore.shared.save(sectionOrder) }
        bumpDataVersion()
    }

    func exportLibrary(_ libraryID: UUID) {
        NotificationCenter.default.post(
            name: .showUnifiedExport,
            object: nil,
            userInfo: ["libraryID": libraryID]
        )
    }

    func importToLibrary(_ libraryID: UUID) {
        NotificationCenter.default.post(
            name: .showUnifiedImport,
            object: nil,
            userInfo: ["libraryID": libraryID]
        )
    }
}

// MARK: - Node Type Helpers

private extension ImbibSidebarNodeType {
    var isSection: Bool {
        if case .section = self { return true }
        return false
    }
}

// MARK: - Context Menu Actions (NSObject target-action bridge)

/// Singleton NSObject that serves as the target for NSMenu item actions.
/// Routes actions back to the view model via NotificationCenter.
@MainActor
final class ContextMenuActions: NSObject {
    static let shared = ContextMenuActions()

    /// The currently active view model. Set by TabContentView on appear.
    weak var viewModel: ImbibSidebarViewModel?

    @objc func createLibrary(_ sender: NSMenuItem) {
        viewModel?.createLibrary()
    }

    @objc func renameItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        viewModel?.editingNodeID = id
    }

    @objc func createCollection(_ sender: NSMenuItem) {
        guard let libraryID = sender.representedObject as? UUID else { return }
        viewModel?.createCollection(in: libraryID)
    }

    @objc func createSubcollection(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: UUID],
              let libraryID = info["libraryID"],
              let collectionID = info["collectionID"] else { return }
        viewModel?.createCollection(in: libraryID, parentID: collectionID)
    }

    @objc func createInboxSubcollection(_ sender: NSMenuItem) {
        guard let collectionID = sender.representedObject as? UUID else { return }
        viewModel?.createInboxCollection(parentID: collectionID)
    }

    @objc func deleteLibrary(_ sender: NSMenuItem) {
        guard let libraryID = sender.representedObject as? UUID else { return }
        viewModel?.deleteLibrary(libraryID)
    }

    @objc func deleteCollection(_ sender: NSMenuItem) {
        guard let collectionID = sender.representedObject as? UUID else { return }
        viewModel?.deleteCollection(collectionID)
    }

    @objc func deleteExplorationCollection(_ sender: NSMenuItem) {
        guard let collectionID = sender.representedObject as? UUID else { return }
        viewModel?.deleteExplorationCollection(collectionID)
    }

    @objc func exportLibrary(_ sender: NSMenuItem) {
        guard let libraryID = sender.representedObject as? UUID else { return }
        viewModel?.exportLibrary(libraryID)
    }

    @objc func importToLibrary(_ sender: NSMenuItem) {
        guard let libraryID = sender.representedObject as? UUID else { return }
        viewModel?.importToLibrary(libraryID)
    }

    @objc func shareLibrary(_ sender: NSMenuItem) {
        guard let libraryID = sender.representedObject as? UUID,
              let library = RustStoreAdapter.shared.getLibrary(id: libraryID) else { return }
        let vm = viewModel
        DispatchQueue.main.async {
            vm?.itemToShareViaICloud = .library(library)
        }
    }

    @objc func shareCollection(_ sender: NSMenuItem) {
        guard let collectionID = sender.representedObject as? UUID,
              let collection = viewModel?.findCollectionModelPublic(collectionID) else { return }
        let vm = viewModel
        DispatchQueue.main.async {
            vm?.itemToShareViaICloud = .collection(collection)
        }
    }

    @objc func hideSearchForm(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        viewModel?.hideSearchForm(rawValue)
    }

    @objc func showSearchForm(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        viewModel?.showSearchForm(rawValue)
    }

    @objc func showAllSearchForms(_ sender: NSMenuItem) {
        viewModel?.showAllSearchForms()
    }

    @objc func moveSectionUp(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        viewModel?.moveSectionUp(rawValue)
    }

    @objc func moveSectionDown(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        viewModel?.moveSectionDown(rawValue)
    }
}

// MARK: - Public Lookup

extension ImbibSidebarViewModel {
    /// Public wrapper for findCollectionModel, used by ContextMenuActions
    func findCollectionModelPublic(_ id: UUID) -> CollectionModel? {
        findCollectionModel(id)
    }
}
#endif
