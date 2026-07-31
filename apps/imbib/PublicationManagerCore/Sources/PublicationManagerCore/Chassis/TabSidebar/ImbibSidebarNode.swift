#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  ImbibSidebarNode.swift
//  imbib
//
//  Unified node type for the NSOutlineView-based sidebar.
//  Uses value types (UUIDs, strings) rather than Core Data objects.
//

import Foundation
import SwiftUI
import ImpressSidebar
import ImpressFTUI

// MARK: - Node Type

/// Discriminated union of all sidebar item types.
/// Uses value types only — no Core Data objects stored here.
enum ImbibSidebarNodeType: Hashable {
    /// One sibling app's WHOLE sidebar, as the outer tier of a COMPOSED sidebar
    /// (impress). The payload is the app id — `SiblingApp.rawValue`.
    ///
    /// Produced ONLY when the shell supplies a `SidebarComposition`; the five
    /// single-preset shells never build one, so every `switch` over this enum
    /// that predates it keeps its existing behaviour through `default`.
    case appGroup(String)

    case section(SidebarSectionType)
    case allInbox
    case inboxFeed(feedID: UUID)
    case inboxCollection(collectionID: UUID)
    case library(libraryID: UUID)
    case libraryCollection(collectionID: UUID, libraryID: UUID)
    case libraryFeed(feedID: UUID, libraryID: UUID)
    case sharedLibrary(libraryID: UUID)
    case scixLibrary(libraryID: UUID)
    case searchForm(SearchFormType)
    case explorationSearch(searchID: UUID)
    case explorationCollection(collectionID: UUID)
    case anyFlag
    case flagColor(FlagColor)
    case allArtifacts
    case artifactType(String)   // ArtifactType.rawValue
    case dismissed
    case citedInManuscripts
    case recent
    case reviewQueue

    /// A user folder of ANY record kind's collection binding (ADR-0022 D3).
    ///
    /// Stage 3: `manuscriptFolder(String)` and `figureFolder(String)` collapsed
    /// into this. They carried the same payload and every one of the seven
    /// sites that matched them immediately looked the kind's
    /// `CollectionCapability` up and delegated — so the BINDING is what the
    /// node actually needs to carry. `bindingID` is a `CollectionBindingID`
    /// value; `folderID` is the store's lowercase item id string.
    ///
    /// Not used for mail folders: `mail-folder` rows are IMAP-owned mailboxes
    /// with no kernel collection binding (the message descriptor declares no
    /// `collection`), so they keep their own read-only case below.
    case recordFolder(bindingID: String, folderID: String)

    // Journal pipeline (per ADR-0011 D8)
    case journalAll
    case journalByStatus(JournalManuscriptStatus)
    case journalSubmissions
    case manuscript(String)   // detail node — child of one of the journal sections

    // Figures section (Stage 2-B — implore's Library facet)
    case figuresAll
    case figuresUnfiled

    // Mail section (Stage 2-A — impart's mail-browsing facet)
    case mailAllInboxes
    case mailAccount(String)   // mail-account item UUID (lowercase store id)
    case mailFolder(String)    // mail-folder item UUID (lowercase store id)

    // Agents section (Stage 2-C — impel's task/run-browsing facet)
    case agentTasksAll
    case agentRunsAll
    case agentTaskState(String)  // kernel task state raw value

    /// A watched folder (ADR-0023 W2) — a local feed of `.bib`/`.ris` files.
    ///
    /// **Why macOS gets a node case where iOS gets a `.host` scope.** W1 built
    /// the row to ride `RecordSidebarSectionContent`, and iOS's sidebar does
    /// read `RecordSidebarBuilder`, so iOS needed no enum to grow. This sidebar
    /// does not read the builder at all — it is an `NSOutlineView` over this
    /// enum — so the choice here was a node case or the `customSurface` seam,
    /// and W1's matrix row left it to W2 to decide. **A node case**, because a
    /// custom surface is by construction a top-level, childless, countless,
    /// menuless whole-pane view (`CustomSurface.swift`'s header), and every one
    /// of those four is a thing this row must do: sit under Libraries, carry a
    /// badge, offer Refresh / Reveal / Stop Watching, and open a list. Using a
    /// custom surface would have meant re-implementing a sidebar row inside a
    /// pane, which is the shape W1 explicitly avoided.
    ///
    /// `tagPath` is carried rather than looked up because it IS the route: the
    /// publications a folder produced are scoped by their provenance tag
    /// (`WatchedFolderProvenanceTag`), so the node is self-contained and no
    /// view body has to consult the coordinator to resolve a selection.
    case watchedFolder(folderID: WatchedFolderID, tagPath: String)

