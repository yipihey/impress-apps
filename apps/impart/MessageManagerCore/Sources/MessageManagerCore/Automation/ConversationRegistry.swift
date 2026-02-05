//
//  ConversationRegistry.swift
//  MessageManagerCore
//
//  Registry for tracking pending research conversation operations.
//  Uses the shared ImpressOperationQueue infrastructure.
//

import Foundation
import ImpressOperationQueue

/// Reference type for research conversations since Core Data objects shouldn't be cached.
/// The registry only tracks operations by UUID; actual conversation lookups go through
/// ResearchConversationRepository.
public struct ConversationRef: Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

/// Registry for tracking pending research conversation automation operations.
/// Extends the generic OperationRegistry with impart-specific functionality.
///
/// Note: We don't cache full entities here because CDResearchConversation objects are
/// Core Data managed objects that should be fetched through ResearchConversationRepository.
/// This registry only tracks operations.
@MainActor
public final class ConversationRegistry: OperationRegistry<UUID, ConversationOperation, ConversationRef> {
    public static let shared = ConversationRegistry()

    private init() {
        super.init(subsystem: "com.imbib.impart", category: "conversation-registry")
    }

    /// Queue an operation for a conversation by its UUID.
    public func queueOperation(_ operation: ConversationOperation, forConversationID id: UUID) {
        queueOperation(operation, for: id)
    }

    /// Pop the next pending operation for a conversation.
    public func popOperation(forConversationID id: UUID) -> ConversationOperation? {
        popOperation(for: id)
    }

    /// Check if there are pending operations for a conversation.
    public func hasPendingOperations(forConversationID id: UUID) -> Bool {
        hasPendingOperations(for: id)
    }
}
