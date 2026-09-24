#if os(macOS)
// Chassis file — macOS-only. ADR-0033 S7; plan wave 6, W6.
//
//  LayoutSurfaceHooks.swift
//  PublicationManagerCore
//
//  The suite-aware `SurfaceHooks` a `surface` pane renders with in a chassis
//  window. `LayoutSurfacePaneView` moved to `packages/ImpressLayout` (W6)
//  and takes its hooks as an argument; what needs PublicationManagerCore —
//  MarkdownUI for `text`, imprint-core's `renderPlotSvg` for `plot`, the
//  chassis' row registry for `list` (`SurfaceRecordListRows`) — stayed here,
//  moved verbatim out of that file, and `ChassisViewKinds` registers
//  `surface` with `.chassis`.
//

import AppKit
import Foundation
import ImpressLayout
import ImpressLogging
import ImpressSurface
import ImprintCore
import MarkdownUI
import SwiftUI
import WebKit

public extension SurfaceHooks {

    /// MarkdownUI for `text`, `renderPlotSvg` for `plot`, and for `list` the
    /// row-style registry through `SurfaceRecordListRows`: a row that carries
    /// a schema the kind manifest claims (every row a `query` source returns
    /// does) is the chassis' own row, and a list of anything else keeps the
    /// kit-grade plain line.
    static let chassis = SurfaceHooks(
        renderMarkdown: { text in AnyView(Markdown(text)) },
        renderPlot: { specJSON in AnyView(SurfacePlotView(specJSON: specJSON)) },
        renderListRows: { rowsJSON, onSelect in
            AnyView(SurfaceRecordListRows(rowsJSON: rowsJSON, onSelect: onSelect))
        },
        log: { message in logInfo(message, category: "surface") }
    )
}

/// Decodes a `plot-spec@1.0.0` payload the SAME way
/// `PlotAutomationHandler` already does for `POST /api/plot/render`
/// (`PlotAutomationHandler.decodeSpec`), then renders it through
/// `renderPlotSvg` — imprint-core's real Typst-backed SVG renderer, the
/// one every plot in the suite goes through.
///
/// KNOWN GAP, flagged for the Mac pass / follow-up:
/// `PlotAutomationHandler.decodeSpec` only understands the xs/ys
/// `series` shape. `impress-plot`'s `plot-spec@1.0.0` ALSO has a `bars`
/// shape — the S9 demo's histogram
/// (`crates/impress-surface/tests/golden/signal-explorer.render.json`
/// carries `{"kind": "plot-spec@1.0.0", "bars": [1, 2, 1]}`) — which this
/// decoder returns `nil` for today, so that surface's plot falls through
/// to `SurfacePlotView`'s "could not render" placeholder rather than a
/// real chart. Fixing it is either a `bars`→`series` shim here or a
/// second decode path in `PlotAutomationHandler`; out of scope for S7
/// itself, which only wires the ONE decode path that already exists.
private func renderedSVG(fromSpecJSON specJSON: String) -> String? {
    guard let data = specJSON.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let spec = PlotAutomationHandler.decodeSpec(object)
    else { return nil }
    let rendered = renderPlotSvg(spec: spec)
    guard rendered.error == nil, !rendered.svg.isEmpty else { return nil }
    return rendered.svg
}

// MARK: - Plot

/// The `plot` widget: `renderPlotSvg`'s SVG through a `WKWebView`, the SAME
/// technique `PlotInspectorPanel.swift`'s (file-private) `PlotSVGView` uses
/// — that type is not reusable from here (Swift `private` at top level is
/// file-scoped), so this is a second, small copy of the same known-working
/// approach rather than an `NSImage(data:)` decode, which does not reliably
/// rasterize raw SVG text on macOS.
private struct SurfacePlotView: View {
    let specJSON: String

    var body: some View {
        if let svg = renderedSVG(fromSpecJSON: specJSON) {
            SurfacePlotSVGView(svg: svg)
                .frame(minHeight: 180)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("Plot", systemImage: "chart.xyaxis.line")
                Text("This build could not render the plot spec.")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(8)
        }
    }
}

private struct SurfacePlotSVGView: NSViewRepresentable {
    let svg: String

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")
        web.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>html,body{margin:0;height:100%;background:transparent}
            .wrap{height:100%;display:flex;align-items:center;justify-content:center;padding:6px;box-sizing:border-box}
            svg{max-width:100%;max-height:100%;height:auto;width:auto}</style></head>
            <body><div class="wrap">\(svg)</div></body></html>
            """
        web.loadHTMLString(html, baseURL: nil)
    }
}
#endif
