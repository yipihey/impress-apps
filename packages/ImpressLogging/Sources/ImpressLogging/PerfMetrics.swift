//
//  PerfMetrics.swift
//  ImpressLogging
//
//  Named-operation performance metrics for the impress suite.
//
//  Where `StoreTimings` answers "how much time do store calls cost, and how
//  much of it is on the main thread", `PerfMetrics` generalizes that to any
//  named operation ("compile", "render", "search", "snapshot", "http", …).
//  For each bucket it tracks count, min/max/mean, p50/p95, main-thread share,
//  and an optional per-bucket time budget. When a sample blows its budget the
//  breach is counted and surfaced as a `warning`-level log in the in-app
//  Console the user already watches — bottlenecks flag themselves.
//
//  Design goals (mirrors StoreTimings):
//    * Callable from ANY thread with near-zero overhead (one unfair lock).
//    * Synchronous recording — no Task/queue dispatch on the hot path.
//    * Additive: introduces no behavior, only observation. Nothing depends on
//      it; wrapping a call in `PerfMetrics.shared.measure(...)` is safe to add
//      or remove at any time.
//
//  Optionally mirrors each measurement to an `os_signpost` interval (behind
//  `signpostsEnabled`, off by default) so Instruments traces line up with the
//  Console timeline.
//

import Foundation
import os

// MARK: - Standard bucket names

/// Canonical bucket identifiers. Buckets are just strings — these constants
/// keep call sites consistent so the Console/HTTP views group cleanly.
public enum PerfBucket {
    public static let compile = "compile"
    public static let render = "render"
    public static let search = "search"
    public static let store = "store"
    public static let snapshot = "snapshot"
    public static let http = "http"
}

// MARK: - Per-bucket stat

public struct PerfBucketStat: Sendable, Codable {
    public let name: String
    public var count: Int
    public var totalNanos: UInt64
    public var minNanos: UInt64
    public var maxNanos: UInt64
    public var mainThreadCount: Int
    /// Median (50th percentile) over the retained sample window.
    public var p50Nanos: UInt64
    /// 95th percentile over the retained sample window.
    public var p95Nanos: UInt64
    /// Configured time budget for this bucket, if any.
    public var budgetNanos: UInt64?
    /// Number of samples that exceeded `budgetNanos`.
    public var breachCount: Int

    public var meanNanos: UInt64 { count == 0 ? 0 : totalNanos / UInt64(count) }
    public var meanMillis: Double { Double(meanNanos) / 1_000_000 }
    public var minMillis: Double { Double(minNanos) / 1_000_000 }
    public var maxMillis: Double { Double(maxNanos) / 1_000_000 }
    public var p50Millis: Double { Double(p50Nanos) / 1_000_000 }
    public var p95Millis: Double { Double(p95Nanos) / 1_000_000 }
    public var budgetMillis: Double? { budgetNanos.map { Double($0) / 1_000_000 } }

    public var mainThreadShare: Double {
        count == 0 ? 0 : Double(mainThreadCount) / Double(count)
    }
}

// MARK: - Snapshot

public struct PerfSnapshot: Sendable, Codable {
    public let capturedAt: Date
    public let buckets: [PerfBucketStat]

    /// Buckets that have at least one budget breach, worst first.
    public var breaches: [PerfBucketStat] {
        buckets.filter { $0.breachCount > 0 }
            .sorted { $0.maxNanos > $1.maxNanos }
    }

    /// The single slowest bucket by max sample, if any.
    public var slowestBucket: PerfBucketStat? {
        buckets.max { $0.maxNanos < $1.maxNanos }
    }
}

// MARK: - PerfMetrics singleton

