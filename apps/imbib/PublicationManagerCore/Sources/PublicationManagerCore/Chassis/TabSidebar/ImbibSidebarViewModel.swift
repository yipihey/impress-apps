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
import ImpressLogging
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

    /// ADR-0023 W2 — the watcher-only redraw hook (see
    /// `.watchedFoldersDidChange`). Held so it can be torn down.
    @ObservationIgnored var watchedFolderObserver: NSObjectProtocol?

    /// The folder whose unattached PDFs the user asked to review (ADR-0023 W5),
    /// or `nil`. Drives a `.sheet(item:)` in `TabContentView` — the same shape
    /// `scixLibraryToShowInfo` uses, so no new presentation mechanism.
    var attachmentReviewRequest: WatchedAttachmentReviewRequest?

    /// ADR-0023 W4 — whether this shell's file-unit coordinators are running.
    @ObservationIgnored private var didStartFileUnitWatchers = false

    // MARK: - Section State

    var sectionOrder: [SidebarSectionType]
    private var collapsedSections: Set<SidebarSectionType>

    /// Collapse state for a COMPOSED sidebar's two tiers. Empty (= everything
    /// expanded) in the five single-preset shells, which never build a group.
    private var collapsedComposition: Set<SidebarCompositionKey>

    // MARK: - Orderable Items

    var searchForms: [SearchFormType] = SearchFormStore.loadVisibleFormsSync()
    var hiddenSearchForms: Set<SearchFormType> = SearchFormStore.loadHiddenSync()
    var flagColors: [FlagColor] = FlagColorOrderStore.loadOrderSync()

    // MARK: - Counts & Status

    var flagCounts = FlagCounts.empty

    /// Flag counts PER RECORD KIND — populated only in a composed sidebar,
    /// where several groups show a Flagged section at once and each counts its
    /// own kind. Empty in a flat sidebar, where `flagCounts` is the one answer
    /// and is computed exactly as before.
    private(set) var flagCountsByKind: [RecordKindID: FlagCounts] = [:]
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

    /// The COMPOSITION this shell renders, or nil for a shell that runs a
    /// single flat preset.
    ///
    /// nil is the value all five sibling apps have, and it is what makes every
    /// composed code path below unreachable for them rather than merely
    /// false-valued: `buildSectionNodes`, `children(of:)`, `canAcceptDrop` and
    /// the outline configuration's new closures all branch on this one
    /// property, and it is set from an ENVIRONMENT value that only impress's
    /// root supplies (`ChassisRootView(sidebarComposition:)`). No `appID ==`
    /// test anywhere — ADR-0022 D9's rule, and the reason macOS impress could
    /// not simply be special-cased here.
    var sidebarComposition: SidebarComposition? {
        didSet {
            guard oldValue != sidebarComposition else { return }
            initializeExpansionState()
        }
    }

    /// Where persisted sidebar state is read from and written to. Injected so a
    /// unit test can seed and observe it without touching `UserDefaults` —
    /// see `SidebarPersistenceScope`.
    private let persistence: SidebarPersistenceScope

    /// - Parameters:
    ///   - store: the publication store. `MockPublicationStore` in tests.
    ///   - persistence: the persisted-state seam. `.inMemory()` in tests.
    ///   - shellConfiguration: the shell preset. Settable afterwards too
    ///     (`TabContentView` applies it from the environment), but an init
    ///     parameter lets a test build a fully-specified view model in one
    ///     expression — the persisted order and collapse state are read HERE,
    ///     before any caller could assign them.
    ///   - sidebarComposition: nil for the five single-preset shells.
    init(
        store: any PublicationStoreProtocol = RustStoreAdapter.shared,
        persistence: SidebarPersistenceScope = .userDefaults,
        shellConfiguration: AppShellConfiguration = .imbib,
        sidebarComposition: SidebarComposition? = nil
    ) {
        self.store = store
        self.persistence = persistence
        self.shellConfiguration = shellConfiguration
        self.sidebarComposition = sidebarComposition
        self.sectionOrder = persistence.loadSectionOrder()
        self.collapsedSections = persistence.loadCollapsedSections()
        self.collapsedComposition = persistence.loadComposedCollapse()
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
        startWatchingFolders()
        startFileUnitWatchers()
    }

    /// ADR-0023 W2: restore the persisted watched folders and begin watching.
    ///
    /// Registration happens now so the sidebar has rows immediately; the first
    /// GATHER — the part that writes — is held behind
    /// `FolderWatchStartupGate`'s 90 seconds inside the watcher, which is the
    /// suite's background-service rule and the reason it is a value there
    /// rather than a sleep here.
    private func startWatchingFolders() {
        guard watchedFolderObserver == nil else { return }
        watchedFolderObserver = NotificationCenter.default.addObserver(
            forName: .watchedFoldersDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.bumpDataVersion() }
        }
        Task { @MainActor [weak self] in
            await WatchedFolderIngestCoordinator.shared.start()
            self?.bumpDataVersion()
        }
    }

    /// ADR-0023 W4: start the coordinators for the FILE-unit kinds this shell
    /// shows a section for.
    ///
    /// Separate from `startWatchingFolders()` and called from `configure(_:)`
    /// rather than from `init`, because the shell preset is applied AFTER
    /// construction (`TabContentView`'s `.task` sets `shellConfiguration`, then
    /// calls `configure`). Reading it in `init` would give every host imbib's
    /// preset and start nothing. Idempotent: `configure` runs on every `.task`
    /// re-evaluation, and the coordinator registry hands back the running one.
    private func startFileUnitWatchers() {
        let scopes = Self.watchedKindScopes(for: shellConfiguration)
            .filter { $0 != WatchedFolderIngestCoordinator.kindScope }
        guard !scopes.isEmpty, !didStartFileUnitWatchers else { return }
        didStartFileUnitWatchers = true
        Task { @MainActor [weak self] in
            for scope in scopes {
                await WatchedFolderIngestCoordinator.coordinator(forKindScope: scope)?.start()
            }
            self?.bumpDataVersion()
        }
    }

    /// The sidebar section each `file`-unit kind's watched folders appear in.
    ///
    /// DECLARED rather than derived, and small on purpose. The chassis has no
    /// section→kind table — a section's kind is a per-shell BINDING
    /// (`sectionBindings`) and most sections carry none — so deriving one here
    /// would be inventing a second answer to a question the preset half-answers
    /// already. imbib's publications are absent because their folders ride the
    /// Libraries section through `watchedFolderNodes()`, which is W2's row and
    /// a different surface.
    ///
    /// W3 (imprint) landed and added `.manuscript: .manuscripts`.
    static let watchedFileSections: [String: SidebarSectionType] = [
        RecordKindID.message.rawValue: .mail,
        RecordKindID.figure.rawValue: .figures,
        RecordKindID.manuscript.rawValue: .manuscripts,
    ]

    /// The kind scopes a shell watches: publications always (W2's behaviour,
    /// unchanged), plus every file-unit kind whose section this shell shows.
    static func watchedKindScopes(for configuration: AppShellConfiguration) -> [String] {
        [WatchedFolderIngestCoordinator.kindScope]
            + watchedFileSections
                .filter { configuration.permits($0.value) }
                .keys
                .sorted()
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
        let section = shellConfiguration.defaultSection
        let flatID = Self.defaultLeafID(for: section)

        if let group = defaultLandingGroup(for: section) {
            // COMPOSED: the same leaf, in the group that owns it — and its
            // ancestors expanded first. `restoreSelection` drops a selection
            // whose ancestor is collapsed, so landing inside a collapsed group
            // would leave the window with nothing selected and no obvious
            // reason why (`beginEditingNode`'s ancestor expansion is the
            // precedent for doing this before the write, not after).
            let groupNodeID = ImbibSidebarNodeID.appGroup(group.id)
            expansionState.expand(groupNodeID)
            expansionState.expand(
                ImbibSidebarNodeID.grouped(group.id, ImbibSidebarNodeID.section(section)))
            selectedNodeID = ImbibSidebarNodeID.grouped(group.id, flatID)
        } else {
            selectedNodeID = flatID
        }

        bumpDataVersion()
    }

    /// The canonical selectable leaf of a section, flat.
    ///
    /// Group-header sections (`.manuscripts`, `.figures`, `.mail`, `.agents`)
    /// are not selectable rows, so landing on the header would leave
    /// `selectedTab` at its `.inbox` default and render the publication list.
    private static func defaultLeafID(for section: SidebarSectionType) -> UUID {
        switch section {
        case .manuscripts: return ImbibSidebarNodeID.journalAll
        case .figures: return ImbibSidebarNodeID.figuresAll
        case .mail: return ImbibSidebarNodeID.mailAllInboxes
        case .agents: return ImbibSidebarNodeID.agentTasks
        default: return ImbibSidebarNodeID.section(section)
        }
    }

    /// In a composed sidebar, the group that should own the default landing:
    /// the FIRST group whose own preset permits the host's default section.
    /// The order is the composition's, which is `SiblingApp.descriptors`' —
    /// never a literal here.
    private func defaultLandingGroup(for section: SidebarSectionType) -> SidebarNodeGroup? {
        guard let composition = sidebarComposition else { return nil }
        let groups = composition.groups.map { SidebarNodeGroup(group: $0, host: shellConfiguration) }
        return groups.first { $0.configuration.permits(section) } ?? groups.first
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
        // A structural refresh is exactly when a tag can have appeared or gone.
        invalidateTagCache()
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
                // App-group headers are an app's PRESENCE, never a destination.
                if node.isAppGroup { return false }
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
            },
            // Composed shells only. Passing nil (not a closure that returns
            // false) is what keeps the app-group branch in
            // `SidebarOutlineView.viewFor` unreachable in the five sibling
            // shells rather than merely unused — their cells are produced by
            // exactly the code that produced them before this tier existed.
            isAppGroupItem: sidebarComposition == nil ? nil : { $0.isAppGroup },
            // The caller `handleExpansionChange` never had. Every shell gets
            // this: section collapse not persisting is a pre-existing bug in
            // all six, not something the composition introduced.
            onExpansionChanged: { [weak self] node, expanded in
                self?.handleExpansionChange(node: node, expanded: expanded)
            }
        )
    }

    // MARK: - Expansion State Initialization

    private func initializeExpansionState() {
        if let composition = sidebarComposition {
            // COMPOSED: two tiers, one persisted key space, default EMPTY —
            // "collate their sidebars" means a user opening impress sees five
            // sidebars, not five closed drawers.
            for group in composition.groups {
                let binding = SidebarNodeGroup(group: group, host: shellConfiguration)
                if !collapsedComposition.contains(binding.collapseKey) {
                    expansionState.expand(ImbibSidebarNodeID.appGroup(binding.id))
                }
                for section in sectionOrder
                where !collapsedComposition.contains(binding.collapseKey(section: section)) {
                    expansionState.expand(
                        ImbibSidebarNodeID.grouped(
                            binding.id, ImbibSidebarNodeID.section(section)))
                }
            }
            return
        }
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
        let perfToken = PerfMetrics.shared.begin("sidebar", detail: "rebuildTabMap")
        defer { perfToken.end() }
        tabToNodeID.removeAll()
        func registerNode(_ node: ImbibSidebarNode) {
            if let tab = node.imbibTab {
                tabToNodeID[tab] = node.id
            }
            // The tag FOREST is lazily built and can be 9k+ nodes; recursing
            // it here materialised every level on every data-version bump.
            // Tag tabs are registered in one bulk pass below instead — same
            // mapping (`.tag(path)` ↔ `ImbibSidebarNodeID.tag(path)`), no
            // node construction.
            if case .tag = node.nodeType { return }
            for child in children(of: node) {
                registerNode(child)
            }
        }
        for section in buildSectionNodes() {
            registerNode(section)
        }
        for level in tagLevels().values {
            for path in level {
                tabToNodeID[.tag(path: path)] = ImbibSidebarNodeID.tag(path)
            }
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
        if let composition = sidebarComposition {
            // COMPOSED: the root tier is one node per app group, in the
            // composition's order — which is `SiblingApp.descriptors`'. No
            // section, kind or app id is named here; each group's sections are
            // resolved lazily in `children(of:)` from the group's own preset.
            //
            // EMPTY GROUPS ARE KEPT (the iOS decision, verbatim): a group is an
            // app's presence in impress, not a claim about its data.
            for group in composition.groups {
                let binding = SidebarNodeGroup(group: group, host: shellConfiguration)
                nodes.append(ImbibSidebarNode(
                    id: ImbibSidebarNodeID.appGroup(binding.id),
                    nodeType: .appGroup(binding.id),
                    displayName: binding.title,
                    iconName: binding.systemImage,
                    isAppGroup: true,
                    appGroup: binding))
            }
        } else {
            for section in sectionOrder {
                guard shouldShowSection(section) else { continue }
                nodes.append(makeSectionNode(section))
            }
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

    /// Whether a section renders, under a given preset.
    ///
    /// The preset is a PARAMETER rather than `shellConfiguration` because in a
    /// composed sidebar the answer differs per group: the window's preset is
    /// the flat `.impress` union, and asking it inside the imprint group is how
    /// a union loses whose section this is. It defaults to the window's preset,
    /// so every flat call site reads exactly as it did.
    private func shouldShowSection(
        _ section: SidebarSectionType,
        configuration: AppShellConfiguration? = nil
    ) -> Bool {
        let shellConfiguration = configuration ?? self.shellConfiguration
        // Thin-twin: the app-shell config restricts which sections exist at all
        // (imprint = Manuscripts facet only). Content gating applies on top.
        guard shellConfiguration.permits(section) else { return false }
        switch section {
        case .inbox, .libraries, .search, .flagged:
            return true
        case .tags:
            // Content gate, like every other section here: an empty Tags
            // section is a row that promises browsing and delivers none. The
            // gate is the WHOLE vocabulary, never the filtered one — a section
            // that disappeared on the first non-matching keystroke would take
            // the filter field's subject off screen mid-sentence, and "nothing
            // matches what you typed" is what the field's own count is for.
            return !tagPaths.isEmpty
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

    /// The children of a node, with a composed sidebar's per-node corrections
    /// applied ONCE, here, for the whole subtree.
    ///
    /// Every child of a node that belongs to a group belongs to the same group,
    /// so this is the single place that has to know it. Three things happen and
    /// all three are structural rather than per-builder:
    ///
    ///   * the child is tagged with the group, so it can answer "which preset
    ///     decides my kind" long after the group loop returned;
    ///   * its id is re-keyed into the group's namespace, so the imbib group's
    ///     red flag and the imprint group's red flag are two rows and not one;
    ///   * its `treeDepth` gains a level, because a composed sidebar is one
    ///     level deeper and indentation is drawn from `treeDepth` alone
    ///     (`indentationPerLevel == 0`). This is why the ten hand-assigned
    ///     `treeDepth` sites did not need to change.
    func children(of node: ImbibSidebarNode) -> [ImbibSidebarNode] {
        let children = rawChildren(of: node)
        guard let group = node.appGroup else { return children }
        return children.map { $0.adopting(group: group) }
    }

    private func rawChildren(of node: ImbibSidebarNode) -> [ImbibSidebarNode] {
        switch node.nodeType {
        case .appGroup:
            // A group's children are the sections that group's OWN preset
            // permits, in the shared section order. Nothing enumerates a
            // section here: `shouldShowSection` is the same gate the flat
            // sidebar runs, handed a different preset.
            guard let group = node.appGroup else { return [] }
            return sectionOrder
                .filter { shouldShowSection($0, configuration: group.configuration) }
                .map { makeSectionNode($0) }
        case .section(let sectionType):
            return sectionChildren(sectionType, configuration: node.appGroup?.configuration)
        case .tag(let path):
            // The tag tree nests to any depth, one level per expand.
            return tagChildren(under: path)
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

    /// A section's rows, under a given preset.
    ///
    /// Only the three kind-bound arms actually read the preset — Flagged and
    /// Dismissed (which kind's flags/dismissals these are) and Manuscripts
    /// (whether the shell carries the Submissions auxiliary route). The other
    /// twelve are the same rows regardless, so they take no parameter and are
    /// untouched.
    private func sectionChildren(
        _ section: SidebarSectionType,
        configuration: AppShellConfiguration? = nil
    ) -> [ImbibSidebarNode] {
        let configuration = configuration ?? shellConfiguration
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
            return flaggedChildren(configuration: configuration)
        case .tags:
            return tagChildren(under: nil)
        case .artifacts:
            return artifactsChildren()
        case .dismissed:
            return dismissedChildren(configuration: configuration)
        case .citedInManuscripts:
            return citedInManuscriptsChildren()
        case .reviewQueue:
            return reviewQueueChildren()
        case .manuscripts:
            return journalChildren(configuration: configuration)
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
    /// The TREE is `MailSidebarSnapshot` (Stage 5c, cross-platform): role
    /// ordering, the six folder glyphs, the display-name fallback chain and the
    /// All-Inboxes fan-out all live there now, so impart-iOS's sidebar shows the
    /// same rows in the same order without re-encoding any of it. This method
    /// only maps the snapshot onto macOS's `ImbibSidebarNode`.
    private func mailChildren() -> [ImbibSidebarNode] {
        let snapshot = MailSidebarSnapshot.load()
        var nodes: [ImbibSidebarNode] = [
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.mailAllInboxes,
                nodeType: .mailAllInboxes,
                displayName: MailSidebarSnapshot.allInboxesTitle,
                iconName: MailSidebarSnapshot.allInboxesSystemImage,
                displayCount: snapshot.allInboxesCount > 0 ? snapshot.allInboxesCount : nil
            ),
        ]
        for account in snapshot.accounts {
            var accountNode = ImbibSidebarNode(
                id: ImbibSidebarNodeID.mailAccount(account.storeID),
                nodeType: .mailAccount(account.storeID),
                displayName: account.name,
                iconName: "person.crop.circle"
            )
            accountNode.treeDepth = 0
            accountNode.hasTreeChildren = !account.folders.isEmpty
            nodes.append(accountNode)
            for folder in account.folders {
                var folderNode = ImbibSidebarNode(
                    id: ImbibSidebarNodeID.mailFolder(folder.storeID),
                    nodeType: .mailFolder(folder.storeID),
                    displayName: folder.name,
                    iconName: folder.systemImage
                )
                folderNode.displayCount = folder.messageCount > 0 ? folder.messageCount : nil
                folderNode.treeDepth = 1
                nodes.append(folderNode)
            }
        }
        // ADR-0023 W4: watched archive folders come LAST, so adding one never
        // reshuffles the account rows a user has learned the position of — the
        // same rule `librariesChildren()` follows for imbib's.
        nodes.append(contentsOf: watchedFileFolderNodes(kindScope: RecordKindID.message.rawValue))
        return nodes
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
        // ADR-0023 W4 — implore's watched `.vsz` folders, last (see mailChildren).
        nodes.append(contentsOf: watchedFileFolderNodes(kindScope: RecordKindID.figure.rawValue))
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

        // The kernel row IS the entry (ADR-0022 F3): `fetchFolders` returns
        // `CollectionKernelRow`s, so `name` / `sortOrder` / tree `parentID` are
        // typed fields rather than a payload decode. An unnamed folder keeps
        // reading "Untitled Folder" — the kernel spells a missing name as "",
        // where the decoder spelled it `nil`.
        struct FolderEntry {
            let id: String
            let name: String
            let sortOrder: Int
            let parentID: String?
        }
        let entries = folders.map { row in
            FolderEntry(
                id: row.id,
                name: row.name.isEmpty ? "Untitled Folder" : row.name,
                sortOrder: Int(row.sortOrder),
                parentID: row.parentID)
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
    private func journalChildren(
        configuration: AppShellConfiguration? = nil
    ) -> [ImbibSidebarNode] {
        let shellConfiguration = configuration ?? self.shellConfiguration
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
        // ADR-0023 W3 — imprint's watched manuscript folders, after the user's
        // own folders (the rule `mailChildren`/`figuresChildren` follow: a
        // folder the user adds must never reshuffle the rows above it).
        return nodes + manuscriptFolderNodes()
            + watchedFileFolderNodes(kindScope: RecordKindID.manuscript.rawValue)
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
        // ADR-0023 W2: watched folders are feeds, and imbib's feeds sit beside
        // the libraries they feed. They come LAST so adding one never reshuffles
        // the library rows a user has learned the position of.
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
            + watchedFolderNodes()
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

    // MARK: Tags

    /// The tag vocabulary, read ONCE per structural refresh.
    ///
    /// `listTags()` is an FFI round trip that builds a struct per definition,
    /// and imbib's vocabulary is 23,916 of them. It was being called once per
    /// section-visibility check and again for every LEVEL of the tree the user
    /// expands — and with a filter field above it, once more per keystroke.
    /// Invalidated by `invalidateTagCache()` on every structural refresh, which
    /// is the same event that rebuilds the rows this feeds.
    @ObservationIgnored private var tagPathCache: [String]?

    private var tagPaths: [String] {
        if let tagPathCache { return tagPathCache }
        // DE-DUPLICATED at the read. The definitions table is allowed to hold
        // the same path more than once — the real library had 23,916 rows for
        // 9,090 paths — and while the tree builder below dedupes anyway (it
        // works through a `Set`), it would do so over 2.6× the strings on every
        // rebuild and every keystroke of the filter. `createTag` no longer
        // mints duplicates; this is what makes the rows already in a user's
        // store cost nothing.
        let paths = Array(Set(RustStoreAdapter.shared.listTags().map(\.path)))
        tagPathCache = paths
        return paths
    }

    func invalidateTagCache() {
        tagPathCache = nil
        tagLevelCache = nil
    }

    /// The tag tree's LEVEL structure — parent path ("" for the roots) →
    /// sorted level paths directly beneath it — derived from
    /// `filteredTagPaths` in ONE pass and cached.
    ///
    /// Without this, `tagChildren(under:)` re-filtered and re-split the whole
    /// vocabulary once per LEVEL, and `rebuildTabMap()` visits every level of
    /// the tree: 9,090 paths made a single rebuild ~82M string splits on the
    /// main thread, which is what "imbib takes minutes to start" was made of
    /// (2026-08-07, the Swift half — the store half was the planner picking
    /// `idx_items_read`). Invalidated with the vocabulary cache above and on
    /// every filter edit.
    @ObservationIgnored private var tagLevelCache: [String: [String]]?

    private func tagLevels() -> [String: [String]] {
        if let tagLevelCache { return tagLevelCache }
        var levels: [String: Set<String>] = [:]
        for tag in filteredTagPaths {
            let parts = tag.split(separator: "/")
            guard !parts.isEmpty else { continue }
            for depth in 0..<parts.count {
                let parent = depth == 0 ? "" : parts[0..<depth].joined(separator: "/")
                levels[parent, default: []].insert(parts[0...depth].joined(separator: "/"))
            }
        }
        let sorted = levels.mapValues { $0.sorted() }
        tagLevelCache = sorted
        return sorted
    }

    /// The Tags section's filter text, from the sidebar's filter field.
    ///
    /// Setting it rebuilds the outline and REVEALS the matches (see
    /// `revealFilteredTags`) — a filtered tree whose matches stay behind
    /// collapsed parents has answered the user's question and then hidden the
    /// answer.
    var tagFilter: String = "" {
        didSet {
            guard tagFilter != oldValue else { return }
            // The level cache derives from the FILTERED vocabulary.
            tagLevelCache = nil
            revealFilteredTags()
            bumpDataVersion()
        }
    }

    /// The vocabulary the Tags rows are built from right now.
    var filteredTagPaths: [String] {
        TagPathFilter.retain(tagPaths, matching: tagFilter)
    }

    /// Whether this shell shows the sidebar's tag filter field.
    ///
    /// The field is chrome for the Tags SECTION, so it appears on exactly the
    /// same terms: a shell that permits the section, with a vocabulary to
    /// filter. In a composed sidebar any one group permitting `.tags` is
    /// enough — the field narrows all of them, because "which tags are called
    /// <this>" is a better question across the apps than inside one.
    var showsTagFilter: Bool {
        guard !tagPaths.isEmpty else { return false }
        if let sidebarComposition {
            return sidebarComposition.groups.contains {
                $0.configuration(inHost: shellConfiguration).permits(.tags)
            }
        }
        return shellConfiguration.permits(.tags)
    }

    /// How many surviving paths may be auto-revealed. Above this the user is
    /// still typing, not yet reading: expanding 10,000 interior rows realises
    /// them all AND walks the vocabulary once per row. The count is shown in
    /// the filter field, so a filter too broad to reveal says so rather than
    /// silently doing less than it appears to.
    private static let tagRevealLimit = 200

    private func revealFilteredTags() {
        guard TagPathFilter.normalized(tagFilter) != nil else { return }
        let surviving = filteredTagPaths
        guard surviving.count <= Self.tagRevealLimit else { return }
        // Every ANCESTOR of a surviving path: those are the rows that have to
        // be open for the match itself to be on screen.
        var ancestors = Set<UUID>()
        for path in surviving {
            let parts = path.split(separator: "/")
            guard parts.count > 1 else { continue }
            for depth in 1..<parts.count {
                ancestors.insert(
                    ImbibSidebarNodeID.tag(parts[0..<depth].joined(separator: "/")))
            }
        }
        expansionState.expandAll(ancestors)
    }

    /// One LEVEL of the tag tree — the rows directly beneath `parent`, or the
    /// roots when it is nil.
    ///
    /// Level-at-a-time rather than a whole tree because this sidebar builds
    /// children lazily (`rawChildren(of:)`), which is what keeps a vocabulary
    /// of thousands of tags from being walked on every rebuild. Interior paths
    /// are materialised even when nothing carries them exactly: matching is
    /// descendant-inclusive (`TagPathMatch`), so an interior row selects a real
    /// set and its badge counts what it shows.
    ///
    /// The filter narrows the VOCABULARY, not these rows — which is what keeps
    /// the parents of a matching leaf on screen, since every level here is
    /// derived from the paths that survived (`TagPathFilter`).
    private func tagChildren(under parent: String?) -> [ImbibSidebarNode] {
        let level = tagLevels()[parent ?? ""] ?? []
        return level.map { path in
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.tag(path),
                nodeType: .tag(path: path),
                displayName: path.split(separator: "/").last.map(String.init) ?? path,
                iconName: "tag"
            )
        }
    }

    // MARK: Flagged

    private func flaggedChildren(
        configuration: AppShellConfiguration? = nil
    ) -> [ImbibSidebarNode] {
        // WHOSE flags these are. In a composed sidebar each group's Flagged
        // section counts its OWN kind — imbib's papers, imprint's manuscripts —
        // which is the count half of the same fact `SidebarNodeGroup
        // .retargetedTab` supplies for the row's destination. Flat shells pass
        // nil and read the single `flagCounts` they always read.
        let flagCounts = resolvedFlagCounts(under: configuration)

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

    private func dismissedChildren(
        configuration: AppShellConfiguration? = nil
    ) -> [ImbibSidebarNode] {
        let shellConfiguration = configuration ?? self.shellConfiguration
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
    /// ADR-0022 C2: `.libraryCollection` resolves here TOO, so the generic
    /// sites below serve publication collections without an arm of their own.
    ///
    /// The node CASE stays `.libraryCollection` deliberately — it is not a
    /// `.recordFolder` and cannot become one, because `imbibTab` maps it to
    /// `.collection(id)` (a `PublicationSource`, feeding the publication-only
    /// multi-select union) while `.recordFolder` maps to `.record(.folder(...))`.
    /// Converging the ROUTE means rewriting publication content routing, which
    /// is `UnifiedPublicationListWrapper`'s remit, not the sidebar's. What
    /// converges here is every VERB.
    private func folderNode(
        _ node: ImbibSidebarNode
    ) -> (capability: CollectionCapability, folderID: String)? {
        switch node.nodeType {
        case .recordFolder(let bindingID, let folderID):
            guard let capability = BuiltinRecordKinds.collectionCapability(forBindingID: bindingID)
            else { return nil }
            return (capability, folderID)
        case .libraryCollection(let collectionID, _):
            guard let capability = BuiltinRecordKinds.collectionCapability(
                forBindingID: CollectionBindingID.publication)
            else { return nil }
            // Node id == item id for collections (unlike folders, whose node id
            // is derived), and the kernel wants the store's lowercase form.
            return (capability, collectionID.uuidString.lowercased())
        default:
            return nil
        }
    }

    /// The kernel row behind a collection node, for the sites that need the
    /// per-row facts the node does not carry — `isSmart` above all.
    ///
    /// Reads through `CollectionStoreAdapter`, so it is marker-aware: unlike
    /// `store.listCollections(libraryId:)` it keeps answering after the
    /// `collections.unified` flip.
    private func collectionRow(_ node: ImbibSidebarNode) -> CollectionKernelRow? {
        guard let folder = folderNode(node) else { return nil }
        return CollectionStoreAdapter.shared.row(
            folder.capability.bindingID, id: folder.folderID)
    }

    /// Whether a collection node offers the organise verbs, evaluated against
    /// the KERNEL row rather than a second legacy read (ADR-0022 C2 axis 2).
    ///
    /// A row the kernel cannot find is treated as organisable, which is the
    /// frozen behaviour: `buildCollectionContextMenu` used to bail out entirely
    /// on a missing row, and the manuscript/figure path never consulted a row
    /// at all.
    private func allowsOrganize(_ node: ImbibSidebarNode, tierID: String? = nil) -> Bool {
        guard let folder = folderNode(node) else { return false }
        let tier = tierID.flatMap { folder.capability.tier($0) }
        let isSmart = collectionRow(node)?.isSmart ?? false
        return folder.capability.allowsOrganize(isSmart: isSmart, tier: tier)
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
              let kind = canonicalSectionKinds[section],
              let capability = BuiltinRecordKinds.registry[kind]?.collection
        else { return nil }
        // ADR-0022 C2, THIRD gate: a container-scoped kind has no SECTION-level
        // root, so its section header is not a folder host.
        //
        // This gate is what the container axis buys here, and it is load-bearing
        // rather than decorative. `.inbox`, `.libraries` and `.exploration` are
        // all `.primary` AND all bound to `.publication` in the canonical table,
        // so the moment the publication kind declared a `CollectionCapability`
        // those three headers would otherwise have started hosting "New
        // Collection", accepting collection drops as "move to root", and
        // reordering through `reorderFolders`. None of that is imbib's frozen
        // behaviour: a publication collection's root is its LIBRARY (the
        // container), which is why the tree hangs off `library` nodes and why
        // "New Collection" lives on the LIBRARY context menu.
        //
        // Manuscripts and figures are unaffected — their folders genuinely are
        // section-rooted, which is exactly what `container == nil` says.
        guard capability.container == nil else { return nil }
        return capability
    }

    /// Sidebar node id for a folder of `bindingID` (node ids are DERIVED for
    /// folders — unlike collections, node id != item id).
    private static func folderNodeID(_ bindingID: String, _ folderID: String) -> UUID {
        ImbibSidebarNodeID.recordFolder(bindingID, folderID)
    }

    /// Sidebar node id for a collection of ANY binding (ADR-0022 C2).
    ///
    /// The two conventions genuinely differ and must not be unified: folder
    /// node ids are DERIVED (`recordFolder(binding, id)`) because one store id
    /// could appear under several bindings, while a `.libraryCollection` node's
    /// id IS the collection's item id — which is what makes `renameItem`'s
    /// represented object work unchanged for both.
    private static func collectionNodeID(_ bindingID: String, _ collectionID: String) -> UUID {
        if bindingID == CollectionBindingID.publication,
           let uuid = UUID(uuidString: collectionID) {
            return uuid
        }
        return folderNodeID(bindingID, collectionID)
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
            // ADR-0022 C2: deliberately NOT `allowsOrganize`. The frozen macOS
            // behaviour gives a SMART collection the same tree capabilities as
            // a manual one — `capabilities(of:)` has never consulted `isSmart`;
            // only the MENU and the publication drop do. Gating this on the
            // per-row predicate would newly make smart collections
            // undraggable and undeletable, which is a behaviour change, not a
            // convergence. Same set the `.recordFolder` arm below produces for
            // a `canOrganize` binding, so the rows agree anyway.
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
        case .tag:
            // EXPLICIT rather than left to `default`, because "read-only" is a
            // decision here and not an omission (the matrix row records both
            // halves as ❌-planned rather than ➖):
            //  * rename / delete — a tag path is vocabulary shared by every
            //    kind that carries it. Renaming the ROW would fork the
            //    vocabulary for everything this shell cannot see; the honest
            //    verb is a store-wide rewrite that has no Rust seam yet.
            //  * drag — tag rows are alphabetical. There is no user order to
            //    persist, which is exactly what `.flagColor` above has.
            //  * drop — SHOULD apply the tag, and does not yet:
            //    `handlePublicationDrop` has no `.tag` arm, and claiming
            //    `.droppable` before it does would give the row a drop
            //    highlight and then swallow the papers.
            return .readOnly
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
        case .watchedFileFolder:
            // ADR-0023 W4, for the same four reasons as the row below — with
            // drop even less meaningful: for a file-unit kind there is no
            // record to drop ONTO a folder, only files the user puts there.
            return .readOnly
        case .watchedFolder:
            // ADR-0023 W2. Deliberately read-only in the OUTLINE's sense:
            //  * rename — the display name is the provenance tag's leaf and
            //    therefore the identity of "papers this folder produced";
            //    renaming it in place would orphan every tag already written.
            //  * delete — ⌫ on a row that owns imported papers reads as
            //    "delete the papers". The verb is "Stop Watching", in the menu,
            //    where its consequences can be named.
            //  * drop — D4's rule is one-way: the watcher never writes a user's
            //    files, so dropping a paper onto a folder can mean nothing.
            //  * drag — a folder is not a container to reorder into.
            return .readOnly
        default:
            return .readOnly
        }
    }

    // MARK: - Drag-Drop

    private func canAcceptDrop(_ dragged: ImbibSidebarNode, target: ImbibSidebarNode?) -> Bool {
        // An app group is not draggable and never a reorder target: group order
        // is `SiblingApp.descriptors`', the one table, not a per-user
        // preference. (`capabilities(of:)` already withholds `.draggable`, so
        // this is the belt to that's braces.)
        if case .appGroup = dragged.nodeType { return false }

        guard let target = target else {
            // Root level. Flat: sections reorder here. COMPOSED: the root tier
            // is app groups, so a section dropped at root is a section trying
            // to leave its app — refused, and refused VISIBLY (no drop
            // feedback) rather than silently accepted into the wrong place.
            if sidebarComposition != nil { return false }
            return dragged.nodeType.isSection
        }

        // COMPOSED: a section may reorder within ITS OWN group and nowhere
        // else. Without this arm the `(.section, _)` case below would refuse
        // every section drag once a group tier existed — `handleReorder` treats
        // `parent == nil` as "section reorder" and a grouped section's parent is
        // never nil — so section reorder would simply stop working, with no
        // error. That is the "breaks silently" this exists to prevent.
        if case .section = dragged.nodeType, case .appGroup(let targetGroupID) = target.nodeType {
            guard let draggedGroupID = dragged.appGroup?.id else { return false }
            if draggedGroupID == targetGroupID { return true }
            noteCrossGroupRefusal(from: draggedGroupID, to: targetGroupID)
            return false
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

    /// A cross-group section drop was refused. Reported ONCE per distinct pair
    /// rather than on every mouse-move: `canAcceptDrop` runs continuously
    /// during a drag, and a refusal that fills the console is a refusal nobody
    /// reads. The user already sees the refusal (no drop feedback); this is for
    /// the person who has to explain it.
    ///
    /// Also the only reason a `refusedCrossGroupDrops` set exists at all: the
    /// alternative — a silently ignored gesture — is exactly what a section
    /// drag would have become the moment a group tier appeared above it.
    private var refusedCrossGroupDrops: Set<String> = []

    /// Which app group a node belongs to: the group it was adopted into, or —
    /// for a group HEADER, which is a root node and therefore adopted by no
    /// parent — itself.
    private static func owningGroupID(of node: ImbibSidebarNode) -> String? {
        if let id = node.appGroup?.id { return id }
        if case .appGroup(let id) = node.nodeType { return id }
        return nil
    }

    private func noteCrossGroupRefusal(from source: String, to destination: String) {
        let pair = "\(source)→\(destination)"
        guard refusedCrossGroupDrops.insert(pair).inserted else { return }
        Logger.library.warningCapture(
            "Sidebar: refused a cross-group section drop (\(pair)). A section belongs to the "
                + "app whose sidebar it is; reorder it within its own group.",
            category: "sidebar")
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
            // Root level: section reorder. In a COMPOSED sidebar the root tier
            // is app groups, whose order is the suite table's — nothing to
            // reorder and nothing to persist.
            if sidebarComposition != nil { return }
            let newOrder = siblings.compactMap { node -> SidebarSectionType? in
                if case .section(let type) = node.nodeType { return type }
                return nil
            }
            sectionOrder = newOrder
            persistence.saveSectionOrder(newOrder)
            bumpDataVersion()
            return
        }

        switch parentType {
        case .appGroup(let groupID):
            // Section reorder WITHIN a group. The siblings are only that
            // group's sections, so writing them as the whole order would drop
            // every section the other four groups show; the new relative order
            // is merged into the positions the group already occupies instead.
            //
            // The order stays SUITE-WIDE, one `SidebarSectionType` list, which
            // is what it has always been: moving Flagged above Libraries is a
            // statement about the sidebar, and a per-group order would make
            // "where is Flagged" have five answers.
            let reordered = siblings.compactMap { node -> SidebarSectionType? in
                guard case .section(let type) = node.nodeType else { return nil }
                // A mixed-group sibling list should be impossible —
                // `canAcceptDrop` refuses cross-group drops — so if one
                // arrives, say so and drop the whole gesture rather than
                // half-apply it.
                if let owner = node.appGroup?.id, owner != groupID {
                    noteCrossGroupRefusal(from: owner, to: groupID)
                    return nil
                }
                return type
            }
            guard reordered.count == siblings.count else { return }
            sectionOrder = Self.merging(reordered, into: sectionOrder)
            persistence.saveSectionOrder(sectionOrder)
            bumpDataVersion()
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

        case .library, .libraryCollection:
            // ADR-0022 C2: root collections under a library, and sub-collections
            // under a collection, both reorder through the SAME generic path as
            // manuscript and figure folders. The two arms were byte-identical
            // before (each collected `.libraryCollection` ids and called
            // `reorderCollections`), and `reorderFolders` does exactly what
            // `reorderCollections` did: one write per sibling, index as
            // `sort_order`, one non-structural `.otherField` event and one
            // "Edit sort_order" undo entry each.
            reorderFolders(siblings)

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

    // `reorderCollections` is gone (ADR-0022 C2): it was `reorderFolders`
    // written against `store.updateIntField` instead of the kernel, and both
    // of its callers now take the generic path.

    /// Reorder the collection-folder rows of a sibling list (ADR-0022 D3).
    /// Grouped by binding so a mixed list can never cross-number two trees;
    /// in practice a sibling list is homogeneous by construction.
    /// The global section order, with one SUBSET re-sequenced in place.
    ///
    /// The subset's members keep the SLOTS they already occupied in the global
    /// order and are re-filled in the new relative order; sections outside the
    /// subset do not move at all. That is what makes a section drag inside
    /// impress's imprint group a statement about imprint's sections and not a
    /// silent re-shuffle of the four groups the user was not looking at.
    static func merging(
        _ reordered: [SidebarSectionType], into order: [SidebarSectionType]
    ) -> [SidebarSectionType] {
        let subset = Set(reordered)
        var remaining = reordered.filter { order.contains($0) }
        var result: [SidebarSectionType] = []
        result.reserveCapacity(order.count)
        for section in order {
            if subset.contains(section) {
                if !remaining.isEmpty { result.append(remaining.removeFirst()) }
            } else {
                result.append(section)
            }
        }
        // Sections the drag introduced that the global order did not know
        // (a preset can permit a section the persisted order predates).
        for section in reordered where !order.contains(section) {
            result.append(section)
        }
        return result
    }

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
        // COMPOSED: nothing moves BETWEEN app groups. Every reparent below is
        // a store write (a folder's parent, a feed's library), and applying one
        // across groups would move a record container into another app's
        // sidebar while its store row stayed where it was — the two would
        // disagree, on disk, with no error. `canAcceptDrop` already refuses
        // these; this is the write-side half of the same guard, and it says so
        // rather than returning quietly.
        if sidebarComposition != nil, let newParent,
           let source = node.appGroup?.id,
           let destination = Self.owningGroupID(of: newParent),
           source != destination {
            noteCrossGroupRefusal(from: source, to: destination)
            return
        }

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
        // Container-scoped kinds (publication collections) fall through to the
        // container-aware path below: their root is a LIBRARY, not a section
        // header, and their move may have to carry a new container. Manuscript
        // and figure folders — `container == nil` — take this branch exactly as
        // they always have.
        if let folder = folderNode(node), folder.capability.canOrganize,
           folder.capability.container == nil {
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

        // ADR-0022 C2: publication collections reparent through the KERNEL, with
        // the owning library carried as the container argument.
        //
        // What this replaces was the clearest case for the container axis in the
        // whole survey: TWO Swift writes (`updateField("parent_id")` plus a
        // conditional `reparentItem`) that had to stay consistent by hand, plus
        // a Swift ancestor walk over a legacy read. `reparent_in` performs both
        // writes in one `store.update` and does the cycle check in Rust.
        //
        // The container is passed ONLY when the library actually changes —
        // matching the legacy `if sourceLibraryID != targetLibID` guard exactly,
        // so a same-library move is still a one-field write and its undo still
        // leaves the envelope alone.
        //
        // DELIBERATE IMPROVEMENT, recorded rather than smuggled: this move now
        // has a complete, exact Undo entry ("Move Folder"). The legacy path
        // registered only the `updateField` half, so undoing a cross-library
        // move restored the tree parent and left the collection in the wrong
        // library. That is the same gap figure folders closed in G2.
        guard case .libraryCollection(let collectionID, let sourceLibraryID) = node.nodeType,
              let newParent else { return }
        let adapter = CollectionStoreAdapter.shared
        let bindingID = CollectionBindingID.publication
        let movingID = collectionID.uuidString.lowercased()

        let destination: (parentID: String?, libraryID: UUID)
        switch newParent.nodeType {
        case .library(let libraryID):
            destination = (nil, libraryID)
        case .libraryCollection(let targetColID, let targetLibID):
            guard targetColID != collectionID,
                  !adapter.isAncestor(
                    bindingID, ancestorID: movingID,
                    of: targetColID.uuidString.lowercased())
            else { return }
            destination = (targetColID.uuidString.lowercased(), targetLibID)
        default:
            return
        }

        adapter.reparent(
            bindingID,
            id: movingID,
            newParentID: destination.parentID,
            newContainerID: sourceLibraryID == destination.libraryID
                ? nil
                : destination.libraryID.uuidString.lowercased())
        libraryManager?.loadLibraries()
        bumpDataVersion()
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
    //
    // C2 retired the LAST Swift ancestor walk with it: the publication-collection
    // copy that took `[CollectionModel]` from `store.listCollections`. Its only
    // caller, `handleReparent`, now uses the same adapter pre-check as every
    // other binding, so there is one drag-feedback walk in the app and one
    // authoritative check in Rust.

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

        case .libraryCollection(let collectionID, _):
            // ADR-0022 C2: the smart guard is the KERNEL row's `isSmart` (axis
            // 2), read through the marker-aware adapter, instead of a
            // `store.listCollections(libraryId:)` scan that goes blind at the
            // WP G7 flip. Same predicate, same refusal, one fewer legacy read.
            let bindingID = CollectionBindingID.publication
            let itemID = collectionID.uuidString.lowercased()
            guard let row = CollectionStoreAdapter.shared.row(bindingID, id: itemID),
                  !row.isSmart else { return }
            // Membership is the kernel's `Contains` edge — the SAME edge
            // `ImbibStore.add_to_collection` writes.
            //
            // The wave-3 survey listed "also ensures library membership" as a
            // fifth axis this path needed. It is a PHANTOM: that claim came
            // from the call-site comment below, not from the code —
            // `add_to_collection` is thirty lines of `AddReference(Contains)`
            // and nothing else. So `addMembers` is already faithful, and no
            // ensure-container hook was added for a behaviour that never
            // existed. (Full note in `collection_ops`' module docs.)
            CollectionStoreAdapter.shared.addMembers(
                bindingID, collectionID: itemID,
                itemIDs: uuids.map { $0.uuidString.lowercased() },
                undo: .coordinator)
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

        case .inboxCollection(collectionID: let colID):
            // NOT converged: the Inbox tier's collections still build their
            // nodes from `store.listCollections(inboxLib.id)`, so routing the
            // WRITE through the kernel while the READ stays legacy would give
            // one tree two writers. Converges with the inbox tier (C2 matrix).
            store.updateField(id: colID, field: "name", value: trimmed)
            bumpDataVersion()

        case .inboxFeed(let feedID), .libraryFeed(let feedID, _):
            store.updateField(id: feedID, field: "name", value: trimmed)
            bumpDataVersion()

        case .libraryCollection, .recordFolder:
            // Collection folders (ADR-0022 D3): one rename for every binding —
            // and, since C2, for publication collections too. The payload field
            // is `name` for all of them; where the row NESTS (payload ref vs.
            // envelope parent) and which CONTAINER it sits in are both
            // irrelevant to a rename.
            //
            // Event and undo parity with the `store.updateField(field:"name")`
            // this replaces is exact: the kernel's `applyRename` posts
            // (structural: false, [id], .otherField) and registers
            // `StoreKernelUndoAction.renameCollection` — the same "Edit name"
            // string the Rust `SetPayload("name")` undo description carried.
            //
            // No `loadLibraries()` here, deliberately: the legacy path did not
            // reload either, and the collection tree is rebuilt from the store
            // on every `bumpDataVersion()` anyway.
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

        case .watchedFolder(let folderID, _):
            buildWatchedFolderContextMenu(menu, folderID: folderID)

        case .watchedFileFolder(let folderID, let kindScope):
            buildWatchedFileFolderContextMenu(menu, folderID: folderID, kindScope: kindScope)

        case .libraryCollection(_, let libID):
            // ADR-0022 C2: the SAME builder as manuscript/figure folders. The
            // per-row smart predicate and the owning library are arguments now,
            // not a second `store.listCollections` read inside the builder.
            guard let folder = folderNode(node) else { return nil }
            buildFolderContextMenu(
                menu, capability: folder.capability, folderID: folder.folderID,
                nodeID: node.id,
                allowsOrganize: allowsOrganize(node, tierID: CollectionTierID.libraries),
                containerID: libID.uuidString.lowercased())

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

            // ADR-0023 W2 — the folder-picking affordance, next to the verb it
            // is a sibling of ("New Library" makes an empty one; this adopts a
            // folder of .bib/.ris files that already exists).
            let watchItem = NSMenuItem(title: "Add Watched Folder…", action: #selector(ContextMenuActions.addWatchedFolder(_:)), keyEquivalent: "")
            watchItem.target = ContextMenuActions.shared
            menu.addItem(watchItem)

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

        // ADR-0023 W4 — "Watch Folder…" on any section that hosts a FILE-unit
        // kind's watched folders. Appended after the switch rather than in an
        // arm of it, because the sections that qualify are declared data
        // (`watchedFileSections`) and the `default:` arm above already returns
        // for two of the three.
        if let kindScope = Self.watchedFileSections.first(where: { $0.value == section })?.key,
            let capability = BuiltinRecordKinds.fileDiscovery(forKindScope: kindScope) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let extensions = capability.fileExtensions.map { ".\($0)" }.joined(separator: " / ")
            let watchItem = NSMenuItem(
                title: "Watch Folder for \(extensions) Files…",
                action: #selector(ContextMenuActions.addWatchedFileFolder(_:)),
                keyEquivalent: "")
            watchItem.target = ContextMenuActions.shared
            watchItem.representedObject = kindScope
            menu.addItem(watchItem)
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

    // `buildCollectionContextMenu` is gone (ADR-0022 C2). It was
    // `buildFolderContextMenu` with three literals instead of the capability's
    // nouns and an `isSmart` read of its own; the generic builder now takes the
    // per-row predicate as an argument, so publication collections and folders
    // share ONE builder. The labels are unchanged: `containerNoun: "Collection"`
    // yields "New Subcollection", and `deleteTitleOverride: "Delete"` keeps the
    // bare Delete imbib has always shown.

    /// Context menu for a collection folder of ANY binding (ADR-0022 D3).
    /// The manuscript and figure menus were already label-for-label
    /// identical — Rename / New Subfolder / ─── / Delete Folder — so the
    /// merge is literal; only the represented objects carry the binding now.
    /// - Parameters:
    ///   - allowsOrganize: the PER-ROW predicate (ADR-0022 C2 axis 2). `false`
    ///     emits Delete only — imbib's frozen smart-collection menu. Always
    ///     `true` for manuscript and figure folders, whose schemas have no
    ///     smart rows, so their menus are unchanged.
    ///   - containerID: the owning library, for the container-scoped bindings
    ///     whose "New Subcollection" must name it.
    private func buildFolderContextMenu(
        _ menu: NSMenu, capability: CollectionCapability, folderID: String, nodeID: UUID,
        allowsOrganize: Bool = true, containerID: String? = nil
    ) {
        guard capability.canOrganize else { return }

        if allowsOrganize {
            let renameItem = NSMenuItem(title: "Rename", action: #selector(ContextMenuActions.renameItem(_:)), keyEquivalent: "")
            renameItem.target = ContextMenuActions.shared
            // Rename edits by SIDEBAR NODE id — derived for folders, and equal
            // to the item id for collections, which `collectionNodeID` unifies.
            renameItem.representedObject = nodeID
            menu.addItem(renameItem)

            let newSubItem = NSMenuItem(title: capability.newSubContainerTitle, action: #selector(ContextMenuActions.createFolder(_:)), keyEquivalent: "")
            newSubItem.target = ContextMenuActions.shared
            newSubItem.representedObject = FolderMenuTarget(
                bindingID: capability.bindingID, folderID: folderID, containerID: containerID)
            menu.addItem(newSubItem)

            menu.addItem(.separator())
        }

        let deleteItem = NSMenuItem(title: capability.deleteContainerTitle, action: #selector(ContextMenuActions.deleteFolder(_:)), keyEquivalent: "")
        deleteItem.target = ContextMenuActions.shared
        deleteItem.representedObject = FolderMenuTarget(
            bindingID: capability.bindingID, folderID: folderID, containerID: containerID)
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

    /// Persist a row's new expanded/collapsed state.
    ///
    /// This method existed with NO CALLERS: collapse state was loaded at launch
    /// and never written, in all six shells, because `SidebarOutlineView` had
    /// nowhere to call it from. It now has one
    /// (`SidebarOutlineConfiguration.onExpansionChanged`), and it handles both
    /// tiers — an app group and a per-group section key the composed key space,
    /// a flat section keeps the key space the five siblings have always used.
    ///
    /// Taking the NODE rather than a bare id is what makes the composed half
    /// possible: a grouped section's id is namespaced, so it cannot be matched
    /// against `ImbibSidebarNodeID.section(_:)`, and the group it belongs to is
    /// on the node.
    func handleExpansionChange(node: ImbibSidebarNode, expanded: Bool) {
        if let group = node.appGroup ?? appGroupBinding(of: node) {
            let key: SidebarCompositionKey
            switch node.nodeType {
            case .appGroup:
                key = group.collapseKey
            case .section(let section):
                key = group.collapseKey(section: section)
            default:
                // Folders and leaves inside a group are in-memory expansion
                // state, exactly as they are in a flat sidebar.
                return
            }
            if expanded {
                collapsedComposition.remove(key)
            } else {
                collapsedComposition.insert(key)
            }
            persistence.saveComposedCollapse(collapsedComposition)
            return
        }

        // Flat: check if this is a section node
        guard case .section(let section) = node.nodeType,
              sectionOrder.contains(section) else { return }
        if expanded {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
        persistence.saveCollapsedSections(collapsedSections)
    }

    /// The group binding for an app-group HEADER, which carries its own group
    /// but is not `adopting`-ed by any parent (it is a root node).
    private func appGroupBinding(of node: ImbibSidebarNode) -> SidebarNodeGroup? {
        guard case .appGroup(let id) = node.nodeType,
              let group = sidebarComposition?[id] else { return nil }
        return SidebarNodeGroup(group: group, host: shellConfiguration)
    }

    // MARK: - Flag Counts

    func refreshFlagCounts() {
        flagCounts = flagCountsSnapshot(ofKind: shellConfiguration.recordKind(for: .flagged))

        // A composed sidebar shows SEVERAL Flagged sections at once, one per
        // group, each bound to its group's own kind. Precompute them here — the
        // tree build is synchronous and must not fan out store reads per row.
        // Empty (and therefore free) in a flat sidebar.
        guard let composition = sidebarComposition else {
            flagCountsByKind = [:]
            return
        }
        var byKind: [RecordKindID: FlagCounts] = [:]
        for group in composition.groups {
            guard let kind = group.configuration.recordKind(for: .flagged),
                  byKind[kind] == nil else { continue }
            byKind[kind] = flagCountsSnapshot(ofKind: kind)
        }
        flagCountsByKind = byKind
    }

    /// Flag counts for one record kind. `.manuscript` and `.publication` are
    /// the two kinds with a flag-only read verb; any other kind reports no
    /// counts rather than paying for a full scan (the ROWS are still correct —
    /// this is the badge, and a missing badge is the shipped behaviour for
    /// every kind that has never had one).
    private func flagCountsSnapshot(ofKind kind: RecordKindID?) -> FlagCounts {
        var total = 0
        var byColor: [String: Int] = [:]
        if kind == .manuscript {
            // Manuscript-flag shells (imprint): the Flagged section counts
            // flagged manuscripts, matching what its rows list.
            for row in RustStoreAdapter.shared.getFlaggedManuscripts() {
                if let color = row.flagColor {
                    total += 1
                    byColor[color, default: 0] += 1
                }
            }
        } else if kind == nil || kind == .publication {
            // Use getFlaggedPublications — returns only flagged rows, avoiding
            // a full table scan.
            for pubRow in store.getFlaggedPublications() {
                if let color = pubRow.flag?.color {
                    total += 1
                    byColor[color.rawValue, default: 0] += 1
                }
            }
        } else {
            return .empty
        }
        return FlagCounts(total: total, byColor: byColor)
    }

    /// The counts a Flagged section should show under a given preset.
    ///
    /// Keyed on whether this shell COMPOSES, not on whether the per-kind cache
    /// happens to be populated: the first tree is built before
    /// `refreshFlagCounts` runs, and falling back to `flagCounts` there would
    /// put imbib's publication badges on imprint's manuscript rows for a frame.
    /// No badge is the honest answer while the count is unknown.
    private func resolvedFlagCounts(under configuration: AppShellConfiguration?) -> FlagCounts {
        guard sidebarComposition != nil else { return flagCounts }
        guard let kind = configuration?.recordKind(for: .flagged) else { return .empty }
        return flagCountsByKind[kind] ?? .empty
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
    /// - Parameter containerID: the OWNING CONTAINER to create in (ADR-0022
    ///   C2) — imbib's library, which a ROOT collection cannot inherit from a
    ///   parent because it has none. `nil` for bindings with no container axis.
    func createFolder(bindingID: String, parentID: String? = nil, containerID: String? = nil) {
        // CREATION is the one publication-collection verb that does NOT converge
        // this wave, and the reason is the Edit menu, not the store: the legacy
        // path registers its undo as "Create Collection" while the kernel's
        // `create` registers `StoreKernelUndoAction.createCollection` = "New
        // Folder". Routing publications through the kernel would silently
        // relabel a live Edit-menu entry, and the frozen-behaviour bar forbids
        // that. Closing it needs a capability-declared create action name — a
        // deliberate UX decision, not a side effect of a refactor.
        //
        // The MENU is converged regardless: one builder, one represented-object
        // type, the container axis carrying the difference. Only the
        // implementation forks, here, once.
        if bindingID == CollectionBindingID.publication {
            guard let container = containerID.flatMap({ UUID(uuidString: $0) }) else { return }
            createCollection(in: container, parentID: parentID.flatMap { UUID(uuidString: $0) })
            return
        }

        // The default NAME is the capability's noun, not a literal.
        let capability = BuiltinRecordKinds.collectionCapability(forBindingID: bindingID)
        let noun = capability?.containerNoun ?? "Folder"
        let name = parentID != nil ? "New Sub\(noun.lowercased())" : "New \(noun)"
        guard let row = CollectionStoreAdapter.shared.create(
            bindingID,
            name: name,
            parentID: parentID,
            containerID: containerID
        ) else { return }
        if let parentID {
            expansionState.expand(Self.collectionNodeID(bindingID, parentID))
        }
        // Publication collections hang off LIBRARY nodes, whose counts and
        // children the manager owns; the folder bindings have no such host.
        if containerID != nil {
            if let container = containerID.flatMap({ UUID(uuidString: $0) }) {
                expansionState.expand(container)
            }
            libraryManager?.loadLibraries()
        }
        bumpDataVersion()
        Self.logger.infoCapture(
            "created \(bindingID) folder '\(row.name)' (\(row.id)) parent=\(parentID ?? "root")"
                + (containerID.map { " container=\($0)" } ?? ""),
            category: "sidebar")
        let newNodeID = Self.collectionNodeID(bindingID, row.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.editingNodeID = newNodeID
        }
    }

    /// Delete a collection folder. Contained records are NEVER deleted — the
    /// membership goes away with the row (`Contains` edges cascade; envelope-
    /// filed members are unfiled by `ON DELETE SET NULL`).
    func deleteFolder(bindingID: String, folderID: String) {
        // Publication collections carry their own selection route
        // (`.collection(id)`, not `.record(.folder(...))`) and their own host
        // refresh, so the clear-selection step is per-binding. Both branches
        // then run the SAME kernel delete.
        if bindingID == CollectionBindingID.publication {
            if let uuid = UUID(uuidString: folderID) {
                switch selectedTab {
                case .collection(let id) where id == uuid,
                     .inboxCollection(let id) where id == uuid,
                     .explorationCollection(let id) where id == uuid:
                    selectedNodeID = nil
                default:
                    break
                }
            }
        } else if let selected = selectedFolderID(bindingID),
                  selected == UUID(uuidString: folderID) {
            selectedNodeID = nil
        }
        CollectionStoreAdapter.shared.delete(bindingID, id: folderID)
        if bindingID == CollectionBindingID.publication {
            libraryManager?.loadLibraries()
        }
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
                // ADR-0022 C2: the same kernel delete the context-menu Delete
                // now runs, so ⌫ and the menu cannot diverge. Undo action name
                // is unchanged ("Delete" both before and after), and the
                // kernel's `restore` puts back membership and child
                // collections that the old item-snapshot undo dropped.
                deleteFolder(
                    bindingID: CollectionBindingID.publication,
                    folderID: id.uuidString.lowercased())
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
    /// The OWNING CONTAINER the action applies in (ADR-0022 C2) — imbib's
    /// library. `nil` for bindings with no container axis, which is what
    /// manuscript and figure folders always carry.
    let containerID: String?

    init(bindingID: String, folderID: String?, containerID: String? = nil) {
        self.bindingID = bindingID
        self.folderID = folderID
        self.containerID = containerID
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

    // `createSubcollection` is gone (ADR-0022 C2): "New Subcollection" is built
    // by the generic folder menu now and carries a `FolderMenuTarget`
    // (binding + parent + container), so the `[String: UUID]` dictionary this
    // unpacked has no producer left.

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
        viewModel?.createFolder(
            bindingID: target.bindingID, parentID: target.folderID,
            containerID: target.containerID)
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
