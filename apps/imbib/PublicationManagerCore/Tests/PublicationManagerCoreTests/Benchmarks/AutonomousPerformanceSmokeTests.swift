//
//  AutonomousPerformanceSmokeTests.swift
//  PublicationManagerCoreTests
//
//  Coarse, deterministic guards for catastrophic regressions. These are not
//  microbenchmarks; keep serious measurements in Criterion/Instruments.
//

import XCTest
@testable import PublicationManagerCore

final class AutonomousPerformanceSmokeTests: XCTestCase {
    private static let bibTeXThousandEntryBudgetSeconds = 5.0

    func testBibTeXParserThousandEntriesStayUnderCatastrophicRegressionBudget() throws {
        let parser = BibTeXParserFactory.createParser()
        let content = BibTeXBenchmark.generateEntries(count: 1_000)

        let warmupEntries = try parser.parseEntries(content)
        XCTAssertEqual(warmupEntries.count, 1_000)

        let start = CFAbsoluteTimeGetCurrent()
        let entries = try parser.parseEntries(content)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(entries.count, 1_000)
        XCTAssertLessThan(
            elapsed,
            Self.bibTeXThousandEntryBudgetSeconds,
            """
            BibTeX parsing crossed the autonomous smoke-test budget.
            This budget is intentionally loose and should only fail for catastrophic regressions.
            Elapsed: \(String(format: "%.3f", elapsed))s
            Budget: \(Self.bibTeXThousandEntryBudgetSeconds)s
            """
        )
    }
}
