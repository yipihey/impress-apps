#if os(macOS)
// Chassis file — macOS-only. Plan wave 6, W3 (L8 leaf 4): the outline sidebar.
//
//  LayoutOutlinePaneView.swift
//  PublicationManagerCore
//
//  The `outline` view kind: the navigator pane IS the app's sidebar.
//
//  ## What it draws
//
//  The chassis sidebar, whole — `ImbibSidebarColumn` over an
//  `ImbibSidebarViewModel` with `ImbibSidebarLifecycle` applied, exactly as
//  `TabContentView` hosts it. So the rows are the app's sections and their
//  children (libraries, collections, feeds, flags, dismissed, the record
//  kinds' folders and states), the counts are the badges the sidebar already
//  computes from its snapshot / per-`dataVersion` caches (never a query per
//  row per render — `SidebarStoreCallRatchetTests` is the law and this pane
//  adds no builder), and the context menus, inline rename, delete (with its
//  confirmations), drag and drop are the view model's own
//  (`capabilities(of:)`, `buildContextMenu`, `handleExternalDrop`, …). None of
//  that is re-implemented here: a second rename or drop path is how two
//  definitions of one capability start to drift.
//
//  Which sections it shows is Rust's table (`outline_sections_json`): the
//  view model's `layoutSectionFilter` hides any section the chassis would
//  draw and the table does not name, and that is logged.
//
//  ## What selecting a row does
//
//  NOT what it does in `TabContentView` (drive `SectionContentView`). The
//  selected tab becomes an `OutlineNode` (`LayoutOutlineNode`), Rust answers
//  with the target and the verbs (`outline_row_verbs_json`), and this view
//  applies those verbs — a `select` on the channel and a `set-query` on the
//  pane with the `list` role, or a `set-pane` to a scoped `legacy` pane for a
//  route the algebra cannot express yet. The list pane re-runs its query and
//  the `info` pane follows the list's selection through the channel, as it
//  always did (ADR-0031 D3/D5).
//
//  A click is one unit (review PH-M2): the dedupe is committed only once
//  every verb Rust named has applied, and a verb refused halfway rolls back
//  the ones before it (each is on its target pane's exploration ring), so a
//  refused click leaves neither a half-routed tree nor a row that ignores a
//  second click. It is still two or three undo entries, not one — that needs
//  Rust to apply the outline's verbs as one step, which is not this layer's.
//
//  ## The launch selection
//
//  The view model selects its default section by itself when it is
//  configured. That is not a user's choice, so it retargets the list only
//  when Rust says the list is still on the preset's own query
//  (`initial_selection_applies`) — a layout restored at launch with the list
//  on a collection stays on that collection, and the sidebar then follows it
//  (below).
//
//  ## Following the list (review PH-H5)
//
//  The outline is not the only writer of the list's query: an agent's
//  `set-query` or `apply-layout`, a surface's `open`, an undo all retarget
//  it. When the list's spec changes on a version this view did not apply,
//  the sidebar is re-read against it. Which row IS the list's query is
//  Rust's answer to the forward question, asked of candidate rows (the
//  current one, the ids the query and its bindings name, the section rows,
//  its tag and flag filters): a row whose `outline_row_verbs` leave the list
//  pane alone is the row the list shows. The sidebar selects it, or
//  deselects — with a log line — when no row is; either way the dedupe is
//  cleared, so one click on any row, the highlighted one included, routes.
//
//  ## Across a re-layout (review PH-M6)
//
//  The sidebar's view model, the dedupe and the last-seen list spec live in
//  `LayoutOutlinePaneState`, keyed by the pane's tile, so a split or swap
//  that rebuilds this view by structure keeps the expansion, the selection
//  and the filter, and does not configure the sidebar a second time.
//

import Foundation
import ImpressLayout
import ImpressLogging
import ImpressRustCore
import SwiftUI

@MainActor
struct LayoutOutlinePaneView: View {

    let context: PaneContext

    /// Outlives this view: see `LayoutOutlinePaneState`.
    private let state: LayoutOutlinePaneState

