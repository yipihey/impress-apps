//
//  ImpelUndoCoordinator.swift
//  CounselEngine
//
//  Snapshot-based undo coordinator for GRDB persistence.
//
//  GRDB has no built-in undo support. This coordinator captures state before
//  mutations and registers compensating closures with the system UndoManager.
//  The snapshot is captured at the service layer, not inside CounselDatabase,
//  to keep the database layer clean and testable.
//
//  Undoable: conversation rename/delete, standing order edits, task title edits.
//  Not undoable: agent task execution, agent messages (external side effects).
//

import Foundation
import ImpressKit

@MainActor
@Observable
public final class ImpelUndoCoordinator: UndoRegistering {
    public static let shared = ImpelUndoCoordinator()

    /// The window's UndoManager, set by wireUndo modifier.
    public var undoManager: UndoManager?

    /// Register an undoable action with a compensating closure.
    ///
    /// The caller must capture the previous state before performing the mutation,
    /// then pass a closure that restores that state.
    ///
    /// Example:
    /// ```swift
    /// let oldConversation = try db.fetchConversation(id: id)
    /// try db.updateConversation(newConversation)
    /// ImpelUndoCoordinator.shared.registerUndo(
    ///     actionName: "Rename Conversation"
    /// ) {
    ///     if let old = oldConversation {
    ///         try db.updateConversation(old)
    ///     }
    /// }
    /// ```
    public func registerUndo(
        actionName: String,
        compensate: @escaping @Sendable () throws -> Void
    ) {
        guard let um = undoManager else { return }

        um.registerUndo(withTarget: self) { [weak self] coordinator in
            guard let self = coordinator as? ImpelUndoCoordinator else { return }
            Task { @MainActor in
                do {
                    try compensate()
                    // Register redo (undo the undo) — the caller should
                    // capture state again if redo is needed. For simplicity,
                    // we don't auto-register redo for GRDB operations.
                } catch {
                    // Log but don't crash — undo is best-effort
                    print("[ImpelUndo] Failed to undo '\(actionName)': \(error)")
                }
            }
        }

        um.setActionName(actionName)
    }

    /// Register an undoable action with an async compensating closure.
    public func registerUndoAsync(
        actionName: String,
        compensate: @escaping @Sendable () async throws -> Void
    ) {
        guard let um = undoManager else { return }

        um.registerUndo(withTarget: self) { [weak self] coordinator in
            guard let self = coordinator as? ImpelUndoCoordinator else { return }
            Task { @MainActor in
                do {
                    try await compensate()
                } catch {
                    print("[ImpelUndo] Failed to undo '\(actionName)': \(error)")
                }
            }
        }

        um.setActionName(actionName)
    }

    private init() {}
}
