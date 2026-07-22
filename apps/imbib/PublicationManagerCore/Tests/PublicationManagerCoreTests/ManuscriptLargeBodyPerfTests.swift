//
//  ManuscriptLargeBodyPerfTests.swift
//  PublicationManagerCoreTests
//
//  A perf gate on the manuscript SAVE hot path with a realistically large body
//  (~2 MB). The editor debounces a compare-and-set save on every edit; if the
//  save (payload write + body_content_hash) ever degrades to super-linear, a
//  big manuscript would stutter on every keystroke. This test times the CAS
//  save against a generous budget so a pathological regression fails loudly,
//  while normal machine-to-machine variance doesn't flake it.
//
//  Runs against ImbibStore on a temp file (the real save path the adapter's
//  setManuscriptBody uses), so it's deterministic and headless.
//

import XCTest
import ImbibRustCore
@testable import PublicationManagerCore

final class ManuscriptLargeBodyPerfTests: XCTestCase {

    /// Generous ceiling: a single ~2 MB CAS save must stay well under this.
    /// Catches O(n²) regressions (which would be seconds), not micro-latency.
    private let saveBudgetSeconds: Double = 2.0

    func testLargeBodyCASSaveIsWithinBudget() throws {
        let dbPath = NSTemporaryDirectory() + "manuscript-perf-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = try ImbibStore.open(path: dbPath)
        let manuscript = try store.createManuscript(
            title: "Large", format: "typst", body: "", authors: [])

        // ~2 MB of realistic Typst-ish source.
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)
        var body = "= A Large Manuscript\n\n"
        body.reserveCapacity(2_100_000)
        var section = 0
        while body.utf8.count < 2_000_000 {
            section += 1
            body += "== Section \(section)\n\n\(paragraph)\n\n"
        }
        XCTAssertGreaterThan(body.utf8.count, 2_000_000, "Body should be ~2 MB")

        // First save (unconditional) — establishes the stored hash.
        let first = try store.setManuscriptBody(id: manuscript.id, body: body, expectedHash: nil)
        XCTAssertTrue(first.applied)

        // The guarded (compare-and-set) save is the per-edit hot path. Time it.
        let editedBody = body + "\n\n== Appended\n\nOne more paragraph."
        let start = ProcessInfo.processInfo.systemUptime
        let outcome = try store.setManuscriptBody(
            id: manuscript.id, body: editedBody, expectedHash: first.newHash)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertTrue(outcome.applied, "CAS save with the correct expected hash must apply")
        XCTAssertLessThan(
            elapsed, saveBudgetSeconds,
            "2 MB CAS save took \(String(format: "%.3f", elapsed))s, over the \(saveBudgetSeconds)s budget"
        )

        // Sanity: the round-trip read returns the full large body intact.
        let detail = try XCTUnwrap(store.getManuscriptDetail(id: manuscript.id))
        XCTAssertEqual(detail.bodyContent.utf8.count, editedBody.utf8.count)
    }
}
