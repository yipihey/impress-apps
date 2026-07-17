//
//  ImbibSearchActionTests.swift
//  PublicationManagerCoreTests
//

import XCTest
@testable import PublicationManagerCore

final class ImbibSearchActionTests: XCTestCase {

    func testWorkflowMetadataKeepsFlagshipSearchesDistinct() {
        XCTAssertTrue(ImbibSearchWorkflow.localFind.searchesLocalStore)
        XCTAssertFalse(ImbibSearchWorkflow.localFind.usesOnlineSources)
        XCTAssertEqual(ImbibSearchWorkflow.localFind.shortcut, "⌘F")
        XCTAssertEqual(ImbibSearchWorkflow.localFind.presentationID, "global-search-palette")

        XCTAssertFalse(ImbibSearchWorkflow.onlineSourceSearch.searchesLocalStore)
        XCTAssertTrue(ImbibSearchWorkflow.onlineSourceSearch.usesOnlineSources)
        XCTAssertEqual(ImbibSearchWorkflow.onlineSourceSearch.shortcut, "⌘S")
        XCTAssertEqual(ImbibSearchWorkflow.onlineSourceSearch.presentationID, "smart-search-overlay")
    }

    func testActionIdentityIncludesWorkflowAndContext() {
        let libraryID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let paperID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!

        let libraryFind = ImbibSearchAction.localFind(
            context: .library(libraryID, "Library"),
            source: .keyboardShortcut
        )
        let paperFind = ImbibSearchAction.localFind(
            context: .publication(paperID, "Paper"),
            source: .keyboardShortcut
        )

        XCTAssertEqual(libraryFind.id, "localFind:library-\(libraryID.uuidString)")
        XCTAssertEqual(paperFind.id, "localFind:publication-\(paperID.uuidString)")
        XCTAssertNotEqual(libraryFind.id, paperFind.id)
    }

    func testNotificationRoundTripPreservesTypedAction() {
        let paperID = UUID(uuidString: "00000000-0000-0000-0000-000000000333")!
        let action = ImbibSearchAction.localFind(
            context: .pdf(paperID, "PDF"),
            source: .toolbarButton
        )
        let notification = Notification(
            name: .performSearchAction,
            object: action,
            userInfo: ["workflow": action.workflow.rawValue]
        )

        XCTAssertEqual(ImbibSearchAction.from(notification), action)
    }

    func testNotificationFallbackDecodesWorkflowAndSourceFromUserInfo() {
        let notification = Notification(
            name: .performSearchAction,
            object: nil,
            userInfo: [
                "workflow": ImbibSearchWorkflow.onlineSourceSearch.rawValue,
                "source": ImbibSearchActionSource.automation.rawValue
            ]
        )

        let action = ImbibSearchAction.from(notification)
        XCTAssertEqual(action?.workflow, .onlineSourceSearch)
        XCTAssertEqual(action?.source, .automation)
        XCTAssertEqual(action?.context, .global)
    }

    func testCommandRegistrySearchCommandsUseTypedActions() {
        let commands = CommandRegistry.shared.commands
        let localFind = commands.first { $0.id == "globalSearch" }
        let onlineSearch = commands.first { $0.id == "nlSearch" }

        XCTAssertEqual(localFind?.notificationName, .performSearchAction)
        XCTAssertEqual(localFind?.searchAction?.workflow, .localFind)
        XCTAssertEqual(localFind?.searchAction?.source, .commandPalette)

        XCTAssertEqual(onlineSearch?.notificationName, .performSearchAction)
        XCTAssertEqual(onlineSearch?.searchAction?.workflow, .onlineSourceSearch)
        XCTAssertEqual(onlineSearch?.searchAction?.source, .commandPalette)
    }

    func testCommandExecutePostsTypedSearchAction() {
        let expected = ImbibSearchAction.localFind(
            context: .collection(UUID(uuidString: "00000000-0000-0000-0000-000000000444")!, "Collection"),
            source: .commandPalette
        )
        let command = Command(
            id: "testSearchCommand",
            title: "Test Search",
            category: .search,
            notificationName: .performSearchAction,
            searchAction: expected
        )

        let received = expectation(description: "typed search action posted")
        var observed: ImbibSearchAction?
        let token = NotificationCenter.default.addObserver(
            forName: .performSearchAction,
            object: nil,
            queue: nil
        ) { notification in
            observed = ImbibSearchAction.from(notification)
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        command.execute()

        wait(for: [received], timeout: 1.0)
        XCTAssertEqual(observed, expected)
    }
}