    @Environment(\.appShellConfiguration) private var shell
    @Environment(LibraryManager.self) private var libraryManager

    init(context: PaneContext) {
        self.context = context
        self.state = LayoutOutlinePaneState.state(for: context)
    }

    var body: some View {
        let viewModel = state.viewModel
        ImbibSidebarColumn(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(
                ImbibSidebarLifecycle(
                    viewModel: viewModel,
                    prepare: { model in applySectionFilter(to: model) },
                    configured: { model in
                        router.route(model.selectedTab, initial: true)
                        router.reconcile(because: "launch")
                    },
                    remounted: { _ in router.reconcile(because: "remount") }))
            .onChange(of: viewModel.selectedTab) { _, tab in
                // A change the outline made itself to follow the list.
                if let echo = state.echo {
                    state.echo = nil
                    if echo == tab { return }
                }
                router.route(tab, initial: false)
            }
            .onChange(of: context.controller.version) { _, version in
                router.listMayHaveMoved(at: version)
            }
            // Deleting the SELECTED library leaves the sidebar's selection on
            // the dead id (the chassis never reassigns it), so `selectedTab`
            // does not change and `route` never hears of it. The library list
            // does change.
            .onChange(of: libraryManager.libraries.map(\.id)) { _, ids in
                if case .library(let id) = state.routedTab, !ids.contains(id) {
                    router.clearSelection(because: "its library was deleted")
                }
            }
    }

    private var router: LayoutOutlineRouter {
        LayoutOutlineRouter(
            controller: context.controller, tile: context.tile, shell: shell,
            dismissedLibraryID: libraryManager.dismissedLibrary?.id, state: state)
    }

    // MARK: Sections

    private func applySectionFilter(to model: ImbibSidebarViewModel) {
        let appID = context.controller.appID
        let json = outlineSectionsJson(appId: appID)
        guard let rows = (try? LayoutJSONValue.decode(json))?.arrayValue else {
            logWarning("outline: section table for \(appID) did not decode: \(json)", category: "layout")
            return
        }
        var permitted: Set<SidebarSectionType> = []
        var legacy: [String] = []
        for row in rows {
            guard let name = row.objectValue?["section"]?.stringValue else { continue }
            guard let section = LayoutOutlineNode.section(named: name) else {
                logWarning(
                    "outline: Rust names section '\(name)' for \(appID), which this build has no "
                        + "SidebarSectionType for", category: "layout")
                continue
            }
            permitted.insert(section)
            if row.objectValue?["legacy"]?.boolValue == true { legacy.append(name) }
        }
        model.layoutSectionFilter = permitted
        let dropped = SidebarSectionType.allCases
            .filter { shell.permits($0) && !permitted.contains($0) }
            .map(LayoutOutlineNode.sectionName)
        logInfo(
            "outline: \(appID) shows \(permitted.count) sections from Rust (\(legacy.count) legacy: "
                + "\(legacy.sorted().joined(separator: ", ")))"
                + (dropped.isEmpty ? "" : "; dropped, not in Rust's table: \(dropped.joined(separator: ", "))"),
            category: "layout")
    }
}

// MARK: - The router

/// What selecting a row does to the tree, and what the tree moving does to
/// the selection — the outline's whole behaviour, out of the view so a test
/// can drive it against a real `SharedLayout` (and so it holds no SwiftUI
/// state: everything that must outlive the view is `state`).
@MainActor
struct LayoutOutlineRouter {

    let controller: LayoutController
    /// The outline pane's own tile — where focus goes when a row is clicked.
    let tile: UInt64
    let shell: AppShellConfiguration
    let dismissedLibraryID: UUID?
    let state: LayoutOutlinePaneState

    // MARK: The panes Rust answers about