    // App-owned whole-pane surface (Stage 2 WP-X0, ADR-0021)
    case customSurface(String)  // CustomSurfaceDescriptor.id
}

// MARK: - Sidebar Node

/// Unified node for the imbib sidebar NSOutlineView.
///
/// Conforms to `SidebarTreeNode` so it works with `SidebarOutlineView`.
/// Deterministic UUIDs for fixed items (sections, allInbox, flags, etc.)
/// ensure stable identity across rebuilds.
@MainActor
struct ImbibSidebarNode: SidebarTreeNode {
    /// `var` rather than `let` for exactly one reason: `adopting(group:…)`
    /// re-keys a node into its app group's namespace. Two rows in a composed
    /// sidebar can otherwise share a deterministic id (`.flagColor(.red)` in
    /// the imbib group and in the imprint group), and `SidebarOutlineView`
    /// caches wrappers, children and flattening info in UUID-keyed dictionaries
    /// — a duplicate id is not a cosmetic clash there, it is one row silently
    /// standing in for another.
    var id: UUID
    let nodeType: ImbibSidebarNodeType
    let displayName: String
    let iconName: String
    var displayCount: Int?
    var starCount: Int?
    var iconColor: Color?
    var treeDepth: Int = 0
    var hasTreeChildren: Bool = false
    var parentID: UUID?
    var childIDs: [UUID] = []
    var ancestorIDs: [UUID] = []

    /// Whether this node is a section header (group item in NSOutlineView)
    var isGroup: Bool = false

    /// Whether this node is an APP-GROUP header — the outer tier a composed
    /// sidebar has and a flat one does not.
    ///
    /// A separate flag from `isGroup`, not a mode on it: the two tiers coexist
    /// and render differently, and `isGroup`'s meaning (uppercased header with
    /// a `sectionMenu` button) is frozen pixel behaviour in five shells.
    /// `false` for every node the single-preset shells build.
    var isAppGroup: Bool = false

    /// The app group this node belongs to, or nil in a flat sidebar.
    ///
    /// Carried on the node because the macOS tree is built LAZILY — see
    /// `SidebarNodeGroup` for the four questions this answers that a flat tree
    /// never had to ask.
    var appGroup: SidebarNodeGroup?
}

// MARK: - Group adoption

extension ImbibSidebarNode {

    /// This node as it appears INSIDE an app group: re-keyed into the group's id
    /// namespace, tagged with the group, and pushed one level deeper.
    ///
    /// Applied at exactly ONE place — `ImbibSidebarViewModel.children(of:)`,
    /// whenever the parent has a group — so all three corrections happen once
    /// per node, for every node in the subtree, with no builder-site edits. That
    /// is what keeps `treeDepth` (hand-assigned at ten sites, and the ONLY
    /// source of indentation because `indentationPerLevel == 0`) correct under a
    /// new tier without touching any of the ten.
    func adopting(group: SidebarNodeGroup, depthOffset: Int = 1) -> ImbibSidebarNode {
        var copy = self
        copy.appGroup = group
        copy.id = ImbibSidebarNodeID.grouped(group.id, id)
        copy.treeDepth += depthOffset
        return copy
    }
}

// MARK: - Tab Mapping

