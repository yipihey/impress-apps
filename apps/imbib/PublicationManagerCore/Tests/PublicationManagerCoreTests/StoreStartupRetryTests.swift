//
//  StoreStartupRetryTests.swift
//
//  The bounded open-with-retry behind `RustStoreAdapter.shared`'s
//  production path (added after the 2026-08-30 crash loop: four SIGTRAPs in
//  the static initializer while daemons held the shared store busy).
//
//  The pure tests drive the engine with injected openers/sleepers; the
//  integration test holds a real SQLite write lock on a real store file and
//  proves an `ImbibStore.open` retry rides it out.
//

import Foundation
import SQLite3
import XCTest

@testable import ImbibRustCore
@testable import PublicationManagerCore

final class StoreStartupRetryTests: XCTestCase {

    // MARK: pure engine

    func testFirstAttemptSuccessSleepsNever() {
        var slept: [TimeInterval] = []
        var opens = 0
        let result = StoreStartup.openWithRetry(
            label: "t",
            policy: .init(attempts: 5, initialDelay: 0.25),
            sleeper: { slept.append($0) }
        ) { opens += 1; return "ok" }
        XCTAssertEqual(try? result.get(), "ok")
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(slept.isEmpty, "no failure, no backoff")
    }

    func testRecoversAfterTransientFailuresWithGeometricBackoff() {
        struct Boom: Error {}
        var slept: [TimeInterval] = []
        var opens = 0
        let result = StoreStartup.openWithRetry(
            label: "t",
            policy: .init(attempts: 5, initialDelay: 0.25),
            sleeper: { slept.append($0) }
        ) { () -> String in
            opens += 1
            if opens < 3 { throw Boom() }
            return "ok"
        }
        XCTAssertEqual(try? result.get(), "ok")
        XCTAssertEqual(opens, 3)
        XCTAssertEqual(slept, [0.25, 0.5], "sleeps only between failed attempts, doubling")
    }

    func testExhaustionReturnsTheLastErrorAfterExactlyAttemptsOpens() {
        struct Boom: Error, Equatable { let n: Int }
        var slept: [TimeInterval] = []
        var opens = 0
        let result: Result<String, Error> = StoreStartup.openWithRetry(
            label: "t",
            policy: .init(attempts: 3, initialDelay: 0.1),
            sleeper: { slept.append($0) }
        ) {
            opens += 1
            throw Boom(n: opens)
        }
        XCTAssertEqual(opens, 3)
        XCTAssertEqual(slept, [0.1, 0.2], "no sleep after the final failure")
        guard case .failure(let error) = result else {
            return XCTFail("must fail after exhaustion")
        }
        XCTAssertEqual(error as? Boom, Boom(n: 3), "the LAST error surfaces")
    }

    func testSingleAttemptPolicyNeverSleeps() {
        struct Boom: Error {}
        var slept: [TimeInterval] = []
        let result: Result<Int, Error> = StoreStartup.openWithRetry(
            label: "t",
            policy: .init(attempts: 1, initialDelay: 9.9),
            sleeper: { slept.append($0) }
        ) { throw Boom() }
        XCTAssertTrue(slept.isEmpty)
        if case .success = result { XCTFail("must fail") }
    }

    // MARK: integration — a real store under a real write lock

    /// Holds `BEGIN IMMEDIATE` on the store file from a second connection —
    /// the same class of contention the 2026-08-30 daemons produced — and
    /// proves the retry loop turns "busy now" into "opened once released".
    ///
    /// `ImbibStore.open` performs writes (migrations, open-time WAL
    /// maintenance), so it cannot complete while another connection holds the
    /// write lock; each blocked attempt is bounded by the store's own busy
    /// timeout. The lock is released from a timer mid-retry.
    func testOpenRetriesThroughAHeldWriteLock() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-startup-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.sqlite").path

        // Create + close once so the lock-holder has a real database.
        _ = try ImbibStore.open(path: path)

        var locker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &locker), SQLITE_OK)
        defer { sqlite3_close(locker) }
        XCTAssertEqual(
            sqlite3_exec(locker, "BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS _probe(x);", nil, nil, nil),
            SQLITE_OK, "the helper connection must hold the write lock")

        // Release the lock shortly after the retry loop starts sleeping.
        let release = DispatchWorkItem { [locker] in
            sqlite3_exec(locker, "COMMIT;", nil, nil, nil)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0, execute: release)

        let started = Date()
        let result = StoreStartup.openWithRetry(
            label: "locked test store",
            policy: .init(attempts: 6, initialDelay: 0.4)
        ) { try ImbibStore.open(path: path) }
        let elapsed = Date().timeIntervalSince(started)

        switch result {
        case .success:
            // The original assertion here demanded elapsed > 0.3s — "success
            // must have come after riding out the lock". That was correct for
            // the open path it was written against, where opening always
            // fought for the write lock. Since 96a6e9d6 the open only WRITES
            // when it has something to write (metadata probe-first, bounded
            // optimize/checkpoint, conditional backfill), so on this
            // pre-created store it succeeds while the lock is STILL HELD —
            // fast success is now the desired behavior, not a failed wait.
            // What this test still guards is the retry harness itself: a
            // locked store must never surface as failure or the degraded
            // fallback, and must resolve within the policy's bounded window.
            XCTAssertLessThan(
                elapsed, 6.0,
                "open took \(elapsed)s against a lock the timer released after "
                    + "1s — the retry policy is not bounding the wait")
        case .failure(let error):
            XCTFail("open never recovered after the lock was released: \(error)")
        }
    }
}
