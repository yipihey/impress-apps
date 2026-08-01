//
//  ImbibSidebarBindings.swift
//  imbib-iOS
//
//  The ENTIRE app-specific surface of imbib's iOS sidebar (Stage 5a).
//
//  It replaces `IOSSidebarView.swift` — 1,357 lines with a fifteen-arm
//  `switch sectionType` that read NO `AppShellConfiguration` and rendered
//  `.sharedWithMe` / `.artifacts` / `.reviewQueue` / `.dismissed` as
//  `EmptyView()`. Which sections exist, in what order, with which titles and
//  icons, and which record kind each serves now come from
//  `AppShellConfiguration.imbib` and `PublicationRecordKind.descriptor`, and
//  are rendered by PMC's `RecordSidebarBuilder` / `RecordSidebarView` — the
//  same two files imprint-iOS runs on.
//
//  This file only says WHERE the rows come from (`RustStoreAdapter`,
//  `LibraryManager`, `SciXLibraryRepository`) and translates the chassis's
//  `RecordSidebarScope` into imbib-iOS's existing `SidebarSection` routes, in
//  both directions — the sidebar writes selection, and imbib's notifications
//  (`navigateToCollection`, `navigateToSmartSearch`, `showInbox`, …) write it
//  too, so the mapping has to round-trip. Binding-only: there is no
//  `onSelect` callback anywhere below.
//
//  The chrome (sheets, toolbar menus, pull-to-refresh, notification wiring)
//  lives in `IOSSidebarHost.swift`; the shape lives in the preset; the rows
//  live here.
//

import Foundation
import ImpressFTUI
import ImpressLogging
import OSLog
import PublicationManagerCore
import SwiftUI

// MARK: - Route vocabulary

/// imbib's half of `RecordSidebarScope.host` (which see): the rows whose
/// meaning the chassis cannot know.
///
/// Half of imbib's sidebar is neither a status, a folder of the publication
/// kind's collection binding, nor a whole section: libraries sit ABOVE the
/// collection tree (each owns its own), feeds are a stored query rather than a
/// stored membership, SciX libraries are someone else's shelf, and search
/// forms are not record scopes at all. This enum is the ONE place their keys
/// are spelled, so `scope(for:)` and `section(for:)` cannot drift apart.
enum ImbibSidebarRoute: Hashable {
    /// Papers the user viewed or added by hand.
    case recent
    case library(UUID)
    /// A smart search: an inbox feed, a library feed, or an exploration search.
    case feed(UUID)
    case scixLibrary(UUID)
    case searchForm(SearchFormType)
    /// A selection the sidebar has NO row for — imbib's legacy `.search`
    /// route (the online-search pane, reached by ⌘S and `searchCategory`) and
    /// `.manuscripts`. Non-nil on purpose: `RecordSidebarView` seeds a default
    /// selection whenever the binding reads nil, so a nil here would yank the
    /// content pane back to the Inbox on every rebuild.
    case contentOnly

    var key: String {
        switch self {
        case .recent: return "recent"
        case .library(let id): return "library.\(id.uuidString.lowercased())"
        case .feed(let id): return "feed.\(id.uuidString.lowercased())"
        case .scixLibrary(let id): return "scix.\(id.uuidString.lowercased())"
        case .searchForm(let form): return "form.\(form.rawValue)"
        case .contentOnly: return "content-only"
        }
    }

    init?(key: String) {
        switch key {
        case "recent": self = .recent; return
        case "content-only": self = .contentOnly; return
        default: break
        }
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "library":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .library(id)
        case "feed":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .feed(id)
        case "scix":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .scixLibrary(id)
        case "form":
            guard let form = SearchFormType(rawValue: parts[1]) else { return nil }
            self = .searchForm(form)
        default:
            return nil
        }
    }

    var scope: RecordSidebarScope { .host(.publication, key: key) }
}

// MARK: - Store snapshot

