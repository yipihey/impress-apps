//
//  ImpartUndoCoordinator.swift
//  MessageManagerCore
//
//  Bridges Core Data's viewContext undoManager with the SwiftUI window's
//  undo manager. Conforms to UndoRegistering for shared wireUndo modifier.
//
//  Core Data's viewContext.undoManager automatically tracks all object graph
//  changes for folder CRUD and message triage operations.
//

import Foundation
import ImpressKit

@MainActor
@Observable
public final class ImpartUndoCoordinator: UndoRegistering {
    public static let shared = ImpartUndoCoordinator()

    /// The window's UndoManager, set by wireUndo modifier.
    public var undoManager: UndoManager? {
        didSet {
            syncUndoState()
        }
    }

    /// The Core Data viewContext's undo manager.
    private var coreDataUndoManager: UndoManager? {
        PersistenceController.shared.viewContext.undoManager
    }

    /// Sync undo/redo availability from Core Data to the window.
    private func syncUndoState() {
        // Core Data's viewContext.undoManager is the authoritative source.
        // The window's undo manager routes through the NSResponder chain,
        // so when the message list or folder sidebar has focus, Cmd+Z triggers
        // the Core Data undo manager's undo operation.
    }

    private init() {}
}
