//
//  KitDemo.swift — THROWAWAY (plan wave 6, W6; proof mode wave 7, T3).
//
//  The kit on its own: a scratch store in a temp directory (never the user's
//  workspace), one surface created through the surface FFI, a layout tree
//  whose panes the kit does not register (outline, list, info — they render
//  as placeholders) plus one `surface` pane showing that surface. Nothing
//  here is PublicationManagerCore, and nothing registers a view kind.
//
//  `--prove` (wave 7, T3) then drives the running window IN-PROCESS — real
//  AppKit key events into the surface's text field, the Edit menu's own Undo
//  item, File ▸ New Window and a window close — and prints PASS/FAIL per
//  claim. In-process because it needs no assistive-access grant: nothing
//  here can reach another app.
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

    static var surfaceID: String?

    /// What the host hooks recorded, in PublicationManagerCore's shape:
    /// `didOpen` sets the one automation host, `didClose` clears it.
    static var host: LayoutController?

    static let proving = CommandLine.arguments.contains("--prove")

    static let services = LayoutHostServices(
        openStore: { Demo.store },
        didOpen: { controller in Demo.host = controller },
        didClose: { _ in Demo.host = nil })

    static func prepare() {
        guard let store else { return }
        let surfaces = SharedSurface.open(store: store, host: "")
        // A text field, a select with nothing stored, a date an agent wrote
        // as a plain day, and a button whose event carries the text.
        let spec = #"""
            {"surface": "1.0", "name": "kit-demo",
             "state": {"bins": 12, "note": "", "mode": null, "day": "2026-09-25"},
             "root": {"column": [
               {"text": "Rendered by ImpressLayout alone — no PublicationManagerCore."},
               {"id": "bins", "field": {"slider": {"min": 1, "max": 64, "step": 1}},
                "label": "Bins", "bind": "state.bins"},
               {"id": "note", "field": {"text": {}}, "label": "Note", "bind": "state.note"},
               {"id": "mode", "field": {"select": {"options": ["linear", "log"]}},
                "label": "Mode", "bind": "state.mode"},
               {"id": "day", "field": {"date": {}}, "label": "Day", "bind": "state.day"},
               {"id": "go", "button": {"label": "Emit", "on_click": [
                 {"emit": {"name": "bins-chosen",
                           "payload": {"bins": "{{state.bins}}", "note": "{{state.note}}"}}}]}}
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
        surfaceID = id
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
        if proving {
            await Proof.run()
            try? FileManager.default.removeItem(at: directory)
            say("scratch store removed; exiting")
            NSApp.terminate(nil)
        }
    }

    static func say(_ line: String) {
        print("kit-demo: \(line)")
        fflush(stdout)
    }
}

// MARK: - Proof mode

@MainActor
enum Proof {

    static var failures = 0

    static func check(_ name: String, _ passed: Bool, _ detail: String) {
        if !passed { failures += 1 }
        Demo.say("PROOF \(name): \(passed ? "PASS" : "FAIL") — \(detail)")
    }

    static func settle(_ seconds: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func run() async {
        guard let controller = LayoutTreeRuntime.shared.controller,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        else {
            check("setup", false, "no controller or window")
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        await settle()
        snapshot(window, name: "kit-demo-window.png")
        await redrawCounter(controller)
        await typedValueReachesTheButton(window)
        await undoFromTheEditMenu(controller, window)
        await twoWindows(controller)
        Demo.say("PROOF summary: \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
    }

    // PH-H1 = SK-K6: a focus or a resize reloads no pane; a set-query one.
    static func redrawCounter(_ controller: LayoutController) async {
        guard let list = controller.paneWithRole("list"),
              let detail = controller.paneWithRole("detail"),
              var query = controller.tree?.pane(list)?.query.objectValue
        else {
            check("redraw counter", false, "no list/detail pane")
            return
        }
        let runtime = LayoutTreeRuntime.shared
        controller.apply(.focus(target: .id(list)))
        await settle()

        let beforeFocus = runtime.paneResolveCount
        controller.apply(.focus(target: .id(detail)))
        await settle()
        let afterFocus = runtime.paneResolveCount
        check("focus redraws no pane", afterFocus == beforeFocus,
            "pane resolves \(beforeFocus) → \(afterFocus)")

        controller.apply(.resizeShare(pane: list, share: 1.7))
        await settle()
        let afterResize = runtime.paneResolveCount
        check("resize redraws no pane", afterResize == afterFocus,
            "pane resolves \(afterFocus) → \(afterResize)")

        query["limit"] = .int(7)
        let verb = LayoutJSONValue.object([
            "verb": .string("set-query"), "target": LayoutPaneRef.id(list).json,
            "query": .object(query),
        ])
        _ = try? controller.applyVerbJSON(verb.jsonString(), actor: LayoutController.guiActor)
        await settle()
        let afterQuery = runtime.paneResolveCount
        check("set-query redraws exactly one pane", afterQuery == afterResize + 1,
            "pane resolves \(afterResize) → \(afterQuery)")
    }

    // SK-K3: type into the surface's text field, press the button WITHOUT
    // leaving the field, and the button's event carries what was typed.
    // SK-K12: showing the select and date fields sent nothing.
    static func typedValueReachesTheButton(_ window: NSWindow) async {
        guard let id = Demo.surfaceID, let store = Demo.store else { return }
        let before = fields(renderedBy: store, id)
        check("select bound to null stays null after render", before["mode"] == .null,
            "mode = \(String(describing: before["mode"]))")
        check("date-only value is not rewritten on render", before["day"] == .string("2026-09-25"),
            "day = \(String(describing: before["day"]))")

        guard let field = editableTextFields(in: window.contentView).first else {
            check("typed value reaches the button", false, "no text field found")
            return
        }
        window.makeFirstResponder(field)
        await settle(0.3)
        for character in "hello" {
            let text = String(character)
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: 0)
            {
                window.sendEvent(event)
            }
        }
        await settle(0.3)
        let shown = field.currentEditor()?.string ?? field.stringValue
        Demo.say("typed into the Note field: \"\(shown)\" (first responder is a text view: "
            + "\(window.firstResponder is NSText))")

        // D7: ⌘Z while typing is the typing's own undo, not the tree's.
        if let (menu, index) = menuItem(action: NSSelectorFromString("undo:")) {
            let version = LayoutTreeRuntime.shared.controller?.version
            let editor = window.firstResponder as? NSTextView
            Demo.say("while typing: undo target "
                + "\(NSApp.target(forAction: NSSelectorFromString("undo:"), to: nil, from: nil).map { String(describing: type(of: $0)) } ?? "none"), "
                + "editor allowsUndo \(editor?.allowsUndo ?? false), editor undoManager canUndo "
                + "\(editor?.undoManager?.canUndo ?? false), same as window's: "
                + "\(editor?.undoManager === window.undoManager), window canUndo \(window.undoManager?.canUndo ?? false)")
            menu.update()
            menu.performActionForItem(at: index)
            await settle(0.3)
            let undone = field.currentEditor()?.string ?? field.stringValue
            check("Edit ▸ Undo while typing undoes the typing, not the tree",
                undone.count < shown.count && LayoutTreeRuntime.shared.controller?.version == version,
                "\"\(shown)\" → \"\(undone)\", tree version unchanged: "
                    + "\(LayoutTreeRuntime.shared.controller?.version == version)")
            if let (redoMenu, redoIndex) = menuItem(action: NSSelectorFromString("redo:")) {
                redoMenu.update()
                redoMenu.performActionForItem(at: redoIndex)
                await settle(0.3)
            }
            let restored = field.currentEditor()?.string ?? field.stringValue
            Demo.say("Edit ▸ Redo while typing: \"\(restored)\"")
        }

        // Press the button through accessibility — an action, not a mouse
        // click, so focus stays in the field exactly as a click on a
        // SwiftUI button leaves it.
        // SwiftUI's buttons are neither NSButtons nor (in-process, without an
        // assistive client) AX elements, so click where the button is: the
        // spec puts it directly below the date picker.
        guard let picker = views(of: NSDatePicker.self, in: window.contentView).first else {
            check("typed value reaches the button", false, "no date picker to find the button by")
            return
        }
        let below = picker.convert(picker.bounds, to: nil)
        let leading = field.convert(field.bounds, to: nil).minX
        let point = NSPoint(x: leading + 16, y: below.minY - 19)
        Demo.say("clicking at \(point) — hit view: "
            + "\(window.contentView?.hitTest(point).map { String(describing: type(of: $0)) } ?? "none")")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            {
                window.sendEvent(event)
            }
        }
        await settle(1.0)
        let events = self.events(store, id)
        let note = events.last(where: { $0["name"] as? String == "bins-chosen" })
            .flatMap { ($0["payload"] as? [String: Any])?["note"] as? String }
        check("typed value reaches the button", note == "hello",
            "bins-chosen payload note = \(note.map { "\"\($0)\"" } ?? "none") "
                + "(\(events.count) event(s)); still editing: \(window.firstResponder is NSText)")

        let after = fields(renderedBy: store, id)
        Demo.say("state after the click: note = \(String(describing: after["note"]))")
        check("select still unchosen after the click", after["mode"] == .null,
            "mode = \(String(describing: after["mode"]))")
        window.makeFirstResponder(nil)
    }

    // SK-K13: ⌘Z through the Edit menu undoes the focused pane's selection.
    static func undoFromTheEditMenu(_ controller: LayoutController, _ window: NSWindow) async {
        guard let list = controller.paneWithRole("list"),
              let kind = controller.tree?.pane(list)?.queryKinds.first
        else {
            check("Edit ▸ Undo", false, "no list pane")
            return
        }
        // Where a click into the tree leaves AppKit focus: the hosting view.
        window.makeFirstResponder(window.contentView)
        controller.apply(.focus(target: .id(list)))
        let id = UUID().uuidString.lowercased()
        controller.apply(.select(pane: list, kind: kind, ids: [id]))
        await settle()
        let selected = controller.tree?.selection(onChannelOf: list, kind: kind) ?? []

        guard let (menu, index) = menuItem(action: NSSelectorFromString("undo:")) else {
            check("Edit ▸ Undo", false, "no Edit ▸ Undo item in the main menu")
            return
        }
        menu.update()
        let item = menu.items[index]
        Demo.say("responder chain: \(chain(from: window))")
        Demo.say("Edit ▸ Undo target: "
            + "\(NSApp.target(forAction: item.action!, to: nil, from: item).map { String(describing: type(of: $0)) } ?? "none")")
        Demo.say("Edit ▸ \(item.title) (\(item.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")"
            + "\(item.keyEquivalent.uppercased())) enabled: \(item.isEnabled)")
        menu.performActionForItem(at: index)
        await settle()
        let after = controller.tree?.selection(onChannelOf: list, kind: kind) ?? []
        check("Edit ▸ Undo undoes the focused pane's selection",
            selected == [id] && after.isEmpty,
            "selection \(selected.count) → \(after.count)")

        if let (redoMenu, redoIndex) = menuItem(action: NSSelectorFromString("redo:")) {
            redoMenu.update()
            redoMenu.performActionForItem(at: redoIndex)
            await settle()
            let redone = controller.tree?.selection(onChannelOf: list, kind: kind) ?? []
            check("Edit ▸ Redo puts it back", redone == [id], "selection → \(redone.count)")
        }
    }

    // SK-K10 + PH-H3: ⌘N opens a second window with its own controller;
    // closing it leaves the first registered and still the host.
    static func twoWindows(_ first: LayoutController) async {
        guard let (menu, index) = menuItem(titled: "New") else {
            check("two windows", false, "no File ▸ New Window item")
            return
        }
        let windowsBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        menu.performActionForItem(at: index)
        await settle(4)
        let runtime = LayoutTreeRuntime.shared
        let controllers = runtime.controllers
        let second = controllers.first { $0 !== first }
        check("⌘N gives the new window its own controller",
            controllers.count == 2 && second != nil,
            "\(controllers.count) live controllers")
        check("the new window is current and the host",
            runtime.controller === second && Demo.host === second,
            "current is \(runtime.controller === second ? "second" : "first"), host is "
                + (Demo.host === second ? "second" : Demo.host === first ? "first" : "nil"))

        guard let newWindow = NSApp.windows.first(where: {
            $0.isVisible && !windowsBefore.contains(ObjectIdentifier($0))
        }) else {
            check("closing the new window", false, "could not find it")
            return
        }
        newWindow.performClose(nil)
        await settle(2)
        check("closing it leaves the first window registered and the host",
            runtime.controllers.count == 1 && runtime.controller === first && Demo.host === first,
            "\(runtime.controllers.count) live, host is "
                + (Demo.host === first ? "first" : Demo.host == nil ? "nil" : "other"))
        check("the first window's feed is still on", first.isSubscribed, "subscribed: \(first.isSubscribed)")
    }

    // MARK: Helpers

    /// The window as drawn, into `$TMPDIR` — in-process, so no
    /// screen-recording grant is involved.
    static func snapshot(_ window: NSWindow, name: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            Demo.say("window snapshot: \(url.path)")
        }
    }

    /// The surface's fields as a FRESH handle renders them: a new
    /// `SharedSurface` reads the store, not any handle's cache.
    static func fields(renderedBy store: SharedStore, _ id: String) -> [String: LayoutJSONValue] {
        let reply = SharedSurface.open(store: store, host: "")
            .surfaceHttp(method: "GET", path: "/api/surface/\(id)/render", body: "")
        guard let tree = try? LayoutJSONValue.decode(reply.body) else { return [:] }
        var out: [String: LayoutJSONValue] = [:]
        func walk(_ node: LayoutJSONValue) {
            if let body = node["node"], body["kind"]?.stringValue == "field",
               let id = node["id"]?.stringValue {
                out[id] = body["value"] ?? .null
            }
            for key in ["items", "body"] {
                if let items = node["node"]?[key]?.arrayValue { items.forEach(walk) }
                if let child = node["node"]?[key], child.objectValue != nil { walk(child) }
            }
        }
        if let root = tree["root"] { walk(root) }
        return out
    }

    static func events(_ store: SharedStore, _ id: String) -> [[String: Any]] {
        let reply = SharedSurface.open(store: store, host: "")
            .surfaceHttp(method: "GET", path: "/api/surface/\(id)/events", body: "")
        let object = try? JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as? [String: Any]
        return object?["events"] as? [[String: Any]] ?? []
    }

    static var seenRoles: Set<String> = []

    static func views<T: NSView>(of type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews { found += views(of: type, in: subview) }
        return found
    }

    static func chain(from window: NSWindow) -> String {
        var names: [String] = []
        var responder: NSResponder? = window.firstResponder
        while let current = responder, names.count < 12 {
            names.append(String(describing: type(of: current)))
            responder = current.nextResponder
        }
        return names.joined(separator: " → ")
    }

    static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for subview in view.subviews { found += buttons(in: subview) }
        return found
    }

    static func editableTextFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { found.append(field) }
        for subview in view.subviews { found += editableTextFields(in: subview) }
        return found
    }

    static func element(
        in root: Any?, role: NSAccessibility.Role, title: String, depth: Int = 0
    ) -> NSAccessibilityProtocol? {
        guard depth < 60, let node = root as? NSAccessibilityProtocol else { return nil }
        if let seen = node.accessibilityRole() { seenRoles.insert(seen.rawValue) }
        if node.accessibilityRole() == role,
           node.accessibilityTitle() == title || node.accessibilityLabel() == title {
            return node
        }
        let children = node.accessibilityChildren() ?? []
        for child in children {
            if let found = element(in: child, role: role, title: title, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    static func menuItem(action: Selector) -> (NSMenu, Int)? {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            if let index = menu.items.firstIndex(where: { $0.action == action }) {
                return (menu, index)
            }
        }
        return nil
    }

    static func menuItem(titled prefix: String) -> (NSMenu, Int)? {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            if let index = menu.items.firstIndex(where: {
                $0.title.hasPrefix(prefix) && $0.keyEquivalent == "n"
                    && $0.keyEquivalentModifierMask == .command
            }) {
                return (menu, index)
            }
        }
        return nil
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
            LayoutTreeHost(appID: Demo.appID, services: Demo.services)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    // Only the first window reports.
                    guard LayoutTreeRuntime.shared.controllers.count <= 1 else { return }
                    await Demo.report()
                }
        }
    }
}
