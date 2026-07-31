// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): route enums, tab
// identity and notification names. Pure Foundation/SwiftUI value types — the
// ROUTE vocabulary of the chassis, which iOS had to re-encode as its own
// literals while this was gated.
//
// Stage 3 (declarative chassis) collapsed the FOUR parallel per-kind route
// enums that used to live here — `ImbibJournalRoute`, `FigureRoute`,
// `MailRoute`, `AgentRoute`, 18 cases between them, each a near-transcription
// of the next — plus their twelve `ImbibContentRoute`/`ImbibTab` wrapper
// cases, into ONE `RecordRoute` (kind + `RecordSidebarScope`). Adding a
// record kind no longer adds a case to any enum in this file; that was the
// one wart ADR-0021's litmus re-run (step 6) admitted the G8 gate did not
// cover.
//
//  TabSidebarTypes.swift
//  imbib
//
//  Created by Claude on 2026-02-06.
//

import Foundation
import SwiftUI
import ImpressFTUI

// MARK: - Notification Names

extension NSNotification.Name {
    /// Posted by SectionContentView when batch PDF download is requested.
    /// userInfo: ["publicationIDs": [UUID], "libraryID": UUID]
    public static let showBatchDownload = NSNotification.Name("showBatchDownload")
}

/// Tab selection for the sidebarAdaptable TabView.
///
/// Each case maps to a tab or tab within a section in the TabView.
/// Uses value types (UUIDs, strings) rather than Core Data objects
/// so the enum is Hashable without issues.
public enum ImbibTab: Hashable {
    case inbox
    case library(UUID)
    case sharedLibrary(UUID)
    case scixLibrary(UUID)
    case searchForm(SearchFormType)
    case exploration(UUID)
    case collection(UUID)            // Collection in a regular library
    case explorationCollection(UUID) // Collection in exploration library
    case inboxFeed(UUID)             // Smart search with feedsToInbox
    case inboxCollection(UUID)       // Collection in the inbox library
    case libraryFeed(UUID)           // Auto-refreshing feed in a non-inbox library
    case flagged(String?)     // nil = any flag, String = FlagColor.rawValue
    case customSurface(String)  // app-owned whole-pane surface (WP-X0)

    /// One watched folder's produced publications (ADR-0023 W2).
    ///
    /// The tag path travels with the id because it IS the scope: a watched
    /// folder's papers are the ones carrying its provenance tag, so this
    /// resolves to `.publicationList(.tag(_))` with no lookup and no new
    /// `PublicationSource` case.
    case watchedFolder(WatchedFolderID, tagPath: String)
    case allArtifacts
    case artifactType(String)   // ArtifactType.rawValue
    case dismissed
    case citedInManuscripts   // pseudo smart library — papers cited in any imprint manuscript
    case recent               // papers the user viewed or added by hand (never automated ingest)
    case reviewQueue          // pending agent review-requests from the shared impress store

    // MARK: Record-kind tabs (Stage 3 — ONE case for every kind)
    //
    // These three replaced fourteen: journalAll, journalByStatus,
    // journalSubmissions, manuscript, manuscriptFolder, figuresAll,
    // figuresUnfiled, figureFolder, mailAllInboxes, mailAccount, mailFolder,
    // agentTasks, agentRuns, agentTasksByState. Every one of them differed
    // from a sibling only in which record kind it named, which is exactly the
    // "node/tab/route case-addition pattern" ADR-0021 called the honest
    // remaining cost of adding a kind.

    /// A record kind's list|detail surface — which kind, which subset.
    case record(RecordRoute)
    /// ONE record, full-pane, with no list — the deep-link shape (⌘F palette
    /// hit, `.navigateToManuscript`). The id is the store's string id.
    case recordDetail(RecordKindID, String)
    /// A non-record route the shell preset declares (`AuxiliaryRoute`).
    case auxiliary(AuxiliaryRoute)

