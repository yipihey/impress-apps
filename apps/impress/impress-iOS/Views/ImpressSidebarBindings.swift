//
//  ImpressSidebarBindings.swift
//  impress-iOS
//
//  What impress-iOS can render, said in data.
//
//  The preset (`AppShellConfiguration.impress`) permits EVERY section — that is
//  its whole point, and it is the same value the macOS target uses. This file
//  is the HOST half: `presenting(_:)` narrows it to the kinds this BUILD has a
//  pane for, and `RecordSidebarBuilder` drops every section bound to a kind
//  that is not in the set. No section-name literal appears in the KIND gate,
//  which is the property `presentableKinds` exists to buy (it replaced
//  imprint-iOS's hardcoded `section != .citedInManuscripts`).
//
//  WHAT RENDERS, and what it took:
//
//    | kind          | sections                  | list                       | detail                      |
//    |---------------|---------------------------|----------------------------|-----------------------------|
//    | .message      | Mail                      | MailStoreReader.messages   | MessageDetailPane           |
//    | .figure       | Figures                   | FigureStoreReader          | FigureDetailPane            |
//    | .task         | Agents                    | AgentStoreReader           | AgentRecordDetailPane       |
//    | .publication  | Inbox, Libraries, Flagged,| IOSPublicationListPane     | IOSPublicationDetailPane    |
//    |               | Cited in Manuscripts,     | (PublicationListCore)      |                             |
//    |               | Dismissed                 |                            |                             |
//    | .manuscript   | Manuscripts               | RecordListHost over        | IOSManuscriptReadOnlyPane   |
//    |               |                           | ManuscriptRowData          |                             |
//
//  Every detail pane is the CHASSIS's. Two of them (figure, agent) were
//  `#if os(macOS)` until this app needed them; the publication pane was
//  imbib-APP-PRIVATE until I2 lifted it into PMC; the manuscript pane is I2's
//  new read-only twin. A sixth app's private copy of a pane is the thing
//  ADR-0022 D9 claims impress does not need, and after I2 it does not have one.
//
//  WHAT IS STILL DECLARED ABSENT, and why — each of these is a real gap, named
//  rather than papered over with an EmptyView. Two of the five that used to be
//  here are gone, because I2 built the surfaces they named.
//
//    * .artifact — `ArtifactDetailView` is macOS-only and is a genuine
//      per-artifact-type switch, not a bridge. KIND gate.
//    * .agentRun — a chassis LIMIT, not an app one, and worth naming precisely:
//      `sectionBindings` maps a section to ONE kind, so `.agents` binds `.task`
//      and the derived nodes are task nodes. There is no derived route to
//      `.all(.agentRun)`. A host CAN supply its own nodes, but host nodes
//      REPLACE the derived ones (`RecordSidebarBuilder`), so surfacing Runs
//      means re-spelling the task rows and the descriptor's statuses app-side —
//      forking the declaration to add a sibling to it. Same shape as the
//      "mixed-kind Flagged/Dismissed" gap already in the matrix. KIND gate.
//
//  And four sections that ARE publication-bound and therefore now survive the
//  kind gate, but which this host still cannot honestly serve. They are turned
//  off by the CONTENT gate — `sectionIsAvailable` — which is the instrument for
//  "this host has nothing behind it", and each says why:
//
//    * .search — two separate misses. The section's rows are imbib's ONLINE
//      search forms (ADS/SciX/arXiv query builders), which impress does not
//      ship; and the chassis's grouped mixed-kind search, impress's showcase,
//      is `StoreSearchSurface` — the one AppKit-linking chassis builtin, so
//      `CustomSurfaceRegistry.builtin` is empty on iOS and ⌘⇧F opens nothing
//      here. Unchanged by I2 and still the honest answer.
//    * .exploration — its rows are collections that imbib's `ExplorationService`
//      CREATES in the exploration library. Nothing in impress creates them, and
//      `IOSInfoTab`'s Explore row is gated on a `LibraryManager` this shell
//      does not inject, so the section would be permanently empty rather than
//      merely empty today.
//    * .scixLibraries — remote shelves behind ADS credentials. impress reads
//      the shared store; it syncs nothing.
//    * .sharedWithMe — group libraries, whose membership comes from imbib's
//      sharing sync. Same reason.
//    * .reviewQueue — unbound in the preset (its rows are `review-request@1.0.0`,
//      which has no descriptor), so the builder would give it one OPAQUE row
//      that routes nowhere on iOS.
//

import PublicationManagerCore
import SwiftUI

/// One store read per data version, shared by the sidebar's closures.
@MainActor
final class ImpressSidebarSnapshot {
    private var version: Int = .min

    private(set) var mail: MailSidebarSnapshot = .empty
    private(set) var figureFolders: [RecordFolder] = []
    private(set) var figureCount: Int = 0
    private(set) var taskCount: Int = 0

