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
//  ["item"]`) names WHICH stored surface this pane shows. The session
//  (`SurfacePaneModel`) lives in ImpressSurfaceSession so iOS can open the
//  same surface; this file is the macOS tile that hosts it.
//
//  ## What this file owns vs. what `ImpressSurface` and the host own
//
//  `ImpressSurface` is kit-grade (ADR-0033 D7): it maps a `RenderTree` to
//  SwiftUI and holds no logic. This file opens `SharedSurface` on the store
//  the layout was opened on, for this window's app, and forwards the window
//  root's j / k / ⏎ / ⎋ to the surface. `SurfacePaneModel` decodes the render
//  and dispatch envelopes (the effects' outcomes included — Rust has already
//  run them). This file
//  publishes nothing itself: a selection reaches a channel only through the
//  spec's own `publish` action, in Rust (review SK-K4). What needs the SUITE —
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
import ImpressSurfaceSession
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
        // The pane's own bindings moved (a paper selected on its channel):
        // the surface's params are bound from them, so render again
        // (review RS-S3, AC-F15). Rust re-reads the bindings itself.
        .onChange(of: context.refreshToken) {
            model?.render()
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
            // (see `SharedSurface.open`'s doc comment). `appId`: this window's
            // app, so a `publish`/`open` from the surface lands in this
            // window's layout, not impress's (review RS-S4, AC-F6).
            let surface = SharedSurface.open(store: store, host: "", appId: controller.appID)
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
    /// `model.dispatch` — and nothing else. A `select` used to be published
    /// on the pane's channel here as well, so a spec with `on_select:
    /// [{publish}]` published twice (once with the pane query's kind, once
    /// with the record's), and a spec that only `set` state published anyway
    /// (review SK-K4). The spec says what a selection does; Rust does it.
    private func handle(_ event: SurfaceEvent, model: SurfacePaneModel) {
        model.dispatch(event)
    }
}

#endif
