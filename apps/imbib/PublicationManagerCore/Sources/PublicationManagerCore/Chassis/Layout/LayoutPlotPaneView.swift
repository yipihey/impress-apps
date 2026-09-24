#if os(macOS)
// Chassis file — macOS-only. ADR-0031 D1; plan wave 6 follow-up.
//
//  LayoutPlotPaneView.swift
//  PublicationManagerCore
//
//  The `plot` view kind: a figure's plot, in a pane of its own.
//
//  ## What "a figure's plot" is, and why this is the reuse point
//
//  A `figure` row in the store (`impress-core`'s implore schema: format,
//  title, caption, `data_hash`, `script_hash`, width, height) carries no plot
//  specification. implore draws a figure from its own session and dataset and
//  mirrors the RESULT into the content-addressed store under `data_hash`;
//  that artifact is the figure's plot as every app other than implore can
//  see it. The one view that draws it is `FigureDetailPane`'s View tab, so
//  that body moved verbatim into `FigureArtifactView` and both call it
//  (ADR-0031 D11: map, do not rewrite — W4's `ManuscriptPreviewContent` did
//  the same for the manuscript Preview tab).
//
//  The other candidates were not the figure's plot: `renderPlotSvg` and the
//  surface kit's plot views render a `plot-spec@1.0.0` document, which no
//  figure references; implore's canvas renders from implore-core, which
//  PublicationManagerCore does not link.
//
//  ## Resolution
//
//  Like `info`: `single_item`, else the `item` binding. A pane whose query
//  names another kind, or an id that is some other record, gets a named
//  empty state — never the placeholder, never a blank.
//

import Foundation
import ImpressLayout
import ImpressLogging
import ImpressRustCore
import SwiftUI

/// What a `plot` pane should draw, decided from the pane alone. Pure, so the
/// dispatch is testable without a store, a view or the FFI.
enum LayoutPlotTarget: Equatable {
    /// Nothing bound yet: the "select a figure" state.
    case noSelection
    /// The pane's query is over another kind; a plot pane draws figures.
    case wrongKind(String)
    /// The bound value is not an id at all.
    case notAnID(String)
    /// A figure id to look up.
    case figure(UUID)

    /// The pane's first query kind and the id it resolved (`single_item`,
    /// else the `item` binding). A pane with NO kinds (an `item(id)` pane
    /// over anything) is allowed through: the store row decides.
    init(primaryKind: String?, rawItem: String?) {
        if let kind = primaryKind, kind != RecordKindID.figure.rawValue {
            self = .wrongKind(kind)
        } else if let raw = rawItem {
            self = UUID(uuidString: raw).map(Self.figure) ?? .notAnID(raw)
        } else {
            self = .noSelection
        }
    }
}

/// The `plot` view kind: `FigureArtifactView` for the figure the pane
/// resolves, under the toolbar band the tree measured for it.
@MainActor
struct LayoutPlotPaneView: View {

    let context: PaneContext

    /// The figure as last read — derived data, re-read on selection and on
    /// a store event for it (as `FigureDetailPane` does). `nil` with
    /// `schemaRef` set means the id is a record of another kind.
    @State private var row: FigureRowData?
    @State private var otherSchemaRef: String?
    @State private var loadedID: UUID?

    @Environment(\.layoutToolbarBand) private var toolbarBand

    private var target: LayoutPlotTarget {
        LayoutPlotTarget(
            primaryKind: context.primaryKind,
            rawItem: context.singleItem ?? context.bindings["item"])
    }

    var body: some View {
        content
            .padding(.top, toolbarBand)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: target, initial: true) { _, target in load(target) }
            .task(id: loadedID) {
                // Refresh when this figure mutates elsewhere (implore
                // re-exporting its artifact), as `FigureDetailPane` does.
                guard let id = loadedID else { return }
                for await event in ImbibImpressStore.shared.events.subscribe() {
                    if case .itemsMutated(_, let ids) = event, ids.contains(id) {
                        load(target)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch target {
        case .noSelection:
            ChassisEmptyState.noRowSelection(kind: .figure).view
        case .wrongKind(let kind):
            unavailable(
                "This pane lists \u{201C}\(kind)\u{201D}. A plot pane draws a figure's plot.")
        case .notAnID(let raw):
            unavailable("\u{201C}\(raw)\u{201D} is not a figure id.")
        case .figure(let id):
            if let row, loadedID == id {
                FigureArtifactView(dataHash: row.dataHash)
            } else if let schema = otherSchemaRef, loadedID == id {
                unavailable(
                    "\u{201C}\(id.uuidString)\u{201D} is a \u{201C}\(schema)\u{201D}, not a figure.")
            } else {
                unavailable("No figure \u{201C}\(id.uuidString)\u{201D} in the store.")
            }
        }
    }

    private func load(_ target: LayoutPlotTarget) {
        guard case .figure(let id) = target else {
            row = nil
            otherSchemaRef = nil
            loadedID = nil
            return
        }
        let figure = FigureStoreReader.shared.fetchFigure(id: id.uuidString)
            .flatMap { FigureRowData(from: $0) }
        row = figure
        // Not a figure: say what it IS, from the store the layout was opened
        // on (the kit's handle, so no second store is opened for this).
        var other: String?
        if figure == nil, let store = context.controller.store,
            let item = try? store.getItem(id: id.uuidString.lowercased())
        {
            other = item.schemaRef
        }
        otherSchemaRef = other
        loadedID = id
        // The pane is otherwise invisible from outside the window: a plot
        // and a "no renderable artifact" hint occupy the same pixels. This
        // line is what `?category=layout` reads, like `pane N info:`.
        if let figure {
            logInfo(
                "pane \(context.tile) plot: figure \(id.uuidString)"
                    + (figure.dataHash == nil ? " (no rendered artifact)" : ""),
                category: "layout")
        } else if let schema = otherSchemaRef {
            logInfo(
                "pane \(context.tile) plot: \(schema) \(id.uuidString) is not a figure",
                category: "layout")
        } else {
            logInfo("pane \(context.tile) plot: no figure \(id.uuidString)", category: "layout")
        }
    }

    /// Named, never blank: what the pane was asked for and why it cannot
    /// draw it (the `info` pane's "Detail Unavailable" rule).
    private func unavailable(_ message: String) -> some View {
        ChassisEmptyState(
            id: "plot-unavailable",
            title: "Plot Unavailable",
            systemImage: "chart.xyaxis.line",
            message: message
        )
        .view
    }
}
#endif
