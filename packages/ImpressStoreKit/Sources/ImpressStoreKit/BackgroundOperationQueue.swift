//
//  BackgroundOperationQueue.swift
//  ImpressStoreKit
//
//  A single prioritized, deduped queue for all background work that
//  touches the store — feed refreshes, enrichment, SciX sync, tag cache
//  refreshes, and so on. Replaces the ad-hoc per-service Task / actor
//  pattern that was the root cause of several recent performance
//  regressions (parallel group-feed refreshes, tag-refresh pile-ups,
//  thundering-herd scheduled refreshes).
//
//  ## Semantics
//
//  - **Dedup by key**: a second submission of an operation with the same
//    non-nil `dedupeKey` while the first is still in-flight (or still
//    queued) is dropped. This is the structural fix for the double
//    group-feed-refresh bug.
//
//  - **Priority scheduling**: ready operations are popped in priority
//    order (`.userInitiated` > `.background` > `.idle`). A newly
//    submitted user-initiated operation jumps ahead of background work
//    that hasn't started yet.
//
//  - **Concurrency limits**: up to `maxConcurrentWrites` write ops and
//    `maxConcurrentReads` read ops may be in flight simultaneously.
//    Defaults are tuned to match the Rust `READER_POOL_SIZE`.
//
//  - **Startup grace**: `.background` and `.idle` operations are
//    refused for the first 90 seconds after the queue starts, to stop
//    scheduled work from racing the UI-settling phase. User-initiated
//    operations bypass the grace period.
//
//  - **Visibility**: `inFlight` reports the currently running operations
//    for a debug overlay / console view.
//

import Foundation
import ImpressLogging

// MARK: - Operation kind

/// Whether an operation reads or writes the store, and whether it also
/// performs network I/O. The queue uses this to decide how many can run
/// at once.
public enum OperationKind: Sendable, Equatable {
    case read
    case write
    /// Read or write that also performs slow network I/O (feed fetches,
    /// enrichment calls). Treated like `.read` for concurrency but
    /// counted separately for reporting.
    case network
}

// MARK: - Operation priority

public enum OperationPriority: Int, Sendable, Comparable {
    /// Work triggered by a user action in the current session (manual
    /// refresh, typing a tag, opening a paper). Runs immediately,
    /// bypassing the startup grace period.
    case userInitiated = 300
    /// Scheduled background work (auto-refresh feeds, scheduled
    /// enrichment). Waits out the startup grace period.
    case background = 200
    /// Best-effort cleanup, dedup, telemetry. Only runs when nothing
    /// else is queued.
    case idle = 100

    public static func < (lhs: OperationPriority, rhs: OperationPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - BackgroundOperation

/// A unit of store-touching work submitted to `BackgroundOperationQueue`.
public struct BackgroundOperation: Sendable {

    /// Stable identifier — used for cancellation + visibility reporting.
    public let id: UUID

    /// Whether the operation reads or writes.
    public let kind: OperationKind

    /// Priority of the operation.
    public let priority: OperationPriority

    /// Optional dedupe key. If a live (queued or running) operation
    /// shares this key, the new submission is dropped. Typical values:
    /// `"refresh-feed-<feed-uuid>"`, `"tag-cache-refresh"`,
    /// `"enrich-library-<library-uuid>"`. A `nil` key means never dedupe.
    public let dedupeKey: String?

    /// Human-readable label for logs and the debug overlay.
    public let label: String

    /// The async work. Receives the queue reference so nested operations
    /// can be scheduled if necessary.
    public let work: @Sendable (BackgroundOperationQueue) async throws -> Void

    public init(
        id: UUID = UUID(),
        kind: OperationKind,
        priority: OperationPriority = .background,
        dedupeKey: String? = nil,
        label: String,
        work: @escaping @Sendable (BackgroundOperationQueue) async throws -> Void
    ) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.dedupeKey = dedupeKey
        self.label = label
        self.work = work
    }
}

// MARK: - Submission result

public enum SubmissionResult: Sendable, Equatable {
    /// The operation was accepted and queued (or is already running).
    case accepted(UUID)
    /// The operation was dropped because an operation with the same
    /// `dedupeKey` is already live.
    case deduped(existing: UUID)
    /// The operation was refused because the queue is in startup grace
    /// and the operation is not `.userInitiated`.
    case refusedStartupGrace
}

// MARK: - Await result

/// Outcome of `submitAndAwait`. Mirrors `SubmissionResult` but carries
/// a value on the success path.
public enum AwaitResult<T: Sendable>: Sendable {
    case completed(T)
    case deduped(existing: UUID)
    case refusedStartupGrace

