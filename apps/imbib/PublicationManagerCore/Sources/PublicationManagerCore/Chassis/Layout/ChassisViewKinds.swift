#if os(macOS)
// Chassis file — macOS-only. ADR-0031 L6; plan wave 6, W6.
//
//  ChassisViewKinds.swift
//  PublicationManagerCore
//
//  The chassis' view kinds, registered into the kit's `ViewKindRegistry`.
//
//  The layout host is `packages/ImpressLayout` (W6). The kit registers only
//  `placeholder`, `surface` and `console` (ImpressLogging's `ConsoleView`,
//  which needs nothing the kit lacks); everything a pane needs the CHASSIS for is
//  here and is registered at startup by `ChassisViewKinds.registerIfNeeded()`,
//  which `ChassisRootView.init` calls — before its body, so before the first
//  pane of any window renders. Tests that render or ask about these kinds
//  call it too.
//
//  The views in this file moved here verbatim from the old
//  `Chassis/Layout/ViewKindRegistry.swift` (whose generic half went to the
//  kit): the `legacy` pane, the `list` rows and the `info` detail. The other
//  factories' views already had files of their own here —
//  `LayoutOutlinePaneView`, `LayoutPublicationTabPaneView`,
//  `LayoutManuscriptPreviewPaneView`, `LayoutSourcePaneView` — and the
//  `surface` override's hooks are `LayoutSurfaceHooks.swift`.
//

import Foundation
import ImpressFTUI
import ImpressLayout
import ImpressLogging
import ImpressMailStyle
import ImpressRustCore
import SwiftUI

// MARK: - Registration

public enum ChassisViewKinds {

    /// Every kind this package registers, in the order `factories` lists
    /// them. With the kit's own three, every kind a chassis window renders —
    /// NOT the whole of `impress_layout::ViewKindId`: `notes`, `bibtex` and
    /// `surface` exist only as Swift spellings until Rust owns the list
    /// (review PH-M7, plan wave 7 T6).
    public static let kinds: [ViewKindID] = factories.map(\.kind)

    /// The chassis' factories. `surface` replaces the kit's plain one with
    /// the suite-aware hooks (MarkdownUI, `renderPlotSvg`, the row registry).
    static let factories: [ViewKindFactory] = [
        // ---- rendered ----
        // The navigator IS the chassis sidebar (plan wave 6, W3):
        // `LayoutOutlinePaneView` hosts `ImbibSidebarColumn` and turns a
        // selected row into Rust's verbs.
        ViewKindFactory(kind: .outline) { AnyView(LayoutOutlinePaneView(context: $0)) },
        ViewKindFactory(kind: .list) { AnyView(LayoutRowsPaneView(context: $0)) },
        ViewKindFactory(kind: .info) { AnyView(LayoutInfoPaneView(context: $0)) },
        ViewKindFactory(kind: .surface) {
            AnyView(LayoutSurfacePaneView(context: $0, hooks: .chassis))
        },
        ViewKindFactory(kind: .legacy) { AnyView(LayoutLegacyPaneView(context: $0)) },

        // ---- the detail tabs, one per pane (plan wave 6, W4) ----
        //
        // `PDFTab`, `NotesTab` and `BibTeXTab` unchanged, fed from the pane's
        // `single_item` / `$item` with the publication detail lifecycle
        // supplied by `LayoutPublicationTabPaneView` rather than `DetailView`.
        // Over manuscripts `pdf` is the compiled preview (imprint's Writing
        // preset puts it beside `source`); over anything else, PDFTab.
        ViewKindFactory(kind: .pdf) { context in
            context.primaryKind == RecordKindID.manuscript.rawValue
                ? AnyView(LayoutManuscriptPreviewPaneView(context: context))
                : AnyView(LayoutPublicationTabPaneView(context: context, tab: .pdf))
        },
        ViewKindFactory(kind: .notes) {
            AnyView(LayoutPublicationTabPaneView(context: $0, tab: .notes))
        },
        ViewKindFactory(kind: .bibtex) {
            AnyView(LayoutPublicationTabPaneView(context: $0, tab: .bibtex))
        },
        // Session-bearing (D6): the manuscript Source tab over an editor
        // whose `NSTextView` and undo histories come from
        // `SourcePaneSession.registry`, keyed by the spec's `SessionId` —
        // never from view identity — so a split, swap, move or preset change
        // hands the same editor to whichever pane shows it.
        ViewKindFactory(kind: .source, isSessionBearing: true) {
            AnyView(LayoutSourcePaneView(context: $0))
        },

        // A figure's rendered plot — `FigureDetailPane`'s View tab body,
        // moved into `FigureArtifactView` so both draw it one way — resolved
        // like `info`. Not session-bearing: it holds no document or undo.
        // (`console` is the kit's own: `ImpressLayout.LayoutConsolePaneView`.)
        ViewKindFactory(kind: .plot) { AnyView(LayoutPlotPaneView(context: $0)) },
    ]