    /// The spec JSON of the pane carrying `role`, or "" — which Rust reads as
    /// "no such pane" — with a log line saying which, and why (PH-L7: an
    /// empty spec used to be passed silently).
    func specJSON(role: String) -> String {
        let controller = controller
        guard let tile = controller.paneWithRole(role) else {
            logInfo("outline: no pane carries role '\(role)' — asking Rust without one", category: "layout")
            return ""
        }
        guard let pane = controller.pane(tile) else {
            logWarning(
                "outline: pane \(tile) ('\(role)') did not resolve — asking Rust without it", category: "layout")
            return ""
        }
        return pane.specJson
    }

    /// The list pane's spec as the tree holds it now (the decoded mirror; no
    /// FFI call), for noticing that someone else moved it.
    var currentListSpec: LayoutPaneSpec? {
        guard let tree = controller.tree, let tile = tree.paneWithRole("list") else { return nil }
        return tree.pane(tile)
    }

    /// Rust's answer for one row: the target and the verbs.
    func answer(
        for tab: ImbibTab, listSpec: String, detailSpec: String, initial: Bool
    ) throws -> (nodeJSON: String, answer: [String: LayoutJSONValue]) {
        let (node, bindings) = LayoutOutlineNode.node(
            for: tab, shell: shell, dismissedLibraryID: dismissedLibraryID)
        let nodeJSON = try node.jsonString()
        let bindingsJSON = try LayoutJSONValue.object(bindings.mapValues { .string($0) }).jsonString()
        let raw = try outlineRowVerbsJson(
            appId: controller.appID, nodeJson: nodeJSON, bindingsJson: bindingsJSON,
            listSpecJson: listSpec, detailSpecJson: detailSpec, initial: initial)
        guard let object = try LayoutJSONValue.decode(raw).objectValue else {
            throw SharedLayoutError.Json(message: "outline answer is not an object: \(raw)")
        }
        return (nodeJSON, object)
    }

    // MARK: Routing

    func route(_ tab: ImbibTab?, initial: Bool) {
        guard let tab else {
            // The sidebar selected nothing — deleting the selected collection
            // does exactly this (`deleteFolder` / `deleteCollection` set the
            // selection to nil).
            clearSelection(because: "the sidebar's selection went to nil")
            return
        }
        if state.routedTab == tab { return }

        let controller = controller
        let nodeJSON: String
        let answer: [String: LayoutJSONValue]
        do {
            (nodeJSON, answer) = try self.answer(
                for: tab, listSpec: specJSON(role: "list"), detailSpec: specJSON(role: "detail"),
                initial: initial)
        } catch {
            // Nothing applied and the dedupe not set: clicking the row again
            // asks again.
            logWarning("outline: no answer for \(tab): \(error) — nothing applied", category: "layout")
            return
        }

        let target = answer["target"]?.objectValue ?? [:]
        let kind = target["target"]?.stringValue ?? "?"
        let verbs = answer["verbs"]?.arrayValue ?? []
        // 1. MUTATION — what the row asked for and what Rust made of it.
        logInfo(
            "outline select\(initial ? " (launch)" : ""): \(nodeJSON) → \(kind), \(verbs.count) verb(s)"
                + (answer["applies"]?.boolValue == false
                    ? " — not applied: the list is not on the preset's query" : ""),
            category: "layout")
        if kind == "legacy" {
            // The remaining materialization work, recorded where it happens.
            let section = target["section"]?.stringValue ?? "(no section)"
            let reason = target["reason"]?.stringValue ?? ""
            logInfo("outline: '\(section)' opens a scoped legacy pane — \(reason)", category: "layout")
        } else if kind == "inert", let reason = target["reason"]?.stringValue {
            logInfo("outline: row navigates nowhere — \(reason)", category: "layout")
        }
        // Which feed form the list pane hosts, before the verbs make it
        // render (PH-M1; see `LayoutFeedFormRoutes`).
        let listTile = controller.paneWithRole("list")
        if let listTile, !(initial && answer["applies"]?.boolValue == false) {
            LayoutFeedFormRoutes.shared.record(tab, into: listTile, of: controller)
        }
        guard !verbs.isEmpty else {
            state.routedTab = tab
            state.lastListSpec = currentListSpec
            return
        }

        // Selecting IS clicking: focus follows the pane the user acted in
        // (the same rule `PaneContext.select` applies to a list row). Not at
        // launch — nobody clicked.
        if !initial, controller.focused != tile {
            controller.apply(.focus(target: .id(tile)))
        }
        guard applyAtomically(verbs, for: "\(tab)") else {
            if let listTile { LayoutFeedFormRoutes.shared.record(state.routedTab, into: listTile, of: controller) }
            state.lastListSpec = currentListSpec
            return
        }
        // Every verb applied: only now is this row the routed one.
        state.routedTab = tab
        state.lastListSpec = currentListSpec
    }