/// One store read per version, shared by every row.
///
/// The sidebar asks for libraries, per-library collections and feeds, the
/// inbox subtree, the exploration subtree, the cited count and the flag counts
/// on every rebuild; the old sidebar answered each from its own `@State` and a
/// hand-written `refresh()`. This is imprint's `ManuscriptSidebarCounts` with
/// imbib's reads, invalidated by the same `dataVersion` the views observe.
@MainActor
final class ImbibSidebarSnapshot {

    private var version: Int = .min

    private(set) var libraries: [LibraryModel] = []
    private(set) var collectionsByLibrary: [UUID: [CollectionModel]] = [:]
    private(set) var feedsByLibrary: [UUID: [SmartSearch]] = [:]
    private(set) var inboxLibrary: LibraryModel?
    private(set) var inboxCollections: [CollectionModel] = []
    private(set) var inboxFeeds: [SmartSearch] = []
    private(set) var explorationCollections: [CollectionModel] = []
    private(set) var explorationSearches: [SmartSearch] = []
    private(set) var dismissedLibrary: LibraryModel?
    /// Every non-smart collection in the workspace, flat — the move/rename
    /// target set the shared organise menu resolves against.
    private(set) var organisableFolders: [RecordFolder] = []
    private(set) var libraryOfCollection: [UUID: UUID] = [:]
    /// Member count for EVERY collection — inbox, library and exploration
    /// alike, which is why it is not derived from `collectionsByLibrary`.
    private(set) var publicationCountByCollection: [UUID: Int] = [:]
    private(set) var citedCount: Int = 0
    private(set) var flagTotal: Int = 0
    private(set) var flagCountsByColor: [String: Int] = [:]
    /// The tag vocabulary, flat and slash-separated — what the Tags section's
    /// tree is derived from. Read HERE rather than in the closure because
    /// `listTags()` is an FFI round trip that builds a struct per definition
    /// (23,916 of them in imbib), and the sidebar's filter field asks for it
    /// again on every keystroke.
    private(set) var tagPaths: [String] = []

    /// Set by the host once the ADS credential check completes; part of the
    /// version key so the SciX section appears without waiting for a store
    /// mutation.
    var scixAvailable = false

