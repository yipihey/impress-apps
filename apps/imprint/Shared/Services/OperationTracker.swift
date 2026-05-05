//
//  OperationTracker.swift
//  imprint
//
//  Tracks the lifecycle of a document operation queued via the HTTP API.
//  Agents call `POST /api/documents/{id}/insert` and get back an `operationID`
//  which they poll at `GET /api/operations/{id}` to know when the edit has
//  been applied by the editor view.
//
//  The tracker is a small in-memory map keyed by operation UUID. Completed
//  entries are kept for 60 seconds so late pollers get a real result instead
//  of "unknown operation".
//

import Foundation

/// Status of an operation queued via the HTTP API.
public enum OperationStatus: String, Sendable {
    case pending
    case completed
    case failed
}

/// A tracked record for one queued operation.
public struct TrackedOperation: Sendable {
    public let id: UUID
    public let documentID: UUID
    public let kind: String
    public let queuedAt: Date
    public let completedAt: Date?
    public let status: OperationStatus
    public let errorMessage: String?
}

/// Global tracker used by the HTTP router and the automation handler.
/// Thread-safe — both producers (router, view) and consumers (poll endpoint)
/// call into it freely.
public final class OperationTracker: @unchecked Sendable {

    public static let shared = OperationTracker()

    private let lock = NSLock()
    private var entries: [UUID: TrackedOperation] = [:]
    private let retentionWindow: TimeInterval = 60

    private init() {}

    /// Register a newly-queued operation as pending.
    public func registerPending(id: UUID, documentID: UUID, kind: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[id] = TrackedOperation(
            id: id,
            documentID: documentID,
            kind: kind,
            queuedAt: Date(),
            completedAt: nil,
            status: .pending,
            errorMessage: nil
        )
        purgeStale_locked()
    }

    /// Mark an operation as completed. Safe to call from the UI thread after
    /// the automation handler applies the edit.
    public func markCompleted(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = entries[id] else { return }
        entries[id] = TrackedOperation(
            id: existing.id,
            documentID: existing.documentID,
            kind: existing.kind,
            queuedAt: existing.queuedAt,
            completedAt: Date(),
            status: .completed,
            errorMessage: nil
        )
    }

    /// Mark an operation as failed with a short reason.
    public func markFailed(id: UUID, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = entries[id] else { return }
        entries[id] = TrackedOperation(
            id: existing.id,
            documentID: existing.documentID,
            kind: existing.kind,
            queuedAt: existing.queuedAt,
            completedAt: Date(),
            status: .failed,
            errorMessage: reason
        )
    }

    /// Look up an operation by id.
    public func get(id: UUID) -> TrackedOperation? {
        lock.lock()
        defer { lock.unlock() }
        purgeStale_locked()
        return entries[id]
    }

    /// Drop completed entries older than `retentionWindow` seconds.
    private func purgeStale_locked() {
        let cutoff = Date().addingTimeInterval(-retentionWindow)
        entries = entries.filter { _, op in
            guard let completed = op.completedAt else { return true }
            return completed > cutoff
        }
    }
}