/// Thread-safe named-operation performance collector.
///
/// Typical usage:
/// ```swift
/// let pdf = await PerfMetrics.shared.measureAsync(PerfBucket.compile, detail: "typst") {
///     await compiler.compile(source)
/// }
/// ```
public final class PerfMetrics: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = PerfMetrics()

    // MARK: - Configuration

    /// Master switch. When false, `measure`/`record` are near no-ops.
    public var isEnabled: Bool = true

    /// Emit an `os_signpost` interval per measurement. Off by default; enable
    /// during profiling sessions so Instruments lines up with the Console.
    public var signpostsEnabled: Bool = false

    /// How many recent samples to retain per bucket for percentile math.
    /// Bounded so memory stays flat regardless of call volume.
    public var sampleWindow: Int = 1024

    private let signposter = OSSignposter(
        subsystem: "com.impress", category: "PerfMetrics"
    )

    // MARK: - Internal state (guarded by `state`)

    private struct BucketState {
        var count: Int = 0
        var totalNanos: UInt64 = 0
        var minNanos: UInt64 = .max
        var maxNanos: UInt64 = 0
        var mainThreadCount: Int = 0
        var budgetNanos: UInt64?
        var breachCount: Int = 0
        /// Ring buffer of recent sample durations (nanoseconds).
        var samples: [UInt64] = []
        var sampleHead: Int = 0
    }

    private struct State {
        var buckets: [String: BucketState] = [:]
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    private init() {}

    // MARK: - Budgets

    /// Set (or clear, with `nil`) the time budget for a bucket. Samples that
    /// exceed the budget are counted and logged as warnings to the Console.
    public func setBudget(_ bucket: String, millis: Double?) {
        let nanos = millis.map { UInt64(max(0, $0) * 1_000_000) }
        state.withLock { s in
            var b = s.buckets[bucket] ?? BucketState()
            b.budgetNanos = nanos
            s.buckets[bucket] = b
        }
    }

    /// Convenience: set budgets for several buckets at once.
    public func setBudgets(_ budgets: [String: Double]) {
        for (bucket, millis) in budgets { setBudget(bucket, millis: millis) }
    }

    // MARK: - Measurement API

    /// Measure a synchronous block.
    @inlinable
    public func measure<T>(_ bucket: String, detail: String? = nil, count: Int? = nil, _ body: () -> T) -> T {
        let token = begin(bucket, detail: detail, count: count)
        defer { token.end() }
        return body()
    }

    /// Measure a throwing synchronous block.
    @inlinable
    public func measure<T>(_ bucket: String, detail: String? = nil, count: Int? = nil, _ body: () throws -> T) rethrows -> T {
        let token = begin(bucket, detail: detail, count: count)
        defer { token.end() }
        return try body()
    }

    /// Measure an async block.
    @inlinable
    public func measureAsync<T>(_ bucket: String, detail: String? = nil, count: Int? = nil, _ body: () async -> T) async -> T {
        let token = begin(bucket, detail: detail, count: count)
        let result = await body()
        token.end()
        return result
    }

    /// Measure a throwing async block.
    @inlinable
    public func measureAsync<T>(_ bucket: String, detail: String? = nil, count: Int? = nil, _ body: () async throws -> T) async rethrows -> T {
        let token = begin(bucket, detail: detail, count: count)
        do {
            let result = try await body()
            token.end()
            return result
        } catch {
            token.end()
            throw error
        }
    }

    /// Begin a measurement manually. Call `end()` on the returned token.
    public func begin(_ bucket: String, detail: String? = nil, count: Int? = nil) -> Token {
        let signpostState: OSSignpostIntervalState?
        let signpostID: OSSignpostID?
        if signpostsEnabled {
            let id = signposter.makeSignpostID()
            signpostID = id
            signpostState = signposter.beginInterval("perf", id: id, "\(bucket)")
        } else {
            signpostState = nil
            signpostID = nil
        }
        return Token(
            bucket: bucket,
            detail: detail,
            count: count,
            startNanos: DispatchTime.now().uptimeNanoseconds,
            onMain: Thread.isMainThread,
            signpostID: signpostID,
            signpostState: signpostState,
            owner: self
        )
    }

    // MARK: - Recording

    fileprivate func record(bucket: String, detail: String?, count: Int?, elapsedNanos: UInt64, onMain: Bool) {
        guard isEnabled else { return }
        let window = max(1, sampleWindow)
        let breachedBudgetMillis: Double? = state.withLock { s -> Double? in
            var b = s.buckets[bucket] ?? BucketState()
            b.count += 1
            b.totalNanos &+= elapsedNanos
            if elapsedNanos < b.minNanos { b.minNanos = elapsedNanos }
            if elapsedNanos > b.maxNanos { b.maxNanos = elapsedNanos }
            if onMain { b.mainThreadCount += 1 }

            // Bounded ring buffer of recent samples.
            if b.samples.count < window {
                b.samples.append(elapsedNanos)
            } else {
                b.samples[b.sampleHead] = elapsedNanos
                b.sampleHead = (b.sampleHead + 1) % window
            }

            var breach: Double?
            if let budget = b.budgetNanos, elapsedNanos > budget {
                b.breachCount += 1
                breach = Double(budget) / 1_000_000
            }
            s.buckets[bucket] = b
            return breach
        }

        // Surface budget breaches to the Console (outside the lock). This is a
        // fire-and-forget warning; it never blocks the measured path.
        if let budgetMillis = breachedBudgetMillis {
            let ms = String(format: "%.1f", Double(elapsedNanos) / 1_000_000)
            let budget = String(format: "%.0f", budgetMillis)
            let suffix = detail.map { " (\($0))" } ?? ""
            let items = count.map { " [\($0) items]" } ?? ""
            logWarning("⏱ \(bucket)\(suffix) \(ms)ms > \(budget)ms budget\(items)", category: "performance")
        }
    }

    // MARK: - Snapshot / reset

    /// Percentile of a value set. `p` in 0...1. Uses nearest-rank on a sorted copy.
    private func percentile(_ sorted: [UInt64], _ p: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[min(max(0, rank), sorted.count - 1)]
    }

    /// Capture a point-in-time snapshot of all buckets.
    public func snapshot() -> PerfSnapshot {
        state.withLock { s in
            let buckets: [PerfBucketStat] = s.buckets.map { name, b in
                let sortedSamples = b.samples.sorted()
                return PerfBucketStat(
                    name: name,
                    count: b.count,
                    totalNanos: b.totalNanos,
                    minNanos: b.minNanos == .max ? 0 : b.minNanos,
                    maxNanos: b.maxNanos,
                    mainThreadCount: b.mainThreadCount,
                    p50Nanos: percentile(sortedSamples, 0.5),
                    p95Nanos: percentile(sortedSamples, 0.95),
                    budgetNanos: b.budgetNanos,
                    breachCount: b.breachCount
                )
            }
            .sorted { $0.totalNanos > $1.totalNanos }
            return PerfSnapshot(capturedAt: Date(), buckets: buckets)
        }
    }

    /// Reset all sample data. Budgets are preserved so a reset-then-measure
    /// cycle keeps its configured thresholds.
    public func reset() {
        state.withLock { s in
            for (name, b) in s.buckets {
                var cleared = BucketState()
                cleared.budgetNanos = b.budgetNanos
                s.buckets[name] = cleared
            }
        }
    }

    // MARK: - Token

    public struct Token {
        public let bucket: String
        let detail: String?
        let count: Int?
        let startNanos: UInt64
        let onMain: Bool
        let signpostID: OSSignpostID?
        let signpostState: OSSignpostIntervalState?
        weak var owner: PerfMetrics?

        public func end() {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- startNanos
            if let owner, let signpostID, let signpostState, owner.signpostsEnabled {
                owner.signposter.endInterval("perf", signpostState, "\(bucket)")
                _ = signpostID
            }
            owner?.record(
                bucket: bucket,
                detail: detail,
                count: count,
                elapsedNanos: elapsed,
                onMain: onMain
            )
        }
    }
}
