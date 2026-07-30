#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
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
import ImpressRustCore
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

    /// Resolved sources for the current multi-selection — derived from NSOutlineView's
    /// `selectedRowIndexes` via `SidebarOutlineConfiguration.onMultipleSelectionChanged`.
    /// Empty when 0 or 1 rows are selected (downstream uses the single-source path).
    /// Only includes nodes that map cleanly to a `PublicationSource` (libraries,
    /// regular collections); other kinds are silently dropped from the union.
    var selectedSourcesForCombinedView: [PublicationSource] = []

    /// IDs of all selected nodes (for code that needs identity, not source semantics).
    var selectedNodeIDs: Set<UUID> = []

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

    /// Bulk-delete state. Populated by the multi-selection context-menu path
    /// (`buildMultiSelectionContextMenu` → `ContextMenuActions.deleteMultipleLibraries`).
    /// Mirrors `libraryToDelete` / `showDeleteConfirmation` for the single-library case.
    var librariesPendingBulkDelete: [(id: UUID, name: String)] = []
    var showDeleteMultipleLibrariesConfirmation = false

    /// Bulk-delete state for regular collections (`.libraryCollection`).
    var collectionsPendingBulkDelete: [(id: UUID, name: String)] = []
    var showDeleteMultipleCollectionsConfirmation = false

    // MARK: - SciX Library Sheets (triggered by context menu → observed by SectionContentView)

    var scixLibraryToShowInfo: SciXLibrary?
    var scixLibraryToEdit: SciXLibrary?
    var scixLibraryToDelete: SciXLibrary?
    var showSciXDeleteConfirmation = false

    // MARK: - Exploration

    var explorationRefreshTrigger = UUID()

    // MARK: - Private

    private let scixRepository = SciXLibraryRepository.shared
    private let dragDropCoordinator = DragDropCoordinator.shared
    private let store: any PublicationStoreProtocol
    private static let logger = Logger(subsystem: "com.imbib.app", category: "sidebar")

    // Node lookup for tab → nodeID reverse mapping
    private var tabToNodeID: [ImbibTab: UUID] = [:]

    // MARK: - Initialization

    /// The app-shell identity (thin-twin). Defaults to imbib (all sections);
    /// imprint sets `.imprint` to show only the Manuscripts facet.
    var shellConfiguration: AppShellConfiguration = .imbib

    init(store: any PublicationStoreProtocol = RustStoreAdapter.shared) {
        self.store = store
    }

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

        selectDefaultSectionLeaf()
    }

    /// Select the app-shell's default section (imbib = inbox, imprint =
    /// manuscripts). Group-header sections like `.manuscripts` are NOT
    /// selectable rows and `resolveSelectedTab` only maps `.inbox`, so
    /// landing on the header leaves `selectedTab` at its `.inbox` default and
    /// the content area falls back to the publication list. Land on the
    /// section's canonical selectable leaf instead so manuscripts actually
    /// render (manuscripts → "All Manuscripts").
    ///
    /// Stage 4c: extracted from `configure(...)` so "go to the default
    /// landing" is one implementation rather than two. The
    /// `.chassisNavigateToDefaultSection` notification (impart's ⌘1) resolves
    /// through exactly the leaf first launch lands on.
    func selectDefaultSectionLeaf() {
        if shellConfiguration.defaultSection == .manuscripts {
            selectedNodeID = ImbibSidebarNodeID.journalAll
        } else if shellConfiguration.defaultSection == .figures {
            // Same rule as manuscripts: the section header is a group row,
            // so land on the canonical selectable leaf ("All Figures").
            selectedNodeID = ImbibSidebarNodeID.figuresAll
        } else if shellConfiguration.defaultSection == .mail {
            // Same rule again: land on the canonical selectable leaf
            // ("All Inboxes").
            selectedNodeID = ImbibSidebarNodeID.mailAllInboxes
        } else if shellConfiguration.defaultSection == .agents {
            // Same rule again: land on the canonical selectable leaf
            // ("Tasks").
            selectedNodeID = ImbibSidebarNodeID.agentTasks
        } else {
            selectedNodeID = ImbibSidebarNodeID.section(shellConfiguration.defaultSection)
        }

        bumpDataVersion()
    }

    // MARK: - Data Version

    func bumpDataVersion() {
        dataVersion += 1
        rebuildTabMap()
    }

    /// Lightweight version bump: refreshes counts via outline reload but skips
    /// the tab-map rebuild. Use for non-structural mutations (read/star/flag)
    /// where the tree structure is unchanged.
    func bumpDataVersionLight() {
        dataVersion += 1
    }

    /// Called when `RustStoreAdapter.shared.dataVersion` changes.
    /// Refreshes sidebar counts and triggers NSOutlineView reload.
    func refreshFromStore() {
        libraryManager?.loadLibraries()
        refreshFlagCounts()
        // Pull the latest citation-usage records from the shared
        // store. Imprint writes through a separate Swift handle, so
        // imbib's in-process StoreEvent stream never sees those
        // mutations — we refresh on every data-version bump to stay
        // roughly current. The read is cheap (bounded by the number
        // of records, typically a few hundred).
        Task { [weak self] in
            await CitedInManuscriptsSnapshot.shared.refresh()
            await MainActor.run { self?.bumpDataVersion() }
        }
        bumpDataVersion()
    }

    /// Map a sidebar node to a list-content source when one applies.
    /// Used by the multi-selection handler to build `.combined(...)` from
    /// the selected nodes. Returns nil for kinds we don't union (sections,
    /// search forms, scix libraries, smart searches, pseudo-sources).
    private static func publicationSource(for node: ImbibSidebarNode) -> PublicationSource? {
        switch node.nodeType {
        case .library(let id):
            return .library(id)
        case .libraryCollection(let id, _):
            return .collection(id)
        case .inboxCollection(let id):
            return .collection(id)
        case .sharedLibrary(let id):
            return .library(id)
        default:
            // Sections, allInbox header, feeds, scix libraries, smart searches,
            // exploration nodes, pseudo-sources — not unionable in v1.
            return nil
        }
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
            additionalDragTypes: [
                .init(rawValue: UTType.publicationID.identifier),
                .init(rawValue: UTType.manuscriptID.identifier),
                .init(rawValue: UTType.figureID.identifier),
            ],
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
            contextMenuForMultiple: { [weak self] nodes in
                self?.buildMultiSelectionContextMenu(for: nodes)
            },
            canAcceptDrop: { [weak self] dragged, target in
                self?.canAcceptDrop(dragged, target: target) ?? false
            },
            isGroupItem: { $0.isGroup },
            shouldSelectItem: { node in
                // Group items are not selectable except for inbox section
                if node.isGroup {
                    if case .section(.inbox) = node.nodeType { return true }
                    return false
                }
                return true
            },
            sectionMenu: { [weak self] node in
                self?.buildSectionHeaderMenu(for: node)
            },
            onMultipleSelectionChanged: { [weak self] nodes in
                // Mirror NSOutlineView's `selectedRowIndexes` into the view
                // model. Single-selection writes still go through
                // `selectedNodeID` (preserved exactly), so this is purely
                // additive — only consulted by `SectionContentView.currentSource`
                // when count > 1.
                guard let self else { return }
                self.selectedNodeIDs = Set(nodes.map { $0.id })
                if nodes.count > 1 {
                    self.selectedSourcesForCombinedView = nodes.compactMap(Self.publicationSource(for:))
                } else {
                    self.selectedSourcesForCombinedView = []
                }
            },
            onDeleteKeyPressed: { [weak self] nodes in
                // Route to the same flow as right-click → Delete. Single-node
                // delete uses the existing single-confirmation alert; multi-node
                // delete uses the bulk-confirmation alert. Mixed kinds drop
                // (no menu shown when right-clicking either, so be consistent).
                self?.handleDeleteKey(for: nodes)
            }
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
        // App-owned whole-pane surfaces (WP-X0): one selectable top-level
        // node per registered surface, after the record sections. Deliberate
        // ➖ row in the capability matrix: no children, counts, or drag.
        for surface in shellConfiguration.customSurfaces.surfaces {
            nodes.append(ImbibSidebarNode(
                id: ImbibSidebarNodeID.customSurface(surface.id),
                nodeType: .customSurface(surface.id),
                displayName: surface.title,
                iconName: surface.systemImage
            ))
        }
        return nodes
    }

    private func shouldShowSection(_ section: SidebarSectionType) -> Bool {
        // Thin-twin: the app-shell config restricts which sections exist at all
        // (imprint = Manuscripts facet only). Content gating applies on top.
        guard shellConfiguration.permits(section) else { return false }
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
            if shellConfiguration.recordKind(for: .dismissed) == .manuscript {
                // Always available in imprint: it is the destination for the
                // dismiss gesture, so it must exist before anything is in it.
                return true
            }
            guard let lib = libraryManager?.dismissedLibrary else { return false }
            return lib.publicationCount > 0
        case .reviewQueue:
            // Only surface the section while agents are actually waiting on
            // a human decision — keeps the sidebar quiet otherwise.
            return RustStoreAdapter.shared.countPendingReviews() > 0
        case .citedInManuscripts:
            // Only show the section when imprint has written at least
            // one resolved citation-usage record. Keeps the sidebar
            // quiet for users who don't use imprint.
            return !CitedInManuscriptsSnapshot.shared.citedPaperIDs.isEmpty
        case .manuscripts:
            // Journal section is always visible once the pipeline is
            // wired (per ADR-0011 D8). Phase 2 leaves the section open
            // so users can discover the "New Manuscript" command + the
            // Submissions inbox even before any manuscript exists.
            return true
        case .figures, .mail, .agents:
            // Pragmatic gate (Stage 2-A/B/C, noted in the capability matrix):
            // these facet sections show only in the app that owns them. Every
            // shipping preset now excludes them via visibleSections too
            // (imbib's set became explicit with the publications-only
            // purification), so this is belt-and-braces for any shell that
            // leaves visibleSections nil.
            //
            // ADR-0022 D9: the owner set — NOT an `appID ==` test — because
            // `impress` legitimately hosts all three. With an equality gate the
            // impress preset could permit these sections and the sidebar would
            // still drop them on the floor. See
            // AppShellConfiguration.facetOwnerAppIDs.
            return shellConfiguration.passesFacetGate(section)
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
        case .citedInManuscripts:
            return citedInManuscriptsChildren()
        case .reviewQueue:
            return reviewQueueChildren()
        case .manuscripts:
            return journalChildren()
        case .figures:
            return figuresChildren()
        case .mail:
            return mailChildren()
        case .agents:
            return agentsChildren()
        }
    }

    // MARK: Agents (Stage 2-C)

    /// Top-level children of the Agents sidebar section: Tasks (with one
    /// smart child per kernel lifecycle state, `countItems` counts) and
    /// Runs — flat pre-order list with `treeDepth`, same shape as
    /// mailChildren. Read-only by design — the KERNEL owns task lifecycle
    /// (TaskStoreApi.transition is the sole legal state mutation).
    private func agentsChildren() -> [ImbibSidebarNode] {
        let reader = AgentStoreReader.shared
        let totalTasks = reader.taskCount()
        var tasksNode = ImbibSidebarNode(
            id: ImbibSidebarNodeID.agentTasks,
            nodeType: .agentTasksAll,
            displayName: "Tasks",
            iconName: "checklist",
            displayCount: totalTasks > 0 ? totalTasks : nil
        )
        tasksNode.treeDepth = 0
        var nodes: [ImbibSidebarNode] = []
        var stateNodes: [ImbibSidebarNode] = []
        for state in AgentStoreReader.taskStates {
            let count = reader.taskCount(state: state)
            guard count > 0 else { continue }
            var stateNode = ImbibSidebarNode(
                id: ImbibSidebarNodeID.agentTaskState(state),
                nodeType: .agentTaskState(state),
                displayName: AgentStoreReader.stateDisplayName(state),
                iconName: AgentStoreReader.stateIcon(state),
                displayCount: count
            )
            stateNode.treeDepth = 1
            stateNodes.append(stateNode)
        }
        tasksNode.hasTreeChildren = !stateNodes.isEmpty
        nodes.append(tasksNode)
        nodes.append(contentsOf: stateNodes)
        let runCount = reader.runCount()
        nodes.append(ImbibSidebarNode(
            id: ImbibSidebarNodeID.agentRuns,
            nodeType: .agentRunsAll,
            displayName: "Runs",
            iconName: "bolt",
            displayCount: runCount > 0 ? runCount : nil
        ))
        return nodes
    }

    // MARK: Mail (Stage 2-A)

    /// Top-level children of the Mail sidebar section: All Inboxes, then one
    /// node per mail-account with its folders as tree children (flat
    /// pre-order list with `treeDepth`, same shape as figureFolderNodes).
    /// Read-only by design — IMAP owns account/folder lifecycle.
    private func mailChildren() -> [ImbibSidebarNode] {
        let reader = MailStoreReader.shared
        let inboxFolders = reader.fetchInboxFolders()
        let allInboxCount = inboxFolders.reduce(0) { $0 + reader.messageCount(inFolder: $1.id) }
        var nodes: [ImbibSidebarNode] = [
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.mailAllInboxes,
                nodeType: .mailAllInboxes,
                displayName: "All Inboxes",
                iconName: "tray.2",
                displayCount: allInboxCount > 0 ? allInboxCount : nil
            ),
        ]
        for account in reader.fetchAccounts() {
            let payload = MailStoreReader.accountPayload(from: account)
            let folders = Self.roleSortedMailFolders(
                reader.fetchFolders(accountID: account.id))
            var accountNode = ImbibSidebarNode(
                id: ImbibSidebarNodeID.mailAccount(account.id),
                nodeType: .mailAccount(account.id),
                displayName: payload?.name ?? payload?.address ?? "Account",
                iconName: "person.crop.circle"
            )
            accountNode.treeDepth = 0
            accountNode.hasTreeChildren = !folders.isEmpty
            nodes.append(accountNode)
            for folder in folders {
                let folderPayload = MailStoreReader.folderPayload(from: folder)
                var folderNode = ImbibSidebarNode(
                    id: ImbibSidebarNodeID.mailFolder(folder.id),
                    nodeType: .mailFolder(folder.id),
                    displayName: folderPayload?.name ?? "Folder",
                    iconName: Self.mailFolderIcon(role: folderPayload?.role)
                )
                let count = reader.messageCount(inFolder: folder.id)
                folderNode.displayCount = count > 0 ? count : nil
                folderNode.treeDepth = 1
                nodes.append(folderNode)
            }
        }
        return nodes
    }

    /// Role-ordered folder sort: inbox/drafts/sent/archive/trash/spam first,
    /// then custom folders by payload sort_order, then name.
    private static func roleSortedMailFolders(_ folders: [SharedItemRow]) -> [SharedItemRow] {
        let roleOrder: [String: Int] = [
            "inbox": 0, "drafts": 1, "sent": 2, "archive": 3, "trash": 4, "spam": 5,
        ]
        struct Sortable {
            let row: SharedItemRow
            let roleRank: Int
            let sortOrder: Int
            let name: String
        }
        return folders.map { row -> Sortable in
            let payload = MailStoreReader.folderPayload(from: row)
            return Sortable(
                row: row,
                roleRank: payload?.role.flatMap { roleOrder[$0] } ?? 100,
                sortOrder: payload?.sortOrder ?? 0,
                name: payload?.name ?? "")
        }
        .sorted { ($0.roleRank, $0.sortOrder, $0.name) < ($1.roleRank, $1.sortOrder, $1.name) }
        .map(\.row)
    }

    private static func mailFolderIcon(role: String?) -> String {
        switch role {
        case "inbox": return "tray"
        case "sent": return "paperplane"
        case "drafts": return "doc"
        case "trash": return "trash"
        case "archive": return "archivebox"
        case "spam": return "xmark.bin"
        default: return "folder"
        }
    }

    // MARK: Figures (Stage 2-B)

    /// Top-level children of the Figures sidebar section: All Figures,
    /// Unfiled, then the user's figure-collection folder tree.
    private func figuresChildren() -> [ImbibSidebarNode] {
        let figures = FigureStoreReader.shared.fetchFigures()
        let unfiledCount = figures.filter { $0.parentId == nil }.count
        var nodes: [ImbibSidebarNode] = [
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.figuresAll,
                nodeType: .figuresAll,
                displayName: "All Figures",
                iconName: "photo.on.rectangle",
                displayCount: figures.isEmpty ? nil : figures.count
            ),
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.figuresUnfiled,
                nodeType: .figuresUnfiled,
                displayName: "Unfiled",
                iconName: "tray",
                displayCount: unfiledCount > 0 ? unfiledCount : nil
            ),
        ]
        nodes.append(contentsOf: figureFolderNodes(figures: figures))
        return nodes
    }

    /// User folders (figure-collection items) as sidebar children of the
    /// Figures section, nested via envelope `parent` (unlike manuscript
    /// folders, which nest via payload parent_collection_ref). Emits a FLAT,
    /// pre-order list carrying `treeDepth`/`hasTreeChildren` — the same
    /// shape manuscriptFolderNodes uses for the tree flattener.
    private func figureFolderNodes(figures: [SharedItemRow]) -> [ImbibSidebarNode] {
        let folders = FigureStoreReader.shared.fetchFolders()
        guard !folders.isEmpty else { return [] }

        var figureCounts: [String: Int] = [:]
        for figure in figures {
            if let parent = figure.parentId {
                figureCounts[parent, default: 0] += 1
            }
        }

        struct FolderEntry {
            let id: String
            let name: String
            let sortOrder: Int
            let parentID: String?
        }
        let entries = folders.map { row -> FolderEntry in
            let payload = FigureStoreReader.folderPayload(from: row)
            return FolderEntry(
                id: row.id,
                name: payload?.name ?? "Untitled Folder",
                sortOrder: payload?.sortOrder ?? 0,
                parentID: row.parentId)
        }

        func makeNode(_ folder: FolderEntry, depth: Int) -> [ImbibSidebarNode] {
            let childFolders = entries
                .filter { $0.parentID == folder.id }
                .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            var node = ImbibSidebarNode(
                id: ImbibSidebarNodeID.recordFolder(CollectionBindingID.figure, folder.id),
                nodeType: .recordFolder(
                    bindingID: CollectionBindingID.figure, folderID: folder.id),
                displayName: folder.name,
                iconName: "folder"
            )
            let count = figureCounts[folder.id] ?? 0
            node.displayCount = count > 0 ? count : nil
            node.treeDepth = depth
            node.hasTreeChildren = !childFolders.isEmpty
            var result = [node]
            for child in childFolders {
                result.append(contentsOf: makeNode(child, depth: depth + 1))
            }
            return result
        }

        return entries
            .filter { $0.parentID == nil }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .flatMap { makeNode($0, depth: 0) }
    }

    // MARK: Journal (per ADR-0011 D8)

    /// Top-level children of the Journal sidebar section. Five fixed nodes:
    /// All Manuscripts, Drafts, Submitted, Published, Archive, plus the
    /// Submissions inbox.
    ///
    /// Counts are intentionally omitted in Phase 2 — the sidebar build is
    /// synchronous and `ManuscriptBridge` is an actor. A snapshot pattern
    /// (mirroring `CitedInManuscriptsSnapshot`) can layer counts on later
    /// without changing this structure.
    private func journalChildren() -> [ImbibSidebarNode] {
        let descriptor = ManuscriptRecordKind.descriptor
        var nodes: [ImbibSidebarNode] = [
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.journalAll,
                nodeType: .journalAll,
                displayName: "All \(descriptor.pluralDisplayName)",
                iconName: SidebarSectionType.manuscripts.icon
            )
        ]
        // The four statuses this section has surfaced since ADR-0011 D8.
        //
        // Their LABELS and ICONS are now the descriptor's `StatusSpec`s — the
        // same declaration the iOS sidebar and the status badge read, so the
        // three copies of "Drafts"/pencil that used to exist cannot drift.
        //
        // Which four is still a LITERAL, and deliberately so: the descriptor
        // declares seven statuses and iOS's `RecordSidebarBuilder` shows six
        // (all but the dismissed one, which owns the Dismissed section).
        // macOS has never shown Internal Review or In Revision here.
        // Reconciling that is a product decision — it either adds two rows to
        // macOS or removes two from iOS — so it is reported as remaining debt
        // rather than smuggled into a refactor whose contract is that macOS
        // does not change. `hiddenByDefault` is the seam it would use.
        for status in [
            JournalManuscriptStatus.draft, .submitted, .published, .archived,
        ] {
            nodes.append(ImbibSidebarNode(
                id: ImbibSidebarNodeID.journalByStatus(status),
                nodeType: .journalByStatus(status),
                displayName: RecordStatusPresentation.label(for: status.rawValue),
                iconName: RecordStatusPresentation.systemImage(for: status.rawValue)
            ))
        }
        // Reviewer-facing inbox — hidden in the authoring-only imprint shell.
        if shellConfiguration.auxiliaryRoutes.contains(.submissionsInbox) {
            nodes.append(ImbibSidebarNode(
                id: ImbibSidebarNodeID.journalSubmissions,
                nodeType: .journalSubmissions,
                displayName: "Submissions",
                iconName: "tray.and.arrow.down"
            ))
        }
        return nodes + manuscriptFolderNodes()
    }

    /// User folders (manuscript-collection items) as sidebar children of the
    /// Manuscripts section, nested via parentId (GUI-meld plan §5). Emits a
    /// FLAT, pre-order list carrying `treeDepth`/`hasTreeChildren` — the same
    /// shape the publication-collection nodes use for the tree flattener.
    private func manuscriptFolderNodes() -> [ImbibSidebarNode] {
        let folders = RustStoreAdapter.shared.listManuscriptCollections()
        guard !folders.isEmpty else { return [] }

        func makeNode(_ folder: ManuscriptCollectionRow, depth: Int) -> [ImbibSidebarNode] {
            let childFolders = folders
                .filter { $0.parentId == folder.id }
                .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            var node = ImbibSidebarNode(
                id: ImbibSidebarNodeID.recordFolder(CollectionBindingID.manuscript, folder.id),
                nodeType: .recordFolder(
                    bindingID: CollectionBindingID.manuscript, folderID: folder.id),
                displayName: folder.name,
                iconName: folder.isSmart ? "folder.badge.gearshape" : "folder"
            )
            node.displayCount = folder.manuscriptCount > 0 ? Int(folder.manuscriptCount) : nil
            node.treeDepth = depth
            node.hasTreeChildren = !childFolders.isEmpty
            var result = [node]
            for child in childFolders {
                result.append(contentsOf: makeNode(child, depth: depth + 1))
            }
            return result
        }

        return folders
            .filter { $0.parentId == nil }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .flatMap { makeNode($0, depth: 0) }
    }

    // MARK: Review Queue

    /// One pseudo-row representing the pending agent review-requests
    /// (`review-request@1.0.0` items in the shared impress store). Badge
    /// shows the unresolved count; the section itself is hidden when zero
    /// (see `shouldShowSection`).
    private func reviewQueueChildren() -> [ImbibSidebarNode] {
        let count = RustStoreAdapter.shared.countPendingReviews()
        guard count > 0 else { return [] }
        return [
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.reviewQueue,
                nodeType: .reviewQueue,
                displayName: "Pending Reviews",
                iconName: "checklist",
                displayCount: count
            )
        ]
    }

    // MARK: Cited in Manuscripts

    /// One pseudo-row that represents the full "cited in manuscripts"
    /// smart library. Selecting it loads the list of publications that
    /// appear in any imprint manuscript's citation-usage records.
    private func citedInManuscriptsChildren() -> [ImbibSidebarNode] {
        let count = CitedInManuscriptsSnapshot.shared.citedPaperIDs.count
        guard count > 0 else { return [] }
        return [
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.citedInManuscripts,
                nodeType: .citedInManuscripts,
                displayName: "All Cited Papers",
                iconName: "text.book.closed.fill",
                displayCount: count
            )
        ]
    }

    // MARK: Inbox

    private func inboxChildren() -> [ImbibSidebarNode] {
        var nodes: [ImbibSidebarNode] = []

        // "Recent" — papers the user viewed or added by hand. Sits above the
        // feeds because it is about the user's own activity, not ingest.
        nodes.append(
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.recent,
                nodeType: .recent,
                displayName: "Recent",
                iconName: "clock.arrow.circlepath"
            )
        )

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
                // Check via Rust store for collections and library feeds
                let collections = store.listCollections(libraryId: library.id)
                let feeds = store.listSmartSearches(libraryId: library.id)
                    .filter { $0.autoRefreshEnabled && !$0.feedsToInbox }
                let hasCollections = !collections.isEmpty || !feeds.isEmpty
                let count = library.publicationCount
                let starred = store.countStarred(parentId: library.id)
                return ImbibSidebarNode(
                    id: library.id,
                    nodeType: .library(libraryID: library.id),
                    displayName: library.name,
                    iconName: "book.closed",
                    displayCount: count > 0 ? count : nil,
                    starCount: starred > 0 ? starred : nil,
                    hasTreeChildren: hasCollections
                )
            }
    }

    private func libraryCollectionChildren(libraryID: UUID) -> [ImbibSidebarNode] {
        var nodes: [ImbibSidebarNode] = []

        // Library feeds (auto-refresh smart searches in this library, not inbox-bound)
        let feeds = store.listSmartSearches(libraryId: libraryID)
            .filter { $0.autoRefreshEnabled && !$0.feedsToInbox }
        for feed in feeds {
            nodes.append(makeLibraryFeedNode(feed, libraryID: libraryID))
        }

        // Collections
        let collections = store.listCollections(libraryId: libraryID)
        let collectionNodes = collections
            .filter { $0.parentID == nil }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
            .map { makeLibraryCollectionNode($0, libraryID: libraryID, allCollections: collections, depth: 1) }

        nodes.append(contentsOf: collectionNodes)
        return nodes
    }

    private func makeLibraryFeedNode(_ feed: SmartSearch, libraryID: UUID) -> ImbibSidebarNode {
        let unread = unreadCountForFeed(feed)
        return ImbibSidebarNode(
            id: feed.id,
            nodeType: .libraryFeed(feedID: feed.id, libraryID: libraryID),
            displayName: feed.name,
            iconName: feed.isGroupFeed ? "person.3.fill" : "antenna.radiowaves.left.and.right",
            displayCount: unread > 0 ? unread : nil,
            treeDepth: 1
        )
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
                // The shared cross-platform mapping (ImpressFTUI) — adaptive,
                // so a dark-mode sidebar no longer shows the light hexes.
                iconColor: color.displayColor
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
        if shellConfiguration.recordKind(for: .dismissed) == .manuscript {
            let count = RustStoreAdapter.shared.countManuscripts(
                status: JournalManuscriptStatus.dismissed.rawValue)
            return [ImbibSidebarNode(
                id: ImbibSidebarNodeID.dismissed,
                nodeType: .dismissed,
                displayName: "Dismissed",
                iconName: "xmark.circle",
                displayCount: count > 0 ? count : nil
            )]
        }
        guard let lib = libraryManager?.dismissedLibrary else { return [] }
        let count = lib.publicationCount
        guard count > 0 else { return [] }
        let starred = store.countStarred(parentId: lib.id)
        return [ImbibSidebarNode(
            id: ImbibSidebarNodeID.dismissed,
            nodeType: .dismissed,
            displayName: "Dismissed",
            iconName: "xmark.circle",
            displayCount: count,
            starCount: starred > 0 ? starred : nil
        )]
    }

    // MARK: - Collection Folders (ADR-0022 D3)
    //
    // ONE folder pattern for every record kind that has one, and — since the
    // Stage-3 collapse — one NODE case too (`.recordFolder(bindingID:
    // folderID:)`). Everything else follows from the kind's
    // `CollectionCapability` and runs through `CollectionStoreAdapter` (the
    // Rust collection kernel): capabilities, menus, rename, reparent, reorder,
    // delete, drops. Adding a kind's folders is now a descriptor capability
    // plus the lines that BUILD its nodes; no site below gains an arm.

    /// The collection capability + folder id behind a sidebar folder node,
    /// or nil when the node is not a collection folder.
    ///
    /// Total over `CollectionCapability` (ADR-0022 G2's strangler goal): the
    /// `migratedFolderBindings` gate this used to consult is gone. It listed
    /// `{manuscript, figure}`, which is exactly the set of bindings a shipped
    /// descriptor declares, so it had become a no-op — and while it existed, a
    /// newly declared capability would have been silently read-only.
    ///
    /// The lookup is kind-INTRINSIC (`BuiltinRecordKinds`, not
    /// `shellConfiguration.recordKinds`): imbib's preset does not register the
    /// figure kind, yet the chassis it shares renders the Figures section.
    private func folderNode(
        _ node: ImbibSidebarNode
    ) -> (capability: CollectionCapability, folderID: String)? {
        guard case .recordFolder(let bindingID, let folderID) = node.nodeType,
              let capability = BuiltinRecordKinds.collectionCapability(forBindingID: bindingID)
        else { return nil }
        return (capability, folderID)
    }

    /// The capability whose folder tree a section header hosts. The header is
    /// the "move to root" drop target and the "New Folder" menu host.
    ///
    /// Stage 3: the `case .manuscripts / case .figures` switch is gone. A
    /// section hosts a folder tree when it is a kind's HOME section
    /// (`SidebarSectionType.role == .primary` — the declaration
    /// `RecordSidebarSectionRole` already reads) and that kind declares a
    /// collection capability.
    ///
    /// The section→kind table is `AppShellConfiguration.impress`'s: it is the
    /// canonical one (ADR-0022 D9 — the unifying preset names a kind for every
    /// section), and it is deliberately NOT the running shell's. imprint binds
    /// `.flagged: .manuscript`; if this consulted the live shell, imprint's
    /// Flagged header would sprout "New Folder" and accept folder drops. The
    /// `.primary` gate guards that independently, so both halves have to
    /// agree before a header hosts folders.
    ///
    /// Stays `static` (its callers are instance methods, but nothing here
    /// depends on instance state) — the descriptor agent's report noted the
    /// 2-arm switch survived BECAUSE it was static; it turns out it did not
    /// need the shell, only the canonical table.
    private static let canonicalSectionKinds = AppShellConfiguration.impress.sectionBindings

    private static func folderCapability(
        ofSection section: SidebarSectionType
    ) -> CollectionCapability? {
        guard section.role == .primary,
              let kind = canonicalSectionKinds[section] else { return nil }
        return BuiltinRecordKinds.registry[kind]?.collection
    }

    /// Sidebar node id for a folder of `bindingID` (node ids are DERIVED for
    /// folders — unlike collections, node id != item id).
    private static func folderNodeID(_ bindingID: String, _ folderID: String) -> UUID {
        ImbibSidebarNodeID.recordFolder(bindingID, folderID)
    }

    /// The folder of `bindingID` the content pane currently shows, if any.
    ///
    /// Returns a `UUID` rather than the node's raw string: the route carries
    /// the folder as a UUID, and callers compare against store id STRINGS,
    /// whose case the store does not guarantee (`UUID().uuidString` is
    /// uppercase, the store's canonical form is lowercase — see the imbib
    /// CLAUDE.md invariant). Comparing UUIDs removes that trap instead of
    /// re-creating it at the boundary.
    private func selectedFolderID(_ bindingID: String) -> UUID? {
        guard case .record(let route) = selectedTab,
              let folderID = route.scope.folderID,
              BuiltinRecordKinds.registry[route.kind]?.collection?.bindingID == bindingID
        else { return nil }
        return folderID
    }

    /// The in-process drag record backing a kind's list rows.
    ///
    /// G2 remainder #5 (done): the two identical per-kind singletons merged
    /// into `RecordDragSession`, one instance per collection binding, so this
    /// is a registry lookup rather than a switch. Bindings whose rows never
    /// call `begin(ids:)` simply hand back an empty payload.
    @MainActor
    private static func dragSession(for bindingID: String) -> RecordDragSessionProviding? {
        RecordDragSession.shared(for: bindingID)
    }

    /// Where a record drop of `capability`'s kind may land.
    private enum FolderDropTarget {
        case folder(String)
        /// The kind's "Unfiled" pseudo-row: drop clears the record's folder.
        case unfiled
    }

    private func folderDropTarget(
        _ node: ImbibSidebarNode?, capability: CollectionCapability
    ) -> FolderDropTarget? {
        guard let node else { return nil }
        if let folder = folderNode(node), folder.capability.bindingID == capability.bindingID {
            return .folder(folder.folderID)
        }
        // Only envelope-filed kinds have an Unfiled row today (Figures).
        if case .figuresUnfiled = node.nodeType,
           capability.bindingID == CollectionBindingID.figure {
            return .unfiled
        }
        return nil
    }

    // MARK: - Capabilities

    private func capabilities(of node: ImbibSidebarNode) -> TreeNodeCapabilities {
        switch node.nodeType {
        case .section(.inbox):
            return [.draggable, .droppable]
        case .section:
            return .draggable
        case .library:
            return [.draggable, .droppable, .renamable, .deletable]
        case .libraryCollection:
            return [.draggable, .droppable, .renamable, .deletable]
        case .inboxFeed:
            return [.renamable, .deletable]
        case .libraryFeed:
            return [.renamable, .deletable]
        case .inboxCollection:
            return [.renamable, .deletable]
        case .searchForm:
            return .draggable
        case .flagColor:
            return .draggable
        case .scixLibrary:
            return [.draggable, .droppable]
        case .explorationSearch:
            return .draggable
        case .explorationCollection:
            return [.draggable, .deletable]
        case .allArtifacts, .artifactType:
            return .droppable
        case .recordFolder:
            // ADR-0022 D3: the folder verbs are the kind's capability, not a
            // per-kind literal. `canOrganize == false` = read-only rows.
            return folderNode(node)?.capability.canOrganize == true
                ? [.draggable, .droppable, .renamable, .deletable]
                : .readOnly
        case .figuresUnfiled:
            // Drop target only: dropping figures here clears their folder.
            return .droppable
        case .mailAllInboxes, .mailAccount, .mailFolder:
            // Stage 2-A: IMAP owns account/folder lifecycle — mail nodes are
            // read-only (no rename/delete/drag/drop; matrix ➖ with note).
            return .readOnly
        case .agentTasksAll, .agentRunsAll, .agentTaskState:
            // Stage 2-C: the kernel owns task lifecycle — agent nodes are
            // read-only fixed rows (no rename/delete/drag/drop; matrix ➖).
            return .readOnly
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
        // Drag exploration search → Inbox to create a scheduled feed
        case (.explorationSearch, .section(.inbox)):
            return true
        case (.explorationSearch, .inboxCollection):
            return true
        default:
            // Collection folders (manuscripts, figures) — ADR-0022 D3.
            return canAcceptFolderDrop(dragged, target: target)
        }
    }

    /// Collection folders (ADR-0022 D3): nest under a folder of the SAME
    /// binding (never itself, never one of its own descendants) or drop on
    /// the owning section header to move back to root.
    ///
    /// The ancestor walk here is drag FEEDBACK only — the authoritative cycle
    /// check is the Rust kernel's, inside `CollectionStoreAdapter.reparent`.
    private func canAcceptFolderDrop(
        _ dragged: ImbibSidebarNode, target: ImbibSidebarNode
    ) -> Bool {
        guard let drag = folderNode(dragged), drag.capability.canOrganize else { return false }
        if let targetFolder = folderNode(target) {
            guard targetFolder.capability.bindingID == drag.capability.bindingID,
                  targetFolder.folderID != drag.folderID else { return false }
            return !CollectionStoreAdapter.shared.isAncestor(
                drag.capability.bindingID,
                ancestorID: drag.folderID,
                of: targetFolder.folderID)
        }
        if case .section(let section) = target.nodeType {
            return Self.folderCapability(ofSection: section)?.bindingID == drag.capability.bindingID
        }
        return false
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

        case .recordFolder:
            // Collection folders (ADR-0022 D3) reorder within a parent folder;
            // only the folder rows carry sort_order, so the fixed rows are
            // filtered out first and positions are indexes into the filtered
            // list (unchanged).
            reorderFolders(siblings)

        case .section(let section) where Self.folderCapability(ofSection: section) != nil:
            // …or among the hosting section's fixed rows. Stage 3: resolved
            // from the capability, so this arm covers every folder-capable
            // kind (it named `.manuscripts` and `.figures` explicitly). It
            // sits after the specific `.section(...)` arms above, which Swift
            // matches first.
            reorderFolders(siblings)

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

    /// Reorder the collection-folder rows of a sibling list (ADR-0022 D3).
    /// Grouped by binding so a mixed list can never cross-number two trees;
    /// in practice a sibling list is homogeneous by construction.
    private func reorderFolders(_ siblings: [ImbibSidebarNode]) {
        var idsByBinding: [String: [String]] = [:]
        for node in siblings {
            guard let folder = folderNode(node), folder.capability.canOrganize else { continue }
            idsByBinding[folder.capability.bindingID, default: []].append(folder.folderID)
        }
        for (bindingID, ids) in idsByBinding {
            CollectionStoreAdapter.shared.reorder(bindingID, ids: ids)
        }
        // Bumped unconditionally, exactly as `reorderCollections` did — a
        // sibling list with no folder rows still repaints.
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
        // Handle exploration search → inbox feed conversion
        if case .explorationSearch(let searchID) = node.nodeType,
           let newParent = newParent {
            let isInboxTarget: Bool
            switch newParent.nodeType {
            case .section(.inbox), .inboxCollection:
                isInboxTarget = true
            default:
                isInboxTarget = false
            }
            if isInboxTarget {
                convertExplorationToFeed(searchID: searchID)
                return
            }
        }

        // Collection folders (ADR-0022 D3): ONE path for every binding. Where
        // the tree parent lives — payload `parent_collection_ref` for
        // manuscripts, the envelope parent for figures — is the kernel's
        // business, and so is the cycle check (the Swift walk below is only
        // the drag-feedback pre-check that already ran in `canAcceptDrop`).
        if let folder = folderNode(node), folder.capability.canOrganize {
            guard let newParent else { return }
            let adapter = CollectionStoreAdapter.shared
            let bindingID = folder.capability.bindingID
            if let target = folderNode(newParent) {
                guard target.capability.bindingID == bindingID,
                      target.folderID != folder.folderID,
                      !adapter.isAncestor(
                        bindingID, ancestorID: folder.folderID, of: target.folderID)
                else { return }
                adapter.reparent(bindingID, id: folder.folderID, newParentID: target.folderID)
            } else if case .section(let section) = newParent.nodeType,
                      Self.folderCapability(ofSection: section)?.bindingID == bindingID {
                adapter.reparent(bindingID, id: folder.folderID, newParentID: nil)
            } else {
                return
            }
            bumpDataVersion()
            return
        }

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

    /// Convert an exploration smart search into an inbox feed.
    private func convertExplorationToFeed(searchID: UUID) {
        guard let search = store.getSmartSearch(id: searchID) else { return }

        // Create new inbox feed with the exploration search's properties
        let feed = store.createInboxFeed(
            name: search.name,
            query: search.query,
            sourceIDs: search.sourceIDs,
            refreshIntervalSeconds: Int64(RefreshIntervalPreset.daily.rawValue)
        )

        if feed != nil {
            // Delete the original exploration search (move semantics)
            store.deleteItem(id: searchID)
            Self.logger.info("Converted exploration search '\(search.name)' to inbox feed")
        }

        bumpDataVersion()
    }

    // `isAncestorManuscriptFolder` lived here; the walk is now
    // `CollectionStoreAdapter.isAncestor(_:ancestorID:of:)`, one
    // implementation over the kernel's flat tree for every binding — and the
    // authoritative cycle check moved into Rust with it (ADR-0022 D1).

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
        // Record rows dropped onto one of their kind's folders (ADR-0022 D3).
        // The pasteboard type comes from the kind's CollectionCapability and
        // the membership mechanics (Contains edge vs. envelope parent) are
        // the kernel's — the sidebar only picks the binding.
        for descriptor in BuiltinRecordKinds.collectionCapable {
            guard let capability = descriptor.collection,
                  capability.canOrganize,
                  let identifier = capability.dragUTTypeIdentifier else { continue }
            let pasteboardType = NSPasteboard.PasteboardType(identifier)
            guard pasteboard.types?.contains(pasteboardType) == true else { continue }
            return handleRecordDrop(
                pasteboard: pasteboard,
                pasteboardType: pasteboardType,
                descriptor: descriptor,
                capability: capability,
                target: target)
        }

        // Handle publication ID drops
        if let data = pasteboard.data(forType: .init(rawValue: UTType.publicationID.identifier)),
           let target = target {
            let uuids = decodePublicationUUIDs(from: data)
            if !uuids.isEmpty {
                Task { await handlePublicationDrop(uuids, onto: target) }
                return true
            }
        }

        // Handle web URL drops (from browser address bar)
        if pasteboard.types?.contains(.URL) == true,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first, !url.isFileURL, let target = target {
            if isArtifactNode(target) {
                // Route web URLs on artifact nodes to artifact import
                Task { @MainActor in
                    _ = await ArtifactImportHandler.shared.importURL(url, tags: [])
                }
                return true
            }
            if let dropTarget = dropTarget(for: target) {
                let provider = NSItemProvider(object: url as NSURL)
                let info = DragDropInfo(providers: [provider])
                Task {
                    _ = await dragDropCoordinator.performDrop(info, target: dropTarget)
                }
                return true
            }
        }

        // Handle file URL drops
        if pasteboard.types?.contains(.fileURL) == true, let target = target {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
                return false
            }

            // Route drops on artifact nodes to artifact import
            if isArtifactNode(target) {
                let artifactType = artifactTypeForNode(target)
                Task { @MainActor in
                    for url in urls {
                        if url.isFileURL {
                            _ = await ArtifactImportHandler.shared.importFile(
                                at: url,
                                type: artifactType
                            )
                        } else {
                            _ = await ArtifactImportHandler.shared.importURL(url, tags: [])
                        }
                    }
                }
                return true
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

            // Handle PDFs directly — bypass NSItemProvider wrapping which loses file URLs.
            // Copy to temp dir synchronously (while drag session URLs are valid), then escape
            // the NSOutlineView drag tracking run loop mode before starting async work.
            let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            if !pdfURLs.isEmpty {
                if let dropTarget = dropTarget(for: target) {
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("imbib-pdf-drop-\(UUID().uuidString)", isDirectory: true)
                    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    var tempURLs: [URL] = []
                    for url in pdfURLs {
                        let dest = tempDir.appendingPathComponent(url.lastPathComponent)
                        if let _ = try? FileManager.default.copyItem(at: url, to: dest) {
                            tempURLs.append(dest)
                        }
                    }
                    if !tempURLs.isEmpty {
                        let coordinator = dragDropCoordinator
                        let capturedTarget = dropTarget
                        // Delay to escape the drag tracking run loop mode — URLSession
                        // completions are not delivered while AppKit is in drag tracking mode,
                        // causing @MainActor async calls to deadlock.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            Task {
                                let previews = await PDFImportHandler.shared.preparePDFImport(urls: tempURLs, target: capturedTarget)
                                if !previews.isEmpty {
                                    coordinator.pendingDropTarget = capturedTarget
                                    coordinator.pendingPreview = .pdfImport(previews)
                                }
                                // Don't clean up tempDir here — the preview's sourceURL
                                // points to the temp file and is needed when the user confirms.
                                // The OS cleans /tmp periodically.
                            }
                        }
                    }
                }
                return true
            }

            // Route to general file drop handler for other file types
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

    /// File dragged records of one kind into a folder of that kind (or, for
    /// envelope-filed kinds, out of every folder via the Unfiled row).
    ///
    /// This is the single implementation of what used to be one near-copy per
    /// kind. The lazy-pasteboard fallback, the log lines and the return
    /// values are the manuscript path's, verbatim.
    private func handleRecordDrop(
        pasteboard: NSPasteboard,
        pasteboardType: NSPasteboard.PasteboardType,
        descriptor: RecordKindDescriptor,
        capability: CollectionCapability,
        target: ImbibSidebarNode?
    ) -> Bool {
        let noun = descriptor.displayName.lowercased()
        // The pasteboard payload is registered lazily by the SwiftUI list
        // row, so a synchronous read here can return nil — fall back to the
        // in-process drag record before giving up.
        var uuids = pasteboard.data(forType: pasteboardType)
            .map { decodePublicationUUIDs(from: $0) } ?? []
        let viaPasteboard = !uuids.isEmpty
        let dragSession = Self.dragSession(for: capability.bindingID)
        if uuids.isEmpty {
            uuids = dragSession?.take() ?? []
        }

        guard let dropTarget = folderDropTarget(target, capability: capability) else {
            Self.logger.infoCapture(
                "\(noun) drop ignored: target is "
                    + "\(target.map { String(describing: $0.nodeType) } ?? "nil")",
                category: "sidebar")
            return false
        }

        let targetDescription: String
        switch dropTarget {
        case .folder(let folderID): targetDescription = "folder \(folderID)"
        case .unfiled: targetDescription = "Unfiled"
        }

        guard !uuids.isEmpty else {
            Self.logger.warningCapture(
                "\(noun) drop on \(targetDescription) carried no IDs "
                    + "(pasteboard and drag session both empty)",
                category: "sidebar")
            return false
        }

        let itemIDs = uuids.map { $0.uuidString.lowercased() }
        let adapter = CollectionStoreAdapter.shared
        switch dropTarget {
        case .folder(let folderID):
            adapter.addMembers(capability.bindingID, collectionID: folderID, itemIDs: itemIDs)
        case .unfiled:
            adapter.unfile(capability.bindingID, itemIDs: itemIDs)
        }
        _ = dragSession?.take()
        bumpDataVersion()
        Self.logger.infoCapture(
            "dropped \(uuids.count) \(noun)(s) into \(targetDescription) "
                + "(payload via \(viaPasteboard ? "pasteboard" : "drag session"))",
            category: "sidebar")
        return true
    }

    private func dropTarget(for node: ImbibSidebarNode) -> DropTarget? {
        switch node.nodeType {
        case .library(let id):
            return .library(libraryID: id)
        case .libraryCollection(let colID, let libID):
            return .collection(collectionID: colID, libraryID: libID)
        case .section(.inbox):
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

    private func isArtifactNode(_ node: ImbibSidebarNode) -> Bool {
        switch node.nodeType {
        case .allArtifacts, .artifactType: return true
        default: return false
        }
    }

    private func artifactTypeForNode(_ node: ImbibSidebarNode) -> ArtifactType? {
        switch node.nodeType {
        case .artifactType(let rawValue): return ArtifactType(rawValue: rawValue)
        default: return nil  // allArtifacts → nil means auto-detect
        }
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

        case .scixLibrary(let libraryID):
            // Add publications to SciX library (local association; remote sync handled by push flow)
            store.addToScixLibrary(publicationIds: uuids, scixLibraryId: libraryID)
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

        guard let node = findNode(id) else { return }

        // Section headers: map inbox section to .inbox tab directly
        if case .section(let sectionType) = node.nodeType {
            switch sectionType {
            case .inbox:
                selectedTab = .inbox
                ExplorationService.shared.currentExplorationCollectionID = nil
                return
            default:
                return // Other sections not selectable
            }
        }

        guard let tab = node.imbibTab else { return }
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

        case .inboxFeed(let feedID), .libraryFeed(let feedID, _):
            store.updateField(id: feedID, field: "name", value: trimmed)
            bumpDataVersion()

        case .recordFolder:
            // Collection folders (ADR-0022 D3): one rename for every binding.
            // The payload field is `name` for all of them; where the folder
            // NESTS (payload ref vs. envelope parent) is irrelevant here.
            guard let folder = folderNode(node), folder.capability.canOrganize else { break }
            CollectionStoreAdapter.shared.rename(
                folder.capability.bindingID, id: folder.folderID, to: trimmed)
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

        case .inboxFeed(let feedID):
            buildInboxFeedContextMenu(menu, feedID: feedID)

        case .libraryFeed(let feedID, _):
            buildLibraryFeedContextMenu(menu, feedID: feedID)

        case .inboxCollection(let colID):
            buildInboxCollectionContextMenu(menu, collectionID: colID)

        case .searchForm(let formType):
            buildSearchFormContextMenu(menu, formType: formType)

        case .explorationCollection(let colID):
            let deleteItem = NSMenuItem(title: "Delete", action: #selector(ContextMenuActions.deleteExplorationCollection(_:)), keyEquivalent: "")
            deleteItem.target = ContextMenuActions.shared
            deleteItem.representedObject = colID
            menu.addItem(deleteItem)

        case .explorationSearch(let searchID):
            // Exploration smart searches lost their context menu when the
            // SwiftUI sidebar was replaced by the NSOutlineView chassis
            // (b748151): the node kind never got a branch here, so right-click
            // produced no menu at all and the search could not be deleted.
            let deleteItem = NSMenuItem(title: "Delete Search", action: #selector(ContextMenuActions.deleteExplorationSearch(_:)), keyEquivalent: "")
            deleteItem.target = ContextMenuActions.shared
            deleteItem.representedObject = searchID
            menu.addItem(deleteItem)

        case .scixLibrary(let libraryID):
            buildSciXLibraryContextMenu(menu, libraryID: libraryID)

        case .recordFolder:
            guard let folder = folderNode(node) else { return nil }
            buildFolderContextMenu(
                menu, capability: folder.capability, folderID: folder.folderID, nodeID: node.id)

        default:
            Self.logger.infoCapture(
                "Sidebar context menu: no items for node kind \(String(describing: node.nodeType)) ('\(node.displayName)')",
                category: "sidebar"
            )
            return nil
        }

        Self.logger.infoCapture(
            "Sidebar context menu: \(menu.items.count) item(s) for '\(node.displayName)' (\(String(describing: node.nodeType)))",
            category: "sidebar"
        )
        return menu.items.isEmpty ? nil : menu
    }

    private func buildMultiSelectionContextMenu(for nodes: [ImbibSidebarNode]) -> NSMenu? {
        // Same-kind branches only — mixed-kind multi-selection falls through to nil
        // (which lets NSOutlineView fall back to the single-item menu for the
        // right-clicked node). Each branch returns its own menu.
        // Exception: the Exploration section mixes searches and collections,
        // so branch 4 treats them as one deletable kind.
        Self.logger.infoCapture(
            "Sidebar multi-selection context menu: \(nodes.count) node(s) — \(nodes.map(\.displayName).prefix(6).joined(separator: ", "))",
            category: "sidebar"
        )

        // 1. All-libraries multi-selection.
        let libraryIDs = nodes.compactMap { node -> UUID? in
            if case .library(let libID) = node.nodeType { return libID }
            return nil
        }
        if libraryIDs.count == nodes.count, libraryIDs.count >= 2 {
            let menu = NSMenu()
            let item = NSMenuItem(
                title: "Delete \(libraryIDs.count) Libraries…",
                action: #selector(ContextMenuActions.deleteMultipleLibraries(_:)),
                keyEquivalent: ""
            )
            item.target = ContextMenuActions.shared
            item.representedObject = libraryIDs
            menu.addItem(item)
            return menu
        }

        // 2. All-regular-collections multi-selection (`.libraryCollection`).
        let regularCollectionIDs = nodes.compactMap { node -> UUID? in
            if case .libraryCollection(let colID, _) = node.nodeType { return colID }
            return nil
        }
        if regularCollectionIDs.count == nodes.count, regularCollectionIDs.count >= 2 {
            let menu = NSMenu()
            let item = NSMenuItem(
                title: "Delete \(regularCollectionIDs.count) Collections…",
                action: #selector(ContextMenuActions.deleteMultipleCollections(_:)),
                keyEquivalent: ""
            )
            item.target = ContextMenuActions.shared
            item.representedObject = regularCollectionIDs
            menu.addItem(item)
            return menu
        }

        // 3. All-exploration-collections (existing behavior, unchanged).
        let explorationIDs = nodes.compactMap { node -> UUID? in
            if case .explorationCollection(let colID) = node.nodeType { return colID }
            return nil
        }
        if explorationIDs.count == nodes.count, !explorationIDs.isEmpty {
            let menu = NSMenu()
            let count = explorationIDs.count
            let deleteItem = NSMenuItem(
                title: "Delete \(count) Collections",
                action: #selector(ContextMenuActions.deleteMultipleExplorationCollections(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = ContextMenuActions.shared
            deleteItem.representedObject = explorationIDs
            menu.addItem(deleteItem)
            return menu
        }

        // 4. Exploration searches, alone or mixed with exploration collections.
        //    The Exploration section is mostly smart searches, so this is the
        //    branch the user's "delete many Explorations at once" needs.
        let explorationSearchIDs = nodes.compactMap { node -> UUID? in
            if case .explorationSearch(let searchID) = node.nodeType { return searchID }
            return nil
        }
        if !explorationSearchIDs.isEmpty,
           explorationSearchIDs.count + explorationIDs.count == nodes.count {
            let menu = NSMenu()
            let total = explorationSearchIDs.count + explorationIDs.count
            let title = explorationIDs.isEmpty
                ? "Delete \(total) Searches"
                : "Delete \(total) Items"
            let deleteItem = NSMenuItem(
                title: title,
                action: #selector(ContextMenuActions.deleteMultipleExplorationItems(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = ContextMenuActions.shared
            deleteItem.representedObject = [
                "searches": explorationSearchIDs,
                "collections": explorationIDs,
            ] as [String: [UUID]]
            menu.addItem(deleteItem)
            return menu
        }

        Self.logger.infoCapture(
            "Sidebar multi-selection context menu: mixed kinds — falling back to the single-row menu",
            category: "sidebar"
        )
        return nil
    }

    func deleteExplorationCollections(_ collectionIDs: [UUID]) {
        deleteExplorationItems(searchIDs: [], collectionIDs: collectionIDs)
    }

    /// Delete Exploration smart searches (the "lightbulb" rows in the
    /// Exploration section). Same semantics as the iOS sidebar's swipe-delete
    /// and the pre-chassis macOS sidebar: the search definition goes away, the
    /// papers it pulled into the Exploration library stay put.
    func deleteExplorationSearches(_ searchIDs: [UUID]) {
        deleteExplorationItems(searchIDs: searchIDs, collectionIDs: [])
    }

    /// Single code path for deleting Exploration rows, one or many, searches
    /// and/or collections. Bulk deletes are wrapped in a store batch so the
    /// sidebar/list rebuild once instead of N times; each individual delete is
    /// the same call the single-row menu makes, so undo behaves identically.
    func deleteExplorationItems(searchIDs: [UUID], collectionIDs: [UUID]) {
        let total = searchIDs.count + collectionIDs.count
        guard total > 0 else { return }
        Self.logger.infoCapture(
            "Deleting \(searchIDs.count) exploration search(es) and \(collectionIDs.count) exploration collection(s)",
            category: "sidebar"
        )

        let isBatch = total > 1
        if isBatch { store.beginBatchMutation() }

        for searchID in searchIDs {
            if case .exploration(let id) = selectedTab, id == searchID {
                selectedNodeID = nil
            }
            store.deleteSmartSearch(id: searchID)
        }
        for colID in collectionIDs {
            if case .explorationCollection(let id) = selectedTab, id == colID {
                selectedNodeID = nil
            }
            libraryManager?.deleteExplorationCollection(id: colID)
        }

        if isBatch { store.endBatchMutation() }

        explorationRefreshTrigger = UUID()
        bumpDataVersion()
        Self.logger.infoCapture("Exploration delete complete (\(total) item(s))", category: "sidebar")
    }

    private func buildSectionContextMenu(_ menu: NSMenu, section: SidebarSectionType) {
        switch section {
        case .inbox:
            let addFeedItem = NSMenuItem(title: "Add Feed...", action: #selector(ContextMenuActions.addInboxFeed(_:)), keyEquivalent: "")
            addFeedItem.target = ContextMenuActions.shared
            menu.addItem(addFeedItem)

            let newColItem = NSMenuItem(title: "New Collection", action: #selector(ContextMenuActions.createTopLevelInboxCollection(_:)), keyEquivalent: "")
            newColItem.target = ContextMenuActions.shared
            menu.addItem(newColItem)

        case .libraries:
            let newLibItem = NSMenuItem(title: "New Library", action: #selector(ContextMenuActions.createLibrary(_:)), keyEquivalent: "")
            newLibItem.target = ContextMenuActions.shared
            menu.addItem(newLibItem)

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
            }

        default:
            // ADR-0022 D3: the section that hosts a binding's folder tree
            // offers "New Folder" at root. Stage 3: resolved from the
            // capability (this was `case .manuscripts, .figures:`), so a new
            // folder-capable kind's section gets the item with no arm here.
            // Every section handled above returns before reaching this.
            guard let capability = Self.folderCapability(ofSection: section),
                  capability.canOrganize else { break }
            let newFolderItem = NSMenuItem(title: capability.newContainerTitle, action: #selector(ContextMenuActions.createFolder(_:)), keyEquivalent: "")
            newFolderItem.target = ContextMenuActions.shared
            newFolderItem.representedObject = FolderMenuTarget(
                bindingID: capability.bindingID, folderID: nil)
            menu.addItem(newFolderItem)
        }

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

        let addFeedItem = NSMenuItem(title: "Add Feed...", action: #selector(ContextMenuActions.addLibraryFeed(_:)), keyEquivalent: "")
        addFeedItem.target = ContextMenuActions.shared
        addFeedItem.representedObject = libraryID
        menu.addItem(addFeedItem)

        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: "Export...", action: #selector(ContextMenuActions.exportLibrary(_:)), keyEquivalent: "")
        exportItem.target = ContextMenuActions.shared
        exportItem.representedObject = libraryID
        menu.addItem(exportItem)

        let importItem = NSMenuItem(title: "Import...", action: #selector(ContextMenuActions.importToLibrary(_:)), keyEquivalent: "")
        importItem.target = ContextMenuActions.shared
        importItem.representedObject = libraryID
        menu.addItem(importItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete Library", action: #selector(ContextMenuActions.deleteLibrary(_:)), keyEquivalent: "")
        deleteItem.target = ContextMenuActions.shared
        deleteItem.representedObject = libraryID
        menu.addItem(deleteItem)
    }

    private func buildSciXLibraryContextMenu(_ menu: NSMenu, libraryID: UUID) {
        if let remoteID = scixRepository.libraries.first(where: { $0.id == libraryID })?.remoteID {
            let openItem = NSMenuItem(title: "Open on SciX", action: #selector(ContextMenuActions.openSciXLibraryOnWeb(_:)), keyEquivalent: "")
            openItem.target = ContextMenuActions.shared
            openItem.representedObject = remoteID
            menu.addItem(openItem)
            menu.addItem(.separator())
        }

        let refreshItem = NSMenuItem(title: "Refresh Papers", action: #selector(ContextMenuActions.refreshSciXLibraryPapers(_:)), keyEquivalent: "")
        refreshItem.target = ContextMenuActions.shared
        refreshItem.representedObject = libraryID
        menu.addItem(refreshItem)

        let editItem = NSMenuItem(title: "Edit Library…", action: #selector(ContextMenuActions.editSciXLibrary(_:)), keyEquivalent: "")
        editItem.target = ContextMenuActions.shared
        editItem.representedObject = libraryID
        menu.addItem(editItem)

        let collaboratorsItem = NSMenuItem(title: "Manage Collaborators…", action: #selector(ContextMenuActions.manageSciXCollaborators(_:)), keyEquivalent: "")
        collaboratorsItem.target = ContextMenuActions.shared
        collaboratorsItem.representedObject = libraryID
        menu.addItem(collaboratorsItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete Library…", action: #selector(ContextMenuActions.deleteSciXLibrary(_:)), keyEquivalent: "")
        deleteItem.target = ContextMenuActions.shared
        deleteItem.representedObject = libraryID
        menu.addItem(deleteItem)
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

            menu.addItem(.separator())
        }

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(ContextMenuActions.deleteCollection(_:)), keyEquivalent: "")
        deleteItem.target = ContextMenuActions.shared
        deleteItem.representedObject = collectionID
        menu.addItem(deleteItem)
    }

    /// Context menu for a collection folder of ANY binding (ADR-0022 D3).
    /// The manuscript and figure menus were already label-for-label
    /// identical — Rename / New Subfolder / ─── / Delete Folder — so the
    /// merge is literal; only the represented objects carry the binding now.
    private func buildFolderContextMenu(
        _ menu: NSMenu, capability: CollectionCapability, folderID: String, nodeID: UUID
    ) {
        guard capability.canOrganize else { return }

        let renameItem = NSMenuItem(title: "Rename", action: #selector(ContextMenuActions.renameItem(_:)), keyEquivalent: "")
        renameItem.target = ContextMenuActions.shared
        // Rename edits by SIDEBAR NODE id (derived for folders, unlike
        // collections where node id == item id).
        renameItem.representedObject = nodeID
        menu.addItem(renameItem)

        let newSubItem = NSMenuItem(title: capability.newSubContainerTitle, action: #selector(ContextMenuActions.createFolder(_:)), keyEquivalent: "")
        newSubItem.target = ContextMenuActions.shared
        newSubItem.representedObject = FolderMenuTarget(
            bindingID: capability.bindingID, folderID: folderID)
        menu.addItem(newSubItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: capability.deleteContainerTitle, action: #selector(ContextMenuActions.deleteFolder(_:)), keyEquivalent: "")
        deleteItem.target = ContextMenuActions.shared
        deleteItem.representedObject = FolderMenuTarget(
            bindingID: capability.bindingID, folderID: folderID)
        menu.addItem(deleteItem)
    }

    private func buildInboxFeedContextMenu(_ menu: NSMenu, feedID: UUID) {
        let renameItem = NSMenuItem(title: "Rename", action: #selector(ContextMenuActions.renameItem(_:)), keyEquivalent: "")
        renameItem.target = ContextMenuActions.shared
        renameItem.representedObject = feedID
        menu.addItem(renameItem)

        let editItem = NSMenuItem(title: "Edit Feed...", action: #selector(ContextMenuActions.editFeed(_:)), keyEquivalent: "")
        editItem.target = ContextMenuActions.shared
        editItem.representedObject = feedID
        menu.addItem(editItem)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(ContextMenuActions.refreshFeed(_:)), keyEquivalent: "")
        refreshItem.target = ContextMenuActions.shared
        refreshItem.representedObject = feedID
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Feed Settings...", action: #selector(ContextMenuActions.showFeedSettings(_:)), keyEquivalent: "")
        settingsItem.target = ContextMenuActions.shared
        settingsItem.representedObject = feedID
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(ContextMenuActions.deleteFeed(_:)), keyEquivalent: "")
        deleteItem.target = ContextMenuActions.shared
        deleteItem.representedObject = feedID
        menu.addItem(deleteItem)
    }

    private func buildLibraryFeedContextMenu(_ menu: NSMenu, feedID: UUID) {
        let renameItem = NSMenuItem(title: "Rename", action: #selector(ContextMenuActions.renameItem(_:)), keyEquivalent: "")
        renameItem.target = ContextMenuActions.shared
        renameItem.representedObject = feedID
        menu.addItem(renameItem)

        let editItem = NSMenuItem(title: "Edit Feed...", action: #selector(ContextMenuActions.editFeed(_:)), keyEquivalent: "")
        editItem.target = ContextMenuActions.shared
        editItem.representedObject = feedID
        menu.addItem(editItem)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(ContextMenuActions.refreshFeed(_:)), keyEquivalent: "")
        refreshItem.target = ContextMenuActions.shared
        refreshItem.representedObject = feedID
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Feed Settings...", action: #selector(ContextMenuActions.showFeedSettings(_:)), keyEquivalent: "")
        settingsItem.target = ContextMenuActions.shared
        settingsItem.representedObject = feedID
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(ContextMenuActions.deleteFeed(_:)), keyEquivalent: "")
        deleteItem.target = ContextMenuActions.shared
        deleteItem.representedObject = feedID
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
        var total = 0
        var byColor: [String: Int] = [:]
        if shellConfiguration.recordKind(for: .flagged) == .manuscript {
            // Manuscript-flag shells (imprint): the Flagged section counts
            // flagged manuscripts, matching what its rows list.
            for row in RustStoreAdapter.shared.getFlaggedManuscripts() {
                if let color = row.flagColor {
                    total += 1
                    byColor[color, default: 0] += 1
                }
            }
        } else {
            // Use getFlaggedPublications — returns only flagged rows, avoiding
            // a full table scan.
            for pubRow in store.getFlaggedPublications() {
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
        // Phase 3: read from the SidebarSnapshot cache. The cache is
        // populated off the main thread by SidebarSnapshotMaintainer in
        // response to StoreEvents — the sidebar rebuild does zero store
        // I/O during its traversal.
        //
        // If the snapshot hasn't refreshed yet (first build on launch),
        // this returns 0 and the user sees an empty badge for ~50ms
        // until the background refresh publishes fresh values and
        // triggers another rebuild via the storeDidMutate → bumpDataVersion
        // chain. Non-blocking staleness is acceptable; beachballs are not.
        return SidebarSnapshot.shared.unreadCountForFeed(feed.id)
    }

    // MARK: - Feed Management

    func addInboxFeed() {
        selectedTab = .addFeed
    }

    func editFeed(_ feedID: UUID) {
        selectedTab = .editFeed(feedID)
    }

    func refreshFeed(_ feedID: UUID) {
        Task {
            do {
                try await InboxCoordinator.shared.feedScheduler?.refreshFeed(feedID)
            } catch {
                Self.logger.error("Failed to refresh feed \(feedID): \(error)")
            }
        }
    }

    func deleteFeed(_ feedID: UUID) {
        // Clear selection if this feed is selected
        if case .inboxFeed(let id) = selectedTab, id == feedID {
            selectedNodeID = ImbibSidebarNodeID.section(.inbox)
        } else if case .libraryFeed(let id) = selectedTab, id == feedID {
            // Navigate back to parent library
            if let ss = store.getSmartSearch(id: feedID), let libID = ss.libraryID {
                selectedTab = .library(libID)
            }
        }
        store.deleteItem(id: feedID)
        bumpDataVersion()
    }

    func addLibraryFeed(_ libraryID: UUID) {
        selectedTab = .addLibraryFeed(libraryID)
    }

    /// Published state for the feed settings sheet
    var feedSettingsID: UUID?

    func showFeedSettings(_ feedID: UUID) {
        feedSettingsID = feedID
    }

    // MARK: - Section Header Menus

    private func buildSectionHeaderMenu(for node: ImbibSidebarNode) -> NSMenu? {
        guard case .section(let sectionType) = node.nodeType else { return nil }

        switch sectionType {
        case .inbox:
            return buildInboxSectionHeaderMenu()
        case .exploration:
            return buildExplorationSectionHeaderMenu()
        default:
            return nil
        }
    }

    private func buildInboxSectionHeaderMenu() -> NSMenu {
        let menu = NSMenu()

        // Retention submenu
        let retentionSubmenu = NSMenu()
        let currentRetention = InboxRetentionStore.shared.retentionDays
        for preset in InboxRetentionStore.RetentionPreset.allCases {
            let item = NSMenuItem(title: preset.displayName, action: #selector(ContextMenuActions.setInboxRetention(_:)), keyEquivalent: "")
            item.target = ContextMenuActions.shared
            item.representedObject = preset.rawValue
            item.state = preset.rawValue == currentRetention ? .on : .off
            retentionSubmenu.addItem(item)
        }
        let retentionItem = NSMenuItem(title: "Keep Papers For...", action: nil, keyEquivalent: "")
        retentionItem.submenu = retentionSubmenu
        menu.addItem(retentionItem)

        // Auto-remove read toggle
        let autoRemoveItem = NSMenuItem(
            title: "Auto-Remove Read Papers",
            action: #selector(ContextMenuActions.toggleInboxAutoRemoveRead(_:)),
            keyEquivalent: ""
        )
        autoRemoveItem.target = ContextMenuActions.shared
        autoRemoveItem.state = InboxRetentionStore.shared.autoRemoveRead ? .on : .off
        menu.addItem(autoRemoveItem)

        return menu
    }

    private func buildExplorationSectionHeaderMenu() -> NSMenu {
        let menu = NSMenu()

        // Retention submenu
        let retentionSubmenu = NSMenu()
        let currentRetention = ExplorationRetentionStore.shared.retentionDays
        for preset in ExplorationRetentionStore.RetentionPreset.allCases {
            let item = NSMenuItem(title: preset.displayName, action: #selector(ContextMenuActions.setExplorationRetention(_:)), keyEquivalent: "")
            item.target = ContextMenuActions.shared
            item.representedObject = preset.rawValue
            item.state = preset.rawValue == currentRetention ? .on : .off
            retentionSubmenu.addItem(item)
        }
        let retentionItem = NSMenuItem(title: "Keep Explorations For...", action: nil, keyEquivalent: "")
        retentionItem.submenu = retentionSubmenu
        menu.addItem(retentionItem)

        return menu
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

    /// Create a collection folder of ANY binding, expand its parent, and
    /// begin inline rename (ADR-0022 D3). Mirrors `createInboxCollection` —
    /// folder ids are the Rust store's lowercase strings; sidebar node ids
    /// are derived via `ImbibSidebarNodeID`.
    func createFolder(bindingID: String, parentID: String? = nil) {
        guard let row = CollectionStoreAdapter.shared.create(
            bindingID,
            name: parentID != nil ? "New Subfolder" : "New Folder",
            parentID: parentID
        ) else { return }
        if let parentID {
            expansionState.expand(Self.folderNodeID(bindingID, parentID))
        }
        bumpDataVersion()
        Self.logger.infoCapture(
            "created \(bindingID) folder '\(row.name)' (\(row.id)) parent=\(parentID ?? "root")",
            category: "sidebar")
        let newNodeID = Self.folderNodeID(bindingID, row.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.editingNodeID = newNodeID
        }
    }

    /// Delete a collection folder. Contained records are NEVER deleted — the
    /// membership goes away with the row (`Contains` edges cascade; envelope-
    /// filed members are unfiled by `ON DELETE SET NULL`).
    func deleteFolder(bindingID: String, folderID: String) {
        if let selected = selectedFolderID(bindingID), selected == UUID(uuidString: folderID) {
            selectedNodeID = nil
        }
        CollectionStoreAdapter.shared.delete(bindingID, id: folderID)
        bumpDataVersion()
        Self.logger.infoCapture("deleted \(bindingID) folder \(folderID)", category: "sidebar")
    }

    /// Create a manuscript folder. Retained signature — the body is now the
    /// generic capability-driven path.
    func createManuscriptFolder(parentID: String? = nil) {
        createFolder(bindingID: CollectionBindingID.manuscript, parentID: parentID)
    }

    /// Delete a manuscript folder. Contained manuscripts are NOT deleted —
    /// only the folder item (its Contains edges cascade away).
    func deleteManuscriptFolder(_ folderID: String) {
        deleteFolder(bindingID: CollectionBindingID.manuscript, folderID: folderID)
    }

    /// Create a figure folder. Retained signature — the body is now the
    /// generic capability-driven path.
    func createFigureFolder(parentID: String? = nil) {
        createFolder(bindingID: CollectionBindingID.figure, parentID: parentID)
    }

    /// Delete a figure folder. Contained figures and subfolders are NOT
    /// deleted — they are unfiled to root. That used to be an explicit Swift
    /// loop; it is the `parent_id … ON DELETE SET NULL` foreign key now, so
    /// the same end state costs one statement instead of N (and an undo of
    /// the delete re-files them, which the loop could not do).
    func deleteFigureFolder(_ folderID: String) {
        deleteFolder(bindingID: CollectionBindingID.figure, folderID: folderID)
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

    /// Routes a Delete-key press from the sidebar to the same flow that the
    /// right-click context menu uses. Same-kind selections (≥2) trigger the
    /// matching bulk delete; a single library or collection routes to the
    /// existing single-delete confirmation. Mixed kinds and other node
    /// types are silently ignored (matches the "no multi-context-menu" v1 rule).
    func handleDeleteKey(for nodes: [ImbibSidebarNode]) {
        guard !nodes.isEmpty else { return }

        // Single-node case → existing single-delete flow.
        if nodes.count == 1 {
            switch nodes[0].nodeType {
            case .library(let id):
                deleteLibrary(id)
            case .libraryCollection(let id, _):
                deleteCollection(id)
            case .explorationCollection(let id):
                deleteExplorationCollection(id)
            case .explorationSearch(let id):
                deleteExplorationSearches([id])
            case .recordFolder:
                // ADR-0022 D3: one delete for every folder binding.
                guard let folder = folderNode(nodes[0]), folder.capability.canOrganize else {
                    break
                }
                deleteFolder(bindingID: folder.capability.bindingID, folderID: folder.folderID)
            default:
                break  // Unsupported node kind — no Delete action in v1.
            }
            return
        }

        // Multi-node case → all-libraries or all-(regular)-collections only.
        let libraryIDs = nodes.compactMap { node -> UUID? in
            if case .library(let id) = node.nodeType { return id }
            return nil
        }
        if libraryIDs.count == nodes.count {
            deleteLibraries(libraryIDs)
            return
        }
        let collectionIDs = nodes.compactMap { node -> UUID? in
            if case .libraryCollection(let id, _) = node.nodeType { return id }
            return nil
        }
        if collectionIDs.count == nodes.count {
            deleteCollections(collectionIDs)
            return
        }
        let explorationIDs = nodes.compactMap { node -> UUID? in
            if case .explorationCollection(let id) = node.nodeType { return id }
            return nil
        }
        if explorationIDs.count == nodes.count {
            deleteExplorationCollections(explorationIDs)
            return
        }
        // Exploration searches, alone or mixed with exploration collections —
        // mirrors branch 4 of `buildMultiSelectionContextMenu`.
        let explorationSearchIDs = nodes.compactMap { node -> UUID? in
            if case .explorationSearch(let id) = node.nodeType { return id }
            return nil
        }
        if !explorationSearchIDs.isEmpty,
           explorationSearchIDs.count + explorationIDs.count == nodes.count {
            deleteExplorationItems(searchIDs: explorationSearchIDs, collectionIDs: explorationIDs)
            return
        }
        // Collection folders (ADR-0022 D3): a homogeneous selection of one
        // binding's folders deletes them all. Mixed bindings fall through to
        // the no-op, exactly as the two per-kind blocks did.
        let folders = nodes.compactMap { folderNode($0) }
        if folders.count == nodes.count,
           let bindingID = folders.first?.capability.bindingID,
           folders.allSatisfy({ $0.capability.bindingID == bindingID && $0.capability.canOrganize }) {
            for folder in folders { deleteFolder(bindingID: bindingID, folderID: folder.folderID) }
            return
        }
        // Mixed kinds → no-op (consistent with right-click behavior).
    }

    /// Begin the bulk-delete-libraries flow. Resolves names and pops the
    /// confirmation alert in TabContentView. Mirrors `deleteLibrary(_:)` for
    /// the single-library case. Silently drops IDs that no longer resolve.
    func deleteLibraries(_ libraryIDs: [UUID]) {
        guard !libraryIDs.isEmpty, let manager = libraryManager else { return }
        let entries = libraryIDs.compactMap { id -> (id: UUID, name: String)? in
            guard let lib = manager.libraries.first(where: { $0.id == id }) else { return nil }
            return (id: lib.id, name: lib.name)
        }
        guard entries.count >= 2 else { return }
        librariesPendingBulkDelete = entries
        showDeleteMultipleLibrariesConfirmation = true
    }

    /// Begin the bulk-delete-collections flow (regular `.libraryCollection`
    /// nodes). Names aren't shown in the confirmation (mirroring the
    /// single-collection delete which has no confirmation at all) — the
    /// count is sufficient.
    func deleteCollections(_ collectionIDs: [UUID]) {
        guard collectionIDs.count >= 2 else { return }
        // Store as (id, "") tuples to keep the same shape as the libraries case.
        // The alert formatter uses count, not names, for collections.
        collectionsPendingBulkDelete = collectionIDs.map { (id: $0, name: "") }
        showDeleteMultipleCollectionsConfirmation = true
    }

    /// Commit a bulk library delete after confirmation.
    /// Calls `LibraryManager.deleteLibraries(ids:)` (a single batched mutation)
    /// and clears the active selection if it pointed into the deleted set.
    func performBulkDeleteLibraries() {
        let ids = librariesPendingBulkDelete.map { $0.id }
        guard !ids.isEmpty else { return }
        // Clear sidebar selection if it points at one of the doomed libraries —
        // didSet on selectedNodeID re-resolves the active tab.
        if let current = selectedTab,
           case .library(let libID) = current,
           ids.contains(libID) {
            selectedNodeID = nil
        }
        libraryManager?.deleteLibraries(ids: ids)
        librariesPendingBulkDelete = []
        bumpDataVersion()
    }

    /// Commit a bulk regular-collection delete after confirmation.
    func performBulkDeleteCollections() {
        let ids = collectionsPendingBulkDelete.map { $0.id }
        guard !ids.isEmpty else { return }
        // Clear selection if it points at any doomed collection.
        if let current = selectedTab,
           case .collection(let colID) = current,
           ids.contains(colID) {
            selectedNodeID = nil
        }
        store.beginBatchMutation()
        for id in ids { store.deleteItem(id: id) }
        store.endBatchMutation()
        libraryManager?.loadLibraries()
        collectionsPendingBulkDelete = []
        bumpDataVersion()
    }

    // MARK: - SciX Library Context Menu Actions

    func refreshSciXLibrary(_ libraryID: UUID) {
        guard let library = scixRepository.libraries.first(where: { $0.id == libraryID }) else { return }
        Task { await SciXLibraryViewModel().refreshLibraryPapers(library) }
    }

    func editSciXLibrary(_ libraryID: UUID) {
        scixLibraryToEdit = scixRepository.libraries.first(where: { $0.id == libraryID })
    }

    func manageSciXCollaborators(_ libraryID: UUID) {
        scixLibraryToShowInfo = scixRepository.libraries.first(where: { $0.id == libraryID })
    }

    func deleteSciXLibrary(_ libraryID: UUID) {
        scixLibraryToDelete = scixRepository.libraries.first(where: { $0.id == libraryID })
        showSciXDeleteConfirmation = true
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

// MARK: - Folder Menu Target

/// `NSMenuItem.representedObject` payload for the generic folder actions
/// (ADR-0022 D3): which kernel binding, and which folder (nil = the binding's
/// root, i.e. "New Folder" on a section header).
struct FolderMenuTarget {
    let bindingID: String
    let folderID: String?
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

    /// Create a collection folder of any binding (ADR-0022 D3).
    /// representedObject: `FolderMenuTarget` — binding + parent folder id
    /// (nil parent = a root folder).
    @objc func createFolder(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FolderMenuTarget else { return }
        viewModel?.createFolder(bindingID: target.bindingID, parentID: target.folderID)
    }

    /// Delete a collection folder of any binding (ADR-0022 D3).
    @objc func deleteFolder(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FolderMenuTarget,
              let folderID = target.folderID else { return }
        viewModel?.deleteFolder(bindingID: target.bindingID, folderID: folderID)
    }

    @objc func deleteExplorationCollection(_ sender: NSMenuItem) {
        guard let collectionID = sender.representedObject as? UUID else { return }
        viewModel?.deleteExplorationCollection(collectionID)
    }

    @objc func deleteMultipleExplorationCollections(_ sender: NSMenuItem) {
        guard let collectionIDs = sender.representedObject as? [UUID] else { return }
        viewModel?.deleteExplorationCollections(collectionIDs)
    }

    @objc func deleteExplorationSearch(_ sender: NSMenuItem) {
        guard let searchID = sender.representedObject as? UUID else { return }
        viewModel?.deleteExplorationSearches([searchID])
    }

    /// Bulk delete of Exploration rows — searches, collections, or both.
    /// `representedObject` is `["searches": [UUID], "collections": [UUID]]`.
    @objc func deleteMultipleExplorationItems(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: [UUID]] else { return }
        viewModel?.deleteExplorationItems(
            searchIDs: payload["searches"] ?? [],
            collectionIDs: payload["collections"] ?? []
        )
    }

    @objc func deleteMultipleLibraries(_ sender: NSMenuItem) {
        guard let libraryIDs = sender.representedObject as? [UUID] else { return }
        viewModel?.deleteLibraries(libraryIDs)
    }

    @objc func deleteMultipleCollections(_ sender: NSMenuItem) {
        guard let collectionIDs = sender.representedObject as? [UUID] else { return }
        viewModel?.deleteCollections(collectionIDs)
    }

    @objc func exportLibrary(_ sender: NSMenuItem) {
        guard let libraryID = sender.representedObject as? UUID else { return }
        viewModel?.exportLibrary(libraryID)
    }

    @objc func importToLibrary(_ sender: NSMenuItem) {
        guard let libraryID = sender.representedObject as? UUID else { return }
        viewModel?.importToLibrary(libraryID)
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

    @objc func createTopLevelInboxCollection(_ sender: NSMenuItem) {
        viewModel?.createInboxCollection()
    }

    // MARK: - Inbox Feed Actions

    @objc func editFeed(_ sender: NSMenuItem) {
        guard let feedID = sender.representedObject as? UUID else { return }
        viewModel?.editFeed(feedID)
    }

    @objc func refreshFeed(_ sender: NSMenuItem) {
        guard let feedID = sender.representedObject as? UUID else { return }
        viewModel?.refreshFeed(feedID)
    }

    @objc func deleteFeed(_ sender: NSMenuItem) {
        guard let feedID = sender.representedObject as? UUID else { return }
        viewModel?.deleteFeed(feedID)
    }

    @objc func addInboxFeed(_ sender: NSMenuItem) {
        viewModel?.addInboxFeed()
    }

    @objc func addLibraryFeed(_ sender: NSMenuItem) {
        guard let libraryID = sender.representedObject as? UUID else { return }
        viewModel?.addLibraryFeed(libraryID)
    }

    @objc func showFeedSettings(_ sender: NSMenuItem) {
        guard let feedID = sender.representedObject as? UUID else { return }
        viewModel?.showFeedSettings(feedID)
    }

    // MARK: - Retention Settings

    @objc func setInboxRetention(_ sender: NSMenuItem) {
        guard let days = sender.representedObject as? Int else { return }
        InboxRetentionStore.shared.retentionDays = days
    }

    @objc func toggleInboxAutoRemoveRead(_ sender: NSMenuItem) {
        InboxRetentionStore.shared.autoRemoveRead.toggle()
    }

    @objc func setExplorationRetention(_ sender: NSMenuItem) {
        guard let days = sender.representedObject as? Int else { return }
        ExplorationRetentionStore.shared.retentionDays = days
    }

    // MARK: - SciX Library Actions

    @objc func refreshSciXLibraryPapers(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        viewModel?.refreshSciXLibrary(id)
    }

    @objc func editSciXLibrary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        viewModel?.editSciXLibrary(id)
    }

    @objc func manageSciXCollaborators(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        viewModel?.manageSciXCollaborators(id)
    }

    @objc func deleteSciXLibrary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        viewModel?.deleteSciXLibrary(id)
    }

    @objc func openSciXLibraryOnWeb(_ sender: NSMenuItem) {
        guard let remoteID = sender.representedObject as? String,
              let url = URL(string: "https://ui.adsabs.harvard.edu/user/libraries/\(remoteID)") else { return }
        NSWorkspace.shared.open(url)
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
#endif