    /// Apply a click's verbs as one unit: all of them, or — when one is
    /// refused — none, by undoing the ones that did apply (PH-M2).
    @discardableResult
    func applyAtomically(_ verbs: [LayoutJSONValue], for label: String) -> Bool {
        // The exploration ring each applied verb landed on, for a rollback.
        var appliedRings: [UInt64] = []
        for (index, verb) in verbs.enumerated() {
            let ring = explorationRing(of: verb)
            do {
                let applied = try controller.applyVerbJSON(verb.jsonString(), actor: LayoutController.guiActor)
                if let ring { appliedRings.append(ring) }
                // 2. SAVE — what Rust did with it.
                logInfo(
                    "outline applied: \(verb.objectValue?["verb"]?.stringValue ?? "?") → version "
                        + "\(applied.version), \(applied.affectedPanes.count) affected",
                    category: "layout")
            } catch {
                logWarning(
                    "outline verb \(index + 1) of \(verbs.count) refused: "
                        + "\((try? verb.jsonString()) ?? "?") — \(error)",
                    category: "layout")
                rollBack(appliedRings, of: verbs.count, for: label)
                return false
            }
        }
        return true
    }

    /// The tile whose exploration ring a verb is recorded on — its target
    /// (`impress_layout::stack_for`: every verb the outline emits is an
    /// exploration verb on the pane it targets). Resolved BEFORE the verb
    /// runs, as Rust does.
    func explorationRing(of verb: LayoutJSONValue) -> UInt64? {
        guard let target = verb["target"] else { return nil }
        switch target["ref"]?.stringValue {
        case "id": return target["tile"]?.intValue.map(UInt64.init)
        case "role": return target["role"]?.stringValue.flatMap { controller.paneWithRole($0) }
        default: return nil
        }
    }

    /// Undo, newest first, the verbs of a click that did apply before one
    /// was refused — so the tree is back where the click found it.
    func rollBack(_ rings: [UInt64], of total: Int, for tab: String) {
        guard !rings.isEmpty else {
            logInfo("outline: \(tab) refused before any verb applied — nothing to roll back", category: "layout")
            return
        }
        var undone = 0
        for ring in rings.reversed() where controller.apply(.undo(stack: .exploration, pane: ring)) {
            undone += 1
        }
        if undone == rings.count {
            logInfo(
                "outline: \(tab) rolled back — \(undone) of \(total) verb(s) had applied, all undone",
                category: "layout")
        } else {
            logWarning(
                "outline: \(tab) left HALF-ROUTED — \(rings.count) of \(total) verb(s) applied, "
                    + "only \(undone) undone", category: "layout")
        }
    }

    // MARK: Following the list (PH-H5)

    func listMayHaveMoved(at version: UInt64) {
        guard let spec = currentListSpec, spec != state.lastListSpec else { return }
        guard state.lastListSpec != nil else {
            // Not yet routed or reconciled: the launch pass records it.
            return
        }
        reconcile(because: "the list moved at version \(version), not by this outline")
    }

