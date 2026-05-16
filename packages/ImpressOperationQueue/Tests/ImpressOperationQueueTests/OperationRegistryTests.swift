//
//  OperationRegistryTests.swift
//  ImpressOperationQueueTests
//
//  Tests for OperationRegistry queue behavior.
//

import Testing
import Foundation
@testable import ImpressOperationQueue

// MARK: - Test Types

/// Test operation type
enum TestOperation: QueueableOperation {
    case update(value: String)
    case delete
    case transform(from: Int, to: Int)

    var id: UUID { UUID() }

    var operationDescription: String {
        switch self {
        case .update(let value): return "update(\(value))"
        case .delete: return "delete"
        case .transform(let from, let to): return "transform(\(from)->\(to))"
        }
    }
}

/// Test entity type
struct TestEntity: Sendable {
    let id: UUID
    var name: String
}

/// Concrete registry for testing
@MainActor
final class TestRegistry: OperationRegistry<UUID, TestOperation, TestEntity> {
    static let shared = TestRegistry()

    private init() {
        super.init(subsystem: "test", category: "registry")
    }

    func reset() {
        entitiesById.removeAll()
        pendingOperations.removeAll()
    }
}

// MARK: - Tests

@Suite("OperationRegistry Tests")
struct OperationRegistryTests {

    @MainActor
    @Test("Register and unregister entities")
    func registerUnregister() async throws {
        let registry = TestRegistry.shared
        registry.reset()

        let entity = TestEntity(id: UUID(), name: "Test")

        // Register
        registry.register(entity, id: entity.id)
        #expect(registry.entity(withId: entity.id)?.name == "Test")
        #expect(registry.allEntities.count == 1)

        // Unregister
        registry.unregister(id: entity.id)
        #expect(registry.entity(withId: entity.id) == nil)
        #expect(registry.allEntities.isEmpty)
    }

    @MainActor
    @Test("Queue operations increments counter")
    func queueIncrementsCounter() async throws {
        let registry = TestRegistry.shared
        registry.reset()

        let entityId = UUID()
        let initialCounter = registry.operationQueueCounter

        registry.queueOperation(.update(value: "test"), for: entityId)
        #expect(registry.operationQueueCounter == initialCounter + 1)

        registry.queueOperation(.delete, for: entityId)
        #expect(registry.operationQueueCounter == initialCounter + 2)
    }

    @MainActor
    @Test("Pop operations in FIFO order")
    func popFIFO() async throws {
        let registry = TestRegistry.shared
        registry.reset()

        let entityId = UUID()

        registry.queueOperation(.update(value: "first"), for: entityId)
        registry.queueOperation(.update(value: "second"), for: entityId)
        registry.queueOperation(.delete, for: entityId)

        // Pop should return in order
        if case .update(let value) = registry.popOperation(for: entityId) {
            #expect(value == "first")
        } else {
            Issue.record("Expected update operation")
        }

        if case .update(let value) = registry.popOperation(for: entityId) {
            #expect(value == "second")
        } else {
            Issue.record("Expected update operation")
        }

        if case .delete = registry.popOperation(for: entityId) {
            // OK
        } else {
            Issue.record("Expected delete operation")
        }

        // No more operations
        #expect(registry.popOperation(for: entityId) == nil)
    }

    @MainActor
    @Test("Has pending operations")
    func hasPendingOperations() async throws {
        let registry = TestRegistry.shared
        registry.reset()

        let entityId = UUID()

        #expect(!registry.hasPendingOperations(for: entityId))

        registry.queueOperation(.update(value: "test"), for: entityId)
        #expect(registry.hasPendingOperations(for: entityId))

        _ = registry.popOperation(for: entityId)
        #expect(!registry.hasPendingOperations(for: entityId))
    }

    @MainActor
    @Test("Total pending operations count")
    func totalPendingOperations() async throws {
        let registry = TestRegistry.shared
        registry.reset()

        let entity1 = UUID()
        let entity2 = UUID()

        #expect(registry.totalPendingOperations == 0)

        registry.queueOperation(.update(value: "a"), for: entity1)
        registry.queueOperation(.update(value: "b"), for: entity1)
        registry.queueOperation(.delete, for: entity2)

        #expect(registry.totalPendingOperations == 3)

        _ = registry.popOperation(for: entity1)
        #expect(registry.totalPendingOperations == 2)
    }

    @MainActor
    @Test("Unregister clears pending operations")
    func unregisterClearsPending() async throws {
        let registry = TestRegistry.shared
        registry.reset()

        let entityId = UUID()
        let entity = TestEntity(id: entityId, name: "Test")

        registry.register(entity, id: entityId)
        registry.queueOperation(.update(value: "test"), for: entityId)
        registry.queueOperation(.delete, for: entityId)

        #expect(registry.totalPendingOperations == 2)

        registry.unregister(id: entityId)

        #expect(registry.totalPendingOperations == 0)
        #expect(!registry.hasPendingOperations(for: entityId))
    }

    @MainActor
    @Test("Operations for different entities are independent")
    func independentEntityQueues() async throws {
        let registry = TestRegistry.shared
        registry.reset()

        let entity1 = UUID()
        let entity2 = UUID()

        registry.queueOperation(.update(value: "e1-first"), for: entity1)
        registry.queueOperation(.update(value: "e2-first"), for: entity2)
        registry.queueOperation(.update(value: "e1-second"), for: entity1)

        // Pop from entity2 should not affect entity1
        if case .update(let value) = registry.popOperation(for: entity2) {
            #expect(value == "e2-first")
        }

        #expect(registry.hasPendingOperations(for: entity1))
        #expect(!registry.hasPendingOperations(for: entity2))

        // entity1 still has its operations in order
        if case .update(let value) = registry.popOperation(for: entity1) {
            #expect(value == "e1-first")
        }
        if case .update(let value) = registry.popOperation(for: entity1) {
            #expect(value == "e1-second")
        }
    }

    @MainActor
    @Test("Entities with pending operations list")
    func entitiesWithPendingOperationsList() async throws {
        let registry = TestRegistry.shared
        registry.reset()

        let entity1 = UUID()
        let entity2 = UUID()
        let entity3 = UUID()

        registry.queueOperation(.update(value: "a"), for: entity1)
        registry.queueOperation(.delete, for: entity3)

        let pending = registry.entitiesWithPendingOperations
        #expect(pending.contains(entity1))
        #expect(!pending.contains(entity2))
        #expect(pending.contains(entity3))
        #expect(pending.count == 2)
    }
}
