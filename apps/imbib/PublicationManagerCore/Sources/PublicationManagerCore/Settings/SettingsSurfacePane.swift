//
//  SettingsSurfacePane.swift
//  PublicationManagerCore
//
//  A settings pane that is a GENERATED surface (ADR-0036 D5, plan-self-
//  reflective-layer R1): the registry's section — every field typed from
//  `crates/impress-settings`, `settings-service_set` on change — stored as an
//  `impress/ui/surface@1.0.0` row and rendered by `ImpressSurface`'s
//  `SurfaceView`, the same renderer an agent's surface gets. This file holds
//  no form: it installs the section's surface (Rust regenerates the spec and
//  reseeds the state row from the files on every open, so a CLI `set` made
//  while the window was closed shows), drives `SurfacePaneModel` with no
//  layout tile, and shows what Rust renders.
//
//  Three-point trace, all under `settings` / `surface`: the field change is
//  logged by the model's dispatch (mutation), Rust's `settings-service_set`
//  logs the stored value (save), and the model's render logs the tree
//  (display).
//

import ImpressKit
import ImpressLayout
import ImpressLogging
import ImpressRustCore
import ImpressSurface
import SwiftUI

/// One registry section as a pane. `section` is a registry section id
/// (`imbib.retention`); an undeclared one is the unavailable state, named.
public struct SettingsSurfacePane: View {

    public let section: String

    @State private var model: SurfacePaneModel?
    @State private var failure: String?

    public init(section: String) {
        self.section = section
    }

    public var body: some View {
        Group {
            if let model, let tree = model.tree {
                VStack(alignment: .leading, spacing: 0) {
                    if let effectFailure = model.effectFailure {
                        Label(effectFailure, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                    SurfaceView(tree: tree, hooks: .plain) { event in
                        model.dispatch(event)
                    }
                }
            } else if let message = failure ?? model?.lastError {
                ContentUnavailableView(
                    "Settings Unavailable", systemImage: "slider.horizontal.3",
                    description: Text(message))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("settings.surface.\(section)")
        .task(id: section) {
            await attend()
        }
    }

    /// Open the store, install (or refresh) the section's surface, and hold
    /// the model until SwiftUI cancels the task.
    private func attend() async {
        let section = self.section
        await RustStoreAdapter.warmOffMain()
        guard let store = RustStoreAdapter.shared.layoutSharedStore() else {
            failure = "The shared store is not open, so the \(section) pane has nowhere to keep its surface."
            logError("settings pane \(section): no SharedStore handle", category: "settings")
            return
        }
        let surface = SharedSurface.open(store: store, host: "", appId: "imbib")
        let surfaceID: String
        do {
            surfaceID = try ImpressSettings.shared.installSectionSurface(surface: surface, section: section)
        } catch {
            failure = String(describing: error)
            logError("settings pane \(section): install failed — \(error)", category: "settings")
            return
        }
        failure = nil
        let active = SurfacePaneModel(surface: surface, surfaceID: surfaceID, pane: nil)
        model = active
        active.start()
        logInfo("settings pane \(section): showing surface \(surfaceID)", category: "settings")
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        active.stop()
    }
}
