//
//  EInkSourceFetcherTests.swift
//  PublicationManagerCoreTests
//
//  The `awaiting_source` worker (ADR-025 P7): at most two downloads at a
//  time, each row attempted once per session unless it changes, and one
//  `sourceArrived` nudge per sweep that produced a file.
//

import Foundation
import XCTest
@testable import PublicationManagerCore

final class EInkSourceFetcherTests: XCTestCase {

    actor Acquisitions {
        private(set) var ids: [UUID] = []
        private(set) var active = 0
        private(set) var maxActive = 0
        var delay: Duration = .milliseconds(60)
        var succeed: Set<UUID> = []

        func begin(_ id: UUID) {
            ids.append(id)
            active += 1
            maxActive = max(maxActive, active)
        }
        func end() { active -= 1 }
        func setSucceed(_ ids: Set<UUID>) { succeed = ids }
    }

    private func makeFetcher(
        rows: @escaping @Sendable () -> [EInkAwaitingSourceRecord],
        acquisitions: Acquisitions,
        arrived: CountBox,
        maxConcurrent: Int = 2,
        notes: CountBox = CountBox()
    ) -> EInkSourceFetcher {
        EInkSourceFetcher(gate: .open, maxConcurrent: maxConcurrent, coalesce: .milliseconds(20), environment: EInkSourceFetchEnvironment(
            isConfigured: { true },
            awaiting: { rows() },
            acquire: { id in
                await acquisitions.begin(id)
                try? await Task.sleep(for: await acquisitions.delay)
                await acquisitions.end()
                return await acquisitions.succeed.contains(id) ? URL(fileURLWithPath: "/tmp/\(id).pdf") : nil
            },
            onSourceArrived: { count in arrived.record("\(count)") },
            noteOutcome: { id, error in notes.record("\(id): \(error ?? "cleared")") },
            observesStore: false
        ))
    }

    func testAtMostTwoDownloadsRunAtOnceAndOneNudgeFollows() async throws {
        let ids = (0..<5).map { _ in UUID() }
        let rows = ids.map { EInkTestSupport.awaiting(publicationId: $0) }
        let acquisitions = Acquisitions()
        await acquisitions.setSucceed(Set(ids.prefix(3)))
        let arrived = CountBox()
        let fetcher = makeFetcher(rows: { rows }, acquisitions: acquisitions, arrived: arrived)

        let count = await fetcher.sweep()

        XCTAssertEqual(count, 3)
        let awaited1 = await acquisitions.ids.count
        XCTAssertEqual(awaited1, 5, "every awaiting row is tried")
        let awaited2 = await acquisitions.maxActive
        XCTAssertEqual(awaited2, 2, "never more than two downloads in flight")
        XCTAssertEqual(arrived.lines, ["3"], "one nudge per sweep that produced files")
    }

    func testARowIsAttemptedOncePerSessionUnlessItChanges() async throws {
        let id = UUID()
        let acquisitions = Acquisitions()
        let arrived = CountBox()
        let rowBox = RowBox([EInkTestSupport.awaiting(publicationId: id, mirrorId: "m-1")])
        let fetcher = makeFetcher(rows: { rowBox.rows }, acquisitions: acquisitions, arrived: arrived)

        _ = await fetcher.sweep()
        _ = await fetcher.sweep()
        let awaited3 = await acquisitions.ids.count
        XCTAssertEqual(awaited3, 1, "an unchanged row is not retried")
        XCTAssertTrue(arrived.lines.isEmpty, "nothing arrived, nothing nudged")

        // The row gains a DOI: it is worth another try.
        rowBox.rows = [EInkTestSupport.awaiting(publicationId: id, mirrorId: "m-1", doi: "10.1/abc")]
        _ = await fetcher.sweep()
        let awaited4 = await acquisitions.ids.count
        XCTAssertEqual(awaited4, 2)

        await fetcher.resetAttempts()
        _ = await fetcher.sweep()
        let awaited5 = await acquisitions.ids.count
        XCTAssertEqual(awaited5, 3, "a reset forgets the session's attempts")
    }

    func testNudgesInsideTheWindowAreOneSweep() async throws {
        let id = UUID()
        let acquisitions = Acquisitions()
        // One row, built once: a fresh mirror id per call would read as "the row changed".
        let row = EInkTestSupport.awaiting(publicationId: id)
        // Not started: `start()` adds the launch sweep, which is not what this test measures.
        let fetcher = makeFetcher(rows: { [row] }, acquisitions: acquisitions, arrived: CountBox())

        for _ in 0..<4 { await fetcher.nudge() }
        _ = try await EInkTestSupport.waitUntil { await fetcher.sweepCount >= 1 }
        try await Task.sleep(for: .milliseconds(150))

        let awaited6 = await fetcher.sweepCount
        XCTAssertEqual(awaited6, 1, "four nudges inside one window are one sweep")
        let awaited7 = await acquisitions.ids
        XCTAssertEqual(awaited7, [id])
    }

    func testNudgesBeforeTheGateOpensAreIgnoredAndTheLaunchSweepCovers() async throws {
        let id = UUID()
        let acquisitions = Acquisitions()
        let row = EInkTestSupport.awaiting(publicationId: id)
        let fetcher = EInkSourceFetcher(gate: EInkStartupGate(interval: 0.2), coalesce: .milliseconds(20), environment: EInkSourceFetchEnvironment(
            isConfigured: { true },
            awaiting: { [row] },
            acquire: { id in
                await acquisitions.begin(id)
                await acquisitions.end()
                return nil
            },
            onSourceArrived: { _ in },
            observesStore: false
        ))
        await fetcher.start()
        await fetcher.nudge()
        let awaited8 = await fetcher.sweepCount
        XCTAssertEqual(awaited8, 0, "nothing runs inside the gate")

        let swept = try await EInkTestSupport.waitUntil { await acquisitions.ids.count == 1 }
        XCTAssertTrue(swept, "the launch sweep runs once the gate opens")
        let awaited9 = await fetcher.sweepCount
        XCTAssertEqual(awaited9, 1)
        await fetcher.stop()
    }

    final class RowBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [EInkAwaitingSourceRecord]
        init(_ rows: [EInkAwaitingSourceRecord]) { storage = rows }
        var rows: [EInkAwaitingSourceRecord] {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); defer { lock.unlock() }; storage = newValue }
        }
    }

    /// A row that cannot be fetched must say why on itself: only the app can
    /// download, and the log line is gone by the time anybody looks.
    func testEveryAttemptIsRecordedOnTheRowWhetherItWorkedOrNot() async throws {
        let found = UUID()
        let missing = UUID()
        let rows = [found, missing].map { EInkTestSupport.awaiting(publicationId: $0) }
        let acquisitions = Acquisitions()
        await acquisitions.setSucceed([found])
        let notes = CountBox()
        let fetcher = makeFetcher(
            rows: { rows }, acquisitions: acquisitions, arrived: CountBox(), notes: notes)

        let count = await fetcher.sweep()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(notes.lines.count, 2, "one note per attempted row")
        XCTAssertTrue(
            notes.lines.contains("\(found): cleared"),
            "a fetch that worked clears the old reason, got \(notes.lines)")
        let failure = notes.lines.first { $0.hasPrefix("\(missing):") } ?? ""
        XCTAssertTrue(
            failure.contains("No PDF could be found"),
            "the row carries a reason a researcher can act on, got \(failure)")
    }
}
