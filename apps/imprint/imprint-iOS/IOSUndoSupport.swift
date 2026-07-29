//
//  IOSUndoSupport.swift
//  imprint-iOS
//
//  Undo on iOS, for a store-backed app.
//
//  GUI-meld Phase 8 replaced `DocumentGroup` with `WindowGroup` (the library
//  fronts the store, not the system document browser). On iOS, only
//  `DocumentGroup` populates `\.undoManager` — so from that commit on, the
//  editor's Undo/Redo buttons were permanently disabled and shake-to-undo
//  could only ever reach the focused `UITextView`'s own stack, never a
//  library-level delete or dismiss.
//
//  This restores both halves:
//
//  * `sceneUndoManager` is one `UndoManager` per scene, injected into the
//    SwiftUI environment so `@Environment(\.undoManager)` resolves and the
//    buttons enable.
//  * `undoResponderBridge()` puts that SAME manager on the UIKit RESPONDER
//    chain. Shake-to-undo asks the first responder for its `undoManager` and
//    walks up; without a responder vending ours, a shake over the library
//    does nothing. Text editing keeps working as before: while a text view is
//    first responder it vends its own manager, which is the correct
//    precedence.
//

import SwiftUI
import UIKit

// MARK: - Scene undo manager

/// One `UndoManager` per scene, shared by the SwiftUI environment and the
/// responder chain so both halves of undo address the same stack.
@MainActor
final class SceneUndoManager {
    static let shared = SceneUndoManager()
    let manager: UndoManager = {
        let m = UndoManager()
        // Matches the macOS chassis default (KeyboardShortcutsSettings /
        // UndoCoordinator.maxUndoLevels) so a manuscript behaves the same on
        // both platforms.
        m.levelsOfUndo = 50
        return m
    }()
    private init() {}
}

// MARK: - Responder-chain bridge

/// A zero-size view whose backing `UIViewController` vends the scene's
/// `UndoManager` to the responder chain, enabling shake-to-undo for actions
/// that are not text edits.
struct UndoResponderBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UndoHostingController {
        UndoHostingController()
    }

    func updateUIViewController(_ controller: UndoHostingController, context: Context) {}
}

/// Vends the scene undo manager and can become first responder so a shake
/// reaches it when no text view is focused.
final class UndoHostingController: UIViewController {
    override var undoManager: UndoManager? { SceneUndoManager.shared.manager }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Only claim first responder when nothing else wants it — becoming
        // first responder over a focused text view would steal the keyboard.
        if view.window?.firstResponder == nil {
            becomeFirstResponder()
        }
    }
}

extension View {
    /// Put the scene undo manager on the UIKit responder chain.
    ///
    /// `\.undoManager` is a READ-ONLY key path — SwiftUI derives it from the
    /// responder chain and it cannot be injected with `.environment(...)`.
    /// So the responder bridge is not merely the shake half of the fix: it is
    /// also what makes `@Environment(\.undoManager)` resolve at all under
    /// `WindowGroup`, which is what re-enables the editor's Undo/Redo buttons.
    func undoEnabled() -> some View {
        background(UndoResponderBridge().frame(width: 0, height: 0))
    }
}

// MARK: - First-responder lookup

extension UIWindow {
    /// The current first responder in this window, if any.
    fileprivate var firstResponder: UIResponder? {
        guard let root = rootViewController?.view else { return nil }
        return Self.firstResponder(in: root)
    }

    private static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }
}