    func refresh(_ store: RustStoreAdapter, libraryManager: LibraryManager, force: Bool = false) {
        guard force || version != store.dataVersion else { return }
        version = store.dataVersion

        var specialIDs = Set<UUID>()
        inboxLibrary = store.getInboxLibrary()
        if let inbox = inboxLibrary { specialIDs.insert(inbox.id) }
        let explorationLibrary = libraryManager.explorationLibrary
        for special in [explorationLibrary, libraryManager.saveLibrary, libraryManager.dismissedLibrary] {
            if let special { specialIDs.insert(special.id) }
        }
        dismissedLibrary = libraryManager.dismissedLibrary

        libraries = store.listLibraries().filter { !$0.isInbox && !specialIDs.contains($0.id) }

        var collections: [UUID: [CollectionModel]] = [:]
        var feeds: [UUID: [SmartSearch]] = [:]
        var folders: [RecordFolder] = []
        var owner: [UUID: UUID] = [:]
        var memberCounts: [UUID: Int] = [:]

        func index(_ rows: [CollectionModel], library: UUID) {
            for row in rows {
                owner[row.id] = library
                memberCounts[row.id] = row.publicationCount
                guard !row.isSmart else { continue }
                folders.append(
                    RecordFolder(
                        id: row.id, name: row.name, parentID: row.parentID,
                        sortOrder: Int64(row.sortOrder)))
            }
        }

        for library in libraries {
            let rows = store.listCollections(libraryId: library.id)
            collections[library.id] = rows
            // `!feedsToInbox` (not macOS's stricter `autoRefreshEnabled &&
            // !feedsToInbox`): the hand-written sidebar listed every
            // non-inbox-bound smart search under its library, and narrowing it
            // here would silently drop rows the user has today.
            feeds[library.id] = store.listSmartSearches(libraryId: library.id)
                .filter { !$0.feedsToInbox }
            index(rows, library: library.id)
        }
        collectionsByLibrary = collections
        feedsByLibrary = feeds

        if let inbox = inboxLibrary {
            inboxCollections = store.listCollections(libraryId: inbox.id)
            inboxFeeds = store.listSmartSearches(libraryId: inbox.id).filter(\.feedsToInbox)
            index(inboxCollections, library: inbox.id)
        } else {
            inboxCollections = []
            inboxFeeds = []
        }

        if let exploration = explorationLibrary {
            let rows = store.listCollections(libraryId: exploration.id)
            explorationCollections = rows
            explorationSearches = store.listSmartSearches(libraryId: exploration.id)
            index(rows, library: exploration.id)
        } else {
            explorationCollections = []
            explorationSearches = []
        }

        organisableFolders = folders
        libraryOfCollection = owner
        publicationCountByCollection = memberCounts

        citedCount = CitedInManuscriptsSnapshot.shared.citedPaperIDs.count

        // The flag rows had NO counts in the hand-written sidebar; macOS has
        // shown them since ADR-0021. One flagged-only read (never a full
        // table scan), exactly like `ImbibSidebarViewModel.refreshFlagCounts`.
        var total = 0
        var byColor: [String: Int] = [:]
        for row in store.getFlaggedPublications() {
            guard let color = row.flag?.color else { continue }
            total += 1
            byColor[color.rawValue, default: 0] += 1
        }
        flagTotal = total
        flagCountsByColor = byColor

        // De-duplicated: the definitions table may hold a path more than once
        // (the real library had 23,916 rows for 9,090 paths), and the tree
        // builder should not pay for that on every rebuild.
        tagPaths = Array(Set(store.listTags().map(\.path)))
    }
}

// MARK: - Bindings

@MainActor
enum ImbibSidebarBindings {

    private static var store: RustStoreAdapter { RustStoreAdapter.shared }

    /// imbib's declarative identity. The sidebar is whatever this says.
    ///
    /// `.presenting([.publication])` is this HOST's capability statement.
    /// `AppShellConfiguration.imbib` also permits `.artifacts`, whose rows are
    /// `artifact@1.0.0` items rendered on macOS by `ArtifactListWrapper` —
    /// imbib-iOS has no artifact surface at all, so naming the KIND drops that
    /// section (and any future artifact-bound one) without a section-name
    /// literal in app code. Publications are the one kind this build renders:
    /// `IOSUnifiedPublicationListWrapper` and `DetailView`.
    static var configuration: AppShellConfiguration {
        .imbib.presenting([.publication])
    }

    static var descriptor: RecordKindDescriptor { PublicationRecordKind.descriptor }

    /// The rebuild trigger. The store's version alone is not enough: hiding a
    /// search form or reordering the section list changes the ROWS without
    /// touching the store, and `RecordSidebarView` rebuilds on this Int.
    static func dataVersion(chromeRevision: Int) -> Int {
        store.dataVersion &* 1_000 &+ chromeRevision
    }

    // MARK: Scope translation (chassis vocabulary ⇄ imbib-iOS routes)

