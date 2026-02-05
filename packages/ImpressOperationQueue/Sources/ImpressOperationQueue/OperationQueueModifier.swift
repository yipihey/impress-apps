//
//  OperationQueueModifier.swift
//  ImpressOperationQueue
//
//  SwiftUI ViewModifier for processing queued operations.
//

import SwiftUI

/// Generic ViewModifier for processing queued operations.
///
/// Usage:
/// ```swift
/// ContentView(document: $document)
///     .operationQueueHandler(
///         registry: DocumentRegistry.shared,
///         entityId: document.id
///     ) { operation in
///         // Handle the operation
///         switch operation {
///         case .updateContent(let source):
///             document.source = source
///         }
///     }
/// ```
public struct OperationQueueModifier<
    EntityID: Hashable & Sendable,
    Operation: QueueableOperation,
    Entity
>: ViewModifier {

    let registry: OperationRegistry<EntityID, Operation, Entity>
    let entityId: EntityID
    let handler: (Operation) -> Void

    public init(
        registry: OperationRegistry<EntityID, Operation, Entity>,
        entityId: EntityID,
        handler: @escaping (Operation) -> Void
    ) {
        self.registry = registry
        self.entityId = entityId
        self.handler = handler
    }

    public func body(content: Content) -> some View {
        content
            .onChange(of: registry.operationQueueCounter) { _, _ in
                processOperations()
            }
            .onAppear {
                processOperations()
            }
    }

    private func processOperations() {
        while let operation = registry.popOperation(for: entityId) {
            handler(operation)
        }
    }
}

// MARK: - View Extension

extension View {
    /// Attach an operation queue handler to this view.
    public func operationQueueHandler<EntityID, Operation, Entity>(
        registry: OperationRegistry<EntityID, Operation, Entity>,
        entityId: EntityID,
        handler: @escaping (Operation) -> Void
    ) -> some View where EntityID: Hashable & Sendable, Operation: QueueableOperation {
        modifier(OperationQueueModifier(
            registry: registry,
            entityId: entityId,
            handler: handler
        ))
    }
}
