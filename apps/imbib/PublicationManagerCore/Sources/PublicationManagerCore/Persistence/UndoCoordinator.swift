import Foundation
import ImbibRustCore
import OSLog

/// Coordinates undo/redo with the system UndoManager and the Rust operation log.
///
/// Usage:
/// 1. Set `undoManager` from the SwiftUI environment (in ContentView).
/// 2. After each mutation on RustStoreAdapter, call `registerUndo(info:)`.
/// 3. macOS automatically wires Cmd+Z / Cmd+Shift+Z through the responder chain.
@MainActor
@Observable
public final class UndoCoordinator {
    public static let shared = UndoCoordinator()

    /// The window's UndoManager, set by the root view via @Environment(\.undoManager).
    public var undoManager: UndoManager?

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

                // Register redo (the inverse of the undo)
                if let redoInfo {
                    self.registerUndo(info: redoInfo)
                }
            }
        }

        um.setActionName(description)
    }

    private init() {}
}
