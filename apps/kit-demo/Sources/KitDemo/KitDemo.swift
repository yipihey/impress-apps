//
//  KitDemo.swift — THROWAWAY (plan wave 6, W6).
//
//  The kit on its own: a scratch store in a temp directory (never the user's
//  workspace), one surface created through the surface FFI, a layout tree
//  whose panes the kit does not register (outline, list, info — they render
//  as placeholders) plus one `surface` pane showing that surface. Nothing
//  here is PublicationManagerCore, and nothing registers a view kind.
//

import AppKit
import Foundation
import ImpressLayout
import ImpressRustCore
import SwiftUI

/// The scratch store and the tree applied to it, built once before the window.
@MainActor
enum Demo {

    static let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("impress-kit-demo-\(ProcessInfo.processInfo.processIdentifier)")

    static let store: SharedStore? = {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("kit-demo.sqlite").path
            let store = try SharedStore.open(path: path)
            say("scratch store at \(path)")
            return store
        } catch {
            say("store did not open: \(error)")
            return nil
        }
    }()

    /// The app id whose preset seeds the tree. `impress`'s Default is outline
    /// + list + info, three kinds the kit leaves to a host.
    static let appID = "impress"

    static func prepare() {
        guard let store else { return }
        let surfaces = SharedSurface.open(store: store, host: "")
        let spec = #"""
            {"surface": "1.0", "name": "kit-demo", "state": {"bins": 12},
             "root": {"column": [
               {"text": "Rendered by ImpressLayout alone — no PublicationManagerCore."},
               {"id": "bins", "field": {"slider": {"min": 1, "max": 64, "step": 1}},
                "label": "Bins", "bind": "state.bins"},
               {"id": "go", "button": {"label": "Emit", "on_click": [
                 {"emit": {"name": "bins-chosen", "payload": {"bins": "{{state.bins}}"}}}]}}
             ]}}
            """#
        let created = surfaces.surfaceHttp(method: "POST", path: "/api/surface", body: spec)
        guard created.status < 300,
            let object = try? JSONSerialization.jsonObject(with: Data(created.body.utf8))
                as? [String: Any],
            let id = object["id"] as? String
        else {
            say("surface create answered \(created.status): \(created.body)")
            return
        }
        say("surface created: \(id)")

        let layout = SharedLayout.open(store: store, appId: appID, device: nil)
        let split = #"""
            {"verb": "split", "target": {"ref": "role", "role": "detail"},
             "dir": "vertical", "after": true,
             "new": {"channel": {"number": 2}, "view_kind": "surface",
                     "query": {"kinds": ["surface"], "scope": {"scope": "item",
                               "id": {"ref": "id", "id": "\#(id)"}},
                               "filters": [], "sort": [], "limit": null,
                               "relation": null, "text": null}}}
            """#
        do {
            let applied = try layout.apply(verbJson: split, actor: "human")
            say("tree applied: version \(applied.version), \(applied.changedTiles.count) tiles changed")
            let snapshot = try layout.snapshot()
            say("tree leaves: \(snapshot.leaves.count)")
        } catch {
            say("split refused: \(error)")
        }
    }

    /// What the kit rendered, read back from its own runtime once the host
    /// has opened: the controller's version and, per leaf, its view kind and
    /// the kind the registry resolves it to (a kind nobody registered →
    /// `placeholder`, ADR-0031 D4).
    static func report() async {
        try? await Task.sleep(for: .seconds(3))
        guard let controller = LayoutTreeRuntime.shared.controller, let tree = controller.tree,
            let window = tree.firstWindow
        else {
            say("no controller opened")
            return
        }
        say("kit registry: \(ViewKindRegistry.builtin.registeredKinds.map(\.rawValue).sorted())")
        say("tree on screen: version \(controller.version), \(tree.leaves(of: window.root).count) panes")
        for tile in tree.leaves(of: window.root) {
            guard let spec = tree.pane(tile) else { continue }
            let kind = ViewKindID(spec.viewKind)
            let resolved = ViewKindRegistry.builtin.resolvedKind(for: kind)
            let detail = kind == .surface
                ? " (single item \(controller.pane(tile)?.singleItem ?? "unresolved"))" : ""
            say("pane \(tile): \(kind.rawValue) → renders \(resolved.rawValue)\(detail)")
        }
    }

    static func say(_ line: String) {
        print("kit-demo: \(line)")
        fflush(stdout)
    }
}

@main
struct KitDemoApp: App {

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        Demo.prepare()
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("ImpressLayout — standalone") {
            LayoutTreeHost(
                appID: Demo.appID,
                services: LayoutHostServices(openStore: { Demo.store }))
                .frame(minWidth: 1100, minHeight: 700)
                .task { await Demo.report() }
        }
    }
}