    // Publications (I2)
    private(set) var libraries: [LibraryModel] = []
    private(set) var collectionsByLibrary: [UUID: [CollectionModel]] = [:]
    private(set) var inboxLibrary: LibraryModel?
    private(set) var citedCount: Int = 0
    /// Every publication-side row title this host can label a list column with,
    /// keyed by the scope its node selects. The sidebar knows the name; the
    /// list column would otherwise have to re-read the store to learn it.
    private(set) var publicationTitles: [RecordSidebarScope: String] = [:]

    // Manuscripts (I2)
    private(set) var manuscriptFolders: [RecordFolder] = []
    private(set) var manuscriptCount: Int = 0

    func refresh(version newVersion: Int, force: Bool = false) {
        guard force || version != newVersion else { return }
        version = newVersion
        let store = RustStoreAdapter.shared

        mail = MailSidebarSnapshot.load()
        figureCount = FigureStoreReader.shared.fetchFigures().count
        taskCount = AgentStoreReader.shared.taskCount()
        // The kernel row → chassis folder mapping. `parentID` is the TREE
        // parent (never the owning container) — the c902a22f invariant.
        figureFolders = FigureStoreReader.shared.fetchFolders()
            .compactMap { row -> RecordFolder? in
                guard let id = UUID(uuidString: row.id) else { return nil }
                return RecordFolder(
                    id: id,
                    name: row.name,
                    parentID: row.parentID.flatMap(UUID.init(uuidString:)),
                    sortOrder: row.sortOrder)
            }

        // Publications. `listLibraries()` includes the Inbox library, which the
        // Inbox SECTION owns — so the Libraries section drops it rather than
        // giving the same rows two homes (imbib's rule, applied by capability
        // rather than by name: `isInbox` is a field on the row).
        let allLibraries = store.listLibraries()
        inboxLibrary = allLibraries.first(where: \.isInbox) ?? store.getInboxLibrary()
        libraries = allLibraries.filter { !$0.isInbox }
        collectionsByLibrary = Dictionary(
            uniqueKeysWithValues: allLibraries.map {
                ($0.id, store.listCollections(libraryId: $0.id))
            })
        citedCount = CitedInManuscriptsSnapshot.shared.citedPaperIDs.count

        var titles: [RecordSidebarScope: String] = [:]
        for library in allLibraries {
            titles[PublicationSource.libraryRouteScope(library.id)] = library.name
            for collection in collectionsByLibrary[library.id] ?? [] {
                titles[.folder(.publication, collection.id)] = collection.name
            }
        }
        publicationTitles = titles

        // Manuscripts: the descriptor declares a `CollectionCapability`, so the
        // builder asks for folders and the derived section is the whole story.
        manuscriptCount = store.countManuscripts()
        manuscriptFolders = store.listManuscriptCollections()
            .compactMap { row -> RecordFolder? in
                guard let id = UUID(uuidString: row.id) else { return nil }
                return RecordFolder(
                    id: id,
                    name: row.name,
                    parentID: row.parentId.flatMap(UUID.init(uuidString:)),
                    sortOrder: Int64(row.sortOrder))
            }
    }
}

@MainActor
enum ImpressSidebarBindings {

    /// The kinds this BUILD can present. Everything the preset permits that is
    /// bound to another kind drops out — declared, not filtered by name.
    ///
    /// `.publication` and `.manuscript` joined the set in I2, when the chassis
    /// grew the two public iOS surfaces they were waiting on.
    static let presentable: Set<RecordKindID> = [
        .message, .figure, .task, .publication, .manuscript,
    ]

    /// Sections this host turns off for lack of CONTENT rather than for lack of
    /// a pane for their kind. Each is justified in this file's header; the set
    /// is here so the UI suite's declared-absent list has one place to agree
    /// with.
    static let contentGatedSections: Set<SidebarSectionType> = [
        .search, .exploration, .scixLibraries, .sharedWithMe, .reviewQueue,
    ]

    static var configuration: AppShellConfiguration {
        .impress.presenting(presentable)
    }

    /// Where the shell lands on a regular-width device. Mail, because it is the
    /// only kind whose rows the seed and the real suite both reliably have.
    /// `RecordSidebarView` seeds no default of its own until its body runs,
    /// which iPad portrait never does before the user reveals the sidebar
    /// (impart's finding).
    static let landingScope: RecordSidebarScope = .all(.message)

