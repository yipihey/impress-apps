//
//  SurfaceHooks.swift
//  ImpressSurface
//
//  What the HOST supplies so `SurfaceView` can stay kit-grade (ADR-0033 D7):
//  this package must not depend on MarkdownUI, ImprintRustCore or any
//  domain store, so the three widgets that need real suite machinery —
//  `text` (Markdown), `plot` (a `plot-spec@1.0.0` payload through
//  imprint-core's `render_plot_svg`), and `list` (rows through the host's
//  own row-style registry, per the vocabulary reference in
//  `docs/agent-surfaces.md`) — are closures the host fills in, not imports
//  this package makes itself.
//
//  `.plain` is what a standalone host (or a test) gets for free: Markdown as
//  plain `Text`, a plot as a labelled placeholder, and list rows as an
//  ordinary `List` over each row's `displayText`
//  (`SurfaceJSONValue.displayText` — a `title`/`name`/`label`/`text` key
//  when one exists, else the row stringified). `LayoutSurfacePaneView`
//  (PublicationManagerCore, work package S7) supplies the real one: MarkdownUI
//  for `renderMarkdown`, `renderPlotSvg` for `renderPlot`, and (for now, see
//  that file) a plain list for `renderListRows` too — the row-style registry
//  wire-up is follow-up work, noted there.
//

import SwiftUI
import ImpressLogging

/// Closures the host fills in for the three widgets a kit-grade renderer
/// cannot draw itself. See the file header.
public struct SurfaceHooks {

    /// `text` — the node's already-resolved Markdown string.
    public var renderMarkdown: (String) -> AnyView

    /// `plot` — the node's `spec` field, as `serde_json::to_string`d text
    /// (a `plot-spec@1.0.0` payload; never pixels, per ADR-0033's Defaults).
    public var renderPlot: (_ specJSON: String) -> AnyView

    /// `list` — the node's `rows` field, as JSON text, plus the callback to
    /// fire with the selected row ids (`SurfaceView` turns that into a
    /// `.select` `SurfaceEvent`).
    public var renderListRows: (_ rowsJSON: String, _ onSelect: @escaping ([String]) -> Void) -> AnyView

    /// A one-line trace hook — `LayoutSurfacePaneView` wires this to
    /// `logInfo(_:category: "surface")`'s three-point trace; `.plain` no-ops
    /// it so a test or a standalone host is not forced to have a logger.
    public var log: (String) -> Void

    public init(
        renderMarkdown: @escaping (String) -> AnyView,
        renderPlot: @escaping (_ specJSON: String) -> AnyView,
        renderListRows: @escaping (_ rowsJSON: String, _ onSelect: @escaping ([String]) -> Void) -> AnyView,
        log: @escaping (String) -> Void
    ) {
        self.renderMarkdown = renderMarkdown
        self.renderPlot = renderPlot
        self.renderListRows = renderListRows
        self.log = log
    }

    /// The kit-grade default: no suite machinery, just SwiftUI.
    public static let plain = SurfaceHooks(
        renderMarkdown: { text in
            AnyView(Text(text))
        },
        renderPlot: { _ in
            AnyView(
                Label("Plot", systemImage: "chart.xyaxis.line")
                    .foregroundStyle(.secondary)
                    .padding(8)
            )
        },
        renderListRows: { rowsJSON, onSelect in
            AnyView(PlainSurfaceListRows(rowsJSON: rowsJSON, onSelect: onSelect))
        },
        // `ImpressLogging`'s global convenience — the one place this
        // kit-grade package touches suite logging, and only because a
        // standalone host or a test gets a real trace line for free instead
        // of a silent no-op. `LayoutSurfacePaneView` overrides this with its
        // own three-point trace (mutation / save / display, category
        // "surface") rather than using `.plain`'s.
        log: { message in logInfo(message, category: "surface") }
    )
}

/// The `.plain` hooks' `list` rendering: one line per row, via
/// `SurfaceJSONValue.displayText`. A real host's row style (imbib's
/// `RecordViewerRegistry`, per `docs/agent-surfaces.md`'s vocabulary
/// reference) is a follow-up, not this package's job.
private struct PlainSurfaceListRows: View {
    let rowsJSON: String
    let onSelect: ([String]) -> Void

    @State private var selection = Set<String>()

    var body: some View {
        List(rows, selection: $selection) { row in
            Text(row.text)
        }
        .onChange(of: selection) { _, newValue in
            onSelect(Array(newValue).sorted())
        }
    }

    private var rows: [PlainSurfaceListRow] {
        guard let value = try? SurfaceJSONValue.decode(rowsJSON),
            let array = value.arrayValue
        else { return [] }
        return array.enumerated().map { index, item in
            let id = item.objectValue?["id"]?.stringValue ?? String(index)
            return PlainSurfaceListRow(id: id, text: item.displayText)
        }
    }
}

private struct PlainSurfaceListRow: Identifiable, Hashable {
    let id: String
    let text: String
}
