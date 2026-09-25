#if os(macOS)
// Kit file (ImpressLayout) — macOS-only. Plan wave 7, T3.
//
//  LayoutTreeRuntime.swift
//  ImpressLayout
//
//  What the kit knows about its WINDOWS: which layout controllers are live in
//  this process, which one belongs to the key window, and how ⌘Z from the
//  Edit menu reaches that window's tree.
//
//  ## Several windows per process (SK-K10, PH-H3)
//
//  Every chassis app is a `WindowGroup`, so ⌘N opens a second window with a
//  second `LayoutTreeHost` and a second `LayoutController`. Until wave 7 the
//  runtime held ONE pointer, last writer wins, and any window's close set it
//  to nil — so after ⌘N and closing the new window, the window still on
//  screen had dead ⌃⌘ chords and its HTTP automation answered 409 "no tree"
//  while a tree was rendering. Now:
//
//  - every host registers its controller while its window is attached and
//    unregisters it when the window goes away — by IDENTITY, so closing one
//    window never unregisters another;
//  - `controller` is the key window's controller, falling back to the most
//    recently opened live one;
//  - the host hears `didOpen` for whichever controller is current — when it
//    opens, when its window becomes key, and when the window that was current
//    closes and this one takes over. `didClose` is always followed by the
//    current controller's `didOpen` while any tree is still open, so a host
//    whose `didClose` clears a single "the host" slot (PublicationManagerCore
//    sets `LayoutAutomation.shared.host = nil` there) gets it back at once.
//
//  ## ⌘Z through the Edit menu (SK-K13)
//
//  Edit ▸ Undo's ⌘Z is a menu key equivalent, and AppKit handles those
//  before any SwiftUI `.onKeyPress`, so a key handler on the tree root never
//  saw plain ⌘Z at all. The menu item sends `undo:` down the responder chain
//  instead. `LayoutWindowResponder` sits in that chain for each tree window —
//  between the window's content view and the `NSWindow`, whose own `undo:`
//  answers from its undo manager — and routes the chord per ADR-0031 D7
//  (`LayoutController.routeUndoChord`). What it does not take, it passes on
//  to the window, so typing and editor sessions keep their own undo exactly
//  as before. No app has to mount a `Commands` for this.
//

import AppKit
import Foundation
import ImpressLogging
import ObjectiveC
import SwiftUI

// MARK: - The runtime

/// The live layout controllers of this process, for the menu chords and the
/// host's automation registration. It holds no layout state of its own: it
/// is a set of pointers to the objects that ask Rust.
@MainActor
public final class LayoutTreeRuntime {
    public static let shared = LayoutTreeRuntime()

    /// The startup render-loop guard's length (CLAUDE.md, ADR-0019 D6).
    public static let startupGraceSecs: TimeInterval = 90

    /// When the runtime was first touched — the first tree host, which opens
    /// at launch. What `remainingStartupGrace` counts from.
    let launchedAt: Date

    private struct Entry {
        weak var controller: LayoutController?
        let id: ObjectIdentifier
        let services: LayoutHostServices
    }

    /// Live controllers, oldest first.
    private var entries: [Entry] = []
    private weak var current: LayoutController?