    /// `RecordSidebarScope` → the route `IOSContentView.contentList` renders.
    /// nil = this shell has no content for that node.
    static func section(for scope: RecordSidebarScope?) -> SidebarSection? {
        switch scope {
        case .host(_, let key):
            // ADR-0023 W2: watched-folder keys are the chassis's own vocabulary
            // (`WatchedFolderRoute`, whose `keyPrefix` is public precisely so a
            // host can recognise keys it did not build), so they are resolved
            // BEFORE imbib's route enum — which would return nil for them and
            // silently drop the selection.
            if case .folder(let folderID)? = WatchedFolderRoute(key: key) {
                return .watchedFolder(folderID)
            }
            switch ImbibSidebarRoute(key: key) {
            case .recent: return .recent
            case .library(let id): return .library(id)
            case .feed(let id): return .smartSearch(id)
            case .scixLibrary(let id): return .scixLibrary(id)
            case .searchForm(let form): return .searchForm(form)
            case .contentOnly, nil: return nil
            }
        // Every collection — inbox, library or exploration — is one route:
        // `IOSUnifiedPublicationListWrapper(source: .collection(id))`.
        case .folder(_, let id): return .collection(id)
        case .flagged(_, let color): return .flagged(color)
        // The same destination a watched folder's row lands on — one scope,
        // two doors (ADR-0023 W2 built the door; this is the general one).
        case .tag(_, let path): return .tag(path)
        case .section(.inbox, _): return .inbox
        case .section(.citedInManuscripts, _): return .citedInManuscripts
        case .section(.dismissed, _): return .dismissed
        // The publication descriptor declares no status lifecycle, so the
        // builder never emits these for imbib.
        case .all, .status, .section, nil: return nil
        }
    }

    /// The inverse, for the writers that are NOT the sidebar: imbib navigates
    /// by notification (`showInbox`, `navigateToCollection`,
    /// `navigateToSmartSearch`, `showLibrary`, `searchCategory`) and by ⌘S, and
    /// the sidebar's highlight has to follow.
    static func scope(for section: SidebarSection?) -> RecordSidebarScope? {
        switch section {
        case .inbox: return .section(.inbox, .publication)
        case .recent: return ImbibSidebarRoute.recent.scope
        case .library(let id): return ImbibSidebarRoute.library(id).scope
        case .smartSearch(let id): return ImbibSidebarRoute.feed(id).scope
        case .scixLibrary(let id): return ImbibSidebarRoute.scixLibrary(id).scope
        case .searchForm(let form): return ImbibSidebarRoute.searchForm(form).scope
        case .collection(let id), .inboxCollection(let id): return .folder(.publication, id)
        case .flagged(let color): return .flagged(.publication, color)
        case .citedInManuscripts: return .section(.citedInManuscripts, .publication)
        case .dismissed: return .section(.dismissed, .publication)
        case .tag(let path): return .tag(.publication, path)
        case .watchedFolder(let id): return WatchedFolderRoute.folder(id).scope(kind: .publication)
        // Routes with no sidebar row of their own.
        case .search, .manuscripts: return ImbibSidebarRoute.contentOnly.scope
        case nil: return nil
        }
    }

    // MARK: Data source