    /// Convenience: returns the value on `.completed`, `nil` otherwise.
    public var value: T? {
        if case .completed(let v) = self { return v }
        return nil
    }
}

// MARK: - Operation summary (for visibility)

public struct OperationSummary: Sendable, Equatable {
    public let id: UUID
    public let kind: OperationKind
    public let priority: OperationPriority
    public let label: String
    public let dedupeKey: String?
    public let state: State
    public let submittedAt: Date
    public let startedAt: Date?

    public enum State: Sendable, Equatable {
        case queued
        case running
    }
}

// MARK: - Queue

/// Single prioritized, deduped queue for all background store work.
///
/// The queue runs as an actor so submission is `async`. Internally it
/// maintains a priority-ordered list of pending operations plus a map
/// of currently-running operations. A single worker task loops over the
/// pending list, spawning child tasks for each operation it pulls off.
public actor BackgroundOperationQueue {

    // MARK: - Shared instance

    public static let shared = BackgroundOperationQueue()

    // MARK: - Configuration

    public var maxConcurrentWrites: Int = 1
    public var maxConcurrentReads: Int = 4
    public var startupGraceSeconds: TimeInterval = 90

    // MARK: - Internal state

    private struct PendingEntry {
        let op: BackgroundOperation
        let submittedAt: Date
    }

    private struct RunningEntry {
        let op: BackgroundOperation
        let submittedAt: Date
        let startedAt: Date
        let task: Task<Void, Never>
    }

    private var pending: [PendingEntry] = []
    private var running: [UUID: RunningEntry] = [:]
    private var liveKeys: [String: UUID] = [:]

    private let startedAt: Date
    private var wakeContinuations: [CheckedContinuation<Void, Never>] = []

    public init() {
        self.startedAt = Date()
        // Kick off the worker loop. It lives for the process lifetime.
        Task { await self.workerLoop() }
    }

    // MARK: - Submit + await

    /// Submit an operation that returns a value and await its result.
    ///
    /// - If accepted: runs the work and returns `.completed(value)`.
    /// - If deduped: returns `.deduped(existingID)` immediately; the
    ///   work closure does NOT run.
    /// - If refused (startup grace): returns `.refusedStartupGrace`.
    /// - If the work throws: the error propagates to the caller.
    public nonisolated func submitAndAwait<T: Sendable>(
        kind: OperationKind,
        priority: OperationPriority = .userInitiated,
        dedupeKey: String? = nil,
        label: String,
        work: @escaping @Sendable (BackgroundOperationQueue) async throws -> T
    ) async throws -> AwaitResult<T> {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AwaitResult<T>, Error>) in
            Task {
                let op = BackgroundOperation(
                    kind: kind,
                    priority: priority,
                    dedupeKey: dedupeKey,
                    label: label
                ) { _ in
                    do {
                        let value = try await work(Self.shared)
                        cont.resume(returning: .completed(value))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }

                let result = await self.submit(op)
                switch result {
                case .accepted:
                    // Continuation will be resolved from inside op's closure
                    // when the worker runs it. Nothing to do here.
                    return
                case .deduped(let existing):
                    cont.resume(returning: .deduped(existing: existing))
                case .refusedStartupGrace:
                    cont.resume(returning: .refusedStartupGrace)
                }
            }
        }
    }

    // MARK: - Submission

    /// Submit an operation to the queue. Non-blocking — the operation
    /// runs asynchronously after this call returns.
    @discardableResult
    public func submit(_ op: BackgroundOperation) -> SubmissionResult {
        // Dedup first — if a matching key is live, drop the new one.
        if let key = op.dedupeKey, let existingID = liveKeys[key] {
            Logger.storeKit.debug(
                "[OpQueue] dedup: dropping \(op.label) (\(op.id)); already live as \(existingID) [key=\(key)]"
            )
            return .deduped(existing: existingID)
        }

        // Startup grace — non-user-initiated work is refused until the
        // grace period elapses.
        if op.priority != .userInitiated {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < startupGraceSeconds {
                Logger.storeKit.debug(
                    "[OpQueue] startup grace: refusing \(op.label) (\(Int(self.startupGraceSeconds - elapsed))s left)"
                )
                return .refusedStartupGrace
            }
        }

        pending.append(PendingEntry(op: op, submittedAt: Date()))
        if let key = op.dedupeKey {
            liveKeys[key] = op.id
        }
        wakeWorker()
        return .accepted(op.id)
    }

    // MARK: - Cancellation

