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
    /// We assign this directly to viewContext.undoManager so Core Data
    /// tracks mutations on the same UndoManager that Cmd+Z targets.
    public var undoManager: UndoManager? {
        didSet { syncUndoState() }
    }

    /// Bridge: assign the window's UndoManager to Core Data's viewContext
    /// so that mutations register on the UndoManager that the Edit menu sees.
    private func syncUndoState() {
        let context = PersistenceController.shared.viewContext
        if let um = undoManager {
            um.levelsOfUndo = 50
            context.undoManager = um
        } else {
            context.undoManager = nil
        }
    }

    private init() {}
}