    case addFeed               // Navigate to search form picker for feed creation
    case addLibraryFeed(UUID)    // Navigate to feed creation for a specific library
    case editFeed(UUID)          // Navigate to search form to edit an existing feed
}

// MARK: - Content Routes

/// Declarative route for the main imbib content area.
///
/// The sidebar resolves to one of these value routes, and
/// `SectionContentView` renders the route. Keeping this as a small value type
/// makes SwiftUI identity, search mode, and future route additions explicit
/// instead of scattering them through view-body switches.
public enum ImbibContentRoute: Equatable {
    case publicationList(PublicationSource)
    case searchForm(ImbibSearchFormRoute)
    case artifacts(ArtifactType?)
    case reviewQueue
    case feedFormPicker
    /// ANY record kind's list|detail section (Stage 3). Replaces the four
    /// per-kind wrapper cases `.journal`/`.figures`/`.mail`/`.agents`, which
    /// wrapped four enums that said the same four things.
    case record(RecordRoute)
    /// One record, full-pane, no list — the deep-link shape.
    case recordDetail(RecordKindID, String)
    /// A non-record route the shell preset declares (Submissions inbox).
    case auxiliary(AuxiliaryRoute)
    /// App-owned whole-pane surface (WP-X0) — rendered full-pane, no
    /// list/detail split, no detail toolbar cluster.
    case customSurface(String)

    /// Stable key for selection clearing and SwiftUI cache boundaries.
    ///
    /// In-memory only: `SectionContentView.tabKey` compares it across body
    /// evaluations. Nothing persists it (sidebar persistence is section ORDER
    /// and collapse state, `SidebarSectionOrderStore`), which is why the
    /// record arms could adopt the scope's canonical `scopeKey` spelling
    /// instead of preserving the old `journal-`/`figures-` prefixes.
    public var stableID: String {
        switch self {
        case .publicationList(let source):
            return "source-\(source.viewID)"
        case .searchForm(let route):
            return "search-\(route.stableID)"
        case .artifacts(let type):
            return "artifacts-\(type?.rawValue ?? "all")"
        case .reviewQueue:
            return "reviewQueue"
        case .feedFormPicker:
            return "feedFormPicker"
        case .record(let route):
            return "record-\(route.stableID)"
        case .recordDetail(let kind, let id):
            return "record-detail-\(kind.rawValue)-\(id)"
        case .auxiliary(let route):
            return "aux-\(route.rawValue)"
        case .customSurface(let id):
            return "custom-\(id)"
        }
    }

    public var publicationSource: PublicationSource? {
        if case .publicationList(let source) = self { return source }
        return nil
    }

    public var isSearchForm: Bool {
        if case .searchForm = self { return true }
        return false
    }

    public var isArtifactRoute: Bool {
        if case .artifacts = self { return true }
        return false
    }
}

public struct ImbibSearchFormRoute: Equatable {
    public let formType: SearchFormType
    public let mode: SearchFormMode
    public let editingFeedID: UUID?

    public init(
        formType: SearchFormType,
        mode: SearchFormMode,
        editingFeedID: UUID? = nil
    ) {
        self.formType = formType
        self.mode = mode
        self.editingFeedID = editingFeedID
    }

    public var stableID: String {
        var parts = [formType.rawValue, mode.routeKey]
        if let editingFeedID {
            parts.append("edit-\(editingFeedID.uuidString)")
        }
        return parts.joined(separator: "-")
    }
}

// MARK: - Record Routes

