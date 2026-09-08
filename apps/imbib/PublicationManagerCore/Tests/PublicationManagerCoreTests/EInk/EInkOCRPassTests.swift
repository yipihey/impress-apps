//
//  EInkOCRPassTests.swift
//  PublicationManagerCoreTests
//
//  Handwriting recognition over the imported ink (ADR-025 P7): jobs run one
//  at a time, a job with no legible text is still completed (nil text, the
//  confidence kept) so it is never retried forever, and a recogniser
//  failure completes the job empty rather than leaving it pending.
//

import Foundation
import ImbibRustCore
import XCTest
@testable import PublicationManagerCore

final class EInkOCRPassTests: XCTestCase {

    actor Recognitions {
        private(set) var paths: [String] = []
        private(set) var active = 0
        private(set) var maxActive = 0
        func begin(_ path: String) {
            paths.append(path)
            active += 1
            maxActive = max(maxActive, active)
        }
        func end() { active -= 1 }
    }

    @MainActor
    final class Completions {
        var results: [(UUID, String?, Double)] = []
    }

    private func job(publication: UUID = UUID(), page: Int = 1, image: String) -> EInkOCRJob {
        EInkOCRJob(from: EinkOcrJob(
            annotationId: UUID().uuidString, publicationId: publication.uuidString,
            linkedFileId: UUID().uuidString, pageNumber: Int32(page), imagePath: image))!
    }

    func testJobsRunSeriallyAndEmptyTextStillCompletes() async throws {
        let publication = UUID()
        let jobs = [
            job(publication: publication, page: 1, image: "/tmp/ink/legible.png"),
            job(publication: publication, page: 2, image: "/tmp/ink/blank.png"),
            job(publication: publication, page: 3, image: "/tmp/ink/broken.png"),
        ]
        let recognitions = Recognitions()
        let completions = await Completions()
        let pass = EInkOCRPass(gate: .open, environment: EInkOCREnvironment(
            isConfigured: { true },
            pendingJobs: { id in id == nil || id == publication ? jobs : [] },
            recognize: { path in
                await recognitions.begin(path)
                try? await Task.sleep(for: .milliseconds(30))
                await recognitions.end()
                switch path {
                case "/tmp/ink/legible.png": return ("  Reread section 3 ", 0.91)
                case "/tmp/ink/blank.png": return ("   ", 0.12)
                default: throw OCRError.renderingFailed
                }
            },
            complete: { job, text, confidence in
                completions.results.append((job.annotationId, text, confidence))
                return true
            }
        ))

        let done = await pass.run(publicationIds: [publication])

        XCTAssertEqual(done, 3)
        let awaited1 = await recognitions.maxActive
        XCTAssertEqual(awaited1, 1, "one Vision request at a time")
        let results = await completions.results
        XCTAssertEqual(results.map(\.1), ["Reread section 3", nil, nil], "trimmed text; nil when nothing legible")
        XCTAssertEqual(results.map(\.2), [0.91, 0.12, 0.0])
        let awaited2 = await pass.completedCount
        XCTAssertEqual(awaited2, 3)
    }

    func testARunWhileRunningQueuesOneMorePass() async throws {
        let publication = UUID()
        let jobs = [job(publication: publication, image: "/tmp/ink/a.png")]
        let counter = CountBox()
        let pass = EInkOCRPass(gate: .open, environment: EInkOCREnvironment(
            isConfigured: { true },
            pendingJobs: { _ in counter.bump("listed"); return jobs },
            recognize: { _ in
                try? await Task.sleep(for: .milliseconds(80))
                return ("x", 0.5)
            },
            complete: { _, _, _ in true }
        ))

        async let first = pass.run(publicationIds: [publication])
        try await Task.sleep(for: .milliseconds(20))
        let second = await pass.run(publicationIds: [publication])
        let firstDone = await first

        XCTAssertEqual(second, 0, "the overlapping call does not run itself")
        XCTAssertEqual(firstDone, 2, "…but the first pass runs once more for it")
        XCTAssertEqual(counter["listed"], 2)
    }
}
