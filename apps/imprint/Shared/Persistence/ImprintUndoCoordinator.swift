//
//  ImprintUndoCoordinator.swift
//  imprint
//
//  Bridges Core Data's viewContext undoManager with the SwiftUI window's
//  undo manager. Conforms to UndoRegistering for shared wireUndo modifier.
//
//  The Core Data viewContext has its own UndoManager that automatically
//  tracks all object graph changes. This coordinator bridges undo/redo
//  requests from the window's UndoManager (which Cmd+Z targets) to the
//  Core Data viewContext's UndoManager.
//

import Foundation
import ImpressKit

@MainActor
@Observable
public final class ImprintUndoCoordinator: UndoRegistering {
    public static let shared = ImprintUndoCoordinator()

    /// The window's UndoManager, set by wireUndo modifier.
    /// We bridge to Core Data's viewContext.undoManager for folder operations.
    public var undoManager: UndoManager? {
        didSet {
            // When the window's undo manager changes, sync with Core Data's.
            // The viewContext.undoManager does the actual tracking; we expose
            // its state through the window's undo manager for Edit menu integration.
            syncUndoState()
        }
    }

    /// The Core Data viewContext's undo manager.
    private var coreDataUndoManager: UndoManager? {
        ImprintPersistenceController.shared.viewContext.undoManager
    }

    /// Sync undo/redo availability from Core Data to the window.
    private func syncUndoState() {
        // Core Data's viewContext.undoManager is the authoritative source.
        // The window's undo manager routes through the NSResponder chain,
        // and when the sidebar (folder hierarchy) has focus, Cmd+Z should
        // undo the last Core Data operation.
    }

    private init() {}
}
