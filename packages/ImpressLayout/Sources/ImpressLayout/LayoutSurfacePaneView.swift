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
//  the layout was opened on, decodes a `SurfaceDispatchResult` (the effects'
//  outcomes included — Rust has already run them), forwards the window
//  root's j / k / ⏎ / ⎋ to the surface, and publishes a `select` event on
//  the pane's own channel. What needs the SUITE —
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
                // (ADR-0031 D3) — and it names what is unfilled, rather than
                // the publication detail pane's words it borrowed until wave
                // 7 (SK-K21).
                LayoutUnavailable(
                    "No Surface", systemImage: "rectangle.dashed",
                    message:
                        "This pane's item parameter is unbound, so it names no surface "
                        + "(tile \(String(context.tile))).")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The subscription lives exactly as long as this task (SK-K18 /
        // AC-F17): SwiftUI cancels it when the pane disappears or its surface
        // id changes, and re-runs it when the pane appears again. The old
        // shape unsubscribed in `onDisappear` and returned early from `open`
        // on reappearing with the same id, so a pane hidden once (a tab
        // switch, maximize/restore) never heard an agent's write again.
        .task(id: surfaceID) {
            await attend(surfaceID: surfaceID)
        }
    }

    @ViewBuilder
    private func content(surfaceID: String) -> some View {
        if let model, let tree = model.tree {
            VStack(spacing: 0) {
                if let failure = model.effectFailure {
                    effectFailureLine(failure, model: model)
                }
                SurfaceView(tree: tree, hooks: hooks, keyInput: model.keyInput) { event in
                    handle(event, model: model)
                }
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

    /// A failed effect is said, above the surface, until dismissed (SK-K16).
    private func effectFailureLine(_ failure: String, model: SurfacePaneModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(failure).lineLimit(2)
            Spacer(minLength: 0)
            Button {
                model.dismissEffectFailure()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Lifetime

    /// Open (or reuse) this pane's `SharedSurface` handle, start its feed,
    /// take the root's keys, and hold all three until SwiftUI cancels the
    /// task — then release all three.
    ///
    /// `surfaceID` arrives as the `.task(id:)` snapshot, and every other
    /// value this reads off `context` is a `let` on the view's own struct,
    /// not `@State` — so, per CLAUDE.md's capture rule, nothing here can go
    /// stale across the `await`.
    private func attend(surfaceID: String?) async {
        let tile = context.tile
        let controller = context.controller
        guard let surfaceID else {
            model = nil
            return
        }
        let active: SurfacePaneModel
        if let existing = model, existing.surfaceID == surfaceID {
            active = existing
        } else {
            logInfo("surface pane \(tile): opening surface \(surfaceID)", category: "surface")
            guard let store = controller.store else {
                logError(
                    "surface pane \(tile): no SharedStore handle — surface not rendered",
                    category: "surface")
                return
            }
            // `host: ""` — SharedSurface resolves the layout device id itself
            // (see `SharedSurface.open`'s doc comment).
            let surface = SharedSurface.open(store: store, host: "")
            active = SurfacePaneModel(surface: surface, surfaceID: surfaceID, pane: tile)
            model = active
        }
        active.start()
        let keys = active.keyInput
        controller.setKeyHandler(for: tile, owner: active) { key in
            switch key {
            case .down: return keys.send(.next)
            case .up: return keys.send(.previous)
            case .activate: return keys.send(.activate)
            case .leave: return keys.send(.leave)
            }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        controller.removeKeyHandler(for: tile, owner: active)
        active.stop()
    }

    // MARK: Events

    /// Every `SurfaceEvent` the renderer sends, forwarded to Rust via
    /// `model.dispatch` — and, for a `select` event, ALSO published on this
    /// pane's own channel via `context.select(_:)`, exactly the way
    /// `LayoutRowsPaneView` publishes a row click. (Whether the renderer
    /// should publish at all, or leave it to the spec's own `publish`
    /// effect, is review SK-K4 — wave 7's T6.)
    private func handle(_ event: SurfaceEvent, model: SurfacePaneModel) {
        if event.kind == .select, let ids = event.value.arrayValue?.compactMap(\.stringValue) {
            context.select(ids)
        }
        model.dispatch(event)
    }
}

// MARK: - The per-pane model

/// Owns ONE `SharedSurface` handle and its invalidation subscription for the
/// life of this pane's surface id (see `LayoutSurfacePaneView.attend`).
/// `@Observable` so the view re-renders when `tree`/`lastError` change,
/// exactly the way `LayoutController` drives `LayoutWindowView` — the same
/// idiom, one level down.
@MainActor
@Observable
final class SurfacePaneModel {

    let surface: SharedSurface
    let surfaceID: String
    let pane: UInt64
    /// Where the window root's j / k / ⏎ / ⎋ arrive for this surface.
    let keyInput = SurfaceKeyInput()

    private(set) var tree: RenderTree?
    private(set) var lastError: String?
    /// The most recent dispatch's failed effects, until dismissed.
    private(set) var effectFailure: String?
    private var subscribed = false
    private var everSubscribed = false
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

    /// Render, then subscribe. Idempotent; a pane that appears again after
    /// being hidden re-renders (it may have missed writes) and resubscribes.
    func start() {
        render()
        guard !subscribed else { return }
        do {
            try surface.subscribe(
                listener: SurfaceInvalidationBridge(surfaceID: surfaceID) { [weak self] in
                    self?.render()
                })
            subscribed = true
            logInfo(
                "surface pane \(pane): \(everSubscribed ? "resubscribed" : "subscribed") to \(surfaceID)",
                category: "surface")
            everSubscribed = true
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
        logInfo("surface pane \(pane): unsubscribed from \(surfaceID)", category: "surface")
    }

    func dismissEffectFailure() {
        effectFailure = nil
    }

    /// The DISPLAY leg of the trace: re-read the resolved tree from Rust.
    ///
    /// `SharedSurface.render` is async and runs its sources on Rust's own
    /// runtime (wave 7, SK-K2): the main actor is suspended, not blocked,
    /// while a slow verb runs.
    ///
    /// A tree equal to the one on screen is not adopted, so the feed's echo
    /// of this pane's own dispatch — which the dispatch reply already
    /// rendered — redraws nothing (SK-K15). The FFI call itself still runs:
    /// the feed carries no way to tell our write from an agent's, and
    /// skipping it could hide the agent's.
    func render() {
        logDebug("surface pane \(pane): render requested for \(surfaceID)", category: "surface")
        generation += 1
        let ticket = generation
        let (surface, surfaceID, pane) = (self.surface, self.surfaceID, self.pane)
        Task { [weak self] in
            do {
                let json = try await surface.render(surfaceId: surfaceID, pane: pane)
                let decoded = try RenderTree.decode(json)
                guard let self, ticket == self.generation else { return }
                self.lastError = nil
                guard decoded != self.tree else {
                    logDebug("surface pane \(pane): render unchanged", category: "surface")
                    return
                }
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

    /// The MUTATION leg (the request) and the SAVE leg (what Rust did,
    /// effects included) of the trace, as ONE line each; the reply's tree is
    /// the DISPLAY leg. Dispatches run in the order they were made, each
    /// awaiting the one before it.
    func dispatch(_ event: SurfaceEvent) {
        let value = (try? event.value.jsonString()) ?? "?"
        logInfo(
            "surface pane \(pane): \(event.kind.rawValue) \(event.widget)=\(value.prefix(80))",
            category: "surface")
        let eventJSON: String
        do {
            eventJSON = try event.jsonString()
        } catch {
            lastError = String(describing: error)
            logWarning(
                "surface pane \(pane): \(event.kind.rawValue) \(event.widget) failed — \(error)",
                category: "surface")
            return
        }
        generation += 1
        let ticket = generation
        let previous = lastDispatch
        let (surface, surfaceID, pane) = (self.surface, self.surfaceID, self.pane)
        let (kind, widget) = (event.kind.rawValue, event.widget)
        lastDispatch = Task { [weak self] in
            await previous?.value
            do {
                let replyJSON = try await surface.dispatch(
                    surfaceId: surfaceID, pane: pane, eventJson: eventJSON)
                let reply = try SurfaceDispatchReply.decode(replyJSON)
                let failed = reply.effects.filter { !$0.ok }
                logInfo(
                    "surface pane \(pane): \(kind) \(widget) → "
                        + "\(reply.ok ? "ok" : "refused: \(reply.message)"), "
                        + "\(reply.effects.count) effect(s), \(failed.count) failed",
                    category: "surface")
                // Rust has run every effect already (none is left for the
                // host); a failed one is reported, not retried (SK-K16). This
                // is what Rust did, so it is said even if a newer call
                // overtook the reply's tree.
                for effect in failed {
                    logWarning(
                        "surface pane \(pane): \(effect.kind) effect failed — \(effect.message)",
                        category: "surface")
                }
                guard let self else { return }
                self.effectFailure =
                    failed.isEmpty
                    ? nil : failed.map { "\($0.kind) failed: \($0.message)" }.joined(separator: "; ")
                guard ticket == self.generation else { return }
                if let newTree = reply.tree {
                    self.lastError = nil
                    if newTree != self.tree { self.tree = newTree }
                } else if !reply.ok {
                    self.lastError = reply.message
                }
            } catch {
                logWarning(
                    "surface pane \(pane): \(kind) \(widget) failed — \(error)",
                    category: "surface")
                guard let self, ticket == self.generation else { return }
                self.lastError = String(describing: error)
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

/// `impress_surface_service::dto::SurfaceDispatchResult`'s wire shape:
/// `{"ok", "message", "tree", "effects"}`. Rust has already RUN every effect
/// by the time this arrives — `call`, `publish`, `emit`, `open`, `refresh`;
/// none is a to-do for the host — and `effects` says how each one went. A
/// dispatch can be `ok` with a failed effect (a publish that found no pane,
/// an `open` Rust refused), which is why the pane reads them (SK-K16).
struct SurfaceDispatchReply: Decodable {
    let ok: Bool
    let message: String
    let tree: RenderTree?
    let effects: [Effect]

    struct Effect: Decodable, Equatable {
        let kind: String
        let ok: Bool
        let message: String
    }

    private enum CodingKeys: String, CodingKey { case ok, message, tree, effects }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        tree = try container.decodeIfPresent(RenderTree.self, forKey: .tree)
        effects = try container.decodeIfPresent([Effect].self, forKey: .effects) ?? []
    }

    static func decode(_ json: String) throws -> SurfaceDispatchReply {
        try JSONDecoder().decode(SurfaceDispatchReply.self, from: Data(json.utf8))
    }
}
#endif
