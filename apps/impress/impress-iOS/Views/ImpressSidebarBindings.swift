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
//  that is not in the set. No section-name literal appears anywhere below,
//  which is the property `presentableKinds` exists to buy (it replaced
//  imprint-iOS's hardcoded `section != .citedInManuscripts`).
//
//  WHAT RENDERS, and what it took:
//
//    | kind      | section   | list                      | detail                  |
//    |-----------|-----------|---------------------------|-------------------------|
//    | .message  | Mail      | MailStoreReader.messages  | MessageDetailPane       |
//    | .figure   | Figures   | FigureStoreReader         | FigureDetailPane        |
//    | .task     | Agents    | AgentStoreReader          | AgentRecordDetailPane   |
//
//  All three detail panes are the CHASSIS's. Two of them (figure, agent) were
//  `#if os(macOS)` until this app needed them, each for exactly one AppKit call;
//  they were un-gated in PublicationManagerCore rather than re-written here,
//  because a sixth app's private copy of a chassis pane is the thing ADR-0022
//  D9 claims impress does not need.
//
//  WHAT IS DECLARED ABSENT, and why — each of these is a real gap, named rather
//  than papered over with an EmptyView:
//
//    * .publication — there is NO public iOS publication pane in the chassis.
//      imbib-iOS has one, but it is imbib-app-private (`IOSDetailView` and its
//      tabs live in the imbib target, not PMC); the C1 wave found the same
//      thing. Declaring `.publication` here would render nine sections (Inbox,
//      Libraries, Shared, SciX, Search, Exploration, Flagged, Cited in
//      Manuscripts, Dismissed) that select into nothing.
//    * .manuscript — the manuscript pane on iOS is imprint's editor HOST
//      (`IOSManuscriptLibraryView` + the session registry), which is an editor,
//      not a viewer, and lives in imprint's target. `ManuscriptDetailPane` is
//      still macOS-only and — unlike the figure and agent panes — is not one
//      AppKit call away from portable: it hosts the editor SESSION, which is
//      the imbib CLAUDE.md invariant. A read-only manuscript route is a real
//      future option; embedding imprint's editor is not.
//    * .artifact — `ArtifactDetailView` is macOS-only and is a genuine
//      per-artifact-type switch, not a bridge.
//    * .agentRun — a chassis LIMIT, not an app one, and worth naming precisely:
//      `sectionBindings` maps a section to ONE kind, so `.agents` binds `.task`
//      and the derived nodes are task nodes. There is no derived route to
//      `.all(.agentRun)`. A host CAN supply its own nodes, but host nodes
//      REPLACE the derived ones (`RecordSidebarBuilder`), so surfacing Runs
//      means re-spelling the task rows and the descriptor's statuses app-side —
//      forking the declaration to add a sibling to it. Same shape as the
//      "mixed-kind Flagged/Dismissed" gap already in the matrix.
//    * .reviewQueue — unbound in the preset (its rows are `review-request@1.0.0`,
//      which has no descriptor), so the builder would give it one OPAQUE row
//      that routes nowhere on iOS. Suppressed by the content gate below, which
//      is the honest instrument for "this host has nothing behind it".
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

    func refresh(version newVersion: Int, force: Bool = false) {
        guard force || version != newVersion else { return }
        version = newVersion
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
    }
}

@MainActor
enum ImpressSidebarBindings {

    /// The kinds this BUILD can present. Everything the preset permits that is
    /// bound to another kind drops out — declared, not filtered by name.
    static let presentable: Set<RecordKindID> = [.message, .figure, .task]

    static var configuration: AppShellConfiguration {
        .impress.presenting(presentable)
    }

    /// Where the shell lands on a regular-width device. Mail, because it is the
    /// only one of the three whose rows the seed and the real suite both
    /// reliably have. `RecordSidebarView` seeds no default of its own until its
    /// body runs, which iPad portrait never does before the user reveals the
    /// sidebar (impart's finding).
    static let landingScope: RecordSidebarScope = .all(.message)

    static func dataSource(
        snapshot: ImpressSidebarSnapshot,
        version: Int
    ) -> RecordSidebarDataSource {
        let sync = { snapshot.refresh(version: version) }
        return RecordSidebarDataSource(
            folders: { kind in
                sync()
                // Only `.figure` declares a `CollectionCapability`, so the
                // builder only ever asks for its folders — the `guard` states
                // that rather than relying on it.
                guard kind == .figure else { return [] }
                return snapshot.figureFolders
            },
            count: { scope in
                sync()
                switch scope {
                case .all(.message): return snapshot.mail.allInboxesCount
                case .all(.figure): return snapshot.figureCount
                case .all(.task): return snapshot.taskCount
                default: return nil
                }
            },
            // The CONTENT gate. `presenting(_:)` has already removed every
            // section bound to a kind impress-iOS cannot show; what is left is
            // the one section with no kind to be incapable of.
            sectionIsAvailable: { $0 != .reviewQueue })
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
