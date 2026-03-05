//
//  UndoRegistering.swift
//  ImpressKit
//
//  Shared protocol and view modifier for wiring NSUndoManager
//  across all impress apps. Each app creates its own coordinator
//  conforming to UndoRegistering; the wireUndo modifier handles
//  the SwiftUI environment plumbing.
//

import SwiftUI

/// Protocol for app-specific undo coordinators.
///
/// Each impress app creates its own coordinator (e.g., `UndoCoordinator` in imbib,
/// `ImprintUndoCoordinator` in imprint) that conforms to this protocol. The shared
/// `.wireUndo(to:)` modifier connects the SwiftUI `@Environment(\.undoManager)` to the
/// coordinator automatically.
@MainActor
public protocol UndoRegistering: AnyObject {
    /// The window's UndoManager, set by the root view via @Environment(\.undoManager).
    var undoManager: UndoManager? { get set }
}

// MARK: - View Modifier

/// Wires `@Environment(\.undoManager)` to an `UndoRegistering` coordinator.
///
/// Replaces the per-app `.onAppear { coordinator.undoManager = undoManager }`
/// + `.onChange(of: undoManager) { ... }` boilerplate.
public struct UndoWiringModifier: ViewModifier {
    @Environment(\.undoManager) private var undoManager
    let coordinator: UndoRegistering

    public init(coordinator: UndoRegistering) {
        self.coordinator = coordinator
    }

    public func body(content: Content) -> some View {
        content
            .onAppear {
                coordinator.undoManager = undoManager
            }
            .onChange(of: undoManager) { _, newValue in
                coordinator.undoManager = newValue
            }
    }
}

public extension View {
    /// Wire the SwiftUI undo manager to an app-specific undo coordinator.
    ///
    /// Usage:
    /// ```swift
    /// ContentView()
    ///     .wireUndo(to: UndoCoordinator.shared)
    /// ```
    func wireUndo(to coordinator: UndoRegistering) -> some View {
        modifier(UndoWiringModifier(coordinator: coordinator))
    }
}
