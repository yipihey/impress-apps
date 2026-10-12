#if os(macOS)
// Chassis file — macOS-only. L8 leaf 4b (docs/plan-l8-sidebar-surface.md, SB-D6).
//
//  LayoutOutlineSurfaceView.swift
//  PublicationManagerCore
//
//  The `outline` view kind's SURFACE route: the navigator pane draws the
//  sidebar as a koine `tree` surface that Rust installs, instead of hosting
//  `ImbibSidebarColumn`. `LayoutOutlinePaneView` branches here when the
//  `impress.outline.surface` setting is on.
//
//  ## What this file owns
//
//  Nothing about the sidebar. The rows are the Rust verb `layout-service_
//  outline-rows`, a selected row is `outline-select` (one atomic step on the
//  live layout), rename / delete / move / create are the `outline-*` verbs
//  forwarding to the collection kernel, and the spec that wires them is
//  `outline_surface_spec` (SB-D1..D5). This view asks Rust to install that
//  spec for this window's app (`installOutlineSurface`, tag `outline:<app>`,
//  one row per app per store, refreshed when the spec changes), hosts it the
//  way `LayoutSurfacePaneView` hosts any surface — a `SurfacePaneModel` with
//  the pane's tile, the root's keys forwarded, every event dispatched to
//  Rust — and draws what `SurfaceView` maps from the tree.
//
//  The one thing only the host knows is a set of library ids (`bindings`):
//  `dismissed_library` and `exploration_library` / `exploration`, passed as
//  literals into the spec, so a change of either re-installs the surface
//  (the `.task` is keyed on them).
//
//  ## Three-point trace (category "layout", then "surface")
//
//  1. MUTATION  `pane N outline: installing surface for <app> (bindings: …)`
//  2. SAVE      `pane N outline: surface <id> installed`
//  3. DISPLAY   `SurfacePaneModel` logs every render it draws (category
//               "surface"); the list pane's own `pane M display: K rows`
//               line after a click is the end of the chain.
//

import Foundation
import ImpressLayout
import ImpressLogging
import ImpressRustCore
import ImpressSurface
import ImpressSurfaceSession
import SwiftUI

@MainActor
struct LayoutOutlineSurfaceView: View {

    let context: PaneContext

    @Environment(LibraryManager.self) private var libraryManager

    @State private var model: SurfacePaneModel?
    @State private var failure: String?

    /// The ids only the host knows, as the JSON object the Rust installer
    /// takes (parameter name → lowercase uuid; absent ones omitted). Keys are
    /// sorted so the same libraries always produce the same string — it is
    /// part of the `.task` identity below.
    private var bindingsJSON: String {
        var bindings: [String: String] = [:]
        if let dismissed = libraryManager.dismissedLibrary?.id {
            bindings["dismissed_library"] = dismissed.uuidString.lowercased()
        }
        if let exploration = libraryManager.explorationLibrary?.id {
            bindings["exploration_library"] = exploration.uuidString.lowercased()
            bindings["exploration"] = exploration.uuidString.lowercased()
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: bindings, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    var body: some View {
        let bindings = bindingsJSON
        Group {
            if let model, let tree = model.tree {
                VStack(spacing: 0) {
                    if let effectFailure = model.effectFailure {
                        effectFailureLine(effectFailure, model: model)
                    }
                    SurfaceView(tree: tree, hooks: .chassis, keyInput: model.keyInput) { event in
                        model.dispatch(event)
                    }
                }
            } else if let message = failure ?? model?.lastError {
                LayoutUnavailable(
                    "Sidebar Unavailable", systemImage: LayoutUnavailable.unknownSymbolName,
                    message: message)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Re-installs (and re-hosts) when the app or the host's library ids
        // change; SwiftUI cancels the previous task, which releases the key
        // handler and stops the model before the next one starts.
        .task(id: "\(context.controller.appID)|\(bindings)") {
            await attend(bindingsJSON: bindings)
        }
        // The pane's own bindings moved: render again (Rust re-reads them).
        .onChange(of: context.refreshToken) {
            model?.render()
        }
    }

    /// A failed effect is said, above the surface, until dismissed.
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

    /// Install the outline surface, host it, and hold the model and the key
    /// handler until SwiftUI cancels the task — then release both.
    ///
    /// Everything read off `context` is taken into locals before the first
    /// `await` (CLAUDE.md's capture rule); `bindingsJSON` arrives as the
    /// `.task(id:)` snapshot.
    private func attend(bindingsJSON: String) async {
        let tile = context.tile
        let controller = context.controller
        let appID = controller.appID
        guard let store = controller.store else {
            failure = "The layout was opened without a store, so the sidebar has nowhere to keep its surface."
            logError("pane \(tile) outline: no SharedStore handle — surface not installed", category: "layout")
            return
        }
        // 1. MUTATION — what is being installed, for whom, with which ids.
        logInfo(
            "pane \(tile) outline: installing surface for \(appID) (bindings: \(bindingsJSON))",
            category: "layout")
        // `host: ""` — SharedSurface resolves the layout device id itself, and
        // `appId` makes a selection land in THIS window's layout.
        let surface = SharedSurface.open(store: store, host: "", appId: appID)
        let surfaceID: String
        do {
            surfaceID = try installOutlineSurface(
                surface: surface, appId: appID, bindingsJson: bindingsJSON)
        } catch {
            // Never a crash: the pane says what failed, and the setting can
            // be turned off to get the legacy sidebar back.
            failure = String(describing: error)
            logWarning(
                "pane \(tile) outline: surface install failed for \(appID) — \(error)", category: "layout")
            return
        }
        // 2. SAVE — Rust stored (or refreshed) the surface row.
        logInfo("pane \(tile) outline: surface \(surfaceID) installed", category: "layout")
        failure = nil

        let active = SurfacePaneModel(surface: surface, surfaceID: surfaceID, pane: tile)
        model = active
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
}
#endif