    static func dataSource(
        snapshot: ImbibSidebarSnapshot,
        libraryManager: LibraryManager,
        searchForms: [SearchFormType]
    ) -> RecordSidebarDataSource {
        // Every closure refreshes first; `refresh` is a no-op once the
        // snapshot's version matches the store's, so a whole rebuild costs one
        // read pass however many times the builder asks. (imprint's
        // `ManuscriptSidebarCounts.models(_:)` is the same trick — the
        // alternative is ordering the host's refresh against the child view's
        // `onChange`, which SwiftUI does not promise.)
        let sync = { snapshot.refresh(RustStoreAdapter.shared, libraryManager: libraryManager) }
        return RecordSidebarDataSource(
            folders: { kind in
                sync()
                guard kind == .publication else { return [] }
                return snapshot.organisableFolders
            },
            folderCounts: { kind, ids in
                sync()
                guard kind == .publication else { return ids.map { _ in 0 } }
                return ids.map { snapshot.publicationCountByCollection[$0] ?? 0 }
            },
            count: { scope in
                sync()
                switch scope {
                case .flagged(_, let color):
                    guard let color else { return snapshot.flagTotal }
                    return snapshot.flagCountsByColor[color]
                case .section(.citedInManuscripts, _):
                    return snapshot.citedCount
                case .section(.dismissed, _):
                    return snapshot.dismissedLibrary?.publicationCount
                default:
                    // No `.tag` badge, deliberately: a count per tag row is one
                    // query per row over a 23,916-path vocabulary, and the rows
                    // are built lazily precisely to avoid that shape.
                    return nil
                }
            },
            tags: { kind in
                sync()
                guard kind == .publication else { return [] }
                return snapshot.tagPaths
            },
            sectionIsAvailable: { section in
                sync()
                // The CONTENT gate — "is there anything in it right now" —
                // transcribed from macOS `ImbibSidebarViewModel.shouldShowSection`
                // so the two shells hide the same sections for the same reasons.
                switch section {
                case .inbox, .libraries, .search, .flagged:
                    return true
                case .tags:
                    // The WHOLE vocabulary, never the filtered one: a section
                    // that vanished on the first non-matching keystroke would
                    // take the filter field with it (same rule as macOS's
                    // `ImbibSidebarViewModel.shouldShowSection`).
                    return !snapshot.tagPaths.isEmpty
                case .sharedWithMe:
                    // `LibraryManager` has no shared-library list on EITHER
                    // platform yet. macOS returns [] here; this shell says so
                    // out loud instead of the old `EmptyView()` arm, so the
                    // day the feature lands one gate flips.
                    return false
                case .scixLibraries:
                    return snapshot.scixAvailable && !SciXLibraryRepository.shared.libraries.isEmpty
                case .exploration:
                    return !snapshot.explorationSearches.isEmpty
                        || !snapshot.explorationCollections.isEmpty
                case .citedInManuscripts:
                    return snapshot.citedCount > 0
                case .dismissed:
                    return (snapshot.dismissedLibrary?.publicationCount ?? 0) > 0
                case .reviewQueue:
                    // Pending agent review-requests are `review-request@1.0.0`
                    // items with no `RecordKindDescriptor`, so the section is
                    // UNBOUND and `presentableKinds` cannot speak for it. This
                    // build has no review pane (macOS renders `ReviewQueueView`),
                    // and that is a HOST capability gap, which is what this
                    // gate is for.
                    return false
                case .artifacts, .manuscripts, .figures, .mail, .agents:
                    // Dropped earlier and more precisely: `.artifacts` by
                    // `presenting([.publication])`, the rest by imbib's
                    // `visibleSections` and the facet gate.
                    return true
                }
            },
            sectionContent: { section, _ in
                sync()
                return sectionContent(section, snapshot: snapshot, searchForms: searchForms)
            }
        )
    }

    // MARK: Section rows

