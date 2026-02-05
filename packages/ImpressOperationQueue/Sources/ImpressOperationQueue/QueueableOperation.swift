//
//  QueueableOperation.swift
//  ImpressOperationQueue
//
//  Protocol for operations that can be queued for async processing.
//

import Foundation

/// Protocol for operations that can be queued for async processing.
/// Apps define their own Operation enum conforming to this.
public protocol QueueableOperation: Identifiable, Sendable {
    /// Unique identifier for this operation instance
    var id: UUID { get }

    /// Human-readable description for logging/debugging
    var operationDescription: String { get }
}
