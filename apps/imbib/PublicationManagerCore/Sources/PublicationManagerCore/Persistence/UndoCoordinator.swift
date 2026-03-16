import Foundation
import ImbibRustCore
import ImpressKit
import ImpressUndoHistory
import OSLog

/// Coordinates undo/redo with the system UndoManager and the Rust operation log.
///
/// Usage:
/// 1. Wire via `.wireUndo(to: UndoCoordinator.shared)` in ContentView.
/// 2. After each mutation on RustStoreAdapter, call `registerUndo(info:)`.
/// 3. macOS automatically wires Cmd+Z / Cmd+Shift+Z through the responder chain.
@MainActor
@Observable
public final class UndoCoordinator: UndoRegistering {
    public static let shared = UndoCoordinator()

    /// The window's UndoManager, set by the root view via @Environment(\.undoManager).
    public var undoManager: UndoManager? {
        didSet {
            undoManager?.levelsOfUndo = maxUndoLevels
        }
    }

    /// Maximum undo levels, synced from app settings.
    public var maxUndoLevels: Int = 50 {
        didSet {
            undoManager?.levelsOfUndo = maxUndoLevels
            UndoHistoryStore.shared.maxEntries = maxUndoLevels
        }
    }

    /// Register an undoable action after a mutation completes.
    ///
    /// The `info` parameter comes from the Rust store's mutation return value.
    /// When the user presses Cmd+Z, the inverse operation is applied through
    /// RustStoreAdapter, and a redo action is registered automatically.
    public func registerUndo(info: UndoInfo) {
        guard let um = undoManager else { return }
        guard !info.operationIds.isEmpty else { return }

        let batchId = info.batchId
        let operationIds = info.operationIds
        let description = info.description

        um.registerUndo(withTarget: self) { [weak self] coordinator in
            guard let self = coordinator as? UndoCoordinator else { return }
            Task { @MainActor in
                let adapter = RustStoreAdapter.shared
                let redoInfo: UndoInfo?

                if let batchId {
                    redoInfo = adapter.undoBatch(batchId: batchId)
                } else if let opId = operationIds.first {
                    redoInfo = adapter.undoOperation(operationId: opId)
                } else {
                    return
                }

                UndoHistoryStore.shared.didUndo()

                // Register redo (the inverse of the undo)
                if let redoInfo {
                    self.registerUndo(info: redoInfo)
                }
            }
        }

        um.setActionName(description)

        // Record to undo history panel
        UndoHistoryStore.shared.recordAction(UndoHistoryEntry(
            actionName: description,
            operationCount: operationIds.count,
            batchId: batchId,
            author: "user:local",
            authorKind: .human
        ))
    }

    /// Register a closure-based undo action for insert/delete operations
    /// that bypass the operation log.
    ///
    /// The `undo` closure performs the compensating action. To support redo,
    /// pass a `redo` closure; when the undo fires, a redo is registered automatically.
    public func registerUndoClosure(
        actionName: String,
        undo undoClosure: @escaping @MainActor () -> Void,
        redo redoClosure: (@MainActor () -> Void)? = nil
    ) {
        guard let um = undoManager else { return }

        um.registerUndo(withTarget: self) { [weak self] _ in
            Task { @MainActor in
                undoClosure()
                UndoHistoryStore.shared.didUndo()
                // Register redo if provided
                if let redo = redoClosure, let self {
                    self.registerUndoClosure(actionName: actionName, undo: redo, redo: undoClosure)
                }
            }
        }

        um.setActionName(actionName)

        // Record to undo history panel
        UndoHistoryStore.shared.recordAction(UndoHistoryEntry(
            actionName: actionName,
            author: "user:local",
            authorKind: .human
        ))
    }

    private init() {}
}