    @MainActor private static var registered = false

    /// Register the chassis' view kinds into `ViewKindRegistry.builtin`.
    /// Idempotent; the first call logs what it registered.
    @MainActor
    public static func registerIfNeeded(into registry: ViewKindRegistry = .builtin) {
        let isBuiltin = registry === ViewKindRegistry.builtin
        if isBuiltin && registered { return }
        for factory in factories { registry.register(factory) }
        if isBuiltin { registered = true }
        logInfo(
            "view kinds: chassis registered \(factories.map(\.kind.rawValue).joined(separator: ", "))"
                + " (\(registry.registeredKinds.count) in the registry)",
            category: "layout")
    }
}

// MARK: - The chassis' pane views

/// D11's migration leaf.
///
/// Two shapes, chosen by the pane's `view_state`:
///
/// * **Scoped** (plan wave 6, W3) — `view_state` carries `{"section",
///   "node", "reason"}`, written by the outline for a row the algebra cannot
///   express yet (`outline.rs`, `OutlineTarget::Legacy`): ONE section's route,
///   `LayoutScopedLegacyPaneView`, not the chassis.
/// * **Unscoped** — no such `view_state`: only a layout saved before W3, or
///   an agent's bare `set-view-kind legacy`, reaches it (no preset writes
///   one). It used to mount a whole `TabContentView` — a second chassis with
///   its own sidebar and lifecycle inside the pane (review PH-L2). It now
///   says what it is and how to leave it.
///
/// The `view_state` keys are Rust's `LEGACY_SECTION_KEY` / `LEGACY_NODE_KEY`
/// / `LEGACY_REASON_KEY`; `LayoutLegacyScopeTests` decodes a Rust-produced
/// `set-pane` through `scope(of:)` so the two spellings cannot drift apart.
@MainActor
struct LayoutLegacyPaneView: View {

    let context: PaneContext

    /// The scoped route a legacy pane's `view_state` names, or nil.
    static func scope(of viewState: LayoutJSONValue?) -> (section: String?, node: LayoutJSONValue, reason: String?)? {
        guard let state = viewState?.objectValue,
              let node = state[LayoutViewStateKey.node], node.objectValue != nil
        else { return nil }
        return (state[LayoutViewStateKey.section]?.stringValue, node, state[LayoutViewStateKey.reason]?.stringValue)
    }

    var body: some View {
        if let scope = Self.scope(of: context.spec?.viewState) {
            LayoutScopedLegacyPaneView(
                context: context, section: scope.section, node: scope.node, reason: scope.reason)
        } else {
            ChassisEmptyState(
                id: "legacy-unscoped",
                title: "Unscoped Legacy Pane",
                systemImage: "shippingbox",
                message: "This pane names no route. Choose a row in the outline to show it here."
            )
            .view
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                logInfo(
                    "pane \(context.tile) legacy: unscoped (no view_state route) — named state, "
                        + "not a second chassis", category: "layout")
            }
        }
    }
}