extension ImbibSidebarNode {
    /// Maps this node to the corresponding ImbibTab for content routing.
    /// Returns nil for section headers (not selectable).
    var imbibTab: ImbibTab? {
        // In a COMPOSED sidebar, the two cross-kind sections (Flagged,
        // Dismissed) take their kind from the GROUP's preset rather than from
        // the window's. Without this, impress's imprint group would list
        // flagged PAPERS under a manuscript app, because `SectionContentView`
        // resolves a bare `.flagged` tab against the flat `.impress` union —
        // which is the user's original "hit and miss" report, transplanted to
        // macOS. nil here (every other node type, and every node in a flat
        // sidebar) falls through to the unchanged switch below.
        if let retargeted = appGroup?.retargetedTab(for: nodeType) { return retargeted }

        switch nodeType {
        case .appGroup:
            // A group header is an app's presence, not a destination.
            return nil
        case .section:
            return nil
        case .allInbox:
            return .inbox
        case .inboxFeed(let feedID):
            return .inboxFeed(feedID)
        case .inboxCollection(let collectionID):
            return .inboxCollection(collectionID)
        case .library(let libraryID):
            return .library(libraryID)
        case .libraryCollection(let collectionID, _):
            return .collection(collectionID)
        case .libraryFeed(let feedID, _):
            return .libraryFeed(feedID)
        case .sharedLibrary(let libraryID):
            return .sharedLibrary(libraryID)
        case .scixLibrary(let libraryID):
            return .scixLibrary(libraryID)
        case .searchForm(let formType):
            return .searchForm(formType)
        case .explorationSearch(let searchID):
            return .exploration(searchID)
        case .explorationCollection(let collectionID):
            return .explorationCollection(collectionID)
        case .anyFlag:
            return .flagged(nil)
        case .flagColor(let color):
            return .flagged(color.rawValue)
        case .allArtifacts:
            return .allArtifacts
        case .artifactType(let rawValue):
            return .artifactType(rawValue)
        case .dismissed:
            return .dismissed
        case .citedInManuscripts:
            return .citedInManuscripts
        case .recent:
            return .recent
        case .reviewQueue:
            return .reviewQueue
        // Record-kind rows (Stage 3): every one produces the SAME tab case,
        // differing only in the kind and scope it names. Adding a kind's rows
        // adds lines here and nowhere downstream.
        case .recordFolder(let bindingID, let folderID):
            guard let kind = BuiltinRecordKinds.kind(forCollectionBindingID: bindingID) else {
                return nil
            }
            return Self.recordTab(kind, folderID) { .folder(kind, $0) }
        case .journalAll:
            return .record(.all(.manuscript))
        case .journalByStatus(let status):
            return .record(.status(.manuscript, status.rawValue))
        case .journalSubmissions:
            return .auxiliary(.submissionsInbox)
        case .manuscript(let id):
            return .recordDetail(.manuscript, id)
        case .figuresAll:
            return .record(.all(.figure))
        case .figuresUnfiled:
            return .record(RecordRoute(kind: .figure, scope: FigureListScope.unfiledRouteScope))
        case .mailAllInboxes:
            return .record(.all(.message))
        case .mailAccount(let id):
            return Self.recordTab(.message, id) { MessageListScope.accountRouteScope($0) }
        case .mailFolder(let id):
            return Self.recordTab(.message, id) { .folder(.message, $0) }
        case .agentTasksAll:
            return .record(.all(.task))
        case .agentRunsAll:
            return .record(.all(.agentRun))
        case .agentTaskState(let state):
            return .record(.status(.task, state))
        case .watchedFolder(let folderID, let tagPath):
            return .watchedFolder(folderID, tagPath: tagPath)
        case .customSurface(let id):
            return .customSurface(id)
        }
    }

    /// A record tab for a node whose id is a STORE STRING (folders, mail
    /// accounts and mailboxes all carry lowercase store ids) while the chassis
    /// scope vocabulary carries a `UUID`.
    ///
    /// An unparseable id falls back to the kind's `all` scope — which is
    /// exactly what the four per-kind dispatchers in `SectionContentView` did
    /// with `if let uuid = UUID(uuidString: id) … else … .all` before they
    /// collapsed. Doing it here instead means the FALLBACK is part of the route
    /// (so selection bookkeeping agrees with what is rendered) rather than
    /// something only the view knew.
    private static func recordTab(
        _ kind: RecordKindID,
        _ storeID: String,
        _ scope: (UUID) -> RecordSidebarScope
    ) -> ImbibTab {
        guard let uuid = UUID(uuidString: storeID) else { return .record(.all(kind)) }
        return .record(RecordRoute(kind: kind, scope: scope(uuid)))
    }
}

// MARK: - Deterministic UUIDs

/// Generates deterministic UUIDs from string identifiers.
/// This ensures section headers, fixed items (allInbox, anyFlag, etc.)
/// have stable IDs across rebuilds without storing state.
enum ImbibSidebarNodeID {

    /// Create a deterministic UUID from a stable string key.
    /// Uses Hasher (seeded per-process) so IDs are stable within a single app launch.
    static func stable(_ key: String) -> UUID {
        // Use UUID v5-style: hash the key and pack into UUID bytes
        var hasher = Hasher()
        hasher.combine("com.imbib.sidebar")
        hasher.combine(key)
        let hash = hasher.finalize()

        // Start from zeroed UUID — NOT UUID() which is random each call
        var uuidBytes: uuid_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        withUnsafeBytes(of: hash) { src in
            withUnsafeMutableBytes(of: &uuidBytes) { dst in
                for i in 0..<min(src.count, 8) {
                    dst[i] = src[i]
                }
            }
        }
        // Set version and variant bits for UUID v5 compatibility
        uuidBytes.6 = (uuidBytes.6 & 0x0F) | 0x50 // version 5
        uuidBytes.8 = (uuidBytes.8 & 0x3F) | 0x80 // variant 1

        return UUID(uuid: uuidBytes)
    }

