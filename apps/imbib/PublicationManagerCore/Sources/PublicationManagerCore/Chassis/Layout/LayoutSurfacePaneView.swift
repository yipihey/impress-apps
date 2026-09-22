#if os(macOS)
// Chassis file — macOS-only, like every other file in this folder.
// ADR-0033 work package S7.
//
//  LayoutSurfacePaneView.swift
//  PublicationManagerCore
//
//  The `surface` view kind: an agent-authored `impress/ui/surface@1.0.0`
//  document, rendered by `packages/ImpressSurface`'s `SurfaceView`, hosted
//  the same way `LayoutInfoPaneView` hosts the publication detail pane —
//  the pane's `item` parameter (`context.singleItem` / `context.bindings
//  ["item"]`) names WHICH stored surface this pane shows.
//
//  ## What this file owns vs. what `ImpressSurface` owns
//
//  `ImpressSurface` is kit-grade (ADR-0033 D7): it maps a `RenderTree` to
//  SwiftUI and holds no logic. Everything that needs real suite machinery —
//  opening `SharedSurface` on the app's store, decoding a
//  `SurfaceDispatchResult`, turning a `plot-spec@1.0.0` payload into pixels
//  through `renderPlotSvg`, rendering `text` through MarkdownUI, publishing
//  a `select` event on the pane's own channel — lives HERE, wired in through
//  `SurfaceHooks` and the `onEvent` closure `SurfaceView` calls.
//
//  ## Session shape
//
//  A surface pane is NOT session-bearing (`ViewKindFactory.isSessionBearing`
//  stays `false`, unlike `.source`): a `SharedSurface` handle holds no
//  buffer of its own, only a reference to the store, so there is nothing an
//  `.id(tile)` on this host would lose by being recreated. One handle is
//  still opened once per pane instance (not per render) and kept in a
//  small `@Observable` model, so the invalidation subscription is not
//  torn down and rebuilt on every keystroke a WIDGET makes — only when the
//  pane's surface id itself changes.
//
//  ## Three-point trace
//
//  `SurfacePaneModel.render`/`.dispatch` log the REQUEST, the RESULT Rust
//  returned, and the tree the renderer then displays (category "surface"),
//  the same discipline `LayoutController` uses for the tree itself:
//  `curl 'http://localhost:23120/api/logs?category=surface&limit=50'`.
//

import AppKit
import Foundation
import ImpressLogging
import ImpressRustCore
import ImpressSurface
import ImprintCore
import MarkdownUI
import Observation
import SwiftUI
import WebKit

// MARK: - The view kind

/// The `surface` view kind: see the file header.
@MainActor
struct LayoutSurfacePaneView: View {

    let context: PaneContext

    @State private var model: SurfacePaneModel?

    /// What the pane's `item` parameter resolved to — the SAME two-source
    /// read `LayoutInfoPaneView.itemID` uses, minus the UUID parse (a
    /// surface id is a store item id, not necessarily one this build ever
    /// turns into a `UUID`).
    private var surfaceID: String? {
        context.singleItem ?? context.bindings["item"]
    }