/// One row of a `list` / `outline` pane.
///
/// A local value rather than `SharedItemRow` itself: `List(selection:)` needs
/// `Identifiable` + `Hashable`, and the FFI record's conformances are the
/// bindgen's business, not something this file should depend on.
struct LayoutPaneRow: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String?
    let schemaRef: String
    /// The layout's own kind id for this row (`library`, not `imbib/library`)
    /// — what a `select` verb and a pane parameter speak.
    let layoutKind: String?
    /// The same row in the chassis' own list-row shape, when its id is a UUID.
    ///
    /// This is what a `list` pane RENDERS (`RecordViewerRegistry.makeListRow`
    /// → `MailStyleRow`): read state, flag, star, tags, date column, the
    /// author/title/venue/abstract stack — imbib's list, not a second one.
    /// The plain fields above are the fallback for a row whose id the
    /// chassis cannot parse.
    let mailStyleRow: KindTaggedRow?

    @MainActor
    init(_ row: SharedItemRow) {
        id = row.id
        schemaRef = row.schemaRef
        let payload = (try? LayoutJSONValue.decode(row.payloadJson))?.objectValue ?? [:]
        var resolvedTitle: String?
        for key in ["title", "name", "subject", "label", "path"] {
            if let value = payload[key]?.stringValue, !value.isEmpty {
                resolvedTitle = value
                break
            }
        }
        title = resolvedTitle ?? row.id
        detail = payload["author"]?.stringValue ?? payload["authors"]?.stringValue
        mailStyleRow = LayoutPaneRowMapper.kindTaggedRow(row)
        layoutKind = LayoutPaneRowMapper.layoutKind(forSchemaRef: row.schemaRef)
    }
}

/// The `list` view kind: the pane's compiled query, run, with selection
/// published on the pane's channel.
///
/// Selection is NOT `@State`. It is read from the channel state in the tree
/// and written with the `select` verb, which is the whole of what "selecting
/// in the list drives the detail pane" means once panes are query-addressed
/// (ADR-0031 D1/D3). The rows themselves are query RESULTS — derived data,
/// re-read when the invalidation feed says this pane is stale.
@MainActor
struct LayoutRowsPaneView: View {

    let context: PaneContext

    @State private var rows: [LayoutPaneRow] = []
    @State private var loadFailed = false
    /// How many rows the pane's query has in all, and whether the rows shown
    /// are fewer — a page is never presented as the whole result (review
    /// PH-H4, SK-K9: a 2,657-paper library used to show its first 500 and
    /// nothing said the rest existed).
    @State private var total: UInt64 = 0
    @State private var truncated = false
    /// Pages of `LayoutController.pageSize` the person asked to see; reset
    /// when the pane's query changes.
    @State private var pages: UInt32 = 1
    @State private var shownQuery = ""
    /// Bumped by every `load()`. The row menus take it as an input: a menu
    /// reads its labels (Star / Unstar, Mark as Read / Unread) from the store
    /// when it is built, and SwiftUI rebuilds it only when an input changes —
    /// without this the menu kept "Unstar" after the row had been unstarred.
    @State private var rowsRevision = 0

    /// The per-kind row factories, from the environment the chassis already
    /// injects — not a lookup of our own, so a host that registered a custom
    /// row gets it in panes too.
    @Environment(\.recordViewerRegistry) private var viewerRegistry

    /// The user's own list settings — venue line, flag stripe, tag chips,
    /// density, how many abstract lines. A pane that ignored them would be a
    /// list that disagrees with the one in the next window, and with the
    /// settings pane that claims to control it.
    @State private var listSettings: ListViewSettings = ListViewSettingsStore.loadSettingsSync()

    /// The toolbar band this pane sits under (`LayoutLinearSplit` reclaims it
    /// for every horizontal child but the first — which is where every
    /// preset's `list` pane is). Without it the first row drew under the
    /// window toolbar: the W2 screenshots of impel, impart and implore all
    /// showed it. Padding OUTSIDE the scroll view, not a content margin: the
    /// band is measured after the first layout, and a content margin that
    /// grows then leaves the scroll origin where it was, so at launch the
    /// first row still sat under the title bar (seen in impress, 2026-09-23)
    /// until the rows were replaced.
    @Environment(\.layoutToolbarBand) private var toolbarBand

