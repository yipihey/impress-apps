#if os(macOS)
// Chassis file — macOS-only. Plan wave 6, W4 pass B.
//
//  LayoutManuscriptPreviewPaneView.swift
//  PublicationManagerCore
//
//  The `pdf` view kind over MANUSCRIPTS: the manuscript's compiled preview,
//  the view the detail pane's Preview tab shows (`ManuscriptPreviewContent`).
//
//  imprint's Writing preset puts a `pdf` pane beside the `source` pane on the
//  same `$item`; pass A answered it with "Detail Unavailable" because `pdf`
//  was only ever a publication tab. The preview is the manuscript's
//  `ManuscriptEditorSession` compile, so both panes read ONE session from
//  `ManuscriptSessionRegistry`: typing in the source pane recompiles what this
//  pane shows. A manuscript with `external_source` gets no session anywhere
//  (ADR-0023 D4), so there is nothing compiled to show and the pane says so.
//

import ImpressLogging
import SwiftUI

@MainActor
struct LayoutManuscriptPreviewPaneView: View {

    let context: PaneContext

    @Environment(\.layoutToolbarBand) private var toolbarBand

    @State private var session: ManuscriptEditorSession?
    @State private var isExternal = false

    private var manuscriptID: UUID? {
        (context.singleItem ?? context.bindings["item"]).flatMap(UUID.init(uuidString:))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { resolve() }
            .onChange(of: manuscriptID) { _, _ in resolve() }
            .manuscriptLiveness(session, manuscriptID: manuscriptID)
    }

    @ViewBuilder
    private var content: some View {
        if manuscriptID == nil {
            ChassisEmptyState.noRowSelection(kind: .manuscript).view
        } else if isExternal {
            ChassisEmptyState(
                id: "preview-external",
                title: "No Preview",
                systemImage: "lock.doc",
                message: "This manuscript indexes a file you edit elsewhere; it is not "
                    + "compiled here."
            )
            .view
        } else {
            ManuscriptPreviewContent(session: session, onShowSource: showSource)
                .padding(.top, toolbarBand)
        }
    }

    private func resolve() {
        guard let id = manuscriptID else {
            session = nil
            isExternal = false
            return
        }
        isExternal = !RustStoreAdapter.shared.manuscriptAllowsEditorSession(id: id)
        session = isExternal ? nil : ManuscriptSessionRegistry.shared.session(for: id)
        logInfo(
            "pane \(context.tile) pdf: manuscript \(id.uuidString) preview"
                + (isExternal ? " — external_source, not compiled" : "")
                + (session?.vm.pdfData == nil ? "" : " (compiled)"),
            category: "layout")
    }

    /// Focus the pane that edits this manuscript: a `source` pane on the same
    /// channel — the one that follows the same selection — the detail role
    /// first. (It ignored channels, so with two channels it could focus an
    /// editor showing another manuscript; review PH-L3.)
    private func showSource() {
        guard let tree = context.controller.tree else { return }
        let sources = LayoutPaneViewState.panes(showing: .source, onChannelOf: context.tile, in: tree)
        let detail = sources.first { tree.pane($0)?.role == "detail" }
        guard let target = detail ?? sources.first else {
            logInfo(
                "pane \(context.tile) pdf: Show Source — no source pane on this pane's channel",
                category: "layout")
            return
        }
        context.controller.apply(.focus(target: .id(target)))
    }
}
#endif
