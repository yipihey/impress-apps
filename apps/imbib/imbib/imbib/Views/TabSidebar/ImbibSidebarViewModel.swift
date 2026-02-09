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
import CoreData
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
            guard let lib = libraryManager?.explorationLibrary,
                  let cdLib = fetchCDLibrary(id: lib.id) else { return false }
            return explorationHasContent(cdLib)
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

        // Top-level feeds (no parent collection)
        let feeds = fetchInboxFeeds()
        let topFeeds = feeds.filter { $0.inboxParentCollection == nil }
        for feed in topFeeds {
            nodes.append(makeInboxFeedNode(feed))
        }

        // Inbox collections
        if let inboxLib = InboxManager.shared.inboxLibrary,
           let collections = inboxLib.collections as? Set<CDCollection>,
           !collections.isEmpty {
            let rootCollections = Array(collections)
                .filter { $0.parentCollection == nil && !$0.isSmartSearchResults && !$0.isSystemCollection }
                .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
            for collection in rootCollections {
                nodes.append(makeInboxCollectionNode(collection, depth: 0))
            }
        }

        return nodes
    }

    private func makeInboxFeedNode(_ feed: CDSmartSearch) -> ImbibSidebarNode {
        let unread = unreadCountForFeed(feed)
        return ImbibSidebarNode(
            id: feed.id,
            nodeType: .inboxFeed(feedID: feed.id),
            displayName: feed.name,
            iconName: feed.isGroupFeed ? "person.3.fill" : "antenna.radiowaves.left.and.right",
            displayCount: unread > 0 ? unread : nil
        )
    }

    private func makeInboxCollectionNode(_ collection: CDCollection, depth: Int) -> ImbibSidebarNode {
        let feeds = fetchInboxFeeds().filter { $0.inboxParentCollection?.id == collection.id }
        let hasContent = collection.hasChildren || !feeds.isEmpty
        let count = collection.allPublicationsIncludingDescendants.filter { !$0.isDeleted }.count
        return ImbibSidebarNode(
            id: collection.id,
            nodeType: .inboxCollection(collectionID: collection.id),
            displayName: collection.name,
            iconName: "folder",
            displayCount: count > 0 ? count : nil,
            treeDepth: depth,
            hasTreeChildren: hasContent
        )
    }

    private func inboxCollectionSubchildren(collectionID: UUID) -> [ImbibSidebarNode] {
        guard let inboxLib = InboxManager.shared.inboxLibrary,
              let collection = findInboxCollection(by: collectionID, in: inboxLib) else { return [] }

        var nodes: [ImbibSidebarNode] = []

        // Nested feeds
        let feeds = fetchInboxFeeds().filter { $0.inboxParentCollection?.id == collection.id }
        for feed in feeds {
            nodes.append(makeInboxFeedNode(feed))
        }

        // Child collections
        let children = collection.sortedChildren
            .filter { !$0.isSmartSearchResults && !$0.isSystemCollection }
        for child in children {
            nodes.append(makeInboxCollectionNode(child, depth: child.depth))
        }

        return nodes
    }

    // MARK: Libraries

    private func librariesChildren() -> [ImbibSidebarNode] {
        guard let manager = libraryManager else { return [] }
        return manager.libraries
            .filter { !$0.isInbox }
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
        // Fetch via Core Data for now — collections still use CDCollection
        guard let cdLibrary = fetchCDLibrary(id: libraryID),
              let collections = cdLibrary.collections as? Set<CDCollection> else { return [] }
        return Array(collections)
            .filter { $0.parentCollection == nil }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
            .map { makeLibraryCollectionNode($0, libraryID: libraryID) }
    }

    private func collectionSubchildren(collectionID: UUID, libraryID: UUID) -> [ImbibSidebarNode] {
        guard let cdLibrary = fetchCDLibrary(id: libraryID),
              let collection = findCollectionInLibrary(by: collectionID, in: cdLibrary) else { return [] }
        return collection.sortedChildren
            .map { makeLibraryCollectionNode($0, libraryID: libraryID) }
    }

    private func makeLibraryCollectionNode(_ collection: CDCollection, libraryID: UUID) -> ImbibSidebarNode {
        let count = collection.allPublicationsIncludingDescendants.filter { !$0.isDeleted }.count
        return ImbibSidebarNode(
            id: collection.id,
            nodeType: .libraryCollection(collectionID: collection.id, libraryID: libraryID),
            displayName: collection.name,
            iconName: collection.isSmartCollection ? "folder.badge.gearshape" : "folder",
            displayCount: count > 0 ? count : nil,
            treeDepth: collection.depth,
            hasTreeChildren: collection.hasChildren
        )
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
        guard let lib = libraryManager?.explorationLibrary,
              let cdLib = fetchCDLibrary(id: lib.id) else { return [] }
        var items: [(order: Int16, node: ImbibSidebarNode)] = []

        // Smart searches
        if let searches = cdLib.smartSearches {
            for search in searches {
                items.append((search.order, ImbibSidebarNode(
                    id: search.id,
                    nodeType: .explorationSearch(searchID: search.id),
                    displayName: search.name,
                    iconName: "lightbulb"
                )))
            }
        }

        // Collections
        if let collections = cdLib.collections as? Set<CDCollection> {
            let rootCollections = Array(collections)
                .filter { $0.parentCollection == nil && !$0.isSmartSearchResults }
            for collection in rootCollections {
                items.append((collection.sortOrder, makeExplorationCollectionNode(collection)))
            }
        }

        items.sort { $0.order != $1.order ? $0.order < $1.order : $0.node.displayName < $1.node.displayName }
        return items.map(\.node)
    }

    private func makeExplorationCollectionNode(_ collection: CDCollection) -> ImbibSidebarNode {
        let count = collection.matchingPublicationCount
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
            treeDepth: collection.depth,
            hasTreeChildren: collection.hasChildren
        )
    }

    private func explorationCollectionSubchildren(collectionID: UUID) -> [ImbibSidebarNode] {
        guard let lib = libraryManager?.explorationLibrary,
              let cdLib = fetchCDLibrary(id: lib.id),
              let collection = findExplorationCollection(by: collectionID, in: cdLib) else { return [] }
        return collection.sortedChildren
            .filter { !$0.isSmartSearchResults }
            .map { makeExplorationCollectionNode($0) }
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
            let reordered = siblings.compactMap { node -> CDSciXLibrary? in
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
            if let collection = findCollectionByID(id) {
                collection.sortOrder = Int16(index)
            }
        }
        try? PersistenceController.shared.viewContext.save()
        bumpDataVersion()
    }

    private func reorderExplorationChildren(_ siblings: [ImbibSidebarNode]) {
        let context = PersistenceController.shared.viewContext
        guard let lib = libraryManager?.explorationLibrary,
              let cdLib = fetchCDLibrary(id: lib.id) else { return }
        for (index, node) in siblings.enumerated() {
            switch node.nodeType {
            case .explorationSearch(let searchID):
                if let search = cdLib.smartSearches?.first(where: { $0.id == searchID }) {
                    search.order = Int16(index)
                }
            case .explorationCollection(let colID):
                if let collection = findCollectionByID(colID) {
                    collection.sortOrder = Int16(index)
                }
            default:
                break
            }
        }
        try? context.save()
        bumpDataVersion()
    }

    private func handleReparent(_ node: ImbibSidebarNode, newParent: ImbibSidebarNode?) {
        guard case .libraryCollection(let collectionID, let sourceLibraryID) = node.nodeType else { return }

        let context = PersistenceController.shared.viewContext

        guard let collection = findCollectionByID(collectionID) else { return }

        if let newParent = newParent {
            switch newParent.nodeType {
            case .library(let libraryID):
                // Move to root of library
                guard let cdLibrary = fetchCDLibrary(id: libraryID) else { return }
                collection.parentCollection = nil
                collection.library = cdLibrary
                try? context.save()
                libraryManager?.loadLibraries()
                bumpDataVersion()

            case .libraryCollection(let targetColID, let targetLibID):
                // Move into target collection
                guard let targetCollection = findCollectionByID(targetColID) else { return }
                // Check for circular reference
                if targetCollection.ancestors.contains(where: { $0.id == collectionID }) { return }
                if targetColID == collectionID { return }

                if sourceLibraryID != targetLibID {
                    if let cdLibrary = fetchCDLibrary(id: targetLibID) {
                        collection.library = cdLibrary
                    }
                }
                collection.parentCollection = targetCollection
                try? context.save()
                libraryManager?.loadLibraries()
                bumpDataVersion()

            default:
                break
            }
        }
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
            if let cdLibrary = fetchCDLibrary(id: id) {
                userInfo["library"] = cdLibrary
            }
        case .libraryCollection(let colID, let libID):
            if let cdLibrary = fetchCDLibrary(id: libID) {
                userInfo["library"] = cdLibrary
            }
            if let collection = findCollectionByID(colID) {
                userInfo["collection"] = collection
            }
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
        let context = PersistenceController.shared.viewContext

        switch target.nodeType {
        case .library(let libraryID):
            guard let cdLibrary = fetchCDLibrary(id: libraryID) else { return }
            await context.perform {
                let request = NSFetchRequest<CDPublication>(entityName: "Publication")
                request.predicate = NSPredicate(format: "id IN %@", uuids)
                guard let publications = try? context.fetch(request) else { return }
                for pub in publications {
                    pub.addToLibrary(cdLibrary)
                }
                try? context.save()
            }

        case .libraryCollection(let collectionID, _):
            guard let collection = findCollectionByID(collectionID),
                  !collection.isSmartCollection else { return }
            await context.perform {
                let request = NSFetchRequest<CDPublication>(entityName: "Publication")
                request.predicate = NSPredicate(format: "id IN %@", uuids)
                guard let publications = try? context.fetch(request) else { return }
                var current = collection.publications ?? []
                let collectionLibrary = collection.effectiveLibrary
                for pub in publications {
                    current.insert(pub)
                    if let library = collectionLibrary {
                        pub.addToLibrary(library)
                    }
                }
                collection.publications = current
                try? context.save()
            }

        default:
            break
        }
    }

    // MARK: - Selection

    /// Resolves `selectedTab` from `selectedNodeID`. Called automatically via `didSet`.
    private func resolveSelectedTab() {
        guard let id = selectedNodeID else {
            selectedTab = nil
            ExplorationService.shared.currentExplorationContext = nil
            return
        }

        guard let node = findNode(id), let tab = node.imbibTab else {
            return
        }
        selectedTab = tab

        // Set exploration context
        if case .explorationCollection(let colID) = node.nodeType {
            if let explorationLib = libraryManager?.explorationLibrary,
               let cdLib = fetchCDLibrary(id: explorationLib.id),
               let collection = findExplorationCollection(by: colID, in: cdLib) {
                ExplorationService.shared.currentExplorationContext = collection
            }
        } else {
            ExplorationService.shared.currentExplorationContext = nil
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
            if let collection = findCollectionByID(colID) {
                collection.name = trimmed
                try? collection.managedObjectContext?.save()
                bumpDataVersion()
            }

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
        guard let collection = findCollectionByID(collectionID) else { return }

        if !collection.isSmartCollection {
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

    /// Bridge from LibraryModel to CDLibrary when needed for Core Data operations.
    func fetchCDLibrary(id: UUID) -> CDLibrary? {
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? PersistenceController.shared.viewContext.fetch(request).first
    }

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

    private func findCollectionByID(_ id: UUID) -> CDCollection? {
        guard let manager = libraryManager else { return nil }
        // Search all libraries (including inbox and exploration) for the collection
        for library in manager.libraries {
            if let cdLibrary = fetchCDLibrary(id: library.id),
               let found = findCollectionInLibrary(by: id, in: cdLibrary) {
                return found
            }
        }
        // Also check inbox library
        if let inboxLib = InboxManager.shared.inboxLibrary,
           let found = findCollectionInLibrary(by: id, in: inboxLib) {
            return found
        }
        // Also check exploration library
        if let explorationLib = manager.explorationLibrary,
           let cdLibrary = fetchCDLibrary(id: explorationLib.id),
           let found = findCollectionInLibrary(by: id, in: cdLibrary) {
            return found
        }
        return nil
    }

    private func findCollectionInLibrary(by id: UUID, in library: CDLibrary) -> CDCollection? {
        guard let collections = library.collections as? Set<CDCollection> else { return nil }
        func findRecursive(in cols: Set<CDCollection>) -> CDCollection? {
            for col in cols {
                if col.id == id { return col }
                if let children = col.childCollections, !children.isEmpty {
                    if let found = findRecursive(in: children) { return found }
                }
            }
            return nil
        }
        return findRecursive(in: collections)
    }

    private func findInboxCollection(by id: UUID, in library: CDLibrary) -> CDCollection? {
        findCollectionInLibrary(by: id, in: library)
    }

    private func findExplorationCollection(by id: UUID, in library: CDLibrary) -> CDCollection? {
        findCollectionInLibrary(by: id, in: library)
    }

    private func explorationHasContent(_ library: CDLibrary) -> Bool {
        let hasSearches = library.smartSearches?.isEmpty == false
        let hasCollections: Bool
        if let collections = library.collections as? Set<CDCollection> {
            hasCollections = collections.contains { !$0.isSmartSearchResults }
        } else {
            hasCollections = false
        }
        return hasSearches || hasCollections
    }

    private func fetchInboxFeeds() -> [CDSmartSearch] {
        let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        request.predicate = NSPredicate(format: "feedsToInbox == YES")
        request.sortDescriptors = [
            NSSortDescriptor(key: "order", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ]
        return (try? PersistenceController.shared.viewContext.fetch(request)) ?? []
    }

    private func unreadCountForFeed(_ feed: CDSmartSearch) -> Int {
        guard let collection = feed.resultCollection,
              let publications = collection.publications else { return 0 }
        return publications.filter { !$0.isRead && !$0.isDeleted }.count
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

    func createCollection(in libraryID: UUID, parent: CDCollection? = nil) {
        guard let cdLibrary = fetchCDLibrary(id: libraryID) else { return }
        let context = cdLibrary.managedObjectContext ?? PersistenceController.shared.viewContext
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = parent != nil ? "New Subcollection" : "New Collection"
        collection.isSmartCollection = false
        collection.library = cdLibrary
        collection.parentCollection = parent

        try? context.save()
        libraryManager?.loadLibraries()

        // Expand parent so child is visible
        if let parent = parent {
            expansionState.expand(parent.id)
        }
        expansionState.expand(libraryID)

        bumpDataVersion()

        // Trigger inline rename
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.editingNodeID = collection.id
        }
    }

    func createInboxCollection(parent: CDCollection? = nil) {
        guard let inboxLib = InboxManager.shared.inboxLibrary else { return }
        let context = inboxLib.managedObjectContext ?? PersistenceController.shared.viewContext
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = parent != nil ? "New Subcollection" : "New Collection"
        collection.isSmartCollection = false
        collection.library = inboxLib
        collection.parentCollection = parent
        try? context.save()

        if let parent = parent {
            expansionState.expand(parent.id)
        }

        bumpDataVersion()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.editingNodeID = collection.id
        }
    }

    func deleteCollection(_ collectionID: UUID) {
        guard let collection = findCollectionByID(collectionID) else { return }

        // Clear selection if this collection is selected (didSet resolves selectedTab)
        switch selectedTab {
        case .collection(let id) where id == collectionID,
             .inboxCollection(let id) where id == collectionID,
             .explorationCollection(let id) where id == collectionID:
            selectedNodeID = nil
        default:
            break
        }

        let context = collection.managedObjectContext ?? PersistenceController.shared.viewContext
        context.delete(collection)
        try? context.save()
        libraryManager?.loadLibraries()
        bumpDataVersion()
    }

    func deleteExplorationCollection(_ collectionID: UUID) {
        guard findCollectionByID(collectionID) != nil else { return }
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
        guard let cdLibrary = fetchCDLibrary(id: libraryID) else { return }
        NotificationCenter.default.post(
            name: .showUnifiedExport,
            object: nil,
            userInfo: ["library": cdLibrary]
        )
    }

    func importToLibrary(_ libraryID: UUID) {
        guard let cdLibrary = fetchCDLibrary(id: libraryID) else { return }
        NotificationCenter.default.post(
            name: .showUnifiedImport,
            object: nil,
            userInfo: ["library": cdLibrary]
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
        let collection = viewModel?.findCollectionByIDPublic(collectionID)
        viewModel?.createCollection(in: libraryID, parent: collection)
    }

    @objc func createInboxSubcollection(_ sender: NSMenuItem) {
        guard let collectionID = sender.representedObject as? UUID else { return }
        let parent = viewModel?.findCollectionByIDPublic(collectionID)
        viewModel?.createInboxCollection(parent: parent)
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
              let cdLibrary = viewModel?.fetchCDLibrary(id: libraryID) else { return }
        // Dispatch async so SwiftUI processes the sheet after NSMenu's event loop exits
        let vm = viewModel
        DispatchQueue.main.async {
            vm?.itemToShareViaICloud = .library(cdLibrary)
        }
    }

    @objc func shareCollection(_ sender: NSMenuItem) {
        guard let collectionID = sender.representedObject as? UUID,
              let collection = viewModel?.findCollectionByIDPublic(collectionID) else { return }
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
    /// Public wrapper for findCollectionByID, used by ContextMenuActions
    func findCollectionByIDPublic(_ id: UUID) -> CDCollection? {
        findCollectionByID(id)
    }
}
#endif