    // A manuscript row's Rename… and Delete… raise the alerts the
    // Manuscripts section raises (`ManuscriptRowChrome`); their state is here.
    @State private var manuscriptRename: ManuscriptRenameRequest?
    @State private var manuscriptRenameDraft = ""
    @State private var pendingManuscriptDelete: Set<UUID> = []
    @State private var showManuscriptDelete = false
    // …and a figure row's Delete… the Figures section's.
    @State private var pendingFigureDelete: Set<UUID> = []
    @State private var showFigureDelete = false
    @Environment(\.appShellConfiguration) private var shellConfiguration
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        rowList
            .listStyle(.inset)
            .manuscriptRenameAlert($manuscriptRename, draft: $manuscriptRenameDraft) { id, title in
                manuscriptActions.onRename(id, title)
            }
            .manuscriptDeleteConfirmation(
                pending: $pendingManuscriptDelete, isPresented: $showManuscriptDelete
            ) { ids in
                ManuscriptDeletion.perform(ids)
                deselect(ids)
            }
            .figureDeleteConfirmation(
                pending: $pendingFigureDelete, isPresented: $showFigureDelete
            ) { ids in
                FigureDeletion.perform(ids)
                deselect(ids)
            }
            .padding(.top, toolbarBand)
            .overlay { emptyOverlay.padding(.top, toolbarBand) }
            // The rows are query RESULTS, so they re-run when Rust says THIS
            // pane is stale — the tile's own token, not the controller's
            // global one, which moves when any pane goes stale (PH-H1: a
            // set-query on another pane used to re-run this pane's query).
            .onChange(of: context.refreshToken) { _, _ in load() }
            .onAppear { load() }
            .task {
                // The invalidation feed sees writes made through the layout's
                // own store handle, and from other connections only `impress/
                // ui/` rows — so a star, flag, tag, dismiss or delete made
                // through `RustStoreAdapter` (every row menu, every triage
                // key) never marked this pane stale, and its rows kept the old
                // star, flag and membership until something else re-ran the
                // query. The legacy lists listen to the store's own event
                // stream for exactly this; so does the pane: a mutation of a
                // row on screen, or a structural / membership change (which
                // can add or remove rows), re-runs the query.
                for await event in ImbibImpressStore.shared.events.subscribe() {
                    switch event {
                    case .itemsMutated(_, let ids):
                        let shown = Set(rows.compactMap { UUID(uuidString: $0.id) })
                        if !shown.isDisjoint(with: ids) { load() }
                    case .structural, .collectionMembershipChanged:
                        load()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .listViewSettingsDidChange)) { _ in
                Task { listSettings = await ListViewSettingsStore.shared.settings }
            }
    }

    private var rowList: some View {
        List(selection: selection) {
            ForEach(rows) { row in
                rowChrome(rowView(row), row).tag(row.id)
            }
            if truncated {
                pageFooter
            }
        }
    }

