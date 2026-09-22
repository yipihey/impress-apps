//
//  SurfaceAutomationBridge.swift
//  PublicationManagerCore
//
//  The chassis' answer to `/api/surface/…`, for whichever app is asking.
//
//  `SurfaceAutomationRoutes` (ImpressAutomation) owns the paths, the 409 and
//  the status text; this owns the two things that package must not learn —
//  the `SharedStore` handle and `SharedSurface`. It is the same split as
//  `LayoutController: LayoutAutomationHost` one door down, and it exists for
//  the same reason: impress is the app that renders surfaces, and impress's
//  router is the shared group plus `/api/status`, so a route mounted in
//  imbib's own router answers on the wrong port (verified live 2026-09-22:
//  404 on 23125, 200 on 23120, with the surface panes on 23125).
//
//  The route TABLE stays in Rust. This forwards method, path and body to
//  `SharedSurface.surfaceHttp` and passes its status and JSON back untouched
//  — no path is spelled here, so `crates/impress-store-ffi/src/surface.rs`
//  remains the one place routes are named.
//

import Foundation
import ImpressAutomation
import ImpressLogging
import ImpressRustCore

/// One registered host per process; `RustStoreAdapter` installs it the first
/// time the kernel store handle is handed out.
@MainActor
final class SurfaceAutomationBridge: SurfaceAutomationHost {

    static let shared = SurfaceAutomationBridge()

    private init() {}

    func routeSurfaceRequest(method: String, path: String, body: String) -> (
        status: Int, body: String
    ) {
        guard let store = RustStoreAdapter.shared.layoutSharedStore() else {
            logWarning(
                "surface automation: no SharedStore handle — \(method) \(path) refused",
                category: "surface")
            return (
                409,
                #"{"error": "the shared store is not open"}"#
            )
        }
        // `host: ""` is the process-wide host, the same one `surface_show`
        // binds a pane under: a surface created by an agent and a surface
        // rendered in this window are one row, not two.
        let surface = SharedSurface.open(store: store, host: "")
        let reply = surface.surfaceHttp(method: method, path: path, body: body)
        logInfo(
            "surface automation: \(method) \(path) → \(reply.status)", category: "surface")
        return (Int(reply.status), reply.body)
    }
}
