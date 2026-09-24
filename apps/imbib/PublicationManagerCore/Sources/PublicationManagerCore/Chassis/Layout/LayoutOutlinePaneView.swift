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
//  ## The launch selection
//
//  The view model selects its default section by itself when it is
//  configured. That is not a user's choice, so it retargets the list only
//  when Rust says the list is still on the preset's own query
//  (`initial_selection_applies`) — a layout restored at launch with the list
//  on a collection stays on that collection.
//

import Foundation
import ImpressLogging
import ImpressRustCore
import SwiftUI

@MainActor
struct LayoutOutlinePaneView: View {

    let context: PaneContext

    @State private var viewModel = ImbibSidebarViewModel()
    /// The tab the last routing acted on — a dedupe, not a selection: the
    /// selection lives in the view model (the sidebar's own) and the tree.
    @State private var routedTab: ImbibTab?

    @Environment(\.appShellConfiguration) private var shell
    @Environment(LibraryManager.self) private var libraryManager

    var body: some View {
        ImbibSidebarColumn(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(
                ImbibSidebarLifecycle(
                    viewModel: viewModel,
                    prepare: { model in applySectionFilter(to: model) },
                    configured: { model in route(model.selectedTab, initial: true) }))
            .onChange(of: viewModel.selectedTab) { _, tab in
                route(tab, initial: false)
            }
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

    // MARK: Routing

    private func route(_ tab: ImbibTab?, initial: Bool) {
        guard let tab else { return }
        if routedTab == tab { return }
        routedTab = tab

        let controller = context.controller
        let (node, bindings) = LayoutOutlineNode.node(
            for: tab, shell: shell, dismissedLibraryID: libraryManager.dismissedLibrary?.id)
        let listSpec = controller.paneWithRole("list").flatMap { controller.pane($0)?.specJson } ?? ""
        let detailSpec =
            controller.paneWithRole("detail").flatMap { controller.pane($0)?.specJson } ?? ""

        let nodeJSON: String
        let answer: [String: LayoutJSONValue]
        do {
            nodeJSON = try node.jsonString()
            let bindingsJSON = try LayoutJSONValue.object(bindings.mapValues { .string($0) }).jsonString()
            let raw = try outlineRowVerbsJson(
                appId: controller.appID, nodeJson: nodeJSON, bindingsJson: bindingsJSON,
                listSpecJson: listSpec, detailSpecJson: detailSpec, initial: initial)
            guard let object = try LayoutJSONValue.decode(raw).objectValue else {
                throw SharedLayoutError.Json(message: "outline answer is not an object: \(raw)")
            }
            answer = object
        } catch {
            logWarning("outline: no answer for \(tab): \(error)", category: "layout")
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
        guard !verbs.isEmpty else { return }

        // Selecting IS clicking: focus follows the pane the user acted in
        // (the same rule `PaneContext.select` applies to a list row). Not at
        // launch — nobody clicked.
        if !initial, controller.focused != context.tile {
            controller.apply(.focus(target: .id(context.tile)))
        }
        for verb in verbs {
            do {
                let applied = try controller.applyVerbJSON(verb.jsonString(), actor: LayoutController.guiActor)
                // 2. SAVE — what Rust did with it.
                logInfo(
                    "outline applied: \(verb.objectValue?["verb"]?.stringValue ?? "?") → version "
                        + "\(applied.version), \(applied.affectedPanes.count) affected",
                    category: "layout")
            } catch {
                logWarning("outline verb refused: \((try? verb.jsonString()) ?? "?") — \(error)", category: "layout")
                return
            }
        }
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

    private var tab: ImbibTab? { LayoutOutlineNode.tab(from: node) }

    var body: some View {
        VStack(spacing: 0) {
            caption
            Divider()
            content
        }
        .padding(.top, toolbarBand)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // NOT `.task(id:)`: that closure is `@Sendable` and nonisolated, and
        // configuring a view model is main-actor work (`LayoutRowsPaneView`
        // made the same call for the same reason).
        .onAppear { show() }
        .onChange(of: node) { _, _ in show() }
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
