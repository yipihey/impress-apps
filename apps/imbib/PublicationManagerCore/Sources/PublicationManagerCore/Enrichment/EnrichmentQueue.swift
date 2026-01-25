//
//  EnrichmentQueue.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - Enrichment Queue

/// Priority queue for managing enrichment requests.
///
/// Requests are processed in priority order (lower rawValue = higher priority).
/// Within the same priority level, requests are processed FIFO.
///
/// ## Features
///
/// - Priority-based ordering
/// - Deduplication by publication ID
/// - Maximum queue size limit
/// - Thread-safe via actor isolation
///
/// ## Usage
///
/// ```swift
/// let queue = EnrichmentQueue(maxSize: 100)
/// await queue.enqueue(request)
/// if let next = await queue.dequeue() {
///     // Process request
/// }
/// ```
public actor EnrichmentQueue {

    // MARK: - Configuration

    /// Maximum number of requests in the queue.
    public let maxSize: Int

    // MARK: - State

    /// Pending requests, grouped by priority.
    private var requestsByPriority: [EnrichmentPriority: [EnrichmentRequest]] = [:]

    /// Set of publication IDs currently in queue (for deduplication).
    private var queuedPublicationIDs: Set<UUID> = []

    // MARK: - Initialization

    /// Create a queue with the specified maximum size.
    ///
    /// - Parameter maxSize: Maximum number of requests (default: 500)
    public init(maxSize: Int = 500) {
        self.maxSize = maxSize

        // Initialize all priority levels
        for priority in EnrichmentPriority.allCases {
            requestsByPriority[priority] = []
        }
    }

    // MARK: - Queue Operations

    /// Add a request to the queue.
    ///
    /// - Parameter request: The enrichment request to queue
    /// - Returns: `true` if the request was added, `false` if rejected (duplicate or full)
    @discardableResult
    public func enqueue(_ request: EnrichmentRequest) -> Bool {
        // Check for duplicate
        guard !queuedPublicationIDs.contains(request.publicationID) else {
            Logger.enrichment.debug("EnrichmentQueue: skipping duplicate \(request.publicationID)")
            return false
        }

        // Check queue size
        guard count < maxSize else {
            Logger.enrichment.warning("EnrichmentQueue: queue full, rejecting \(request.publicationID)")
            return false
        }

        // Add to appropriate priority bucket
        requestsByPriority[request.priority, default: []].append(request)
        queuedPublicationIDs.insert(request.publicationID)

        Logger.enrichment.debug("EnrichmentQueue: enqueued \(request.publicationID) with priority \(request.priority.description)")
        return true
    }

    /// Remove and return the highest priority request.
    ///
    /// - Returns: The next request to process, or `nil` if queue is empty
    public func dequeue() -> EnrichmentRequest? {
        // Process in priority order (lower rawValue = higher priority)
        for priority in EnrichmentPriority.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            if var requests = requestsByPriority[priority], !requests.isEmpty {
                let request = requests.removeFirst()
                requestsByPriority[priority] = requests
                queuedPublicationIDs.remove(request.publicationID)
                return request
            }
        }
        return nil
    }

    /// Peek at the next request without removing it.
    ///
    /// - Returns: The next request, or `nil` if queue is empty
    public func peek() -> EnrichmentRequest? {
        for priority in EnrichmentPriority.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let requests = requestsByPriority[priority], let first = requests.first {
                return first
            }
        }
        return nil
    }

    /// Check if a publication is already queued.
    ///
    /// - Parameter publicationID: The publication ID to check
    /// - Returns: `true` if the publication is in the queue
    public func contains(publicationID: UUID) -> Bool {
        queuedPublicationIDs.contains(publicationID)
    }

    /// Remove a specific publication from the queue.
    ///
    /// - Parameter publicationID: The publication ID to remove
    /// - Returns: `true` if the publication was found and removed
    @discardableResult
    public func remove(publicationID: UUID) -> Bool {
        guard queuedPublicationIDs.contains(publicationID) else {
            return false
        }

        for priority in EnrichmentPriority.allCases {
            if var requests = requestsByPriority[priority] {
                if let index = requests.firstIndex(where: { $0.publicationID == publicationID }) {
                    requests.remove(at: index)
                    requestsByPriority[priority] = requests
                    queuedPublicationIDs.remove(publicationID)
                    return true
                }
            }
        }
        return false
    }

    /// Upgrade priority of an existing request.
    ///
    /// If the publication is already queued at a lower priority, moves it to higher priority.
    ///
    /// - Parameters:
    ///   - publicationID: The publication ID to upgrade
    ///   - newPriority: The new (higher) priority
    /// - Returns: `true` if the request was upgraded
    @discardableResult
    public func upgradePriority(publicationID: UUID, to newPriority: EnrichmentPriority) -> Bool {
        // Find existing request
        for priority in EnrichmentPriority.allCases {
            if var requests = requestsByPriority[priority] {
                if let index = requests.firstIndex(where: { $0.publicationID == publicationID }) {
                    // Only upgrade if new priority is higher (lower rawValue)
                    guard newPriority.rawValue < priority.rawValue else {
                        return false
                    }

                    // Remove from old priority
                    let request = requests.remove(at: index)
                    requestsByPriority[priority] = requests

                    // Create new request with upgraded priority
                    let upgraded = EnrichmentRequest(
                        publicationID: request.publicationID,
                        identifiers: request.identifiers,
                        priority: newPriority
                    )

                    // Add to new priority
                    requestsByPriority[newPriority, default: []].append(upgraded)
                    return true
                }
            }
        }
        return false
    }

    /// Clear all requests from the queue.
    public func clear() {
        for priority in EnrichmentPriority.allCases {
            requestsByPriority[priority] = []
        }
        queuedPublicationIDs.removeAll()
        Logger.enrichment.debug("EnrichmentQueue: cleared")
    }

    // MARK: - Queue Statistics

    /// Total number of requests in the queue.
    public var count: Int {
        requestsByPriority.values.reduce(0) { $0 + $1.count }
    }

    /// Check if the queue is empty.
    public var isEmpty: Bool {
        count == 0
    }

    /// Check if the queue is full.
    public var isFull: Bool {
        count >= maxSize
    }

    /// Number of requests at each priority level.
    public var countsByPriority: [EnrichmentPriority: Int] {
        requestsByPriority.mapValues { $0.count }
    }

    /// All queued publication IDs.
    public var allPublicationIDs: Set<UUID> {
        queuedPublicationIDs
    }
}

// MARK: - Batch Operations

public extension EnrichmentQueue {

    /// Enqueue multiple requests at once.
    ///
    /// - Parameter requests: Requests to enqueue
    /// - Returns: Number of requests successfully added
    @discardableResult
    func enqueue(_ requests: [EnrichmentRequest]) -> Int {
        var added = 0
        for request in requests {
            if enqueue(request) {
                added += 1
            }
        }
        return added
    }

    /// Dequeue multiple requests at once.
    ///
    /// - Parameter count: Maximum number of requests to dequeue
    /// - Returns: Array of dequeued requests (may be fewer than requested)
    func dequeue(count: Int) -> [EnrichmentRequest] {
        var results: [EnrichmentRequest] = []
        for _ in 0..<count {
            guard let request = dequeue() else { break }
            results.append(request)
        }
        return results
    }
}