    /// "Showing 500 of 2,657" and the way to the next page. Not a row of the
    /// selection (no tag), and a plain button, so it is reachable from the
    /// keyboard like every other control.
    private var pageFooter: some View {
        HStack(spacing: 12) {
            Text("Showing \(rows.count.formatted()) of \(Int(total).formatted())")
                .foregroundStyle(.secondary)
            Button("Show \(min(Int(LayoutController.pageSize), Int(total) - rows.count).formatted()) More") {
                pages &+= 1
                load()
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
        .accessibilityIdentifier("pane-page-footer")
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        Group {
            if rows.isEmpty {
                // Empty is not an error and an error is not empty: a refused
                // query says so, an empty result says something else.
                ChassisEmptyState(
                    id: "pane-empty",
                    title: loadFailed ? "Query Refused" : "Nothing Here",
                    systemImage: loadFailed ? "exclamationmark.triangle" : "tray",
                    message: loadFailed
                        ? (context.error ?? "The pane's query did not run.")
                        : "This pane's query matched no items."
                )
                .view
            }
        }
    }

    /// A `list` pane shows the chassis' row.
    ///
    /// The list branch goes through `RecordViewerRegistry`, the SAME factory
    /// the heterogeneous list and the store-search results use, so a pane and
    /// a section show one row design and a kind that overrides its row gets
    /// that override here for free. Writing a row here instead is how L6
    /// ended up with a list that shared nothing with imbib's.
    @ViewBuilder
    private func rowView(_ row: LayoutPaneRow) -> some View {
        if let mailStyle = row.mailStyleRow {
            // The kind's own row when it has one; otherwise the shared chrome
            // with the user's settings, which is what the registry's default
            // builds too.
            if let factory = viewerRegistry[mailStyle.kind], mailStyle.kind != .publication {
                factory.makeListRow(mailStyle)
            } else {
                MailStyleRow(
                    item: mailStyle, configuration: listSettings.mailStyleConfiguration)
            }
        } else {
            // A row whose id is not a UUID: the chassis cannot identify it,
            // so it gets its title and nothing that acts on it.
            Text(row.title)
                .lineLimit(1)
        }
    }

    /// What a `list` row carries besides its look — the legacy list's own
    /// drag payload and context menu for its kind (plan wave 6, W3 / W4):
    ///
    /// * a publication drags `PublicationDragPayload` (the payload
    ///   `MailStylePublicationRow` writes) onto an outline collection or
    ///   library row, and shows `PublicationRowContextMenu` over
    ///   `PublicationListActions.chassis`;
    /// * a manuscript drags `ManuscriptDragPayload` onto a folder and shows
    ///   `ManuscriptRowMenu` over `RecordTriageActions.manuscripts`;
    /// * a figure drags `FigureDragPayload` and shows `FigureRowMenu` over
    ///   `RecordTriageActions.figures`;
    /// * a message, task or agent-run row shows the shared triage segment
    ///   over `RecordTriageActions.storeBacked`, as its own list does, and
    ///   drags nothing (neither list does).
    ///
    /// All act on the selection when the row is part of it, else the row.
    @ViewBuilder
    private func rowChrome(_ content: some View, _ row: LayoutPaneRow) -> some View {
        if let id = UUID(uuidString: row.id),
            row.mailStyleRow?.kind == .publication
        {
            let context = context
            content
                .itemProvider {
                    let selected = context.currentSelection.compactMap(UUID.init(uuidString:))
                    let ids = selected.contains(id) && selected.count > 1 ? selected : [id]
                    return PublicationDragPayload.provider(
                        ids: ids, paperRef: nil,
                        suggestedName: ids.count > 1 ? "\(ids.count) publications" : row.title)
                }
                .contextMenu {
                    LayoutPublicationRowMenu(
                        context: context, targets: targets(for: id), order: rowOrder,
                        revision: rowsRevision)
                }
        } else if let id = UUID(uuidString: row.id),
            row.mailStyleRow?.kind == .manuscript
        {
            content
                .itemProvider {
                    ManuscriptDragPayload.provider(ids: Array(targets(for: id)))
                }
                .contextMenu {
                    LayoutManuscriptRowMenu(
                        rowID: id,
                        revision: rowsRevision,
                        targets: targets(for: id),
                        isFolderScoped: manuscriptFolderID != nil,
                        actions: manuscriptActions,
                        onRename: { request in
                            manuscriptRenameDraft = request.title
                            manuscriptRename = request
                        })
                }
        } else if let id = UUID(uuidString: row.id),
            row.mailStyleRow?.kind == .figure
        {
            content
                .itemProvider {
                    FigureDragPayload.provider(ids: Array(targets(for: id)))
                }
                .contextMenu {
                    FigureRowMenu(
                        rowID: id,
                        isStarred: row.mailStyleRow?.isStarred ?? false,
                        rowTagPaths: tagPaths(of: row),
                        targets: targets(for: id),
                        isFolderScoped: figureFolderID != nil,
                        actions: figureActions)
                }
        } else if let id = UUID(uuidString: row.id),
            let kind = row.mailStyleRow?.kind,
            [RecordKindID.message, .task, .agentRun].contains(kind),
            let descriptor = BuiltinRecordKinds.registry[kind]
        {
            // What MessageListWrapper and AgentRecordListWrapper show: the
            // shared triage segment alone, over the store-backed defaults
            // their sections pass (mail and task lifecycles are owned
            // elsewhere, so the descriptors declare no dismiss or delete).
            content
                .contextMenu {
                    TriageMenu.items(
                        triage: descriptor.triage,
                        row: TriageRowState(
                            isStarred: row.mailStyleRow?.isStarred ?? false,
                            isDismissed: false, isArchived: false),
                        rowTagPaths: tagPaths(of: row),
                        targets: targets(for: id),
                        actions: .storeBacked(descriptor: descriptor))
                }
        } else {
            content
        }
    }

    /// A row's tag paths, as the pane last read them.
    private func tagPaths(of row: LayoutPaneRow) -> Set<String> {
        Set(row.mailStyleRow?.tagDisplays.map(\.path) ?? [])
    }

    /// The folder a figure list pane is scoped to, if any.
    private var figureFolderID: UUID? {
        LayoutPaneScope.parentID(query: context.spec?.query, bindings: context.bindings)
    }

    /// The Figures section's verbs, with the tree as the host.
    private var figureActions: RecordTriageActions {
        .figures(FigureRowActionsHost(
            isFolderScoped: figureFolderID != nil,
            shellConfiguration: shellConfiguration,
            openWindow: openWindow,
            requestDelete: { ids in
                pendingFigureDelete = ids
                showFigureDelete = true
            }))
    }

    /// The ids a row action applies to: the channel's selection when the row
    /// is in it (and it is more than the row), else the row — Mail semantics,
    /// as both legacy lists.
    private func targets(for id: UUID) -> Set<UUID> {
        let selected = Set(context.currentSelection.compactMap(UUID.init(uuidString:)))
        return selected.contains(id) && selected.count > 1 ? selected : [id]
    }

    /// The rows' ids in the order the pane shows them.
    private var rowOrder: [UUID] {
        rows.compactMap { UUID(uuidString: $0.id) }
    }

    /// The folder a manuscript list pane is scoped to, if any.
    private var manuscriptFolderID: UUID? {
        LayoutPaneScope.collectionID(query: context.spec?.query, bindings: context.bindings)
    }

    /// The Manuscripts section's verbs, with the TREE as the host: the
    /// selection is the channel's, Delete… raises this pane's confirmation.
    private var manuscriptActions: RecordTriageActions {
        let context = context
        let kind = RecordKindID.manuscript.rawValue
        return .manuscripts(ManuscriptRowActionsHost(
            folderID: manuscriptFolderID,
            shellConfiguration: shellConfiguration,
            openWindow: openWindow,
            selectedID: {
                context.currentSelection.first.flatMap(UUID.init(uuidString:))
            },
            select: { id in
                context.select(id.map { [$0.uuidString.lowercased()] } ?? [], kind: kind)
            },
            requestDelete: { ids in
                pendingManuscriptDelete = ids
                showManuscriptDelete = true
            }))
    }

    /// Drop deleted ids from the channel's selection.
    private func deselect(_ ids: Set<UUID>) {
        let kept = context.currentSelection.filter {
            UUID(uuidString: $0).map { !ids.contains($0) } ?? true
        }
        context.select(Array(kept), kind: context.primaryKind)
    }

    /// The channel's current selection, written back as a `select` verb.
    private var selection: Binding<Set<String>> {
        let context = context
        return Binding(
            get: { context.currentSelection },
            set: { ids in
                // The kind of what was actually selected, not of the query:
                // a query may name several kinds, and each binds different
                // parameters downstream.
                context.select(Array(ids), kind: kindOfSelection(ids))
            })
    }

    /// The record kind shared by the selected rows, if they agree.
    ///
    /// They disagree only in a multi-selection across kinds, which the `select`
    /// verb cannot express (one kind, many ids); the pane's default kind is
    /// then the honest answer rather than picking one row's kind for all.
    private func kindOfSelection(_ ids: Set<String>) -> String? {
        let kinds = Set(rows.filter { ids.contains($0.id) }.compactMap(\.layoutKind))
        return kinds.count == 1 ? kinds.first : nil
    }

    private func load() {
        let tile = context.tile
        // A new query starts at its first page again.
        let query = context.pane.compiledQueryJson
        if query != shownQuery {
            shownQuery = query
            pages = 1
        }
        // THIS pane's failure, never another pane's or a verb's refusal
        // (PH-M3): `loadPage` throws what Rust refused, and the tile's own
        // error slot says why. The page is the kit's page size times the
        // pages asked for; the query's own limit is honoured by Rust.
        let fetched: [SharedItemRow]
        do {
            let page = try context.loadPage(limit: LayoutController.pageSize &* pages)
            fetched = page.rows
            total = page.total
            truncated = page.truncated
            loadFailed = false
        } catch {
            fetched = []
            total = 0
            truncated = false
            loadFailed = true
        }
        rows = fetched.map(LayoutPaneRow.init)
        rowsRevision &+= 1
        context.controller.didRefresh(tile)
        if truncated {
            logInfo(
                "pane \(tile) display: \(rows.count) of \(total) rows (truncated; \(pages) page(s))",
                category: "layout")
        } else {
            logInfo("pane \(tile) display: \(rows.count) rows", category: "layout")
        }
        PublicationTagRemoval.reportDisplay(
            surface: "pane \(tile)",
            rows: rows.compactMap { row in
                guard let tagged = row.mailStyleRow, tagged.kind == .publication else { return nil }
                return (tagged.id, tagged.tagDisplays.map(\.path))
            })
    }
}

/// The `info` view kind: the record kind's EXISTING detail pane, for whatever
/// the pane's `item` parameter currently resolves to.
///
/// Six kinds route here and every one of them is a view the chassis already
/// ships: `DetailView` is the same failable entry point `SectionContentView`
/// uses for a publication; `ManuscriptDetailPane` is the Manuscripts
/// section's detail; `FigureDetailPane`, `MessageDetailPane` and
/// `AgentRecordDetailPane` are the id-based panes their sections build for
/// their own detail half. Nothing was extracted to get here (ADR-0031 D11 —
/// map, do not rewrite).
///
/// `topInset` is the toolbar band the tree measured for this pane
/// (`layoutToolbarBand`), not the section views' fixed 40 pt. A layout pane
/// DOES reclaim the band — `LayoutLinearSplit` ignores the top safe area for
/// every horizontal child but the first, which is where every preset's `info`
/// pane sits — so 0 put each detail pane's tab picker under the window
/// toolbar, invisible and unclickable. A pane that is not under the toolbar
/// is told 0 and gets no gap.
///
/// The detail TAB is `PaneSpec.view_state["tab"]` (review PH-M6), written
/// with `set-pane` like any other pane state — not view `@State`, which a
/// split rebuilt by structure (back to Info) and no agent could read or set.
/// A manuscript's editor session is resolved HERE, by the host, and passed
/// in (apps/imbib/CLAUDE.md: the session is owned by the host view, never by
/// `ManuscriptDetailPane`).
@MainActor
struct LayoutInfoPaneView: View {

    /// Which detail the pane shows. A plain enum switched over a plain
    /// `some View`, NOT a `@ViewBuilder` returning `(some View)?` — that
    /// shape does not propagate `nil` through `if let` and silently renders
    /// the wrong branch for every case (impress-swiftui-pitfalls rule 3, a
    /// bug this file is the exact shape of).
    enum DetailKind: Equatable {
        case publication
        case manuscript
        case figure
        case message
        case task
        case agentRun
        /// A kind this build has no detail pane for — the honest fallback.
        case unsupported

        /// From the pane's own layout kind — the manifest's short id
        /// (`figure`), which is what a pane query and a `select` verb spell —
        /// through `LayoutKindID`, the join onto the chassis' `RecordKindID`.
        @MainActor
        init(layoutKind: String?) {
            guard let kind = LayoutKindID.recordKind(forLayoutKind: layoutKind) else {
                self = .unsupported
                return
            }
            switch kind {
            case .publication: self = .publication
            case .manuscript: self = .manuscript
            case .figure: self = .figure
            case .message: self = .message
            case .task: self = .task
            case .agentRun: self = .agentRun
            default: self = .unsupported
            }
        }
    }

    /// The tab a pane's `view_state` names; Info when it names none.
    static func tab(in viewState: LayoutJSONValue?) -> DetailTab {
        viewState?[LayoutViewStateKey.tab]?.stringValue.flatMap(DetailTab.init(rawValue:)) ?? .info
    }

    let context: PaneContext

    /// The manuscript's editor session, resolved by this host (debounced like
    /// `ManuscriptSectionView`'s, so arrowing through a list does not open an
    /// editor per row).
    @State private var manuscriptSession: ManuscriptEditorSession?

    @Environment(\.layoutToolbarBand) private var toolbarBand

    private var itemID: UUID? {
        guard let raw = rawItem else { return nil }
        return UUID(uuidString: raw)
    }

    private var rawItem: String? {
        context.singleItem ?? context.bindings["item"]
    }

    /// The kind the pane's query names. A detail pane's query is
    /// `detail_query(list)` — the list's kinds, scoped to `$item` — so this
    /// is the kind of the thing the parameter resolved to, not a guess.
    private var detailKind: DetailKind {
        DetailKind(layoutKind: context.primaryKind)
    }

    /// The pane's detail tab, read from and written to its `view_state`.
    private var selectedTab: Binding<DetailTab> {
        let context = context
        return Binding(
            get: { Self.tab(in: context.spec?.viewState) },
            set: { tab in
                guard tab != Self.tab(in: context.spec?.viewState) else { return }
                LayoutPaneViewState.merge(
                    [LayoutViewStateKey.tab: .string(tab.rawValue)], into: context.tile, controller: context.controller,
                    why: "info tab → \(tab.rawValue)")
            })
    }

    /// The manuscript whose session this pane should hold, or nil.
    private var manuscriptKey: UUID? {
        detailKind == .manuscript ? itemID : nil
    }

    var body: some View {
        Group {
            if let itemID {
                detail(for: itemID)
                    // The leaf's conversion is otherwise invisible: a figure
                    // detail and a "no publication detail" empty state occupy
                    // the same pixels. Naming the branch makes
                    // `?category=layout` the place the proof is read, rather
                    // than a screenshot.
                    .onAppear { logDispatch(itemID) }
                    .onChange(of: itemID) { _, id in logDispatch(id) }
            } else if let raw = rawItem {
                // A bound parameter whose value is not an id at all.
                unavailable(raw)
            } else {
                // An unfilled parameter renders the empty state, NEVER an
                // error (ADR-0031 D3) — this is what a detail pane looks like
                // before the first selection.
                ChassisEmptyState.noRowSelection(
                    kind: LayoutKindID.recordKind(forLayoutKind: context.primaryKind)
                        ?? RecordKindID(context.primaryKind ?? "")
                ).view
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: manuscriptKey) { await resolveManuscriptSession() }
    }

    private func logDispatch(_ id: UUID) {
        logInfo(
            "pane \(context.tile) info: \(detailKind) detail for \(id.uuidString), "
                + "tab \(Self.tab(in: context.spec?.viewState).rawValue)",
            category: "layout")
    }

    /// Resolve the manuscript session for the selected manuscript: drop a
    /// stale one at once, wait out a short quiet window, then ask the
    /// registry — never for a manuscript that indexes an external file
    /// (ADR-0023 D4: no session, so no late save can reach the file).
    private func resolveManuscriptSession() async {
        let tile = context.tile
        guard let id = manuscriptKey else {
            manuscriptSession = nil
            return
        }
        if manuscriptSession?.manuscriptID != id { manuscriptSession = nil }
        try? await Task.sleep(for: .milliseconds(90))
        guard !Task.isCancelled else { return }
        guard RustStoreAdapter.shared.manuscriptAllowsEditorSession(id: id) else {
            logInfo(
                "pane \(tile) info: manuscript \(id.uuidString) has external_source — no editor session",
                category: "layout")
            return
        }
        manuscriptSession = ManuscriptSessionRegistry.shared.session(for: id)
        logInfo(
            "pane \(tile) info: manuscript \(id.uuidString) session "
                + (manuscriptSession == nil ? "unavailable — not in the store" : "resolved"),
            category: "layout")
    }

    @ViewBuilder
    private func detail(for id: UUID) -> some View {
        switch detailKind {
        case .publication:
            // Failable: the id may name a row that has since gone.
            if let view = DetailView(publicationID: id, selectedTab: selectedTab) {
                view
            } else {
                unavailable(id.uuidString)
            }
        case .manuscript:
            ManuscriptDetailPane(
                manuscriptID: id, session: manuscriptSession, selectedTab: selectedTab,
                topInset: toolbarBand)
        case .figure:
            FigureDetailPane(figureID: id, selectedTab: selectedTab, topInset: toolbarBand)
        case .message:
            MessageDetailPane(messageID: id, selectedTab: selectedTab, topInset: toolbarBand)
        case .task:
            AgentRecordDetailPane(
                kind: .task, recordID: id, selectedTab: selectedTab, topInset: toolbarBand)
        case .agentRun:
            AgentRecordDetailPane(
                kind: .run, recordID: id, selectedTab: selectedTab, topInset: toolbarBand)
        case .unsupported:
            unavailable(id.uuidString)
        }
    }

    /// The parameter resolved to something this build has no detail for.
    /// Names the KIND as well as the id: "no detail for <id>" sent every
    /// earlier reader looking for a missing row when the real answer was a
    /// missing view.
    private func unavailable(_ raw: String) -> some View {
        ChassisEmptyState(
            id: "detail-unavailable",
            title: "Detail Unavailable",
            systemImage: RecordKindDescriptor.unknownSymbolName,
            message: "No \u{201C}\(context.primaryKind ?? "item")\u{201D} detail for "
                + "\u{201C}\(raw)\u{201D}."
        )
        .view
    }
}
#endif
