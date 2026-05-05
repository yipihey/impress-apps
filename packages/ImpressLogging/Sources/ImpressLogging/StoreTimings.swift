//
//  StoreTimings.swift
//  ImpressLogging
//
//  Thread-safe instrumentation for counting store calls across the impress
//  suite. Used as the baseline measurement for the multi-phase responsiveness
//  rework. Every call into `RustStoreAdapter` (and, later, `ImpressStore`)
//  records a single measurement: the caller, the elapsed time, and whether
//  the call happened on the main thread.
//
//  This file owns zero behavior. It only observes.
//
//  Invariants verified by the overall rework:
//    1. `mainThreadCalls` goes to 0 in steady state.
//    2. `slowestMainThreadCall` shrinks after each phase.
//    3. `totalCalls` distribution shifts from main → background.
//

import Foundation
import os

// MARK: - Per-caller stat

public struct StoreTimingsCallerStat: Sendable, Codable {
    public let caller: String
    public var count: Int
    public var totalNanos: UInt64
    public var maxNanos: UInt64
    public var mainThreadCount: Int

    public var meanNanos: UInt64 {
        count == 0 ? 0 : totalNanos / UInt64(count)
    }

    public var meanMillis: Double {
        Double(meanNanos) / 1_000_000
    }

    public var maxMillis: Double {
        Double(maxNanos) / 1_000_000
    }
}

// MARK: - Snapshot

public struct StoreTimingsSnapshot: Sendable, Codable {
    public let capturedAt: Date
    public let totalCalls: Int
    public let mainThreadCalls: Int
    public let backgroundCalls: Int
    public let totalMainThreadNanos: UInt64
    public let slowestMainThreadCaller: String
    public let slowestMainThreadNanos: UInt64
    public let topCallers: [StoreTimingsCallerStat]

    public var mainThreadShare: Double {
        totalCalls == 0 ? 0 : Double(mainThreadCalls) / Double(totalCalls)
    }

    public var totalMainThreadMillis: Double {
        Double(totalMainThreadNanos) / 1_000_000
    }

    public var slowestMainThreadMillis: Double {
        Double(slowestMainThreadNanos) / 1_000_000
    }
}

// MARK: - StoreTimings singleton

/// Thread-safe store call counter.
///
/// Designed to be called from *any* thread (including the main thread)
/// with near-zero overhead: a single `OSAllocatedUnfairLock` guards a
/// small in-memory dictionary. All recording is synchronous; there is
/// no Task or queue dispatch.
///
/// Typical usage from a store adapter method:
/// ```swift
/// public func countUnread(parentId: UUID?) -> Int {
///     let token = StoreTimings.shared.begin(caller: #function)
///     defer { token.end() }
///     return Int((try? store.countUnread(parentId: parentId?.uuidString)) ?? 0)
/// }
/// ```
///
/// Or in the convenience form:
/// ```swift
/// return StoreTimings.shared.measure(#function) {
///     Int((try? store.countUnread(parentId: parentId?.uuidString)) ?? 0)
/// }
/// ```
public final class StoreTimings: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = StoreTimings()

    // MARK: - Internal state (guarded by `state`)

    private struct State {
        var totalCalls: Int = 0
        var mainThreadCalls: Int = 0
        var backgroundCalls: Int = 0
        var totalMainThreadNanos: UInt64 = 0
        var slowestMainThreadCaller: String = ""
        var slowestMainThreadNanos: UInt64 = 0
        var byCaller: [String: StoreTimingsCallerStat] = [:]
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    public var isEnabled: Bool = true

    private init() {}

    // MARK: - Measurement API

    /// Measure a synchronous call. Recommended form.
    @inlinable
    public func measure<T>(_ caller: String = #function, _ body: () -> T) -> T {
        let token = begin(caller: caller)
        defer { token.end() }
        return body()
    }

    /// Measure a throwing synchronous call.
    @inlinable
    public func measure<T>(_ caller: String = #function, _ body: () throws -> T) rethrows -> T {
        let token = begin(caller: caller)
        defer { token.end() }
        return try body()
    }

    /// Begin a measurement manually. Call `end()` on the returned token.
    public func begin(caller: String) -> Token {
        Token(
            caller: caller,
            startNanos: DispatchTime.now().uptimeNanoseconds,
            onMain: Thread.isMainThread,
            owner: self
        )
    }

    // MARK: - Recording

    fileprivate func record(caller: String, elapsedNanos: UInt64, onMain: Bool) {
        guard isEnabled else { return }
        state.withLock { s in
            s.totalCalls += 1
            if onMain {
                s.mainThreadCalls += 1
                s.totalMainThreadNanos &+= elapsedNanos
                if elapsedNanos > s.slowestMainThreadNanos {
                    s.slowestMainThreadNanos = elapsedNanos
                    s.slowestMainThreadCaller = caller
                }
            } else {
                s.backgroundCalls += 1
            }
            var entry = s.byCaller[caller] ?? StoreTimingsCallerStat(
                caller: caller,
                count: 0,
                totalNanos: 0,
                maxNanos: 0,
                mainThreadCount: 0
            )
            entry.count += 1
            entry.totalNanos &+= elapsedNanos
            if elapsedNanos > entry.maxNanos { entry.maxNanos = elapsedNanos }
            if onMain { entry.mainThreadCount += 1 }
            s.byCaller[caller] = entry
        }
    }

    // MARK: - Snapshot / reset

    /// Capture a point-in-time snapshot of the counters.
    /// - Parameter topCallerCount: how many callers to include in `topCallers`,
    ///   sorted by total time spent on the main thread.
    public func snapshot(topCallerCount: Int = 20) -> StoreTimingsSnapshot {
        state.withLock { s in
            let top = s.byCaller.values
                .sorted { $0.totalNanos > $1.totalNanos }
                .prefix(topCallerCount)
                .map { $0 }
            return StoreTimingsSnapshot(
                capturedAt: Date(),
                totalCalls: s.totalCalls,
                mainThreadCalls: s.mainThreadCalls,
                backgroundCalls: s.backgroundCalls,
                totalMainThreadNanos: s.totalMainThreadNanos,
                slowestMainThreadCaller: s.slowestMainThreadCaller,
                slowestMainThreadNanos: s.slowestMainThreadNanos,
                topCallers: Array(top)
            )
        }
    }

    /// Reset all counters. Useful to measure a specific interaction in isolation.
    public func reset() {
        state.withLock { s in
            s = State()
        }
    }

    // MARK: - Token

    public struct Token {
        public let caller: String
        let startNanos: UInt64
        let onMain: Bool
        weak var owner: StoreTimings?

        public func end() {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- startNanos
            owner?.record(caller: caller, elapsedNanos: elapsed, onMain: onMain)
        }
    }
}
