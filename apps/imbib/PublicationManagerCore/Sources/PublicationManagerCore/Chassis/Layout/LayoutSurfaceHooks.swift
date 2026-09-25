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
/// The decoder understands the xs/ys `series` shape, which is what
/// `impress-surface`'s signal-explorer golden carries today. It does NOT
/// decode a `bars` shape; a spec that only has one fails here with that
/// reason, rather than as an unexplained placeholder.
///
/// Returns the SVG, or why there is none — which the pane shows and logs
/// (review PH-L4: `rendered.error` used to be dropped).
private func renderedSVG(fromSpecJSON specJSON: String) -> Result<String, PlotRenderFailure> {
    guard let data = specJSON.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .failure(PlotRenderFailure(reason: "the plot spec is not a JSON object")) }
    guard let spec = PlotAutomationHandler.decodeSpec(object) else {
        let keys = object.keys.sorted().joined(separator: ", ")
        return .failure(PlotRenderFailure(
            reason: "the plot spec did not decode (needs a non-empty `series` of xs/ys; has: \(keys))"))
    }
    let rendered = renderPlotSvg(spec: spec)
    if let error = rendered.error {
        return .failure(PlotRenderFailure(reason: "renderPlotSvg failed: \(error)"))
    }
    guard !rendered.svg.isEmpty else {
        return .failure(PlotRenderFailure(reason: "renderPlotSvg returned an empty SVG"))
    }
    return .success(rendered.svg)
}

private struct PlotRenderFailure: Error, Equatable {
    let reason: String
}

// MARK: - Plot

/// The `plot` widget: `renderPlotSvg`'s SVG through a `WKWebView`, the SAME
/// technique `PlotInspectorPanel.swift`'s (file-private) `PlotSVGView` uses
/// — that type is not reusable from here (Swift `private` at top level is
/// file-scoped), so this is a second, small copy of the same known-working
/// approach rather than an `NSImage(data:)` decode, which does not reliably
/// rasterize raw SVG text on macOS.
///
/// The render is memoized by the spec it came from, so a pane re-render
/// (every verb re-renders every pane host today) neither re-runs Typst nor
/// logs a failure twice.
private struct SurfacePlotView: View {
    let specJSON: String

    @State private var rendered: (spec: String, result: Result<String, PlotRenderFailure>)?

    private var result: Result<String, PlotRenderFailure> {
        rendered?.spec == specJSON ? rendered!.result : renderedSVG(fromSpecJSON: specJSON)
    }

    var body: some View {
        content
            .onAppear { render() }
            .onChange(of: specJSON) { _, _ in render() }
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .success(let svg):
            SurfacePlotSVGView(svg: svg)
                .frame(minHeight: 180)
        case .failure(let failure):
            VStack(alignment: .leading, spacing: 4) {
                Label("Plot", systemImage: "chart.xyaxis.line")
                Text("This plot could not be rendered: \(failure.reason)")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            .foregroundStyle(.secondary)
            .padding(8)
        }
    }

    private func render() {
        guard rendered?.spec != specJSON else { return }
        let result = renderedSVG(fromSpecJSON: specJSON)
        rendered = (specJSON, result)
        if case .failure(let failure) = result {
            logWarning("surface plot: \(failure.reason)", category: "surface")
        }
    }
}

private struct SurfacePlotSVGView: NSViewRepresentable {
    let svg: String

    /// The SVG the web view last loaded: an update with the same SVG is not
    /// a reload (PH-L4 — it reloaded, and flickered, on every update).
    final class Coordinator {
        var loadedSVG: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")
        web.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedSVG != svg else { return }
        context.coordinator.loadedSVG = svg
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
