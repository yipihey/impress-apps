#if os(macOS)
// Kit file (ImpressLayout) — macOS-only, like every other file in this
// package. ADR-0033 work package S7.
//
//  LayoutSurfacePaneView.swift
//  ImpressLayout
//
//  The `surface` view kind: an agent-authored `impress/ui/surface@1.0.0`
//  document, rendered by `packages/ImpressSurface`'s `SurfaceView`, hosted
//  the same way `LayoutInfoPaneView` hosts the publication detail pane —
//  the pane's `item` parameter (`context.singleItem` / `context.bindings
//  ["item"]`) names WHICH stored surface this pane shows.
//
//  ## What this file owns vs. what `ImpressSurface` and the host own
//
//  `ImpressSurface` is kit-grade (ADR-0033 D7): it maps a `RenderTree` to
//  SwiftUI and holds no logic. This file opens `SharedSurface` on the store
//  the layout was opened on, decodes a `SurfaceDispatchResult` and publishes
//  a `select` event on the pane's own channel. What needs the SUITE —
//  `text` through MarkdownUI, a `plot-spec@1.0.0` through imprint-core's
//  `renderPlotSvg`, a `list` through the chassis' row registry — is the
//  host's, handed in as `SurfaceHooks` (plan wave 6, W6):
//  PublicationManagerCore re-registers `surface` with its hooks
//  (`LayoutSurfaceHooks.swift`); the kit's own factory uses `.plain`.
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
import Observation
import SwiftUI

// MARK: - The view kind

/// The `surface` view kind: see the file header.
@MainActor
public struct LayoutSurfacePaneView: View {

    let context: PaneContext
    /// How `text`, `plot` and `list` widgets render — the host's (see the
    /// file header). `.plain` is `ImpressSurface`'s kit-grade default.
    let hooks: SurfaceHooks

    public init(context: PaneContext, hooks: SurfaceHooks = .plain) {
        self.context = context
        self.hooks = hooks
    }

    @State private var model: SurfacePaneModel?

    /// What the pane's `item` parameter resolved to — the SAME two-source
    /// read `LayoutInfoPaneView.itemID` uses, minus the UUID parse (a
    /// surface id is a store item id, not necessarily one this build ever
    /// turns into a `UUID`).
    private var surfaceID: String? {
        context.singleItem ?? context.bindings["item"]
    }

    public var body: some View {
        Group {
            if let surfaceID {
                content(surfaceID: surfaceID)
            } else {
                // An unfilled parameter is the empty state, never an error
                // (ADR-0031 D3). The words and glyph are the ones this pane
                // drew before W6 (`ChassisEmptyState.noRowSelection(isArtifact:
                // false)`), kept verbatim by the move.
                LayoutUnavailable(
                    "No Selection", systemImage: "doc.text",
                    message: "Select a publication to view details")
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
            LayoutUnavailable(
                "Surface Unavailable", systemImage: LayoutUnavailable.unknownSymbolName,
                message: lastError)
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

        guard let store = context.controller.store else {
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
    /// Bumped by every render and dispatch; a reply is shown only if no
    /// newer call started after it, so a slow render cannot overwrite the
    /// tree a later dispatch already showed.
    private var generation = 0
    /// The dispatch in flight, if any: the next one waits for it, so the
    /// events reach Rust in the order the person made them.
    private var lastDispatch: Task<Void, Never>?

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
    ///
    /// `SharedSurface.render` is async and runs its sources on Rust's own
    /// runtime (wave 7, SK-K2): the main actor is suspended, not blocked,
    /// while a slow verb runs.
    func render() {
        logInfo(
            "surface pane \(pane): render requested for \(surfaceID)", category: "surface")
        generation += 1
        let ticket = generation
        let (surface, surfaceID, pane) = (self.surface, self.surfaceID, self.pane)
        Task { [weak self] in
            do {
                let json = try await surface.render(surfaceId: surfaceID, pane: pane)
                let decoded = try RenderTree.decode(json)
                guard let self, ticket == self.generation else { return }
                self.lastError = nil
                self.tree = decoded
                logInfo(
                    "surface pane \(pane) display: \(decoded.focusOrder.count) focusable widgets",
                    category: "surface")
            } catch {
                guard let self, ticket == self.generation else { return }
                self.lastError = String(describing: error)
                logWarning(
                    "surface pane \(pane): render failed — \(error)", category: "surface")
            }
        }
    }

    /// The MUTATION leg (the request) and the SAVE leg (what Rust actually
    /// did) of the trace; `render()` above is the DISPLAY leg, called again
    /// here once the reply carries a fresh tree.
    func dispatch(_ event: SurfaceEvent) {
        logInfo(
            "surface pane \(pane): dispatch \(event.kind.rawValue) on \(event.widget)",
            category: "surface")
        let eventJSON: String
        do {
            eventJSON = try event.jsonString()
        } catch {
            lastError = String(describing: error)
            logWarning(
                "surface pane \(pane): dispatch failed — \(error)", category: "surface")
            return
        }
        generation += 1
        let ticket = generation
        let previous = lastDispatch
        let (surface, surfaceID, pane) = (self.surface, self.surfaceID, self.pane)
        lastDispatch = Task { [weak self] in
            await previous?.value
            do {
                let replyJSON = try await surface.dispatch(
                    surfaceId: surfaceID, pane: pane, eventJson: eventJSON)
                let reply = try SurfaceDispatchReply.decode(replyJSON)
                logInfo(
                    "surface pane \(pane) applied: ok=\(reply.ok) message=\(reply.message)",
                    category: "surface")
                guard let self, ticket == self.generation else { return }
                if let newTree = reply.tree {
                    self.lastError = nil
                    self.tree = newTree
                    logInfo(
                        "surface pane \(pane) display: \(newTree.focusOrder.count) focusable widgets",
                        category: "surface")
                } else if !reply.ok {
                    self.lastError = reply.message
                }
            } catch {
                guard let self, ticket == self.generation else { return }
                self.lastError = String(describing: error)
                logWarning(
                    "surface pane \(pane): dispatch failed — \(error)", category: "surface")
            }
        }
    }
}

/// `SharedSurface` is an `Arc` over a Rust object that is `Send + Sync`
/// (its registry and store are locked inside Rust), and its `render`,
/// `dispatch` and `surfaceHttp` are async exports that run on Rust's own
/// runtime — so a handle may be awaited from any task. UniFFI does not
/// mark generated classes `Sendable`; this says what the Rust side
/// guarantees.
extension SharedSurface: @retroactive @unchecked Sendable {}

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
#endif