    var body: some View {
        Group {
            if let surfaceID {
                content(surfaceID: surfaceID)
            } else {
                // An unfilled parameter is the empty state, never an error
                // (ADR-0031 D3) — identical to `LayoutInfoPaneView`'s
                // unselected state.
                ChassisEmptyState.noRowSelection(isArtifact: false).view
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: surfaceID) {
            await open(surfaceID: surfaceID)
        }
        .onDisappear {
            model?.stop()
        }
    }

    @ViewBuilder
    private func content(surfaceID: String) -> some View {
        if let model, let tree = model.tree {
            SurfaceView(tree: tree, hooks: hooks) { event in
                handle(event, model: model)
            }
        } else if let model, let lastError = model.lastError {
            ChassisEmptyState(
                id: "surface-unavailable",
                title: "Surface Unavailable",
                systemImage: RecordKindDescriptor.unknownSymbolName,
                message: lastError
            )
            .view
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Opening

    /// Opens (or reuses) the `SharedSurface` handle for this pane. Called
    /// from `.task(id: surfaceID)`, so it re-runs exactly when the pane's
    /// `item` parameter resolves to a DIFFERENT surface — never on every
    /// keystroke a widget inside it makes, since those go through
    /// `model.dispatch`, not through this path.
    ///
    /// `surfaceID` arrives as a plain parameter (the `.task(id:)` snapshot),
    /// and every other value this reads off `context` is a `let` on the
    /// view's own struct, not `@State` — so, per CLAUDE.md's capture rule,
    /// there is nothing here that can go stale out from under the `await`.
    private func open(surfaceID: String?) async {
        guard let surfaceID else {
            model?.stop()
            model = nil
            return
        }
        if let existing = model, existing.surfaceID == surfaceID {
            return
        }
        model?.stop()
        model = nil

        let tile = context.tile
        logInfo("surface pane \(tile): opening surface \(surfaceID)", category: "surface")

        guard let store = RustStoreAdapter.shared.layoutSharedStore() else {
            logError(
                "surface pane \(tile): no SharedStore handle — surface not rendered",
                category: "surface")
            return
        }
        // `host: ""` — SharedSurface resolves the layout device id itself
        // (see `SharedSurface.open`'s doc comment).
        let surface = SharedSurface.open(store: store, host: "")
        let opened = SurfacePaneModel(surface: surface, surfaceID: surfaceID, pane: tile)
        model = opened
        opened.start()
    }

    // MARK: Events

    /// Every `SurfaceEvent` the renderer sends, forwarded to Rust via
    /// `model.dispatch` — and, for a `select` event, ALSO published on this
    /// pane's own channel via `context.select(_:)`, exactly the way
    /// `LayoutRowsPaneView` publishes a row click: a surface's table/list
    /// selection is how a surface feeds another pane (`docs/agent-surfaces.md`
    /// § Actions, `{"publish": {...}}`), and that only works if the PANE's
    /// selection channel — not just the surface's own dispatch/reduce state —
    /// carries it.
    private func handle(_ event: SurfaceEvent, model: SurfacePaneModel) {
        if event.kind == .select, let ids = event.value.arrayValue?.compactMap(\.stringValue) {
            context.select(ids)
        }
        model.dispatch(event)
    }

    // MARK: Hooks

    /// The suite-aware hooks — MarkdownUI for `text`, `renderPlotSvg` for
    /// `plot`. `list` reuses the kit-grade `.plain` row rendering rather
    /// than `RecordViewerRegistry`: that registry's row factories all take a
    /// `KindTaggedRow` built from a PUBLICATION-shaped payload
    /// (`LayoutPaneRowMapper`), and a surface's `list` rows are arbitrary
    /// agent JSON with no such mapping — wiring the registry through needs a
    /// row-shape adapter this work package does not build. Noted as
    /// follow-up in `docs/plan-agent-surfaces.md`.
    private var hooks: SurfaceHooks {
        SurfaceHooks(
            renderMarkdown: { text in AnyView(Markdown(text)) },
            renderPlot: { specJSON in AnyView(SurfacePlotView(specJSON: specJSON)) },
            renderListRows: { rowsJSON, onSelect in
                SurfaceHooks.plain.renderListRows(rowsJSON, onSelect)
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
    fileprivate static func renderedSVG(fromSpecJSON specJSON: String) -> String? {
        guard let data = specJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let spec = PlotAutomationHandler.decodeSpec(object)
        else { return nil }
        let rendered = renderPlotSvg(spec: spec)
        guard rendered.error == nil, !rendered.svg.isEmpty else { return nil }
        return rendered.svg
    }
}

// MARK: - The per-pane model

/// Owns ONE `SharedSurface` handle and its invalidation subscription for the
/// life of this pane's surface id (see `LayoutSurfacePaneView.open`).
/// `@Observable` so the view re-renders when `tree`/`lastError` change,
/// exactly the way `LayoutController` drives `LayoutWindowView` — the same
/// idiom, one level down.
@MainActor
@Observable
final class SurfacePaneModel {

    let surface: SharedSurface
    let surfaceID: String
    let pane: UInt64

    private(set) var tree: RenderTree?
    private(set) var lastError: String?
    private var subscribed = false

    init(surface: SharedSurface, surfaceID: String, pane: UInt64) {
        self.surface = surface
        self.surfaceID = surfaceID
        self.pane = pane
    }

    /// First render, then subscribe — a pane that shows this surface before
    /// any subsequent `dispatch`/external write still has an answer either
    /// way (mirrors `SharedSurface.render`'s own doc comment on `pane:`).
    func start() {
        render()
        guard !subscribed else { return }
        do {
            try surface.subscribe(
                listener: SurfaceInvalidationBridge(surfaceID: surfaceID) { [weak self] in
                    self?.render()
                })
            subscribed = true
        } catch {
            lastError = String(describing: error)
            logWarning(
                "surface pane \(pane): subscribe failed — \(error)", category: "surface")
        }
    }

    func stop() {
        guard subscribed else { return }
        surface.unsubscribe()
        subscribed = false
    }

    /// The DISPLAY leg of the trace: re-read the resolved tree from Rust.
    func render() {
        logInfo(
            "surface pane \(pane): render requested for \(surfaceID)", category: "surface")
        do {
            let json = try surface.render(surfaceId: surfaceID, pane: pane)
            let decoded = try RenderTree.decode(json)
            lastError = nil
            tree = decoded
            logInfo(
                "surface pane \(pane) display: \(decoded.focusOrder.count) focusable widgets",
                category: "surface")
        } catch {
            lastError = String(describing: error)
            logWarning(
                "surface pane \(pane): render failed — \(error)", category: "surface")
        }
    }

    /// The MUTATION leg (the request) and the SAVE leg (what Rust actually
    /// did) of the trace; `render()` above is the DISPLAY leg, called again
    /// here once the reply carries a fresh tree.
    func dispatch(_ event: SurfaceEvent) {
        logInfo(
            "surface pane \(pane): dispatch \(event.kind.rawValue) on \(event.widget)",
            category: "surface")
        do {
            let eventJSON = try event.jsonString()
            let replyJSON = try surface.dispatch(
                surfaceId: surfaceID, pane: pane, eventJson: eventJSON)
            let reply = try SurfaceDispatchReply.decode(replyJSON)
            logInfo(
                "surface pane \(pane) applied: ok=\(reply.ok) message=\(reply.message)",
                category: "surface")
            if let newTree = reply.tree {
                lastError = nil
                tree = newTree
                logInfo(
                    "surface pane \(pane) display: \(newTree.focusOrder.count) focusable widgets",
                    category: "surface")
            } else if !reply.ok {
                lastError = reply.message
            }
        } catch {
            lastError = String(describing: error)
            logWarning(
                "surface pane \(pane): dispatch failed — \(error)", category: "surface")
        }
    }
}

/// `SharedSurfaceListener`'s callback arrives on the feed's own thread, never
/// the caller's (mirrors `SharedLayoutListener`'s doc comment) — this class
/// does nothing but hop to the main actor, the same shape
/// `LayoutInvalidationBridge` uses in `LayoutController.swift`.
private final class SurfaceInvalidationBridge: SharedSurfaceListener, @unchecked Sendable {
    private let surfaceID: String
    private let onChanged: @MainActor @Sendable () -> Void

    init(surfaceID: String, onChanged: @escaping @MainActor @Sendable () -> Void) {
        self.surfaceID = surfaceID
        self.onChanged = onChanged
    }

    func surfacesChanged(ids: [String]) {
        guard ids.contains(surfaceID) else { return }
        let hop = onChanged
        Task { @MainActor in hop() }
    }
}

/// `impress_surface_service::dto::SurfaceDispatchResult`'s wire shape
/// (`{"ok", "message", "tree", "effects"}`) — only `ok`/`message`/`tree` are
/// modelled; `effects` (the `open`/`publish` actions the host must still
/// run, per `SharedSurface.dispatch`'s doc comment) are not yet consumed
/// here. NOTED AS A GAP, not silently dropped: an `on_click`/`on_select`
/// spec that names `{"open": {...}}` or `{"publish": {...}}` (as opposed to
/// the `context.select` this file already does for a raw `select` EVENT)
/// will validate, dispatch and re-render correctly, but the pane will not
/// itself open a query in another pane or publish on demand from an
/// `on_click`'s `publish` action — only from an actual `select` event on a
/// `table`/`list`, which `handle(_:model:)` above does cover. Wiring
/// `effects` is follow-up, tracked alongside the `list` row-style gap noted
/// on `hooks` above.
private struct SurfaceDispatchReply: Decodable {
    let ok: Bool
    let message: String
    let tree: RenderTree?

    static func decode(_ json: String) throws -> SurfaceDispatchReply {
        try JSONDecoder().decode(SurfaceDispatchReply.self, from: Data(json.utf8))
    }
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
        if let svg = LayoutSurfacePaneView.renderedSVG(fromSpecJSON: specJSON) {
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
