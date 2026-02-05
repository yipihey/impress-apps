//
//  OperationRegistry.swift
//  ImpressOperationQueue
//
//  Generic registry for tracking entities and their pending operations.
//

import Foundation
import SwiftUI
import OSLog

/// Generic registry for tracking entities and their pending operations.
///
/// Usage:
/// ```swift
/// // App defines its operation type
/// enum DocumentOperation: QueueableOperation { ... }
///
/// // App creates registry singleton
/// @MainActor
/// final class DocumentRegistry: OperationRegistry<UUID, DocumentOperation, MyDocument> {
///     static let shared = DocumentRegistry()
/// }
/// ```
@MainActor @Observable
open class OperationRegistry<EntityID: Hashable & Sendable, Operation: QueueableOperation, Entity> {

    /// Registered entities by ID
    public var entitiesById: [EntityID: Entity] = [:]

    /// Pending operations per entity
    public var pendingOperations: [EntityID: [Operation]] = [:]

    /// Counter incremented on each queue, triggers SwiftUI observation
    public private(set) var operationQueueCounter: Int = 0

    /// Logger for this registry
    private let logger: Logger

    public init(subsystem: String, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    /// Register an entity.
    open func register(_ entity: Entity, id: EntityID) {
        entitiesById[id] = entity
    }

    /// Unregister an entity and clear its pending operations.
    open func unregister(id: EntityID) {
        entitiesById.removeValue(forKey: id)
        pendingOperations.removeValue(forKey: id)
    }

    /// Queue an operation for an entity.
    public func queueOperation(_ operation: Operation, for entityId: EntityID) {
        var ops = pendingOperations[entityId] ?? []
        ops.append(operation)
        pendingOperations[entityId] = ops
        operationQueueCounter += 1
        logger.info("Queued operation for \(String(describing: entityId)): \(operation.operationDescription)")
    }

    /// Pop the next pending operation (FIFO).
    public func popOperation(for entityId: EntityID) -> Operation? {
        guard var ops = pendingOperations[entityId], !ops.isEmpty else {
            return nil
        }
        let op = ops.removeFirst()
        if ops.isEmpty {
            pendingOperations.removeValue(forKey: entityId)
        } else {
            pendingOperations[entityId] = ops
        }
        return op
    }

    /// Check if entity has pending operations.
    public func hasPendingOperations(for entityId: EntityID) -> Bool {
        guard let ops = pendingOperations[entityId] else { return false }
        return !ops.isEmpty
    }

    /// Get entity by ID.
    public func entity(withId id: EntityID) -> Entity? {
        entitiesById[id]
    }

    /// All registered entities.
    public var allEntities: [Entity] {
        Array(entitiesById.values)
    }

    /// Count of all pending operations across all entities.
    public var totalPendingOperations: Int {
        pendingOperations.values.reduce(0) { $0 + $1.count }
    }

    /// All entity IDs with pending operations.
    public var entitiesWithPendingOperations: [EntityID] {
        Array(pendingOperations.keys)
    }
}
