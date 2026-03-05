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
    /// We assign this directly to viewContext.undoManager so Core Data
    /// tracks mutations on the same UndoManager that Cmd+Z targets.
    public var undoManager: UndoManager? {
        didSet { syncUndoState() }
    }

    /// Bridge: assign the window's UndoManager to Core Data's viewContext
    /// so that mutations register on the UndoManager that the Edit menu sees.
    private func syncUndoState() {
        let context = ImprintPersistenceController.shared.viewContext
        if let um = undoManager {
            um.levelsOfUndo = 50
            context.undoManager = um
        } else {
            context.undoManager = nil
        }
    }

    private init() {}
}