    // Pre-computed stable IDs for fixed items
    static let allInbox = stable("allInbox")
    static let anyFlag = stable("anyFlag")
    static let dismissed = stable("dismissed")
    static let citedInManuscripts = stable("citedInManuscripts")
    static let recent = stable("recent")
    static let reviewQueue = stable("reviewQueue")

    static func section(_ type: SidebarSectionType) -> UUID {
        stable("section.\(type.rawValue)")
    }

    /// An app group's header row (composed sidebars only).
    static func appGroup(_ groupID: String) -> UUID {
        stable("group.\(groupID)")
    }

    /// A node's id INSIDE an app group.
    ///
    /// Derived from the flat id rather than from the node's own key, so it needs
    /// no per-builder knowledge: every one of the ~30 builder functions keeps
    /// producing exactly the id it produced before, and `adopting(group:)`
    /// namespaces it. Deterministic, like every other id here, and stable for
    /// the same single-launch window (`stable(_:)` seeds a per-process
    /// `Hasher`; nothing persists these).
    static func grouped(_ groupID: String, _ flatID: UUID) -> UUID {
        stable("group.\(groupID).node.\(flatID.uuidString)")
    }

    static func searchForm(_ type: SearchFormType) -> UUID {
        stable("searchForm.\(type.rawValue)")
    }

    static func flagColor(_ color: FlagColor) -> UUID {
        stable("flagColor.\(color.rawValue)")
    }

    static let allArtifacts = stable("allArtifacts")

    static func artifactType(_ rawValue: String) -> UUID {
        stable("artifactType.\(rawValue)")
    }

    // Journal pipeline IDs (per ADR-0011 D8)
    static let journalAll = stable("journal.all")
    static let journalSubmissions = stable("journal.submissions")

    static func journalByStatus(_ status: JournalManuscriptStatus) -> UUID {
        stable("journal.status.\(status.rawValue)")
    }

    static func manuscript(_ manuscriptID: String) -> UUID {
        stable("journal.manuscript.\(manuscriptID)")
    }

    /// Node id for a collection folder of any binding (Stage 3 — replaces
    /// `manuscriptFolder(_:)` and `figureFolder(_:)`).
    ///
    /// The key SPELLING changed (`journal.folder.X` / `figures.folder.X` →
    /// `folder.manuscript.X` / `folder.figure.X`) and that is safe: `stable(_:)`
    /// seeds a per-process `Hasher`, so these UUIDs are documented as stable
    /// only "within a single app launch" and nothing persists them. The
    /// persisted sidebar state is section ORDER and COLLAPSE, keyed by
    /// `SidebarSectionType.rawValue` (`SidebarSectionOrderStore`,
    /// `SidebarCollapsedStateStore`); folder expansion is in-memory
    /// (`TreeExpansionState`).
    static func recordFolder(_ bindingID: String, _ folderID: String) -> UUID {
        stable("folder.\(bindingID).\(folderID)")
    }

    // Figures section IDs (Stage 2-B)
    static let figuresAll = stable("figures.all")
    static let figuresUnfiled = stable("figures.unfiled")

    // Mail section IDs (Stage 2-A)
    static let mailAllInboxes = stable("mail.allInboxes")

    static func mailAccount(_ accountID: String) -> UUID {
        stable("mail.account.\(accountID)")
    }

    static func mailFolder(_ folderID: String) -> UUID {
        stable("mail.folder.\(folderID)")
    }

    // Agents section IDs (Stage 2-C)
    static let agentTasks = stable("agents.tasks")
    static let agentRuns = stable("agents.runs")

    static func agentTaskState(_ state: String) -> UUID {
        stable("agents.tasks.state.\(state)")
    }

    static func customSurface(_ surfaceID: String) -> UUID {
        stable("custom.surface.\(surfaceID)")
    }

    /// Node id for a watched folder (ADR-0023 W2).
    ///
    /// Keyed on the watcher's id, NOT on the store row's — the watcher's is
    /// what the row, the refresh verb and the bookmark all agree on, and the
    /// store's is derived from the path (so it would change if the folder
    /// moved, silently reshuffling the outline).
    static func watchedFolder(_ folderID: WatchedFolderID) -> UUID {
        stable("watched.folder.\(folderID.storageKey)")
    }
}
#endif
