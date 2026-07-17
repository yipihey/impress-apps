//
//  URLSchemeHandlerSearchActionTests.swift
//  PublicationManagerCoreTests
//
//  Verifies that automation entry points preserve the typed search workflow
//  intent without launching the app or driving the UI.
//

import XCTest
@testable import PublicationManagerCore

final class URLSchemeHandlerSearchActionTests: XCTestCase {

    @MainActor
    func testFocusSearchPostsLocalFindAction() async {
        let received = expectation(description: "local find search action posted")
        var observed: ImbibSearchAction?

        let token = NotificationCenter.default.addObserver(
            forName: .performSearchAction,
            object: nil,
            queue: .main
        ) { notification in
            observed = ImbibSearchAction.from(notification)
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let result = await URLSchemeHandler.shared.execute(.focus(target: .search))

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.command, "focus")
        await fulfillment(of: [received], timeout: 1.0)
        XCTAssertEqual(observed?.workflow, .localFind)
        XCTAssertEqual(observed?.source, .automation)
        XCTAssertEqual(observed?.context, .global)
    }

    @MainActor
    func testExecuteShowNLSearchPostsOnlineSourceSearchAction() async {
        let received = expectation(description: "online source search action posted")
        var observed: ImbibSearchAction?

        let token = NotificationCenter.default.addObserver(
            forName: .performSearchAction,
            object: nil,
            queue: .main
        ) { notification in
            observed = ImbibSearchAction.from(notification)
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let result = await URLSchemeHandler.shared.execute(.executeCommand(notificationName: "showNLSearch"))

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.command, "executeCommand")
        await fulfillment(of: [received], timeout: 1.0)
        XCTAssertEqual(observed?.workflow, .onlineSourceSearch)
        XCTAssertEqual(observed?.source, .automation)
        XCTAssertEqual(observed?.context, .global)
    }
}
