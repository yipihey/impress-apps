import Testing
import Foundation
@testable import ImpressLogging

// Serialized: these tests share the `PerfMetrics.shared` singleton, and
// `reset()` intentionally clears ALL buckets (to measure an interaction in
// isolation, matching StoreTimings). Running them in parallel would let one
// test's reset wipe another's in-flight counters.
@Suite("Perf Metrics", .serialized)
struct PerfMetricsTests {

    /// Each test uses its own bucket name so the shared singleton doesn't
    /// bleed state across tests.
    private func uniqueBucket(_ label: String) -> String {
        "test.\(label).\(UUID().uuidString)"
    }

    @Test("measure records a sample into the named bucket")
    func recordsSample() {
        let bucket = uniqueBucket("record")
        PerfMetrics.shared.measure(bucket) { _ = (0..<1000).reduce(0, +) }
        let snap = PerfMetrics.shared.snapshot()
        let stat = snap.buckets.first { $0.name == bucket }
        #expect(stat != nil)
        #expect(stat?.count == 1)
        #expect((stat?.maxNanos ?? 0) > 0)
    }

    @Test("min/max/mean track across multiple samples")
    func minMaxMean() {
        let bucket = uniqueBucket("minmax")
        for _ in 0..<50 {
            PerfMetrics.shared.measure(bucket) { _ = (0..<100).reduce(0, +) }
        }
        let stat = PerfMetrics.shared.snapshot().buckets.first { $0.name == bucket }
        #expect(stat?.count == 50)
        #expect((stat?.minNanos ?? 0) <= (stat?.maxNanos ?? 0))
        let mean = stat?.meanNanos ?? 0
        #expect(mean >= (stat?.minNanos ?? 0))
        #expect(mean <= (stat?.maxNanos ?? 0))
    }

    @Test("p50 <= p95 over a sample window")
    func percentilesOrdered() {
        let bucket = uniqueBucket("pct")
        for i in 0..<200 {
            // Variable work so the distribution has spread.
            PerfMetrics.shared.measure(bucket) { _ = (0..<(i * 20 + 1)).reduce(0, +) }
        }
        let stat = PerfMetrics.shared.snapshot().buckets.first { $0.name == bucket }
        #expect(stat != nil)
        #expect((stat?.p50Nanos ?? 0) <= (stat?.p95Nanos ?? .max))
        #expect((stat?.p95Nanos ?? 0) <= (stat?.maxNanos ?? .max))
    }

    @Test("budget breach is counted when a sample exceeds the budget")
    func budgetBreachCounted() {
        let bucket = uniqueBucket("budget")
        // Zero budget guarantees any non-trivial work breaches it.
        PerfMetrics.shared.setBudget(bucket, millis: 0)
        PerfMetrics.shared.measure(bucket) {
            Thread.sleep(forTimeInterval: 0.002)
        }
        let stat = PerfMetrics.shared.snapshot().buckets.first { $0.name == bucket }
        #expect((stat?.breachCount ?? 0) >= 1)
        #expect(stat?.budgetMillis == 0)
    }

    @Test("no breach when sample is within a generous budget")
    func noBreachWithinBudget() {
        let bucket = uniqueBucket("nobreach")
        PerfMetrics.shared.setBudget(bucket, millis: 10_000) // 10s budget
        PerfMetrics.shared.measure(bucket) { _ = 1 + 1 }
        let stat = PerfMetrics.shared.snapshot().buckets.first { $0.name == bucket }
        #expect(stat?.breachCount == 0)
    }

    @Test("reset clears samples but preserves budgets")
    func resetPreservesBudget() {
        let bucket = uniqueBucket("reset")
        PerfMetrics.shared.setBudget(bucket, millis: 500)
        PerfMetrics.shared.measure(bucket) { _ = 1 }
        PerfMetrics.shared.reset()
        let stat = PerfMetrics.shared.snapshot().buckets.first { $0.name == bucket }
        // Bucket still exists (budget retained), but counts are zeroed.
        #expect(stat?.count == 0)
        #expect(stat?.budgetMillis == 500)
    }

    @Test("async measurement records a sample")
    func asyncMeasure() async {
        let bucket = uniqueBucket("async")
        await PerfMetrics.shared.measureAsync(bucket) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let stat = PerfMetrics.shared.snapshot().buckets.first { $0.name == bucket }
        #expect(stat?.count == 1)
    }

    @Test("snapshot is Codable for HTTP surfacing")
    func snapshotCodable() throws {
        let bucket = uniqueBucket("codable")
        PerfMetrics.shared.measure(bucket) { _ = 1 }
        let snap = PerfMetrics.shared.snapshot()
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(PerfSnapshot.self, from: data)
        #expect(decoded.buckets.contains { $0.name == bucket })
    }
}
