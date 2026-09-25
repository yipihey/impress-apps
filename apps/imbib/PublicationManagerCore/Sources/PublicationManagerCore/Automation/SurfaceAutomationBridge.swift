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
#if os(macOS)
import ImpressLayout
#endif
import ImpressLogging
import ImpressRustCore

/// One registered host per process; `RustStoreAdapter` installs it the first
/// time the kernel store handle is handed out.
@MainActor
final class SurfaceAutomationBridge: SurfaceAutomationHost {

    static let shared = SurfaceAutomationBridge()

    private init() {}

    /// ONE handle for every request (SK-K1), reopened only if the store
    /// handle itself changes. A handle is cheap and stateless — the store's
    /// one surface registry is shared by every handle — but opening one per
    /// request was how the bridge and the panes came to disagree.
    private var surface: SharedSurface?
    private var surfaceStore: SharedStore?

    func routeSurfaceRequest(method: String, path: String, body: String) async -> (
        status: Int, body: String
    ) {
        guard let store = RustStoreAdapter.shared.layoutSharedStore() else {
            logWarning(
                "surface automation: no SharedStore handle — \(method) \(path) refused",
                category: "surface")
            return (
                409,
                #"{"error": "the shared store is not open", "code": "store-unavailable"}"#
            )
        }
        // imbib's own window renders no layout tree, so this is where its
        // process first touches the store FFI: bridge Rust's `surface` and
        // `layout` lines into the Console here too (wave 7 T5).
        #if os(macOS)
        RustLogBridge.installOnce()
        #endif
        // `host: ""` is the process-wide host, the same one `surface_show`
        // binds a pane under: a surface created by an agent and a surface
        // rendered in this window are one row, not two.
        let surface: SharedSurface
        if let cached = self.surface, surfaceStore === store {
            surface = cached
        } else {
            surface = SharedSurface.open(store: store, host: "")
            self.surface = surface
            surfaceStore = store
        }
        // Awaited, not blocked on: Rust runs the request on its own runtime
        // and the main actor is free meanwhile (wave 7, SK-K2).
        let reply = await surface.surfaceHttp(method: method, path: path, body: body)
        logInfo(
            "surface automation: \(method) \(path) → \(reply.status)", category: "surface")
        return (Int(reply.status), reply.body)
    }
}