    static func dataSource(
        snapshot: ImpressSidebarSnapshot,
        version: Int
    ) -> RecordSidebarDataSource {
        let sync = { snapshot.refresh(version: version) }
        return RecordSidebarDataSource(
            folders: { kind in
                sync()
                switch kind {
                case .figure: return snapshot.figureFolders
                case .manuscript: return snapshot.manuscriptFolders
                // Publications DO declare a `CollectionCapability`, but their
                // collections are per-LIBRARY — there is no flat "folder tree
                // of publications" to answer with. The Libraries section
                // resolves them per library in `sectionContent` instead, which
                // is exactly the case `RecordSidebarSectionContent` exists for.
                default: return []
                }
            },
            count: { scope in
                sync()
                switch scope {
                case .all(.message): return snapshot.mail.allInboxesCount
                case .all(.figure): return snapshot.figureCount
                case .all(.task): return snapshot.taskCount
                case .all(.manuscript): return snapshot.manuscriptCount
                case .section(.citedInManuscripts, _):
                    return snapshot.citedCount > 0 ? snapshot.citedCount : nil
                default: return nil
                }
            },
            // The CONTENT gate. `presenting(_:)` has already removed every
            // section bound to a kind impress-iOS cannot show; this removes the
            // ones whose ROWS this host has no source for.
            sectionIsAvailable: { !contentGatedSections.contains($0) },
            sectionContent: { section, kind in
                sync()
                switch section {
                case .inbox:
                    // One row, the inbox library. NOT the primary role's "All
                    // Publications + folder tree": there is no such thing as
                    // all publications (they live in libraries), and the inbox
                    // library's collections are imbib's triage furniture.
                    guard snapshot.inboxLibrary != nil else {
                        return RecordSidebarSectionContent(nodes: [])
                    }
                    return RecordSidebarSectionContent(
                        nodes: [
                            RecordSidebarNode(
                                scope: .section(.inbox, kind),
                                title: SidebarSectionType.inbox.displayName,
                                systemImage: SidebarSectionType.inbox.icon,
                                count: snapshot.inboxLibrary?.publicationCount ?? 0)
                        ])
                case .libraries:
                    return RecordSidebarSectionContent(
                        nodes: snapshot.libraries.map(libraryNode(snapshot)),
                        // impress reads the shared store and organises nothing
                        // in it; the folder verbs would need imbib's
                        // per-library collection semantics.
                        canOrganizeFolders: false,
                        offersRootFolderCreation: false)
                default:
                    return nil
                }
            })
    }

    /// A library row, with its collections as children.
    private static func libraryNode(
        _ snapshot: ImpressSidebarSnapshot
    ) -> (LibraryModel) -> RecordSidebarNode {
        { library in
            let collections = snapshot.collectionsByLibrary[library.id] ?? []
            func node(_ collection: CollectionModel) -> RecordSidebarNode {
                RecordSidebarNode(
                    scope: .folder(.publication, collection.id),
                    title: collection.name,
                    systemImage: collection.isSmart ? "gearshape" : "folder",
                    count: collection.publicationCount > 0
                        ? collection.publicationCount : nil,
                    children: collections
                        .filter { $0.parentID == collection.id }
                        .map(node),
                    isFolder: true)
            }
            return RecordSidebarNode(
                scope: PublicationSource.libraryRouteScope(library.id),
                title: library.name,
                systemImage: "books.vertical",
                count: library.publicationCount > 0 ? library.publicationCount : nil,
                children: collections.filter { $0.parentID == nil }.map(node))
        }
    }

    // MARK: - Scope → publication source

    /// The chassis conversion, plus the one case it deliberately leaves to the
    /// host: `.section(.inbox, _)` carries no library id, and resolving it is a
    /// store read (see `PublicationSource.init?(routeScope:)`).
    static func publicationSource(
        for scope: RecordSidebarScope,
        snapshot: ImpressSidebarSnapshot
    ) -> PublicationSource? {
        if case .section(.inbox, _) = scope {
            return snapshot.inboxLibrary.map { PublicationSource.inbox($0.id) }
        }
        return PublicationSource(routeScope: scope)
    }

    /// The label for a publication list column. Libraries and collections carry
    /// a user-chosen name the sidebar already read; everything else is a
    /// generic scope with a generic name.
    static func publicationTitle(
        for scope: RecordSidebarScope,
        snapshot: ImpressSidebarSnapshot
    ) -> String {
        if let named = snapshot.publicationTitles[scope] { return named }
        switch scope {
        case .section(.inbox, _): return SidebarSectionType.inbox.displayName
        case .section(.citedInManuscripts, _):
            return SidebarSectionType.citedInManuscripts.displayName
        case .section(.dismissed, _): return SidebarSectionType.dismissed.displayName
        case .flagged(_, let raw):
            guard let raw, let color = FlagColor(rawValue: raw) else { return "Flagged" }
            return "\(color.displayName) Flag"
        default: return "Papers"
        }
    }

    /// The label for a manuscript list column. `ManuscriptListScope.title`
    /// answers three of the four cases; `.folder` returns the literal "Folder"
    /// because the chassis scope carries an id and not a name, so the host
    /// supplies the one it just read.
    static func manuscriptTitle(
        for scope: ManuscriptListScope,
        snapshot: ImpressSidebarSnapshot
    ) -> String {
        if case .folder(let id) = scope {
            return snapshot.manuscriptFolders.first { $0.id == id }?.name ?? scope.title
        }
        return scope.title
    }

    /// Store-backed star/flag/tag, from the kind's own descriptor. No app-side
    /// verb table: `RecordTriageActions.storeBacked` reads what the kind
    /// declares, so a kind that cannot be dismissed shows no dismiss.
    static func triageActions(for kind: RecordKindID) -> RecordTriageActions {
        RecordTriageActions.storeBacked(
            descriptor: AppShellConfiguration.impress.recordKinds[kind]
                ?? MessageRecordKind.descriptor)
    }
}
