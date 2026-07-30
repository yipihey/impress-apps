//
//  IOSImpressHostView.swift
//  impress-iOS
//
//  The three-column host: chassis sidebar, chassis list host, chassis detail
//  panes. Everything below is plumbing between three shared components — which
//  is the D9 claim in its iOS spelling.
//
//  Placement rules carried from impart-iOS (each was a bug there first):
//    * the settings sheet lives at the NAVIGATION ROOT, never inside a column —
//      a column's own navigation dismisses it when the split view collapses;
//    * the gear sits on the SIDEBAR column, the column iPhone lands on;
//    * never auto-select in compact width — writing a selection PUSHES the
//      detail over the list the user just landed on.
//

import ImpressMailStyle
import PublicationManagerCore
import SwiftUI

/// The sidebar's selection, translated into the chassis's per-kind list
/// vocabulary. One initialiser, five tries, no section-name literals: each
/// `RecordRouteScope` conformance already knows which route scopes are its own,
/// because the scope carries the kind.
///
/// Two cases carry a TITLE, and the reason is worth naming: `MessageListScope`,
/// `FigureListScope` and `AgentListScope` can name themselves because every
/// scope they have is a fixed subset ("All Figures", "Queued"). A publication
/// library or a manuscript folder is named by the USER, and the sidebar has
/// just read that name — asking the list column to read it again would be a
/// second store round trip for a string the caller is holding.
enum ImpressRoute: Hashable {
    case messages(MessageListScope)
    case figures(FigureListScope)
    case tasks(AgentListScope)
    case publications(PublicationSource, title: String)
    case manuscripts(ManuscriptListScope, title: String)

    /// - Parameter snapshot: needed for the two host-named scopes — the Inbox
    ///   section carries no library id (a store read the chassis conversion
    ///   deliberately refuses), and folder/library titles live in the sidebar's
    ///   own read.
    @MainActor
    init?(scope: RecordSidebarScope, snapshot: ImpressSidebarSnapshot) {
        if let mail = MessageListScope(routeScope: scope) { self = .messages(mail); return }
        if let figure = FigureListScope(routeScope: scope) { self = .figures(figure); return }
        if let agent = AgentListScope(routeScope: scope) { self = .tasks(agent); return }
        if let manuscript = ManuscriptListScope(routeScope: scope) {
            self = .manuscripts(
                manuscript,
                title: ImpressSidebarBindings.manuscriptTitle(
                    for: manuscript, snapshot: snapshot))
            return
        }
        if let source = ImpressSidebarBindings.publicationSource(
            for: scope, snapshot: snapshot) {
            self = .publications(
                source,
                title: ImpressSidebarBindings.publicationTitle(
                    for: scope, snapshot: snapshot))
            return
        }
        return nil
    }

    var kind: RecordKindID {
        switch self {
        case .messages: return .message
        case .figures: return .figure
        case .tasks: return .task
        case .publications: return .publication
        case .manuscripts: return .manuscript
        }
    }

    var title: String {
        switch self {
        case .messages(let s): return s.title
        case .figures(let s): return s.title
        case .tasks(let s): return s.title
        case .publications(_, let title): return title
        case .manuscripts(_, let title): return title
        }
    }
}

struct IOSImpressHostView: View {

    @State private var scope: RecordSidebarScope?
    @State private var selectedRecordID: UUID?
    @State private var selectedTab: DetailTab = AppShellConfiguration.impress.defaultDetailTab
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var snapshot = ImpressSidebarSnapshot()
    @State private var revision = 0
    @State private var showSettings = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Read in `body` so the view observes it (the `@Observable` rule).
    private var storeAdapter: RustStoreAdapter { RustStoreAdapter.shared }
    private var dataVersion: Int { storeAdapter.dataVersion &* 1_000 &+ revision }

    private var route: ImpressRoute? {
        scope.flatMap { ImpressRoute(scope: $0, snapshot: snapshot) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } content: {
            listColumn
        } detail: {
            detailColumn
        }
        .task { refresh() }
        .sheet(isPresented: $showSettings) {
            IOSSettingsScreen(configuration: .impress) { showSettings = false }
                .environment(\.settingsSectionRegistry, ImpressSettingsSections.registry)
        }
    }

    // MARK: - Columns

    private var sidebarColumn: some View {
        RecordSidebarView(
            configuration: ImpressSidebarBindings.configuration,
            dataSource: ImpressSidebarBindings.dataSource(
                snapshot: snapshot, version: dataVersion),
            dataVersion: dataVersion,
            selection: $scope,
            title: "impress")
        .refreshable { refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("toolbar.settings")
            }
        }
    }

    @ViewBuilder
    private var listColumn: some View {
        if let route {
            IOSImpressListColumn(
                route: route,
                selectedID: $selectedRecordID,
                dataVersion: dataVersion)
                // The imbib `.id(source.id)` rule: a route handed to a child as
                // a `let` inside a NavigationSplitView column goes stale
                // without this.
                .id(route)
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "sidebar.left",
                description: Text("Choose a section in the sidebar."))
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let route, let id = selectedRecordID {
            recordDetail(route: route, id: id)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(
                "No Record Selected",
                systemImage: "doc.text",
                description: Text("Select a record to see it here."))
        }
    }

    /// Five chassis panes, no app-side detail view. Two of them were
    /// `#if os(macOS)` before this shell asked for them; the publication pane
    /// was imbib-app-private and the read-only manuscript pane did not exist
    /// until I2 — which is what "chassis-level, never an impress-only fork"
    /// costs and buys.
    @ViewBuilder
    private func recordDetail(route: ImpressRoute, id: UUID) -> some View {
        switch route {
        case .messages:
            MessageDetailPane(messageID: id, selectedTab: $selectedTab)
                .accessibilityIdentifier("messageDetail")
        case .figures:
            FigureDetailPane(figureID: id, selectedTab: $selectedTab)
                .accessibilityIdentifier("figureDetail")
        case .tasks:
            AgentRecordDetailPane(kind: .task, recordID: id, selectedTab: $selectedTab)
                .accessibilityIdentifier("taskDetail")
        case .publications:
            // No `libraryID`: a cross-library scope has none, and the pane
            // resolves the paper's own. No `LibraryViewModel`/`LibraryManager`
            // in the environment either, so Copy BibTeX takes the store route
            // and the Explore row does not render — both declared, not broken.
            IOSPublicationDetailPane(publicationID: id)
                .accessibilityIdentifier("publicationDetail")
        case .manuscripts:
            IOSManuscriptReadOnlyPane(manuscriptID: id, selectedTab: $selectedTab)
                .accessibilityIdentifier("manuscriptDetail")
        }
    }

    // MARK: - Data

    private func refresh() {
        // `force`: the store is written out of process (the Mac apps mirror
        // into the same app group), so a version that has not changed is not
        // evidence the tree has not.
        snapshot.refresh(version: dataVersion, force: true)
        revision += 1
        if scope == nil, horizontalSizeClass != .compact {
            scope = ImpressSidebarBindings.landingScope
        }
    }
}
