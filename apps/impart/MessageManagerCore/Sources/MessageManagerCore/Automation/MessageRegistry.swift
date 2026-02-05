//
//  MessageRegistry.swift
//  MessageManagerCore
//
//  Registry for tracking pending message operations.
//  Uses the shared ImpressOperationQueue infrastructure.
//

import Foundation
import ImpressOperationQueue

/// Empty entity type for messages since Core Data objects shouldn't be cached.
/// The registry only tracks operations by UUID; actual message lookups go through
/// the message repository.
public struct MessageRef: Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

/// Registry for tracking pending message automation operations.
/// Extends the generic OperationRegistry with impart-specific functionality.
///
/// Note: We don't cache full entities here because CDMessage objects are Core Data
/// managed objects that should be fetched through the message repository.
/// This registry only tracks operations.
@MainActor
public final class MessageRegistry: OperationRegistry<UUID, MessageOperation, MessageRef> {
    public static let shared = MessageRegistry()

    private init() {
        super.init(subsystem: "com.imbib.impart", category: "registry")
    }

    /// Queue an operation for a message by its UUID.
    public func queueOperation(_ operation: MessageOperation, forMessageID id: UUID) {
        queueOperation(operation, for: id)
    }

    /// Pop the next pending operation for a message.
    public func popOperation(forMessageID id: UUID) -> MessageOperation? {
        popOperation(for: id)
    }

    /// Check if there are pending operations for a message.
    public func hasPendingOperations(forMessageID id: UUID) -> Bool {
        hasPendingOperations(for: id)
    }
}