/// A record-kind destination: WHICH kind's surface, and WHAT SUBSET of it.
///
/// This one value replaced `ImbibJournalRoute`, `FigureRoute`, `MailRoute` and
/// `AgentRoute`. Those four were parallel by construction — each one's doc
/// comment said so ("the FigureRoute mirror of ImbibJournalRoute", "the
/// MailRoute mirror of FigureRoute", "the AgentRoute mirror of MailRoute") —
/// and each new record kind owed a fifth, plus a wrapper case in
/// `ImbibContentRoute`, a case in `ImbibTab`, and a dispatcher in
/// `SectionContentView`. Now it owes a viewer-registry factory line and
/// nothing else.
///
/// The subset is expressed in `RecordSidebarScope`, the CROSS-PLATFORM sidebar
/// vocabulary iOS's `RecordSidebarView` already produces and selects with —
/// deliberately reused rather than mirrored, so the two shells cannot disagree
/// about what a sidebar row means. Subsets the chassis vocabulary has no word
/// for (implore's "Unfiled", impart's mail ACCOUNTS) ride
/// `RecordSidebarScope.host`, its declared escape hatch, with the key spelled
/// once next to the kind's own scope rather than at call sites
/// (`RecordScopeKey+ListScopes.swift`).
///
/// Equality and hashing are the scope's: routes are SELECTION STATE, and
/// `ImbibSidebarViewModel.tabToNodeID` keys a dictionary on the tab that
/// carries them.
public struct RecordRoute: Hashable, Sendable {

    /// The kind whose viewer renders this route — the `RecordViewerRegistry`
    /// key. Carried explicitly rather than read back off the scope because
    /// `RecordSidebarScope.kind` is optional (`.section`/`.host` may name no
    /// kind) and a route always has one.
    public let kind: RecordKindID

    /// What subset of the kind, in chassis sidebar vocabulary.
    public let scope: RecordSidebarScope

    public init(kind: RecordKindID, scope: RecordSidebarScope) {
        self.kind = kind
        self.scope = scope
    }

    /// Every record of the kind (its dismissal rule still applies).
    public static func all(_ kind: RecordKindID) -> RecordRoute {
        RecordRoute(kind: kind, scope: .all(kind))
    }

    /// One declared `status` value of the kind.
    public static func status(_ kind: RecordKindID, _ status: String) -> RecordRoute {
        RecordRoute(kind: kind, scope: .status(kind, status))
    }

    /// One folder of the kind's collection binding.
    public static func folder(_ kind: RecordKindID, _ folderID: UUID) -> RecordRoute {
        RecordRoute(kind: kind, scope: .folder(kind, folderID))
    }

    /// Flagged records of the kind; nil colour = any flag.
    public static func flagged(_ kind: RecordKindID, _ colorRawValue: String?) -> RecordRoute {
        RecordRoute(kind: kind, scope: .flagged(kind, colorRawValue))
    }

    /// Stable key for SwiftUI cache boundaries — the scope's canonical key,
    /// the same string `stableViewID` is derived from.
    public var stableID: String { scope.scopeKey }
}

/// A per-kind list scope that can be rebuilt from the chassis sidebar
/// vocabulary.
///
/// ADR-0021 D2 keeps the list scopes PARALLEL per kind (`FigureListScope` is
/// figure-only), so one generic route has to land in the right one. This is
/// that hinge, and it is per-KIND code — the conformances live next to the
/// scopes in `RecordScopeKey+ListScopes.swift`, not in the chassis, so a new
/// kind adds its own translation with its own scope and the sink learns
/// nothing new.
public protocol RecordRouteScope: RecordScopeKey {
    /// This kind's scope for a chassis scope, or nil when the chassis scope
    /// names a different kind, or a subset this kind does not have.
    init?(routeScope: RecordSidebarScope)
}

extension SearchFormMode {
    var routeKey: String {
        switch self {
        case .librarySmartSearch(let id, _):
            return "librarySmartSearch-\(id.uuidString)"
        case .inboxFeed:
            return "inboxFeed"
        case .libraryFeed(let id, _):
            return "libraryFeed-\(id.uuidString)"
        case .explorationSearch:
            return "explorationSearch"
        }
    }
}

// MARK: - Flag Counts

/// Sidebar flag counts for badge display
struct FlagCounts {
    var total: Int = 0
    var byColor: [String: Int] = [:]

    static let empty = FlagCounts()
}