    /// Cancel a queued or running operation by id. Running operations
    /// receive a cooperative cancellation; queued operations are removed
    /// from the pending list. No-op if the id is unknown.
    public func cancel(_ id: UUID) {
        if let idx = pending.firstIndex(where: { $0.op.id == id }) {
            let entry = pending.remove(at: idx)
            if let key = entry.op.dedupeKey {
                liveKeys.removeValue(forKey: key)
            }
            return
        }
        if let entry = running[id] {
            entry.task.cancel()
        }
    }

    // MARK: - Visibility

    public var inFlight: [OperationSummary] {
        let runningSummaries = running.values.map {
            OperationSummary(
                id: $0.op.id,
                kind: $0.op.kind,
                priority: $0.op.priority,
                label: $0.op.label,
                dedupeKey: $0.op.dedupeKey,
                state: .running,
                submittedAt: $0.submittedAt,
                startedAt: $0.startedAt
            )
        }
        let pendingSummaries = pending.map {
            OperationSummary(
                id: $0.op.id,
                kind: $0.op.kind,
                priority: $0.op.priority,
                label: $0.op.label,
                dedupeKey: $0.op.dedupeKey,
                state: .queued,
                submittedAt: $0.submittedAt,
                startedAt: nil
            )
        }
        return runningSummaries + pendingSummaries
    }

    public var runningCount: Int { running.count }
    public var queuedCount: Int { pending.count }

    // MARK: - Worker

    private func wakeWorker() {
        for cont in wakeContinuations {
            cont.resume()
        }
        wakeContinuations.removeAll()
    }

    private func waitForWork() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wakeContinuations.append(cont)
        }
    }

    private func workerLoop() async {
        while true {
            // Drain as many pending operations as capacity allows.
            while let op = popReadyOperation() {
                startOperation(op)
            }
            // Sleep until a new op arrives or a running op completes.
            await waitForWork()
        }
    }

    private func popReadyOperation() -> BackgroundOperation? {
        guard !pending.isEmpty else { return nil }

        // Count capacity by kind.
        let runningWrites = running.values.filter { $0.op.kind == .write }.count
        let runningReads = running.values.filter { $0.op.kind != .write }.count
        let writesAvailable = runningWrites < maxConcurrentWrites
        let readsAvailable = runningReads < maxConcurrentReads

        // Highest-priority first; within same priority, FIFO by submission order.
        let sortedIndices = pending.indices.sorted { lhs, rhs in
            if pending[lhs].op.priority != pending[rhs].op.priority {
                return pending[lhs].op.priority > pending[rhs].op.priority
            }
            return pending[lhs].submittedAt < pending[rhs].submittedAt
        }

        for idx in sortedIndices {
            let op = pending[idx].op
            let fits = (op.kind == .write && writesAvailable) ||
                       (op.kind != .write && readsAvailable)
            if fits {
                let entry = pending.remove(at: idx)
                return entry.op
            }
        }
        return nil
    }

    private func startOperation(_ op: BackgroundOperation) {
        let startedAt = Date()
        Logger.storeKit.debug("[OpQueue] start: \(op.label) [\(op.id)]")

        let task = Task.detached(priority: taskPriority(for: op.priority)) { [weak self] in
            defer { Task { await self?.finishOperation(id: op.id) } }
            do {
                try await op.work(Self.shared)
                Logger.storeKit.debug("[OpQueue] done: \(op.label) [\(op.id)]")
            } catch is CancellationError {
                Logger.storeKit.debug("[OpQueue] cancelled: \(op.label) [\(op.id)]")
            } catch {
                Logger.storeKit.error("[OpQueue] failed: \(op.label) [\(op.id)]: \(String(describing: error))")
            }
        }

        // Submission timestamp is not tracked past this point; we pass a
        // placeholder because RunningEntry needs it for visibility.
        running[op.id] = RunningEntry(
            op: op,
            submittedAt: startedAt,
            startedAt: startedAt,
            task: task
        )
    }

    private func finishOperation(id: UUID) {
        guard let entry = running.removeValue(forKey: id) else { return }
        if let key = entry.op.dedupeKey, liveKeys[key] == id {
            liveKeys.removeValue(forKey: key)
        }
        wakeWorker()
    }

    private func taskPriority(for p: OperationPriority) -> TaskPriority {
        switch p {
        case .userInitiated: return .userInitiated
        case .background:    return .utility
        case .idle:          return .background
        }
    }
}

// MARK: - Logger helper

import OSLog

private extension Logger {
    static let storeKit = Logger(subsystem: "com.impress.storekit", category: "queue")
}
