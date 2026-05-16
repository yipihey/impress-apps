//
//  ImpressPresenceTests.swift
//  ImpressPresenceTests
//

import XCTest
@testable import ImpressPresence

final class ImpressPresenceTests: XCTestCase {

    func testPresenceInfoInitials() throws {
        let presence = PresenceInfo(
            id: "test-1",
            userName: "Alice Smith"
        )
        XCTAssertEqual(presence.initials, "AS")

        let singleName = PresenceInfo(
            id: "test-2",
            userName: "Bob"
        )
        XCTAssertEqual(singleName.initials, "BO")
    }

    func testPresenceIsActive() throws {
        let recentPresence = PresenceInfo(
            id: "test-1",
            userName: "Alice",
            lastUpdated: Date()
        )
        XCTAssertTrue(recentPresence.isActive)

        let stalePresence = PresenceInfo(
            id: "test-2",
            userName: "Bob",
            lastUpdated: Date().addingTimeInterval(-600) // 10 minutes ago
        )
        XCTAssertFalse(stalePresence.isActive)
    }

    func testActivityDescription() throws {
        let reading = PresenceInfo.Activity.reading(itemId: "p1", itemTitle: "Test Paper")
        XCTAssertEqual(reading.description, "Reading \"Test Paper\"")

        let editing = PresenceInfo.Activity.editing(itemId: "d1", itemTitle: "Draft")
        XCTAssertEqual(editing.description, "Editing \"Draft\"")

        let browsing = PresenceInfo.Activity.browsing(location: "Library")
        XCTAssertEqual(browsing.description, "Browsing Library")

        let idle = PresenceInfo.Activity.idle
        XCTAssertEqual(idle.description, "Online")
    }
}
