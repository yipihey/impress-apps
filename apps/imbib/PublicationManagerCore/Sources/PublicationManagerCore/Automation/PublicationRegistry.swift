//
//  PublicationRegistry.swift
//  PublicationManagerCore
//
//  Registry for tracking pending publication operations.
//  Uses the shared ImpressOperationQueue infrastructure.
//

import Foundation
import ImpressOperationQueue

/// Empty entity type for publications since Core Data objects shouldn't be cached.
/// The registry only tracks operations by UUID; actual publication lookups go through
/// PublicationRepository.
public struct PublicationRef: Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

/// Registry for tracking pending publication automation operations.
/// Extends the generic OperationRegistry with imbib-specific functionality.
///
/// Note: Unlike imprint's DocumentRegistry, we don't cache full entities here
/// because CDPublication objects are Core Data managed objects that should be
/// fetched through PublicationRepository. This registry only tracks operations.
@MainActor
public final class PublicationRegistry: OperationRegistry<UUID, PublicationOperation, PublicationRef> {
    public static let shared = PublicationRegistry()

    private init() {
        super.init(subsystem: "com.imbib.imbib", category: "registry")
    }

    /// Queue an operation for a publication by its UUID.
    public func queueOperation(_ operation: PublicationOperation, forPublicationID id: UUID) {
        queueOperation(operation, for: id)
    }

    /// Pop the next pending operation for a publication.
    public func popOperation(forPublicationID id: UUID) -> PublicationOperation? {
        popOperation(for: id)
    }

    /// Check if there are pending operations for a publication.
    public func hasPendingOperations(forPublicationID id: UUID) -> Bool {
        hasPendingOperations(for: id)
    }
}