    private static func sectionContent(
        _ section: SidebarSectionType,
        snapshot: ImbibSidebarSnapshot,
        searchForms: [SearchFormType]
    ) -> RecordSidebarSectionContent? {
        switch section {
        case .inbox:
            var nodes = [
                RecordSidebarNode(
                    scope: ImbibSidebarRoute.recent.scope,
                    title: "Recent",
                    systemImage: "clock.arrow.circlepath")
            ]
            nodes += snapshot.inboxFeeds.map(feedNode)
            nodes += collectionNodes(snapshot.inboxCollections, includeSmart: false)
            return RecordSidebarSectionContent(
                nodes: nodes,
                // "Inbox" names a destination, not just a group of rows —
                // macOS's `resolveSelectedTab` maps the section node itself to
                // `.inbox`, and the old iOS header carried the same tap.
                headerScope: .section(.inbox, .publication),
                canOrganizeFolders: true,
                // Root collections belong to the inbox LIBRARY, created from
                // the header's own `+` menu (host chrome), not from a generic
                // "new folder at the section root".
                offersRootFolderCreation: false)

        case .libraries:
            let nodes = snapshot.libraries.map { library -> RecordSidebarNode in
                let feeds = (snapshot.feedsByLibrary[library.id] ?? []).map(feedNode)
                let collections = collectionNodes(
                    snapshot.collectionsByLibrary[library.id] ?? [], includeSmart: true)
                return RecordSidebarNode(
                    scope: ImbibSidebarRoute.library(library.id).scope,
                    title: library.name,
                    systemImage: "book.closed",
                    count: library.publicationCount > 0 ? library.publicationCount : nil,
                    children: feeds + collections)
            }
            // ADR-0023 W2 — watched folders, through the seam W1 prepared.
            // `sidebarNodes(kind:)` renders `WatchedFolderRowState` verbatim:
            // the state in the title for degraded rows, and a badge only when
            // the count is trustworthy. Nothing here recomputes either.
            let watched = WatchedFolderIngestCoordinator.shared.rows
                .sidebarNodes(kind: .publication)
            return RecordSidebarSectionContent(
                nodes: nodes + watched,
                canOrganizeFolders: true,
                offersRootFolderCreation: false)

        case .exploration:
            var nodes = snapshot.explorationSearches.map { search in
                RecordSidebarNode(
                    scope: ImbibSidebarRoute.feed(search.id).scope,
                    title: search.name,
                    systemImage: "lightbulb")
            }
            nodes += collectionNodes(
                snapshot.explorationCollections, includeSmart: false,
                icon: explorationIcon(for:))
            // Exploration collections are DERIVED (Refs:, Cites:, Similar:) and
            // their delete goes through `LibraryManager.deleteExplorationCollection`,
            // which also clears `ExplorationService`'s context — so the generic
            // organise verbs stay off and the host supplies the swipe.
            return RecordSidebarSectionContent(nodes: nodes, canOrganizeFolders: false)

        case .scixLibraries:
            let nodes = SciXLibraryRepository.shared.libraries.map { library in
                RecordSidebarNode(
                    scope: ImbibSidebarRoute.scixLibrary(library.id).scope,
                    title: library.name,
                    systemImage: "sparkles",
                    count: library.documentCount > 0 ? library.documentCount : nil)
            }
            return RecordSidebarSectionContent(nodes: nodes)

        case .search:
            let nodes = searchForms.map { form in
                RecordSidebarNode(
                    scope: ImbibSidebarRoute.searchForm(form).scope,
                    title: form.displayName,
                    systemImage: form.icon)
            }
            return RecordSidebarSectionContent(nodes: nodes)

        case .citedInManuscripts:
            // The `.opaque` role's default row is titled after the SECTION;
            // macOS titles this one "All Cited Papers", because the section is
            // the bridge and the row is the smart library.
            return RecordSidebarSectionContent(nodes: [
                RecordSidebarNode(
                    scope: .section(.citedInManuscripts, .publication),
                    title: "All Cited Papers",
                    systemImage: SidebarSectionType.citedInManuscripts.icon,
                    count: snapshot.citedCount)
            ])

        case .flagged:
            // Rows stay declaration-derived (one per `FlagColor`, tinted from
            // the shared mapping). Only the header tap is imbib's: it selects
            // ANY flag, which is what the old sidebar's header did.
            return RecordSidebarSectionContent(headerScope: .flagged(.publication, nil))

        case .tags, .dismissed, .sharedWithMe, .artifacts, .reviewQueue,
             .manuscripts, .figures, .mail, .agents:
            // Fully declaration-derived (Dismissed: imbib's dismissal is a
            // `.libraryMove`, so the builder emits one opaque row + count) or
            // never reached in this shell.
            return nil
        }
    }

    private static func feedNode(_ feed: SmartSearch) -> RecordSidebarNode {
        let unread = SidebarSnapshot.shared.unreadCountForFeed(feed.id)
        return RecordSidebarNode(
            scope: ImbibSidebarRoute.feed(feed.id).scope,
            title: feed.name,
            systemImage: feed.isGroupFeed
                ? "person.3.fill" : "antenna.radiowaves.left.and.right",
            count: unread > 0 ? unread : nil)
    }

