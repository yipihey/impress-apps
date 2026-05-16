//
//  ImpressProgressTests.swift
//  ImpressProgressTests
//

import XCTest
@testable import ImpressProgress

final class ImpressProgressTests: XCTestCase {

    func testMilestoneCreation() throws {
        let milestone = Milestone(
            type: .papersRead,
            value: 100,
            message: "100 papers read"
        )

        XCTAssertEqual(milestone.type, .papersRead)
        XCTAssertEqual(milestone.value, 100)
        XCTAssertEqual(milestone.message, "100 papers read")
    }

    func testDailyActivityCreation() throws {
        let activity = DailyActivity(papersRead: 5, readingMinutes: 120, annotationsMade: 3)

        XCTAssertEqual(activity.papersRead, 5)
        XCTAssertEqual(activity.readingMinutes, 120)
        XCTAssertEqual(activity.annotationsMade, 3)
    }

    func testProgressSummaryDefaults() throws {
        let summary = ProgressSummary()

        XCTAssertEqual(summary.currentStreak, 0)
        XCTAssertEqual(summary.longestStreak, 0)
        XCTAssertEqual(summary.totalPapersRead, 0)
        XCTAssertEqual(summary.papersThisWeek, 0)
        XCTAssertEqual(summary.papersThisMonth, 0)
        XCTAssertTrue(summary.recentMilestones.isEmpty)
    }

    func testMilestoneTypeRawValues() throws {
        XCTAssertEqual(MilestoneType.papersRead.rawValue, "papersRead")
        XCTAssertEqual(MilestoneType.readingStreak.rawValue, "readingStreak")
        XCTAssertEqual(MilestoneType.writingMilestone.rawValue, "writingMilestone")
        XCTAssertEqual(MilestoneType.annotationsMade.rawValue, "annotationsMade")
        XCTAssertEqual(MilestoneType.citationsAdded.rawValue, "citationsAdded")
    }
}