    /// Internal so tests get a runtime of their own; the process uses
    /// `shared`.
    init(launchedAt: Date = Date()) {
        self.launchedAt = launchedAt
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PaneSessionRegistries.flushAll(reason: "app terminating") }
        }
    }

    /// The controller the chords act on: the key window's tree, else the
    /// most recently opened one still live, else nil.
    public var controller: LayoutController? {
        prune()
        if let current, entries.contains(where: { $0.id == ObjectIdentifier(current) }) {
            return current
        }
        return entries.last?.controller
    }

    /// Every live controller, oldest first.
    public var controllers: [LayoutController] {
        prune()
        return entries.compactMap(\.controller)
    }

    /// Whole seconds left of the launch grace, 0 once it is over. A window
    /// opened ten minutes in must not sit deaf to invalidations for 90 s.
    public func remainingStartupGrace(now: Date = Date()) -> UInt32 {
        let left = Self.startupGraceSecs - now.timeIntervalSince(launchedAt)
        return left > 0 ? UInt32(left.rounded(.up)) : 0
    }

    /// A window's controller is attached. The newest window is the key one,
    /// so it becomes current and its host hears `didOpen`.
    public func register(_ controller: LayoutController, services: LayoutHostServices) {
        prune()
        let id = ObjectIdentifier(controller)
        guard !entries.contains(where: { $0.id == id }) else {
            makeCurrent(controller)
            return
        }
        entries.append(Entry(controller: controller, id: id, services: services))
        logInfo(
            "layout runtime: \(controller.appID) tree attached (\(entries.count) live)",
            category: "layout")
        makeCurrent(controller, force: true)
    }

    /// A window's controller is going away. Only THIS controller leaves; the
    /// host hears `didClose` for it and then, if any tree is still open,
    /// `didOpen` for the one now current.
    public func unregister(_ controller: LayoutController) {
        let id = ObjectIdentifier(controller)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        prune()
        entry.services.didClose(controller)
        let wasCurrent = current === controller
        if wasCurrent { current = nil }
        logInfo(
            "layout runtime: \(controller.appID) tree detached (\(entries.count) live)",
            category: "layout")
        if let survivor = self.controller {
            // Re-announce even when the survivor was already current: the
            // host's `didClose` may have cleared a single-slot registration
            // that belonged to it.
            makeCurrent(survivor, force: true)
        }
    }

    /// `controller`'s window became key.
    public func makeCurrent(_ controller: LayoutController) {
        makeCurrent(controller, force: false)
    }

    private func makeCurrent(_ controller: LayoutController, force: Bool) {
        guard let entry = entries.first(where: { $0.id == ObjectIdentifier(controller) }) else {
            return
        }
        guard force || current !== controller else { return }
        current = controller
        entry.services.didOpen(controller)
    }

    private func prune() {
        entries.removeAll { $0.controller == nil }
    }
}

// MARK: - Session registries (SK-K23)

/// Every `PaneSessionRegistry` in the process, type-erased, so the kit can
/// release the session of a pane a verb closed and flush all of them when the
/// app terminates — the two calls the registry documented and nothing made.
@MainActor
enum PaneSessionRegistries {

    private final class Box {
        weak var registry: AnyObject?
        let release: @MainActor (String) -> Void
        let flushAll: @MainActor () -> Void
        init(
            _ registry: AnyObject, release: @escaping @MainActor (String) -> Void,
            flushAll: @escaping @MainActor () -> Void
        ) {
            self.registry = registry
            self.release = release
            self.flushAll = flushAll
        }
    }

    private static var boxes: [Box] = []

    static func add<Session: PaneSession>(_ registry: PaneSessionRegistry<Session>) {
        boxes.append(
            Box(
                registry,
                release: { [weak registry] id in registry?.release(id: id) },
                flushAll: { [weak registry] in registry?.flushAll() }))
    }

    /// Release (flush, then drop) every session with one of these ids, in
    /// whichever registry holds it. A registry without the id ignores it.
    static func release(_ ids: [String]) {
        boxes.removeAll { $0.registry == nil }
        for id in ids {
            for box in boxes { box.release(id) }
        }
    }

    static func flushAll(reason: String) {
        boxes.removeAll { $0.registry == nil }
        guard !boxes.isEmpty else { return }
        logInfo("pane sessions: flushing \(boxes.count) registries (\(reason))", category: "layout")
        for box in boxes { box.flushAll() }
    }
}

// MARK: - The window's responder

/// Sits in one tree window's responder chain, between the content view and
/// the `NSWindow`, and routes ⌘Z / ⇧⌘Z / ⌥⌘Z / ⌥⇧⌘Z to that window's tree.
/// See the file header.
@MainActor
final class LayoutWindowResponder: NSResponder {

    weak var controller: LayoutController?
    weak var window: NSWindow?

    private static var associationKey: UInt8 = 0