    /// A collection tree as sidebar nodes. `isFolder` is what turns the shared
    /// organise grammar on for a row, and SMART collections are not
    /// organisable (no subfolders, no reparent) — they get Rename/Delete from
    /// the host chrome instead, which is exactly what they had before.
    private static func collectionNodes(
        _ collections: [CollectionModel],
        includeSmart: Bool,
        icon: ((CollectionModel) -> String)? = nil
    ) -> [RecordSidebarNode] {
        func children(of parentID: UUID?) -> [CollectionModel] {
            collections
                .filter { $0.parentID == parentID && (includeSmart || !$0.isSmart) }
                .sorted {
                    $0.sortOrder != $1.sortOrder
                        ? $0.sortOrder < $1.sortOrder : $0.name < $1.name
                }
        }
        func build(_ collection: CollectionModel) -> RecordSidebarNode {
            RecordSidebarNode(
                scope: .folder(.publication, collection.id),
                title: collection.name,
                systemImage: icon?(collection)
                    ?? (collection.isSmart ? "folder.badge.gearshape" : "folder"),
                count: collection.publicationCount > 0 ? collection.publicationCount : nil,
                children: children(of: collection.id).map(build),
                isFolder: !collection.isSmart)
        }
        return children(of: nil).map(build)
    }

    /// macOS's exploration-collection glyphs, keyed off the derived name.
    private static func explorationIcon(for collection: CollectionModel) -> String {
        let name = collection.name
        if name.hasPrefix("Refs:") { return "arrow.down.doc" }
        if name.hasPrefix("Cites:") { return "arrow.up.doc" }
        if name.hasPrefix("Similar:") { return "doc.on.doc" }
        if name.hasPrefix("Co-Reads:") { return "person.2.fill" }
        if name.hasPrefix("Search:") { return "magnifyingglass" }
        return "doc.text.magnifyingglass"
    }

    // MARK: Collection actions (the shared organise grammar, on imbib's store)

    /// The kernel calls behind Rename / New Subfolder / Move Folder / Delete.
    ///
    /// Nesting is `updateField(parent_id)` and a cross-library move is
    /// `reparentItem` — the same two calls macOS's `createCollection(in:parentID:)`
    /// and `handleReparent` make (the collection tree parent is the payload
    /// `parent_id`, NEVER the envelope parent; see the c902a22f postmortem).
    /// This is what retires the old sidebar's two `iOS: … not yet supported by
    /// RustStoreAdapter — creating at root` warnings: subcollections now nest.
    static func collectionActions(snapshot: ImbibSidebarSnapshot) -> RecordCollectionActions {
        RecordCollectionActions(
            canOrganize: true,
            createFolder: { name, parentID in
                let libraryID = parentID.flatMap { snapshot.libraryOfCollection[$0] }
                    ?? store.getDefaultLibrary()?.id
                guard let libraryID else {
                    Logger.library.warningCapture(
                        "sidebar: no library to create collection '\(name)' in",
                        category: "sidebar")
                    return nil
                }
                guard let created = store.createCollection(name: name, libraryId: libraryID)
                else { return nil }
                if let parentID {
                    store.updateField(
                        id: created.id, field: "parent_id", value: parentID.uuidString)
                }
                return created.id
            },
            renameFolder: { id, name in
                _ = store.renameCollection(id: id, name: name)
            },
            reparentFolder: { id, newParentID in
                store.updateField(
                    id: id, field: "parent_id", value: newParentID?.uuidString)
                if let newParentID, let target = snapshot.libraryOfCollection[newParentID],
                   snapshot.libraryOfCollection[id] != target {
                    store.reparentItem(id: id, newParentId: target)
                }
            },
            deleteFolder: { id in
                store.deleteCollection(id: id)
            },
            addRecords: { ids, folderID in
                store.addToCollection(publicationIds: Array(ids), collectionId: folderID)
            },
            removeRecords: { ids, folderID in
                store.removeFromCollection(publicationIds: Array(ids), collectionId: folderID)
            })
    }
}