    /// Make the sidebar show the row the list pane is on, or no row.
    func reconcile(because why: String) {
        let controller = controller
        state.lastListSpec = currentListSpec
        guard let listTile = controller.paneWithRole("list") else { return }
        let listSpec = specJSON(role: "list")
        let detailSpec = specJSON(role: "detail")
        let current = state.viewModel.selectedTab

        func isTheList(_ tab: ImbibTab) -> Bool {
            guard let reply = try? answer(
                for: tab, listSpec: listSpec, detailSpec: detailSpec, initial: false)
            else { return false }
            let kind = reply.answer["target"]?["target"]?.stringValue
            guard kind == "query" || kind == "legacy" else { return false }
            // The row IS the list's query when Rust would not touch the list
            // pane to show it (a `select` on the navigator's channel, or a
            // detail re-point, may still be due).
            return (reply.answer["verbs"]?.arrayValue ?? []).allSatisfy { verb in
                explorationRing(of: verb) != listTile
            }
        }

        if let current, isTheList(current) {
            state.routedTab = current
            logInfo("outline: \(why) — in step, still on \(current)", category: "layout")
            return
        }
        let candidates = candidateTabs(listTile: listTile).filter { $0 != current }
        if let found = candidates.first(where: isTheList) {
            state.routedTab = found
            if current != found { state.echo = .some(found) }
            state.viewModel.navigateToTab(found)
            logInfo(
                "outline: \(why) — follows the list to \(found) (was \(current.map { "\($0)" } ?? "none"))",
                category: "layout")
        } else {
            state.routedTab = nil
            if current != nil {
                state.echo = .some(nil)
                state.viewModel.selectedNodeID = nil
            }
            logInfo(
                "outline: \(why) — no row here is the list's query (checked \(candidates.count + 1)); "
                    + "deselected \(current.map { "\($0)" } ?? "nothing"), one click on any row routes",
                category: "layout")
        }
    }

    /// Rows that could be the list's query: the ids its query and bindings
    /// name, the section rows, and its tag / flag filters. Rust decides
    /// which one (if any) it is; this only proposes.
    func candidateTabs(listTile: UInt64) -> [ImbibTab] {
        var tabs: [ImbibTab] = []
        let spec = controller.tree?.pane(listTile)
        var ids: [UUID] = []
        let queryText = (try? spec?.query.jsonString()) ?? ""
        let bindingsText = controller.pane(listTile)?.bindingsJson ?? ""
        for text in [queryText, bindingsText] {
            for match in text.matches(of: #/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/#) {
                if let id = UUID(uuidString: String(match.output)), !ids.contains(id) { ids.append(id) }
            }
        }
        for id in ids {
            tabs.append(contentsOf: [.library(id), .collection(id), .libraryFeed(id), .inboxFeed(id), .exploration(id)])
        }
        tabs.append(contentsOf: [.inbox, .dismissed, .allArtifacts, .citedInManuscripts, .reviewQueue, .recent])
        for filter in spec?.query["filters"]?.arrayValue ?? [] {
            switch filter["filter"]?.stringValue {
            case "tag": if let path = filter["path"]?.stringValue { tabs.append(.tag(path: path)) }
            case "flag": tabs.append(.flagged(filter["color"]?.stringValue))
            default: break
            }
        }
        for kind in spec?.queryKinds ?? [] {
            tabs.append(.record(.all(RecordKindID(kind))))
        }
        return tabs
    }