    /// Install (or re-point) the responder for `window`. Idempotent: it is
    /// retained by the window itself, because `nextResponder` does not
    /// retain, and re-spliced if something replaced the content view's next
    /// responder since.
    @discardableResult
    static func install(in window: NSWindow, controller: LayoutController) -> LayoutWindowResponder {
        let responder: LayoutWindowResponder
        if let existing = objc_getAssociatedObject(window, &associationKey) as? LayoutWindowResponder {
            responder = existing
        } else {
            responder = LayoutWindowResponder()
            objc_setAssociatedObject(
                window, &associationKey, responder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        responder.controller = controller
        responder.window = window
        if let content = window.contentView, content.nextResponder !== responder {
            responder.nextResponder = content.nextResponder
            content.nextResponder = responder
            logInfo(
                "layout: undo routing installed in window \(window.windowNumber) for "
                    + "\(controller.appID)",
                category: "layout")
        }
        return responder
    }

    /// What the chord would do: is a text view taking keystrokes?
    private var textIsFirstResponder: Bool {
        window?.firstResponder is NSText
    }

    @objc func undo(_ sender: Any?) {
        route(redo: false, sender: sender)
    }

    @objc func redo(_ sender: Any?) {
        route(redo: true, sender: sender)
    }

    private func route(redo: Bool, sender: Any?) {
        if let controller,
           controller.routeUndoChord(redo: redo, textIsFirstResponder: textIsFirstResponder) {
            return
        }
        passOn(redo: redo, sender: sender)
    }

    /// Hand the chord to the rest of the chain — the window, whose `undo:`
    /// answers from its undo manager, exactly as if this responder were not
    /// here.
    private func passOn(redo: Bool, sender: Any?) {
        let selector = redo ? #selector(redo(_:)) : #selector(undo(_:))
        if nextResponder?.tryToPerform(selector, with: sender) == true { return }
        guard let manager = window?.undoManager else { return }
        if redo, manager.canRedo {
            manager.redo()
        } else if !redo, manager.canUndo {
            manager.undo()
        }
    }

    /// Edit ▸ Undo / Redo stay enabled while the tree may have something to
    /// undo; when the chord belongs to the chain, the chain's answer stands.
    @objc func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action,
              action == #selector(undo(_:)) || action == #selector(redo(_:))
        else { return false }
        guard let controller else { return false }
        if textIsFirstResponder || controller.focusedPaneIsSessionBearing {
            let manager = window?.undoManager
            return action == #selector(undo(_:))
                ? (manager?.canUndo ?? false) : (manager?.canRedo ?? false)
        }
        return true
    }

    /// The chords as KEYS, for when no menu item claims them (an app with no
    /// Edit ▸ Undo) and for the arrangement ring, which has no menu item:
    /// an unhandled ⌘Z-family keyDown reaches here on its way to the window.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z",
              let controller
        else {
            super.keyDown(with: event)
            return
        }
        let redo = flags.contains(.shift)
        if flags.contains(.option) {
            if redo { controller.redoArrangement() } else { controller.undoArrangement() }
            return
        }
        route(redo: redo, sender: nil)
    }
}

// MARK: - The window anchor

/// An invisible AppKit view in the tree window that knows which `NSWindow`
/// the tree is in: it installs that window's `LayoutWindowResponder` and
/// makes the controller current whenever the window becomes key.
struct LayoutWindowAnchor: NSViewRepresentable {

    let controller: LayoutController

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.controller = controller
    }

    @MainActor
    final class AnchorView: NSView {
        weak var controller: LayoutController? {
            didSet { attach() }
        }
        private var keyObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        private func attach() {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
                self.keyObserver = nil
            }
            guard let window, let controller else { return }
            LayoutWindowResponder.install(in: window, controller: controller)
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, let controller = self.controller
                    else { return }
                    // Re-splice: SwiftUI may have rebuilt the content view's
                    // chain since.
                    LayoutWindowResponder.install(in: window, controller: controller)
                    LayoutTreeRuntime.shared.makeCurrent(controller)
                }
            }
            if window.isKeyWindow {
                LayoutTreeRuntime.shared.makeCurrent(controller)
            }
        }

        // Clicks pass through to the tree.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
