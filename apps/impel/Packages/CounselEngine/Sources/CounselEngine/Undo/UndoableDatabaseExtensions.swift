//
//  UndoableDatabaseExtensions.swift
//  CounselEngine
//
//  Convenience extensions for performing undoable mutations on CounselDatabase.
//  Each method snapshots the previous state, performs the mutation, and registers
//  an undo action with ImpelUndoCoordinator.
//
//  These are the entry points for user-initiated mutations that should be undoable.
//  Agent-driven mutations (TaskOrchestrator) should NOT use these methods.
//

import Foundation

extension CounselDatabase {

    /// Update a conversation with undo support.
    /// Snapshots the current conversation before applying the update.
    @MainActor
    public func updateConversationUndoable(_ conversation: CounselConversation) throws {
        let oldConversation = try fetchConversation(id: conversation.id)

        try updateConversation(conversation)

        if let old = oldConversation {
            ImpelUndoCoordinator.shared.registerUndo(actionName: "Edit Conversation") { [weak self] in
                try self?.updateConversation(old)
            }
        }
    }

    /// Update a standing order with undo support.
    @MainActor
    public func updateStandingOrderUndoable(_ order: StandingOrder) throws {
        // Snapshot the current state
        let oldOrders = try fetchActiveStandingOrders()
        let oldOrder = oldOrders.first { $0.id == order.id }

        try updateStandingOrder(order)

        if let old = oldOrder {
            ImpelUndoCoordinator.shared.registerUndo(actionName: "Edit Standing Order") { [weak self] in
                try self?.updateStandingOrder(old)
            }
        }
    }

    /// Delete a conversation with undo support.
    /// Snapshots the conversation and all its messages before deletion.
    @MainActor
    public func deleteConversationUndoable(id: String) throws {
        guard let conversation = try fetchConversation(id: id) else { return }
        let messages = try fetchMessages(conversationID: id)
        let toolExecutions = try fetchToolExecutions(conversationID: id)

        try deleteConversation(id: id)

        ImpelUndoCoordinator.shared.registerUndo(actionName: "Delete Conversation") { [weak self] in
            guard let self else { return }
            try self.createConversation(conversation)
            for message in messages {
                try self.addMessage(message)
            }
            for execution in toolExecutions {
                try self.addToolExecution(execution)
            }
        }
    }
}