    /// The routed row is gone. What the tree does about it is Rust's
    /// (`outline_cleared_verbs`): the chassis' own "No Selection" — the
    /// navigator's channel stops carrying the dead row, the detail pane
    /// empties, and no other row is selected on the user's behalf (the
    /// chassis never falls back to a parent). The list pane keeps its query,
    /// which names a row that no longer exists and so lists nothing.
    func clearSelection(because why: String) {
        guard let gone = state.routedTab else { return }
        state.routedTab = nil

        let controller = controller
        let (node, _) = LayoutOutlineNode.node(
            for: gone, shell: shell, dismissedLibraryID: dismissedLibraryID)
        let listSpec = specJSON(role: "list")
        let detailSpec = specJSON(role: "detail")
        let nodeJSON: String
        let verbs: [LayoutJSONValue]
        do {
            nodeJSON = try node.jsonString()
            let raw = try outlineClearedVerbsJson(
                nodeJson: nodeJSON, listSpecJson: listSpec, detailSpecJson: detailSpec)
            verbs = try LayoutJSONValue.decode(raw).objectValue?["verbs"]?.arrayValue ?? []
        } catch {
            logWarning("outline: no answer for the cleared selection \(gone): \(error)", category: "layout")
            return
        }
        // 1. MUTATION — which row went away, and what Rust made of it.
        logInfo(
            "outline cleared: \(nodeJSON) — \(why) → \(verbs.count) verb(s), no row selected",
            category: "layout")
        for verb in verbs {
            do {
                let applied = try controller.applyVerbJSON(verb.jsonString(), actor: LayoutController.guiActor)
                // 2. SAVE
                logInfo(
                    "outline applied: \(verb.objectValue?["verb"]?.stringValue ?? "?") → version "
                        + "\(applied.version), \(applied.affectedPanes.count) affected",
                    category: "layout")
            } catch {
                logWarning("outline verb refused: \((try? verb.jsonString()) ?? "?") — \(error)", category: "layout")
                break
            }
        }
        state.lastListSpec = currentListSpec
    }
}

// MARK: - The scoped legacy pane

/// ONE section's route inside a pane (ADR-0031 D11's per-route legacy host).
///
/// The pane's `view_state` names the section, the outline node and the
/// reason the route is not a query yet (`outline.rs`, `OutlineTarget::Legacy`).
/// This view builds a sidebar view model for that one route and renders
/// `SectionContentView` over it — the chassis' own route view, not a copy of
/// it — so a SciX library or a search form shows exactly as it does in the
/// flag-off build, and nothing else of the chassis comes with it. A caption
/// at the top says why the route is hosted rather than queried, because this
/// is the materialization work that remains and it should not be invisible.
@MainActor
struct LayoutScopedLegacyPaneView: View {

    let context: PaneContext
    let section: String?
    let node: LayoutJSONValue
    let reason: String?

    @State private var viewModel = ImbibSidebarViewModel()
    @State private var configured = false

    @Environment(\.appShellConfiguration) private var shell
    @Environment(\.sidebarComposition) private var sidebarComposition
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(\.layoutToolbarBand) private var toolbarBand

    /// The node's route — or, for the lossy `feed-form` node, the exact
    /// form the outline routed here (PH-M1, `LayoutFeedFormRoutes`).
    private var tab: ImbibTab? {
        LayoutFeedFormRoutes.shared.resolved(
            LayoutOutlineNode.tab(from: node), tile: context.tile, controller: context.controller)
    }

    var body: some View {
        VStack(spacing: 0) {
            caption
            Divider()
            content
        }
        .padding(.top, toolbarBand)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Keyed on the resolved TAB, not the node: two Edit Feed… clicks are
        // one node and two forms.
        .onAppear { show() }
        .onChange(of: tab) { _, _ in show() }
    }

    @ViewBuilder
    private var content: some View {
        if tab == nil {
            ChassisEmptyState(
                id: "legacy-route-unknown",
                title: "Nothing to Show",
                systemImage: "sidebar.left",
                message: "Choose a row under \u{201C}\(section ?? "this section")\u{201D} in the outline."
            )
            .view
        } else if configured {
            SectionContentView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ChassisRootLoadingView()
        }
    }

    private var caption: some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            Text("\(section ?? "route") — hosted, not yet a query")
                .font(.caption.weight(.medium))
            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func show() {
        guard let tab else {
            logInfo("pane \(context.tile) legacy: no route for node, section \(section ?? "nil")", category: "layout")
            return
        }
        if !configured {
            viewModel.shellConfiguration = shell
            viewModel.sidebarComposition = sidebarComposition
            viewModel.configure(
                libraryManager: libraryManager,
                libraryViewModel: libraryViewModel,
                searchViewModel: searchViewModel)
            configured = true
        }
        // `configure` lands on the shell's default section; the pane's route
        // is what the tree says, so it is set after.
        viewModel.selectedTab = tab
        // 3. DISPLAY — the pane rendered this one route, not the chassis.
        logInfo(
            "pane \(context.tile) legacy: section \(section ?? "nil") route \(tab) (scoped, not the whole chassis)",
            category: "layout")
    }
}
#endif
